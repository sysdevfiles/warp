#!/bin/bash
# Script helper para instalar `warpinstall.sh` como servicio systemd
set -euo pipefail

if [ "${EUID:-0}" -ne 0 ]; then
  echo "Este script debe ejecutarse como root. Usa: sudo bash install_service.sh"
  exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_PATH="/usr/local/bin/warpinstall.sh"
UNIT_PATH="/etc/systemd/system/warpinstall.service"

echo "Copiando script a $INSTALL_PATH"
cp "$SRC_DIR/warpinstall.sh" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

echo "Instalando unidad systemd en $UNIT_PATH"
cp "$SRC_DIR/warpinstall.service" "$UNIT_PATH"

echo "Recargando systemd, habilitando y arrancando servicio..."
systemctl daemon-reload
systemctl enable --now warpinstall.service

echo "Hecho. Revisa el estado con: systemctl status warpinstall.service"
echo "Si quieres pasar argumentos, edita $UNIT_PATH y modifica ExecStart o crea un archivo de entorno." 
