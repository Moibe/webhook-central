# Webhook Centralizado - Guía de Implementación

## Estructura

```
webhook-central/
├── hooks.json              # Configuración de todos los webhooks
├── scripts/
│   └── deploy.sh          # Script genérico de despliegue
└── projects/
    ├── mide-chatbot.conf       # Configuración para mide-chatbot
    ├── document_ai.conf        # Configuración para document_ai
    └── notificaciones_twilio.conf  # Configuración para notificaciones_twilio
```

## Pasos de Implementación

### 1. Copiar archivos al servidor

Desde tu máquina local (PowerShell):
```bash
scp -r webhook-central/ mbriseno@172.10.30.15:/home/mbriseno/
```

O manualmente en el servidor:
```bash
mkdir -p /home/mbriseno/webhook-central/{scripts,projects}
# Copiar archivos...
```

### 2. Dar permisos de ejecución

En el servidor:
```bash
chmod +x /home/mbriseno/webhook-central/scripts/deploy.sh
chmod 644 /home/mbriseno/webhook-central/hooks.json
chmod 644 /home/mbriseno/webhook-central/projects/*.conf
```

### 3. Actualizar PM2

Parar el webhook actual:
```bash
pm2 stop webhook-listener
pm2 delete webhook-listener
```

Iniciar el nuevo webhook centralizado:
```bash
pm2 start /usr/bin/webhook \
  --name webhook-listener \
  -- -hooks /home/mbriseno/webhook-central/hooks.json -verbose -port 8090

pm2 save
pm2 startup
```

### 4. Eliminar archivos antiguos

Desde cada proyecto:
```bash
rm /home/mbriseno/code/mide-chatbot/hooks.json
rm /home/mbriseno/code/mide-chatbot/script_despliegue.sh
# Repetir para otros proyectos si tienen sus propios webhooks
```

## URLs de los webhooks

- **mide-chatbot**: `http://tu-servidor:8090/hooks/despliegue-mide-chatbot`
- **document_ai**: `http://tu-servidor:8090/hooks/despliegue-document-ai`
- **notificaciones_twilio**: `http://tu-servidor:8090/hooks/despliegue-notificaciones-twilio`

## Agregar nuevos proyectos

1. Crear archivo en `projects/<nombre>.conf` con:
   ```bash
  APP_STACK="python"
   PROJECT_ROOT="/home/mbriseno/code/<nombre>"
   PROJECT_BRANCH="main"
   PM2_NAME="<nombre-api>"

  # Solo para APP_STACK="python"
  VENV_PATH="$PROJECT_ROOT/venv"
   ```

  Para una app Svelte:
  ```bash
  APP_STACK="svelte"
  PROJECT_ROOT="/home/mbriseno/code/<nombre>"
  PROJECT_BRANCH="main"
  PM2_NAME="<nombre-frontend>"
  ```

2. Agregar entrada en `hooks.json`:
   ```json
   {
     "id": "despliegue-<nombre>",
     "execute-command": "/home/mbriseno/webhook-central/scripts/deploy.sh",
     "command-working-directory": "/home/mbriseno/webhook-central",
     "pass-arguments-to-command": [
       {
         "source": "string",
         "name": "<nombre>"
       }
     ]
   }
   ```

3. Reiniciar webhook:
   ```bash
   pm2 restart webhook-listener
   ```

## Refrescar dev con los datos de prod

`scripts/refresh.sh <id-dev> <token>` copia los datos de una app de prod sobre los
de su instancia dev (en la UI: botón de base de datos en la fila dev, solo
superadmin, confirmando con el id). Lo usa una app dev que declare en su `.conf`:

```bash
REFRESH_FROM="/home/mbriseno/code/<repo-prod>"          # checkout de prod (solo se lee)
REFRESH_DATA="AGENTES_DB_PATH:agentes.db LOG_DB_PATH:logs.db CHROMA_PATH:chroma DOCS_FOLDER:./data/documentos"
```

y en `apps.json` `"env": "dev"`, `"refresh_url": "/hooks/refrescar-<id-dev>"` y
`"refresh_from": "<id-prod>"`, más su hook en `hooks.json` (POST, argumentos
`<id-dev>` fijo y `token` de la URL; el token es el mismo `.power_token`).

- Cada ruta se resuelve como la lee la app: la variable del `.env` de ese
  checkout o el default, relativa a su carpeta. Aborta si una ruta de dev cae
  en la misma de prod o fuera de la carpeta de dev.
- Las SQLite se copian con la API de backup (copia consistente aunque prod esté
  escribiendo); las carpetas con `cp` y sus SQLite internas (Chroma) después.
- Detiene la app dev, mueve lo suyo a `~/respaldos-refresco/<id-dev>/<fecha>/dev-anterior/`
  (se guardan las 3 corridas más recientes), pone lo de prod y la vuelve a
  levantar. Si falla a medio cambio, regresa lo de dev.
- Corre desacoplado: el hook responde al instante y el avance queda en
  `logs/deploys.jsonl` con `"kind": "refresh"` y en `logs/<id-dev>/<corrida>.log`.
- No lo uses mientras subes documentos en prod: Chroma podría quedar a medias
  en la copia de dev (se arregla refrescando otra vez).

### Deshacer el último refresco

`scripts/refresh.sh <id-dev> <token> deshacer` (en la UI: botón ↩ junto al de
refrescar, aparece cuando el último refresco de esa app cambió datos). Toma la
corrida más reciente de `~/respaldos-refresco/<id-dev>/`, aparta lo que dev tiene
ahora en `<fecha>/al-deshacer/` y regresa `<fecha>/dev-anterior/` a su lugar, con
la app detenida y verificando que vuelva a quedar en línea. Nada se borra; cada
refresco se deshace una sola vez (deja `deshecho.json`). Si falla a medio camino,
dev queda como estaba. Evento con `"kind": "refresh-undo"`; hook
`deshacer-refresco-<id-dev>` (los mismos argumentos que el de refrescar más el
string `deshacer`) y `"refresh_undo_url"` en `apps.json`.

## Verificar que funciona

```bash
# Ver logs del webhook
pm2 logs webhook-listener

# Probar manualmente
curl -X POST http://127.0.0.1:8090/hooks/despliegue-mide-chatbot

# Ver estado de PM2
pm2 status
```

## Cambiar back si surge un problema

```bash
pm2 restart webhook-listener
```

## Estructura final en el servidor

```bash
/home/mbriseno/
├── code/
│   ├── mide-chatbot/         # (sin hooks.json ni script_despliegue.sh)
│   ├── document_ai/
│   └── notificaciones_twilio/
└── webhook-central/          # ← Nuevo centralizado
    ├── hooks.json
    ├── scripts/
    │   └── deploy.sh
    └── projects/
        ├── mide-chatbot.conf
        ├── document_ai.conf
        └── notificaciones_twilio.conf
```
