#!/bin/bash

# Promueve un proyecto: crea un Pull Request de MERGE_HEAD -> MERGE_BASE en
# GitHub y lo mergea de inmediato (sin pausa de revisión humana).
# Uso: ./promote.sh <proyecto>
# Requiere en projects/<proyecto>.conf: GITHUB_REPO, MERGE_HEAD, MERGE_BASE
# Requiere webhook-central/.github_token (fine-grained PAT: Contents +
# Pull requests en read/write sobre el repo), chmod 600.

set -o pipefail

PROJECT_NAME="$1"

if [ -z "$PROJECT_NAME" ]; then
    echo '{"ok":false,"error":"Proyecto no especificado"}'
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../projects/${PROJECT_NAME}.conf"
TOKEN_FILE="$SCRIPT_DIR/../.github_token"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "{\"ok\":false,\"error\":\"Archivo de configuración no encontrado: ${PROJECT_NAME}.conf\"}"
    exit 1
fi

source "$CONFIG_FILE"

for var in GITHUB_REPO MERGE_HEAD MERGE_BASE; do
    if [ -z "${!var}" ]; then
        echo "{\"ok\":false,\"error\":\"Variable $var no definida en ${PROJECT_NAME}.conf\"}"
        exit 1
    fi
done

if [ ! -f "$TOKEN_FILE" ]; then
    echo '{"ok":false,"error":"Falta webhook-central/.github_token"}'
    exit 1
fi

TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
API="https://api.github.com/repos/$GITHUB_REPO"
AUTH_HEADER="Authorization: Bearer $TOKEN"
ACCEPT_HEADER="Accept: application/vnd.github+json"

# LOCK FILE: evitar promociones simultáneas del mismo proyecto
LOCK_FILE="/tmp/promote-${PROJECT_NAME}.lock"
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE")
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "{\"ok\":false,\"error\":\"Ya hay una promoción de $PROJECT_NAME en curso (PID: $LOCK_PID)\"}"
        exit 1
    else
        rm -f "$LOCK_FILE"
    fi
fi
echo "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# 1. Buscar si ya hay un PR abierto de MERGE_HEAD -> MERGE_BASE (evita duplicar)
EXISTING=$(curl -s -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
    "$API/pulls?state=open&head=$(echo "$GITHUB_REPO" | cut -d/ -f1):$MERGE_HEAD&base=$MERGE_BASE")

PR_NUMBER=$(echo "$EXISTING" | jq -r '.[0].number // empty')

if [ -z "$PR_NUMBER" ]; then
    # 2. No hay PR abierto: crear uno nuevo
    CREATE_RESPONSE=$(curl -s -X POST -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
        "$API/pulls" \
        -d "$(jq -n --arg head "$MERGE_HEAD" --arg base "$MERGE_BASE" \
            '{title: ("Promover " + $head + " -> " + $base), head: $head, base: $base}')")

    PR_NUMBER=$(echo "$CREATE_RESPONSE" | jq -r '.number // empty')
    ERROR_MSG=$(echo "$CREATE_RESPONSE" | jq -r '.message // empty')
    ERRORS_DETAIL=$(echo "$CREATE_RESPONSE" | jq -r '[.errors[]?.message] | join("; ")')

    if [ -z "$PR_NUMBER" ]; then
        if echo "$ERROR_MSG $ERRORS_DETAIL" | grep -qi "no commits between\|no difference"; then
            echo "{\"ok\":true,\"no_changes\":true,\"message\":\"Sin cambios entre $MERGE_HEAD y $MERGE_BASE\"}"
            exit 0
        fi
        echo "{\"ok\":false,\"error\":\"No se pudo crear el PR: ${ERRORS_DETAIL:-${ERROR_MSG:-desconocido}}\"}"
        exit 1
    fi
fi

PR_URL="https://github.com/$GITHUB_REPO/pull/$PR_NUMBER"

# 3. Mergear el PR de inmediato
MERGE_RESPONSE=$(curl -s -X PUT -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" \
    "$API/pulls/$PR_NUMBER/merge" \
    -d '{"merge_method":"merge"}')

MERGED=$(echo "$MERGE_RESPONSE" | jq -r '.merged // false')

if [ "$MERGED" = "true" ]; then
    echo "{\"ok\":true,\"merged\":true,\"pr_number\":$PR_NUMBER,\"pr_url\":\"$PR_URL\"}"
    exit 0
else
    MERGE_ERROR=$(echo "$MERGE_RESPONSE" | jq -r '.message // "conflictos o PR no mergeable"')
    echo "{\"ok\":false,\"error\":\"PR #$PR_NUMBER creado pero no se pudo mergear: $MERGE_ERROR\",\"pr_url\":\"$PR_URL\"}"
    exit 1
fi
