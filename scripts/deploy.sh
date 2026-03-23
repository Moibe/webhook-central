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
CONFIG_FILE="$(dirname "$0")/../projects/${PROJECT_NAME}.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Error: Archivo de configuración no encontrado: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Validar variables requeridas
for var in PROJECT_ROOT PROJECT_BRANCH VENV_PATH PM2_NAME; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: Variable $var no definida en $CONFIG_FILE"
        exit 1
    fi
done

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

# Limpiar lock file al salir (éxito o error)
trap "rm -f $LOCK_FILE" EXIT

echo "="*60
echo "📍 Iniciando despliegue de: $PROJECT_NAME"
echo "📁 Directorio: $PROJECT_ROOT"
echo "🌿 Rama: $PROJECT_BRANCH"
echo "⏰ Hora: $(date)"
echo "="*60

# Navegar al directorio del proyecto
cd "$PROJECT_ROOT" || { echo "❌ No se pudo acceder a $PROJECT_ROOT"; exit 1; }

# 1. ACTUALIZAR CÓDIGO
echo "🔄 Step 1/4: Haciendo git pull..."
git checkout "$PROJECT_BRANCH" || { echo "❌ Error en git checkout"; exit 1; }
git pull origin "$PROJECT_BRANCH" || { echo "❌ Error en git pull"; exit 1; }
echo "✅ Código actualizado"

# 2. ACTUALIZAR DEPENDENCIAS
echo "🔄 Step 2/4: Actualizando dependencias..."
if [ -f "requirements.txt" ]; then
    source "$VENV_PATH/bin/activate"
    pip install -r requirements.txt --quiet || { echo "⚠️ Advertencia: pip install falló pero continuando"; }
    deactivate
    echo "✅ Dependencias actualizadas"
else
    echo "⚠️ no requirements.txt encontrado, saltando pip install"
fi

# 3. REINICIAR PM2
echo "🔄 Step 3/4: Reiniciando proceso PM2..."
pm2 restart "$PM2_NAME" || { echo "❌ Error reiniciando PM2: $PM2_NAME"; exit 1; }
echo "✅ Proceso PM2 reiniciado"

# 4. VALIDAR ESTADO
echo "🔄 Step 4/4: Validando estado..."
pm2 status || { echo "⚠️ Advertencia: pm2 status falló"; }

echo ""
echo "="*60
echo "✅ Despliegue de $PROJECT_NAME completado exitosamente"
echo "⏰ Fin: $(date)"
echo "="*60
