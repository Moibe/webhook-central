#!/bin/bash
# Devuelve el status de pm2 para todos los procesos, como JSON { "pm2_name": "online" }.
# Usado por el hook GET /hooks/pm2-status que consume webhook-central-ui para la columna Live.

pm2 jlist | python3 -c '
import json, sys
data = json.load(sys.stdin)
out = {p["name"]: p["pm2_env"]["status"] for p in data}
print(json.dumps(out))
'
