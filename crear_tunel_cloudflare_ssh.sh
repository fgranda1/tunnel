#!/bin/bash

set -e

echo "=== 🌐 Creación automática de Cloudflare Tunnel para SSH ==="

# 0. Validar dependencias críticas antes de hacer cualquier cosa
DEPENDENCIAS=(jq wget)

echo "[*] Validando dependencias del sistema..."
for cmd in "${DEPENDENCIAS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ Dependencia faltante: $cmd"
        echo "Por favor, instálala antes de continuar. Ejemplo:"
        echo "    sudo apt install -y $cmd"
        exit 1
    fi
done

# 1. Instalar cloudflared según arquitectura
if ! command -v cloudflared &>/dev/null; then
    echo "[+] Instalando cloudflared..."

    ARCH=$(uname -m)
    OS=$(uname -s)

    if [[ "$OS" != "Linux" ]]; then
        echo "❌ Este script está diseñado solo para sistemas Linux."
        exit 1
    fi

    case "$ARCH" in
        x86_64)
            BIN_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        aarch64)
            BIN_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        armv7l)
            BIN_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
            ;;
        *)
            echo "❌ Arquitectura no soportada automáticamente: $ARCH"
            echo "Descarga manual desde:"
            echo "https://github.com/cloudflare/cloudflared/releases"
            exit 1
            ;;
    esac

    echo "[*] Descargando cloudflared para $ARCH..."
    wget -q --show-progress -O cloudflared "$BIN_URL"
    chmod +x cloudflared
    sudo mv cloudflared /usr/local/bin/cloudflared

    if ! command -v cloudflared &>/dev/null; then
        echo "❌ cloudflared no se instaló correctamente."
        exit 1
    fi

    echo "✅ cloudflared instalado correctamente."
fi

# 2. Autenticación (verifica cert.pem)
CERT_FILE="$HOME/.cloudflared/cert.pem"
if [ -f "$CERT_FILE" ]; then
    echo "⚠️ Ya existe un archivo de autenticación: $CERT_FILE"
    read -p "¿Deseas reutilizarlo? (s/n): " REUSE_CERT
    if [[ "$REUSE_CERT" =~ ^[nN]$ ]]; then
        BACKUP_NAME="$CERT_FILE.backup.$(date +%s)"
        echo "[*] Moviendo $CERT_FILE a $BACKUP_NAME"
        mv "$CERT_FILE" "$BACKUP_NAME"
    else
        echo "[*] Usando el archivo existente."
    fi
fi

if [ ! -f "$CERT_FILE" ]; then
    echo "[*] Ejecutando cloudflared tunnel login..."
    TMP_LOG=$(mktemp)

    cloudflared tunnel login 2>&1 | tee "$TMP_LOG"
    LOGIN_URL=$(grep -o 'https://[^ ]*' "$TMP_LOG" | head -n 1)

    if [ -n "$LOGIN_URL" ]; then
        echo "[*] URL de autenticación detectada:"
        echo "$LOGIN_URL"

        if command -v qrencode &>/dev/null; then
            echo "[*] Mostrando QR para autenticación:"
            qrencode -t ANSIUTF8 "$LOGIN_URL"
        else
            echo "(⚠️ No se encontró 'qrencode'. Puedes instalarlo con: sudo apt install -y qrencode)"
        fi
    else
        echo "❌ No se detectó ninguna URL de login. Verifica manualmente."
        cat "$TMP_LOG"
        exit 1
    fi

    rm -f "$TMP_LOG"
fi

# 3. Pedir datos
read -p "Nombre del túnel (ej: mi-tunel): " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME// /-}

read -p "Dominio completo a usar (ej: ssh.mi-dominio.com): " HOSTNAME
read -p "Puerto SSH local (default 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

# 4. Crear el túnel y manejar errores
echo "[*] Creando túnel: $TUNNEL_NAME..."
if ! OUTPUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1); then
    if echo "$OUTPUT" | grep -q "tunnel with name already exists"; then
        echo "❌ Error: Ya existe un túnel con el nombre '$TUNNEL_NAME'."
        echo ""
        echo "ℹ️ Para eliminarlo manualmente, ejecuta:"
        echo "   cloudflared tunnel delete \"$TUNNEL_NAME\""
        echo "Luego vuelve a ejecutar este script."
        exit 1
    else
        echo "❌ Error desconocido al crear el túnel:"
        echo "$OUTPUT"
        exit 1
    fi
fi

# 5. Detectar archivo .json más reciente
echo "[*] Buscando archivo de credenciales..."
JSON_FILE=$(find ~/.cloudflared -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)

if [ ! -f "$JSON_FILE" ]; then
    echo "❌ No se encontró archivo de credenciales JSON. Abortando."
    exit 1
fi

TUNNEL_ID=$(jq -r .TunnelID "$JSON_FILE")
echo "[*] Tunnel ID: $TUNNEL_ID"
echo "[*] Archivo de credenciales: $JSON_FILE"

# 6. Crear archivo config.yml
CONFIG_PATH="$HOME/.cloudflared/config.yml"
echo "[*] Generando configuración en $CONFIG_PATH..."

cat <<EOF > "$CONFIG_PATH"
tunnel: $TUNNEL_ID
credentials-file: $JSON_FILE

ingress:
  - hostname: $HOSTNAME
    service: ssh://localhost:$SSH_PORT
  - service: http_status:404
EOF

# 7. Crear servicio systemd
SERVICE_NAME="cloudflared@$TUNNEL_NAME.service"
echo "[*] Configurando servicio systemd: $SERVICE_NAME"

sudo tee /etc/systemd/system/$SERVICE_NAME > /dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel ($TUNNEL_NAME)
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config $CONFIG_PATH run
Restart=on-failure
User=$USER

[Install]
WantedBy=multi-user.target
EOF

# 8. Activar el servicio
echo "[*] Activando y lanzando servicio..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_NAME
sudo systemctl start $SERVICE_NAME

# 9. Final
echo ""
echo "✅ Túnel creado y ejecutándose como servicio."
echo "🌐 Recuerda crear un registro DNS CNAME en Cloudflare:"
echo "    $HOSTNAME  --->  $TUNNEL_ID.cfargotunnel.com"
echo ""
echo "🔎 Verifica el estado con:"
echo "    sudo systemctl status $SERVICE_NAME"

echo ""
echo "=== ℹ️ Instrucciones para conectarte vía SSH ==="
echo ""
echo "➡️ Linux / macOS:"
echo "    ssh -o ProxyCommand=\"cloudflared access ssh --hostname $HOSTNAME\" usuario@$HOSTNAME"
echo ""
echo "➡️ Windows (PowerShell):"
echo "    ssh -o ProxyCommand=\"cloudflared access ssh --hostname $HOSTNAME\" usuario@$HOSTNAME"
echo ""
echo "➡️ Windows (PuTTY):"
echo "    1. Host Name: $HOSTNAME"
echo "    2. Ve a 'Connection > Proxy' y usa como comando:"
echo "       cloudflared access ssh --hostname $HOSTNAME"
