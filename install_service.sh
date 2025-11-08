#!/bin/bash
# Helper para instalar warpinstall.sh como servicio systemd.

INSTALL_PATH="/usr/local/bin/warpinstall.sh"
UNIT_PATH="/etc/systemd/system/warpinstall.service"
ENV_PATH="/etc/default/warpinstall"

usage_install_service() {
  cat <<'EOF'
Uso: sudo bash install_service.sh [opciones]

Opciones:
  --source <ruta>     Ruta del script warpinstall.sh a copiar (default: junto a este helper)
  --warp-key <clave>  Clave WARP+ que se inyectara al servicio
  --ssh-port <puerto> Puerto SSH observado por el instalador (default: 22)
  --enable-service    Reiniciar warpinstall.service despues de instalarlo
  --extra-args "<...>" Argumentos extra para warpinstall.sh dentro de WARP_ARGS
  -h, --help          Mostrar esta ayuda
EOF
}

install_warp_service() {
  local source_script="$1"
  local warp_key="${2:-}"
  local ssh_port="${3:-22}"
  local enable_service="${4:-0}"
  local extra_args="${5:-}"

  if [ "${EUID:-0}" -ne 0 ]; then
    echo "install_service: se requieren privilegios de root." >&2
    return 1
  fi

  if [ ! -f "$source_script" ]; then
    echo "install_service: script fuente no encontrado: $source_script" >&2
    return 1
  fi

  local helper_dir
  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local unit_template="$helper_dir/warpinstall.service"

  cp "$source_script" "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"

  local warp_args=""
  if [ -n "$warp_key" ]; then
    local safe_key
    safe_key=$(printf "%s" "$warp_key" | sed "s/'/'\\''/g")
    warp_args+=" --warp-key '$safe_key'"
  fi
  warp_args+=" --ssh-port $ssh_port"
  if [ -n "$extra_args" ]; then
    warp_args+=" $extra_args"
  fi

  printf "WARP_ARGS=%s\n" "$warp_args" > "$ENV_PATH"
  chmod 600 "$ENV_PATH" 2>/dev/null || true

  if [ -f "$unit_template" ]; then
    cp "$unit_template" "$UNIT_PATH"
  else
    cat > "$UNIT_PATH" <<'UNIT_EOF'
[Unit]
Description=Cloudflare WARP Installer (one-shot)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-/etc/default/warpinstall
ExecStart=/usr/local/bin/warpinstall.sh ${WARP_ARGS}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable warpinstall.service >/dev/null 2>&1 || true

  if [ "$enable_service" -eq 1 ]; then
    systemctl restart warpinstall.service >/dev/null 2>&1 || true
  fi

  echo "Servicio warpinstall.service instalado en $UNIT_PATH"
}

install_service_cli() {
  local source_script=""
  local warp_key=""
  local ssh_port=22
  local enable_service=0
  local extra_args=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --source)
        source_script="$2"
        shift 2
        ;;
      --warp-key|-k)
        warp_key="$2"
        shift 2
        ;;
      --ssh-port|-p)
        ssh_port="$2"
        shift 2
        ;;
      --enable-service)
        enable_service=1
        shift
        ;;
      --extra-args)
        extra_args="$2"
        shift 2
        ;;
      --help|-h)
        usage_install_service
        return 0
        ;;
      *)
        extra_args+="${extra_args:+ }$1"
        shift
        ;;
    esac
  done

  if [ -z "$source_script" ]; then
    local helper_dir
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source_script="$helper_dir/warpinstall.sh"
  fi

  install_warp_service "$source_script" "$warp_key" "$ssh_port" "$enable_service" "$extra_args"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  install_service_cli "$@"
fi
