#!/bin/bash

# Detiene o arranca una app de pm2 desde webhook-central-ui.
# Uso: ./power.sh <stop|start> <id-de-apps.json> <token>
# Responde JSON. Valida TODO contra apps.json y .power_token: nunca ejecuta
# un nombre que no venga de apps.json.

ACTION="$1"
APP_ID="$2"
TOKEN="$3"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
TOKEN_FILE="$ROOT/.power_token"
LOG_FILE="$ROOT/logs/power.jsonl"

# Apps que NO se pueden apagar desde la UI (quien recibe el botón / el listener)
PROTECTED="webhook-listener webhook-central-ui"

fail() {
    echo "{\"ok\":false,\"error\":\"$1\"}"
    exit 1
}

[ -r "$TOKEN_FILE" ] || fail "Token no configurado en el server"
[ -n "$TOKEN" ] && [ "$TOKEN" = "$(cat "$TOKEN_FILE")" ] || fail "Token inválido"
[ "$ACTION" = "stop" ] || [ "$ACTION" = "start" ] || fail "Acción inválida"

PM2_NAME=$(python3 - "$ROOT/apps.json" "$APP_ID" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1])):
    if a.get("id") == sys.argv[2]:
        print(a.get("pm2_name") or "")
        break
PY
)

[ -n "$PM2_NAME" ] || fail "App sin pm2_name o no registrada"
for p in $PROTECTED; do
    [ "$PM2_NAME" = "$p" ] && fail "App protegida: se maneja solo por terminal"
done

if [ "$ACTION" = "stop" ]; then
    OUT=$(pm2 stop "$PM2_NAME" 2>&1)
else
    OUT=$(pm2 restart "$PM2_NAME" 2>&1)
fi
RC=$?

mkdir -p "$ROOT/logs"
printf '{"ts":"%s","action":"%s","id":"%s","pm2_name":"%s","ok":%s}\n' \
    "$(date -u +%FT%TZ)" "$ACTION" "$APP_ID" "$PM2_NAME" "$([ $RC -eq 0 ] && echo true || echo false)" >> "$LOG_FILE"

[ $RC -eq 0 ] || fail "pm2 falló al ejecutar $ACTION"
echo "{\"ok\":true,\"action\":\"$ACTION\",\"pm2_name\":\"$PM2_NAME\"}"
