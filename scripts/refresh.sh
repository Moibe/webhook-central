#!/bin/bash

# Refresca los datos de una instancia DEV con una copia de los de su PROD
# (botón "Refrescar con datos de prod" de webhook-central-ui).
#
# Uso (lo llama el hook):  ./refresh.sh <id-dev> <token>
#   Valida el token (.power_token, el mismo de apagar/encender), el .conf y que la
#   app tenga env "dev" en apps.json; lanza el trabajo desacoplado y responde
#   enseguida un JSON con el id de la corrida. El avance se sigue como un deploy:
#   eventos started/finished con "kind":"refresh" en logs/deploys.jsonl y el
#   detalle en logs/<id-dev>/<corrida>.log.
#
# El .conf de la app dev declara:
#   REFRESH_FROM  carpeta del checkout de prod (de ahí se leen su .env y sus datos)
#   REFRESH_DATA  "VARIABLE:default ..." con las rutas de datos tal como la app las
#                 lee de su .env (relativas a la carpeta de cada checkout)
#
# Garantías:
#   - prod SOLO se lee (las SQLite con la API de backup: copia consistente aunque
#     prod esté escribiendo);
#   - aborta si una ruta de dev resuelve a la misma de prod o queda fuera de dev;
#   - lo que había en dev se MUEVE a ~/respaldos-refresco/<id>/<fecha>/dev-anterior
#     (se conservan las 3 corridas más recientes);
#   - si falla a medio cambio, regresa lo de dev y vuelve a levantar la API;
#   - mientras corre, toma también el candado de deploy de la app.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOKEN_FILE="$ROOT/.power_token"
APPS_FILE="$ROOT/apps.json"
LOG_DIR="$ROOT/logs"
DEPLOYS_JSONL="$LOG_DIR/deploys.jsonl"
RESPALDOS_BASE="${REFRESH_BACKUP_DIR:-$HOME/respaldos-refresco}"
CONSERVAR=3
AYUDANTE="$SCRIPT_DIR/refresh_datos.py"

responder() {
    # $1 ok (true|false); $2 mensaje de error; el resto va como pares clave=valor
    python3 - "$@" <<'PY'
import json, sys
ok, error, *pares = sys.argv[1:]
out = {"ok": ok == "true"}
if error:
    out["error"] = error
for par in pares:
    k, _, v = par.partition("=")
    out[k] = v
print(json.dumps(out, ensure_ascii=False))
PY
}

fail() {
    responder false "$1"
    exit 1
}

pid_vivo() {
    [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null
}

cargar_conf() {
    [[ "$APP_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "Id de app inválido"
    CONFIG_FILE="$ROOT/projects/${APP_ID}.conf"
    [ -f "$CONFIG_FILE" ] || fail "No existe projects/${APP_ID}.conf"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    for var in PROJECT_ROOT PM2_NAME REFRESH_FROM REFRESH_DATA; do
        [ -n "${!var}" ] || fail "Variable $var no definida en ${APP_ID}.conf"
    done
    ENV_APP=$(python3 - "$APPS_FILE" "$APP_ID" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1], encoding="utf-8")):
    if a.get("id") == sys.argv[2]:
        print(a.get("env") or "")
        break
PY
)
    [ "$ENV_APP" = "dev" ] || fail "Solo se refrescan apps con env \"dev\" en apps.json (${APP_ID}: \"${ENV_APP:-sin env}\")"
    REFRESH_LOCK="/tmp/refresh-${APP_ID}.lock"
    DEPLOY_LOCK="/tmp/deploy-${APP_ID}.lock"
}

# ─── Modo hook: validar y lanzar ──────────────────────────────────────────────
if [ "$1" != "--ejecutar" ]; then
    APP_ID="$1"
    TOKEN="$2"
    [ -r "$TOKEN_FILE" ] || fail "Token no configurado en el server"
    [ -n "$TOKEN" ] && [ "$TOKEN" = "$(cat "$TOKEN_FILE")" ] || fail "Token inválido"
    cargar_conf
    pid_vivo "$REFRESH_LOCK" && fail "Ya hay un refresco de ${APP_ID} en curso"
    pid_vivo "$DEPLOY_LOCK" && fail "Hay un despliegue de ${APP_ID} en curso; espera a que termine"
    # Saludo con el hijo: los candados llevan nuestro PID hasta que el hijo
    # compruebe que somos su padre y ponga el suyo. Así no hay hueco entre dos
    # clics y no dependemos de qué PID devuelva $! con setsid.
    echo "$$" > "$REFRESH_LOCK"
    echo "$$" > "$DEPLOY_LOCK"
    RUN_ID="$(date +%s)-$$"
    # Desacoplado: el hook responde ya y el trabajo sigue aunque se cierre el
    # navegador o se reinicie el listener.
    setsid nohup "$0" --ejecutar "$APP_ID" "$RUN_ID" "$$" </dev/null >/dev/null 2>&1 &
    for _ in {1..30}; do
        [ "$(cat "$REFRESH_LOCK" 2>/dev/null)" != "$$" ] && break
        sleep 0.1
    done
    if [ "$(cat "$REFRESH_LOCK" 2>/dev/null)" = "$$" ]; then
        rm -f "$REFRESH_LOCK"
        [ "$(cat "$DEPLOY_LOCK" 2>/dev/null)" = "$$" ] && rm -f "$DEPLOY_LOCK"
        fail "El refresco no arrancó (revisa que scripts/refresh.sh sea ejecutable)"
    fi
    responder true "" "iniciado=true" "run_id=$RUN_ID" "log_file=${APP_ID}/${RUN_ID}.log"
    exit 0
fi

# ─── Modo --ejecutar: el trabajo de verdad ────────────────────────────────────
APP_ID="$2"
RUN_ID="$3"
PADRE="$4"
cargar_conf
[ -n "$PADRE" ] && [ "$(cat "$REFRESH_LOCK" 2>/dev/null)" = "$PADRE" ] || exit 1
echo "$$" > "$REFRESH_LOCK"
echo "$$" > "$DEPLOY_LOCK"

RUN_TS="$(date -u +%Y%m%d-%H%M%S)"
TRABAJO="$RESPALDOS_BASE/$APP_ID/$RUN_TS"
PLAN_FILE="$TRABAJO/plan.json"
LOG_REL="${APP_ID}/${RUN_ID}.log"
LOG_FILE="$LOG_DIR/$LOG_REL"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$DEPLOYS_JSONL"

START_TS=$(date +%s)
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CURRENT_STEP="setup"
ERROR_MSG=""
RESUMEN=""
API_DETENIDA=0
API_ARRANCADA=0

emit_event() {
    RUN_ID="$RUN_ID" APP_ID="$APP_ID" STARTED_AT="$STARTED_AT" PROJECT_BRANCH="$PROJECT_BRANCH" \
    APP_STACK="${APP_STACK:-python}" LOG_REL="$LOG_REL" EVENT="$1" ENDED_AT="${ENDED_AT:-}" \
    DURATION_S="${DURATION_S:-0}" STATUS="${STATUS:-}" EXIT_CODE_VAL="${EXIT_CODE_VAL:-0}" \
    FAILED_STEP="${FAILED_STEP:-}" ERROR_TAIL="${ERROR_TAIL:-}" ERROR_MSG="$ERROR_MSG" \
    RESUMEN="$RESUMEN" RESPALDO="${RESPALDO:-}" REFRESH_FROM="$REFRESH_FROM" \
    python3 -c '
import json, os
e = os.environ
rec = {"id": e["RUN_ID"], "app": e["APP_ID"], "event": e["EVENT"], "kind": "refresh",
       "started_at": e["STARTED_AT"], "branch": e.get("PROJECT_BRANCH", ""), "stack": e.get("APP_STACK", ""),
       "log_file": e["LOG_REL"], "from": e.get("REFRESH_FROM", "")}
if e["EVENT"] == "finished":
    rec.update({"ended_at": e.get("ENDED_AT", ""), "duration_s": int(e.get("DURATION_S") or 0),
                "status": e.get("STATUS", ""), "exit_code": int(e.get("EXIT_CODE_VAL") or 0),
                "failed_step": e.get("FAILED_STEP", ""), "error": e.get("ERROR_MSG", ""),
                "error_tail": e.get("ERROR_TAIL", ""), "resumen": e.get("RESUMEN", ""),
                "respaldo": e.get("RESPALDO", "")})
print(json.dumps(rec, ensure_ascii=False))
' >> "$DEPLOYS_JSONL"
}

error_de() {
    printf '%s' "$1" | python3 -c '
import json, sys
try:
    print(json.loads(sys.stdin.read().strip().splitlines()[-1]).get("error", ""))
except Exception:
    print("")
'
}

finalizar() {
    local code=$?
    if [ "$API_DETENIDA" = "1" ] && [ "$API_ARRANCADA" = "0" ]; then
        echo "♻️  Volviendo a levantar $PM2_NAME tras el fallo…"
        pm2 restart "$PM2_NAME" || echo "⚠️  No se pudo levantar $PM2_NAME: revísalo con pm2"
    fi
    DURATION_S=$(( $(date +%s) - START_TS ))
    ENDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    EXIT_CODE_VAL=$code
    if [ "$code" -eq 0 ]; then
        STATUS="success"
        FAILED_STEP=""
        ERROR_TAIL=""
        echo "✅ Refresco de $APP_ID terminado en ${DURATION_S}s"
    else
        STATUS="failed"
        FAILED_STEP="$CURRENT_STEP"
        [ -n "$ERROR_MSG" ] || ERROR_MSG="Falló en el paso $CURRENT_STEP"
        echo "❌ $ERROR_MSG"
        ERROR_TAIL=$(tail -n 30 "$LOG_FILE" 2>/dev/null)
    fi
    rm -rf "$TRABAJO/nuevo" "$PLAN_FILE"
    if [ -d "$TRABAJO/dev-anterior" ]; then
        RESPALDO="$TRABAJO/dev-anterior"
    else
        rm -rf "$TRABAJO"
        RESPALDO=""
    fi
    emit_event "finished"
    [ "$(cat "$REFRESH_LOCK" 2>/dev/null)" = "$$" ] && rm -f "$REFRESH_LOCK"
    [ "$(cat "$DEPLOY_LOCK" 2>/dev/null)" = "$$" ] && rm -f "$DEPLOY_LOCK"
}
trap finalizar EXIT

emit_event "started"
exec >>"$LOG_FILE" 2>&1

echo "============================================================"
echo "🔄 Refresco de datos de $APP_ID"
echo "📤 Desde (prod): $REFRESH_FROM"
echo "📥 Hacia (dev):  $PROJECT_ROOT"
echo "🗂️  Datos: $REFRESH_DATA"
echo "🆔 Corrida: $RUN_ID   ⏰ $(date)"
echo "============================================================"

estado_pm2() {
    pm2 jlist 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    print("desconocido 0"); sys.exit()
for p in data:
    if p.get("name") == sys.argv[1]:
        env = p.get("pm2_env", {})
        print(env.get("status", "desconocido"), env.get("restart_time", 0))
        break
else:
    print("ausente 0")
' "$PM2_NAME"
}

CURRENT_STEP="preparar"
echo "📦 Paso 1/5: copiando lo de prod a $TRABAJO/nuevo (prod solo se lee)…"
SALIDA=$(python3 "$AYUDANTE" preparar --dev "$PROJECT_ROOT" --prod "$REFRESH_FROM" \
    --datos "$REFRESH_DATA" --trabajo "$TRABAJO") || { ERROR_MSG=$(error_de "$SALIDA"); exit 1; }
RESUMEN=$(printf '%s' "$SALIDA" | python3 -c 'import json, sys; print(json.loads(sys.stdin.read()).get("resumen", ""))')
echo "   $RESUMEN"

CURRENT_STEP="detener"
echo "⏸️  Paso 2/5: deteniendo $PM2_NAME…"
pm2 stop "$PM2_NAME" || { ERROR_MSG="pm2 no pudo detener $PM2_NAME"; exit 1; }
API_DETENIDA=1

CURRENT_STEP="cambiar"
echo "🔁 Paso 3/5: lo de dev va al respaldo y lo de prod a su lugar…"
SALIDA=$(python3 "$AYUDANTE" cambiar --plan "$PLAN_FILE") || { ERROR_MSG=$(error_de "$SALIDA"); exit 1; }

CURRENT_STEP="arrancar"
echo "▶️  Paso 4/5: levantando $PM2_NAME…"
pm2 restart "$PM2_NAME" || { ERROR_MSG="pm2 no pudo levantar $PM2_NAME"; exit 1; }
API_ARRANCADA=1

CURRENT_STEP="verificar"
echo "🩺 Paso 5/5: comprobando que $PM2_NAME se queda en línea…"
sleep 3
read -r EST1 REIN1 <<< "$(estado_pm2)"
sleep 4
read -r EST2 REIN2 <<< "$(estado_pm2)"
echo "   estado: $EST1 → $EST2, reinicios: $REIN1 → $REIN2"
if [ "$EST2" != "online" ] || [ "$REIN1" != "$REIN2" ]; then
    ERROR_MSG="La API dev no se quedó en línea (estado $EST2, reinicios $REIN1→$REIN2). Los datos ya son los de prod; revisa pm2 logs $PM2_NAME."
    exit 1
fi

CURRENT_STEP="podar"
python3 "$AYUDANTE" podar --base "$RESPALDOS_BASE/$APP_ID" --conservar "$CONSERVAR" >/dev/null \
    || echo "⚠️  No se pudieron borrar respaldos viejos (no es grave)"

CURRENT_STEP="done"
exit 0
