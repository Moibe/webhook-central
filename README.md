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
