#!/bin/bash

# Script genérico de despliegue para múltiples proyectos
# Uso: ./deploy.sh <proyecto>
# Ejemplo: ./deploy.sh mide-chatbot

PROJECT_NAME="$1"

if [ -z "$PROJECT_NAME" ]; then
    echo "❌ Error: Proyecto no especificado"
    echo "Uso: $0 <proyecto>"
    exit 1
fi

# Cargar configuración del proyecto
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../projects/${PROJECT_NAME}.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Error: Archivo de configuración no encontrado: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Stack de la app (python por defecto para mantener compatibilidad)
APP_STACK="${APP_STACK:-python}"

if [ "$APP_STACK" != "python" ] && [ "$APP_STACK" != "svelte" ]; then
    echo "❌ Error: APP_STACK no soportado: $APP_STACK"
    echo "Valores permitidos: python, svelte"
    exit 1
fi

# Validar variables requeridas
for var in PROJECT_ROOT PROJECT_BRANCH PM2_NAME; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: Variable $var no definida en $CONFIG_FILE"
        exit 1
    fi
done

if [ "$APP_STACK" = "python" ] && [ -z "$VENV_PATH" ]; then
    echo "❌ Error: Variable VENV_PATH no definida en $CONFIG_FILE para APP_STACK=python"
    exit 1
fi

# LOCK FILE: evitar deploys simultáneos del mismo proyecto
LOCK_FILE="/tmp/deploy-${PROJECT_NAME}.lock"

if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE")
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "❌ Error: Ya hay un despliegue de $PROJECT_NAME en ejecución (PID: $LOCK_PID)"
        echo "Intenta nuevamente después de que termine el despliegue actual"
        exit 1
    else
        # PID viejo, limpiar lock file
        rm -f "$LOCK_FILE"
    fi
fi

# Crear lock file
echo "$$" > "$LOCK_FILE"

# === Logging estructurado ===
LOG_DIR="$SCRIPT_DIR/../logs"
DEPLOY_ID="$(date +%s)-$$"
DEPLOY_LOG_REL="${PROJECT_NAME}/${DEPLOY_ID}.log"
DEPLOY_LOG="$LOG_DIR/$DEPLOY_LOG_REL"
DEPLOYS_JSONL="$LOG_DIR/deploys.jsonl"
mkdir -p "$(dirname "$DEPLOY_LOG")"
touch "$DEPLOYS_JSONL"

START_TS=$(date +%s)
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CURRENT_STEP="setup"
ENDED_AT=""
DURATION_S=0
STATUS=""
EXIT_CODE_VAL=0
FAILED_STEP=""
ERROR_TAIL=""

emit_event() {
    DEPLOY_ID="$DEPLOY_ID" \
    PROJECT_NAME="$PROJECT_NAME" \
    STARTED_AT="$STARTED_AT" \
    PROJECT_BRANCH="$PROJECT_BRANCH" \
    APP_STACK="$APP_STACK" \
    DEPLOY_LOG_REL="$DEPLOY_LOG_REL" \
    EVENT="$1" \
    ENDED_AT="$ENDED_AT" \
    DURATION_S="$DURATION_S" \
    STATUS="$STATUS" \
    EXIT_CODE_VAL="$EXIT_CODE_VAL" \
    FAILED_STEP="$FAILED_STEP" \
    ERROR_TAIL="$ERROR_TAIL" \
    python3 -c '
import json, os
ev = os.environ["EVENT"]
rec = {
    "id": os.environ["DEPLOY_ID"],
    "app": os.environ["PROJECT_NAME"],
    "event": ev,
    "started_at": os.environ["STARTED_AT"],
    "branch": os.environ.get("PROJECT_BRANCH",""),
    "stack": os.environ.get("APP_STACK",""),
    "log_file": os.environ["DEPLOY_LOG_REL"],
}
if ev == "finished":
    rec["ended_at"] = os.environ.get("ENDED_AT","")
    try:
        rec["duration_s"] = int(os.environ.get("DURATION_S","0") or 0)
    except ValueError:
        rec["duration_s"] = 0
    rec["status"] = os.environ.get("STATUS","")
    try:
        rec["exit_code"] = int(os.environ.get("EXIT_CODE_VAL","0") or 0)
    except ValueError:
        rec["exit_code"] = 0
    rec["failed_step"] = os.environ.get("FAILED_STEP","")
    rec["error_tail"] = os.environ.get("ERROR_TAIL","")
print(json.dumps(rec, ensure_ascii=False))
' >> "$DEPLOYS_JSONL"
}

finalize() {
    local code=$?
    END_TS=$(date +%s)
    DURATION_S=$((END_TS - START_TS))
    ENDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    EXIT_CODE_VAL=$code
    if [ "$code" -eq 0 ]; then
        if [ "$NO_CHANGES" = "1" ]; then
            STATUS="no_changes"
        else
            STATUS="success"
        fi
        FAILED_STEP=""
        ERROR_TAIL=""
    else
        STATUS="failed"
        FAILED_STEP="$CURRENT_STEP"
        if [ -f "$DEPLOY_LOG" ]; then
            ERROR_TAIL=$(tail -n 30 "$DEPLOY_LOG")
        fi
    fi
    emit_event "finished"
    rm -f "$LOCK_FILE"
}
trap finalize EXIT

# Evento "started" antes de redirigir output (queda fuera del log de deploy
# porque va directo al jsonl)
emit_event "started"

# A partir de aquí, todo lo que se imprima va a stdout (visible vía pm2 logs
# del webhook-listener) Y al log persistente del deploy.
exec > >(tee -a "$DEPLOY_LOG") 2>&1

echo "============================================================"
echo "📍 Iniciando despliegue de: $PROJECT_NAME"
echo "📁 Directorio: $PROJECT_ROOT"
echo "🌿 Rama: $PROJECT_BRANCH"
echo "🧱 Stack: $APP_STACK"
echo "🆔 Deploy ID: $DEPLOY_ID"
echo "⏰ Hora: $(date)"
echo "============================================================"

CURRENT_STEP="cd_project"
cd "$PROJECT_ROOT" || { echo "❌ No se pudo acceder a $PROJECT_ROOT"; exit 1; }

# 1. ACTUALIZAR CÓDIGO
CURRENT_STEP="git_pull"
echo "🔄 Step 1/4: Haciendo git pull..."
git checkout "$PROJECT_BRANCH" || { echo "❌ Error en git checkout"; exit 1; }

# Detectar si hay cambios remotos antes de pull
git fetch origin "$PROJECT_BRANCH" --quiet || { echo "❌ Error en git fetch"; exit 1; }
LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git rev-parse "origin/$PROJECT_BRANCH")
if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
    echo "ℹ️  Sin cambios remotos (HEAD ya en $LOCAL_SHA)."
    echo "⏭️  Saltando build y restart de PM2."
    NO_CHANGES=1
    echo "============================================================"
    echo "✓ Nada que desplegar para $PROJECT_NAME"
    echo "============================================================"
    exit 0
fi

git pull origin "$PROJECT_BRANCH" || { echo "❌ Error en git pull"; exit 1; }
echo "✅ Código actualizado ($LOCAL_SHA → $REMOTE_SHA)"

# 2. ACTUALIZAR DEPENDENCIAS / BUILD
CURRENT_STEP="dependencies"
echo "🔄 Step 2/4: Dependencias y build para $APP_STACK..."

if [ "$APP_STACK" = "python" ]; then
    if [ -f "requirements.txt" ]; then
        source "$VENV_PATH/bin/activate"
        pip install -r requirements.txt --quiet || { echo "⚠️ Advertencia: pip install falló pero continuando"; }
        deactivate
        echo "✅ Dependencias Python actualizadas"
    else
        echo "⚠️ No se encontró requirements.txt, saltando pip install"
    fi
fi

if [ "$APP_STACK" = "svelte" ]; then
    if [ -f "package-lock.json" ]; then
        npm ci --no-audit --no-fund || { echo "❌ Error en npm ci"; exit 1; }
    elif [ -f "yarn.lock" ]; then
        yarn install --frozen-lockfile || { echo "❌ Error en yarn install"; exit 1; }
    elif [ -f "pnpm-lock.yaml" ]; then
        pnpm install --frozen-lockfile || { echo "❌ Error en pnpm install"; exit 1; }
    elif [ -f "package.json" ]; then
        npm install --no-audit --no-fund || { echo "❌ Error en npm install"; exit 1; }
    else
        echo "❌ Error: No se encontró package.json para APP_STACK=svelte"
        exit 1
    fi

    CURRENT_STEP="build"
    # BUILD_MODE permite controlar el --mode que recibe vite build
    # (ej. "staging" para que import.meta.env.MODE sea "staging").
    # Si no se define, vite build usa "production" por defecto.
    if [ -n "$BUILD_MODE" ]; then
        echo "🧱 Compilando con --mode $BUILD_MODE"
        npm run build -- --mode "$BUILD_MODE" || { echo "❌ Error en npm run build"; exit 1; }
    else
        npm run build || { echo "❌ Error en npm run build"; exit 1; }
    fi
    echo "✅ Dependencias y build Svelte completados"
fi

# POST BUILD: ejecutar comandos adicionales si están definidos en el .conf
if [ -n "$POST_BUILD" ]; then
    CURRENT_STEP="post_build"
    echo "🔧 Ejecutando post-build..."
    eval "$POST_BUILD" || { echo "⚠️ Advertencia: post-build falló pero continuando"; }
    echo "✅ Post-build completado"
fi

# 3. REINICIAR PM2
CURRENT_STEP="pm2_restart"
echo "🔄 Step 3/4: Reiniciando proceso PM2..."
# Si la app declara APP_ENV en su .conf (p. ej. "prod"), lo propagamos al
# proceso de PM2 con --update-env para que la app cargue el .env.<APP_ENV>
# correcto en cada despliegue.
if [ -n "$APP_ENV" ]; then
    echo "🌎 APP_ENV=$APP_ENV (propagando vía --update-env)"
    APP_ENV="$APP_ENV" pm2 restart "$PM2_NAME" --update-env || { echo "❌ Error reiniciando PM2: $PM2_NAME"; exit 1; }
else
    pm2 restart "$PM2_NAME" || { echo "❌ Error reiniciando PM2: $PM2_NAME"; exit 1; }
fi
echo "✅ Proceso PM2 reiniciado"

# 4. VALIDAR ESTADO
CURRENT_STEP="validation"
echo "🔄 Step 4/4: Validando estado..."
pm2 status || { echo "⚠️ Advertencia: pm2 status falló"; }

CURRENT_STEP="done"
echo ""
echo "============================================================"
echo "✅ Despliegue de $PROJECT_NAME completado exitosamente"
echo "⏰ Fin: $(date)"
echo "============================================================"
