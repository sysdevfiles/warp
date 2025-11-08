#!/bin/bash
# ===========================================================
# Cloudflare WARP Secure Installer (warpinstall.sh)
# -----------------------------------------------------------
# Compatible con: Ubuntu 22.04 / 24.04 LTS
# Propósito:
#   - Instalar Cloudflare WARP en modo DNS-only (DoH) de forma
#     automática y segura para no perder acceso SSH.
#   - Modo silencioso hacia el usuario: sólo imprime SUCCESS/ERROR
#   - Manejo automático de errores y rollback si se pierde SSH
# ===========================================================

LOG_FILE="/var/log/warpinstall.log"
# Guardamos stdout/stderr originales en fd 3/4 para mensajes al usuario
exec 3>&1 4>&2
# Redirigimos toda la salida normal y de error al log (silencioso para el usuario)
exec 1>>"$LOG_FILE" 2>&1

# --- Mensajería para el usuario (solo SUCCESS/ERROR) ---
ui_success() { echo "SUCCESS: $1" >&3; }
ui_error() {
  echo "ERROR: $1" >&3
  echo "ERROR: $1" >>"$LOG_FILE"
  exit 1
}

# --- Parámetros (no interactivo por defecto) ---
WARP_KEY=""
NONINTERACTIVE=1
SSH_PORT=22
DRY_RUN=0
INSTALL_SERVICE=0
ENABLE_SERVICE=0

usage() {
  cat >&3 <<EOF
Usage: sudo bash $(basename "$0") [options]
Instala Cloudflare WARP en modo DNS-only (DoH) de forma automática.
Opciones:
  --warp-key, -k   Clave WARP+ (opcional)
  --ssh-port, -p   Puerto SSH a comprobar (por defecto: 22)
  --dry-run        Simula la instalación sin aplicar cambios (solo log)
  --install-service, -s  Generar e instalar unidad systemd y archivo de entorno
  --enable-service       Habilitar y arrancar la unidad systemd después de crearla
  --help, -h       Mostrar esta ayuda
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --warp-key|-k)
      WARP_KEY="$2"
      shift 2
      ;;
    --ssh-port|-p)
      SSH_PORT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --enable-service)
      ENABLE_SERVICE=1
      shift
      ;;
    --install-service|-s)
      INSTALL_SERVICE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

# Si dry-run; no necesitamos ser root ni hacer cambios
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry-run: se registrarán las acciones en $LOG_FILE (no se aplicarán cambios)." >&3
  echo "[dry-run] SSH_PORT=$SSH_PORT WARP_KEY=${WARP_KEY:-<none>}" >>"$LOG_FILE"
  echo "[dry-run] Verificando ambiente (sin cambios)" >>"$LOG_FILE"
  if ! command -v ss >/dev/null 2>&1; then
    echo "[dry-run] ss no encontrado (se recomienda iproute2)" >>"$LOG_FILE"
  fi
  ui_success "Dry-run completado. Revisa $LOG_FILE para detalles."
  exit 0
fi

# --- Verificar permisos ---
if [ "$EUID" -ne 0 ]; then
  # Re-lanzar con sudo preservando variable si existe
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" --warp-key "$WARP_KEY"
  else
    ui_error "Este script requiere privilegios de root y sudo no está disponible."
  fi
fi

# --- Definir función de fallo seguro ---
safe_exit_on_error() {
  ui_error "$1"
}

# --- Preparar rollback seguro para evitar perder SSH ---
# Escribimos un script de rollback que se ejecutará en background via systemd-run o nohup.
ROLLBACK_SCRIPT="/usr/local/bin/warp-rollback.sh"
cat > "$ROLLBACK_SCRIPT" <<'RB'
#!/bin/bash
# Comprueba si existe el archivo OK; si existe, salir (no rollback)
OK_FILE="/tmp/warp-rollback-ok"
LOG="/var/log/warpinstall.log"
PORT_FILE="/tmp/warp-ssh-port"
SSH_PORT=22
if [ -f "$OK_FILE" ]; then
  exit 0
fi
if [ -f "$PORT_FILE" ]; then
  SSH_PORT=$(cat "$PORT_FILE" 2>/dev/null || echo 22)
fi
# Comprobar si hay conexiones SSH establecidas en el puerto configurado
if ss -tn state established | grep -q ":${SSH_PORT}"; then
  # Hay al menos una conexión, no hacemos nada
  exit 0
fi
echo "[rollback] No hay conexiones SSH establecidas en puerto ${SSH_PORT}, revirtiendo WARP..." >>"$LOG"
warp-cli disconnect >/dev/null 2>&1 || true
systemctl restart sshd >/dev/null 2>&1 || true
echo "[rollback] Ejecutado." >>"$LOG"
RB
chmod +x "$ROLLBACK_SCRIPT"

# Guardar puerto SSH para que el script de rollback lo use
echo "$SSH_PORT" > /tmp/warp-ssh-port

# Programar la ejecución del rollback en ~60s de forma desvinculada
if command -v systemd-run >/dev/null 2>&1; then
  systemd-run --unit=warp-rollback --on-active=1m "$ROLLBACK_SCRIPT" >/dev/null 2>&1 || \
    nohup bash -c "sleep 60; $ROLLBACK_SCRIPT" >/dev/null 2>&1 &
else
  nohup bash -c "sleep 60; $ROLLBACK_SCRIPT" >/dev/null 2>&1 &
fi

# --- Instalar dependencias ---
apt-get update -y || safe_exit_on_error "Error al actualizar repositorios."
apt-get install -y curl gnupg lsb-release wget apt-transport-https ca-certificates iproute2 net-tools systemd || safe_exit_on_error "Error al instalar dependencias."

# --- Añadir repositorio y clave GPG ---
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg || safe_exit_on_error "Error al importar la clave GPG."

# Detectar codename de la distro y usarlo si está disponible, por seguridad.
DIST_CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $DIST_CODENAME main" > /etc/apt/sources.list.d/cloudflare-client.list

apt-get update -y || safe_exit_on_error "Error al actualizar repositorios luego de añadir repo de Cloudflare."

# --- Instalar paquete cloudflare-warp ---
if ! apt-get install -y cloudflare-warp; then
  # Intentar instalación manual conservadora
  cd /tmp || safe_exit_on_error "No se puede acceder a /tmp."
  DEB_URL="https://pkg.cloudflareclient.com/pool/$DIST_CODENAME/main/c/cloudflare-warp/"
  # Intentar descargar el paquete más reciente disponible por nombre conocido (fallback hardcode)
  if ! wget -q --spider "${DEB_URL}"; then
    # Fallback a versión conocida
    wget -q https://pkg.cloudflareclient.com/pool/jammy/main/c/cloudflare-warp/cloudflare-warp_2024.8.209-1_amd64.deb || safe_exit_on_error "No se pudo descargar el paquete .deb de Cloudflare WARP."
    apt-get install -y ./cloudflare-warp_2024.8.209-1_amd64.deb || safe_exit_on_error "Error al instalar el paquete manualmente."
  else
    # Si la URL base responde, intentar instalar desde repositorio falló por otra razón
    safe_exit_on_error "No se pudo instalar cloudflare-warp desde apt. Revisa $LOG_FILE para más detalles."
  fi
fi

# --- Habilitar servicio ---
systemctl enable --now warp-svc || safe_exit_on_error "No se pudo habilitar/arrancar warp-svc."

# --- Registrar / aplicar licencia (si se provee) ---
warp-cli registration new >/dev/null 2>&1 || echo "[info] warp-cli registration new returned non-zero (posible ya registrado)" >>"$LOG_FILE"
if [ -n "$WARP_KEY" ]; then
  warp-cli registration license "$WARP_KEY" >/dev/null 2>&1 || echo "[warn] No se pudo aplicar la clave WARP+" >>"$LOG_FILE"
fi

# --- Configurar modo DNS-only (DoH) y conectar ---
warp-cli disconnect >/dev/null 2>&1 || true
warp-cli mode doh >/dev/null 2>&1 || safe_exit_on_error "Error al establecer modo DoH."

# --- Proteger sesiones SSH existentes: crear rutas específicas hacia los peers SSH
# Capturar gateway y device actuales para la ruta por defecto
DEFAULT_GW_LINE=$(ip route | awk '/default/ {print $0; exit}')
DEFAULT_GW=$(echo "$DEFAULT_GW_LINE" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
DEFAULT_DEV=$(echo "$DEFAULT_GW_LINE" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
if [ -n "$DEFAULT_GW" ] && [ -n "$DEFAULT_DEV" ]; then
  SSH_PEERS_FILE="/tmp/warp-ssh-peers"
  SSH_ROUTES_FILE="/tmp/warp-ssh-routes"
  PERSIST_ROUTES="/etc/warp-ssh-routes.list"
  # Listar IPs remotas de conexiones SSH establecidas
  ss -tn state established '( sport = :22 or dport = :22 )' | awk '{print $5}' | sed 's/:.*$//' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u > "$SSH_PEERS_FILE" || true
  if [ -s "$SSH_PEERS_FILE" ]; then
    : > "$SSH_ROUTES_FILE"
    : > "$PERSIST_ROUTES"
    while read -r peer; do
      # Añadir ruta host hacia el peer por la gateway original
      ip route replace ${peer}/32 via $DEFAULT_GW dev $DEFAULT_DEV >/dev/null 2>&1 || true
      echo "${peer}" >> "$SSH_ROUTES_FILE"
      echo "${peer}" >> "$PERSIST_ROUTES"
    done < "$SSH_PEERS_FILE"
    echo "[info] Rutas para peers SSH creadas: $(wc -l < "$SSH_ROUTES_FILE")" >>"$LOG_FILE"
  fi
fi

# Conectar
warp-cli connect >/dev/null 2>&1 || safe_exit_on_error "Error al conectar en modo DoH."

# Verificar que warp quedó en modo doh
WARP_STATUS=$(warp-cli status 2>/dev/null || true)
echo "$WARP_STATUS" >>"$LOG_FILE"
echo "$WARP_STATUS" | grep -qi "mode.*doh" || (
  # No quedó en modo doh: intentar rollback inmediato
  echo "[error] warp-cli no quedó en modo doh, realizando rollback" >>"$LOG_FILE"
  warp-cli disconnect >/dev/null 2>&1 || true
  # eliminar rutas añadidas
  if [ -f "/tmp/warp-ssh-routes" ]; then
    while read -r p; do ip route del ${p}/32 >/dev/null 2>&1 || true; done < /tmp/warp-ssh-routes
  fi
  systemctl restart sshd >/dev/null 2>&1 || true
  safe_exit_on_error "warp no quedó en modo DoH (rollback realizado). Revisa $LOG_FILE"
)

# --- Verificar salud del servicio y conectividad SSH local ---
sleep 3

# Si tras la conexión aún hay al menos una sesión SSH establecida, consideramos OK.
if ss -tn state established | grep -q ":${SSH_PORT}"; then
  # Señalamos al rollback que todo salió bien
  touch /tmp/warp-rollback-ok

  # Si se pidió instalar el servicio, crear unidad y archivo de entorno
  if [ "$INSTALL_SERVICE" -eq 1 ]; then
    INSTALL_PATH="/usr/local/bin/warpinstall.sh"
    UNIT_PATH="/etc/systemd/system/warpinstall.service"
    ENV_PATH="/etc/default/warpinstall"

    # Copiar el script actual al path de instalación
    cp "$0" "$INSTALL_PATH" >/dev/null 2>&1 || echo "[warn] No se pudo copiar $0 a $INSTALL_PATH" >>"$LOG_FILE"
    chmod +x "$INSTALL_PATH" || true

    # Construir WARP_ARGS para el EnvironmentFile
    WARP_ARGS=""
    if [ -n "$WARP_KEY" ]; then
      # Escapar comillas simples en la clave
      SAFE_KEY=$(printf "%s" "$WARP_KEY" | sed "s/'/'\\''/g")
      WARP_ARGS="$WARP_ARGS --warp-key '$SAFE_KEY'"
    fi
    WARP_ARGS="$WARP_ARGS --ssh-port $SSH_PORT"

    # Escribir archivo de entorno (solo si se puede)
    printf "WARP_ARGS=%s\n" "$WARP_ARGS" > "$ENV_PATH" 2>/dev/null || echo "[warn] No se pudo escribir $ENV_PATH" >>"$LOG_FILE"
    chmod 600 "$ENV_PATH" 2>/dev/null || true

    # Escribir unidad systemd (usar EnvironmentFile)
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

    # Recargar systemd y habilitar la unidad (no arrancar) a menos que se pida --enable-service
    systemctl daemon-reload >/dev/null 2>&1 || echo "[warn] systemctl daemon-reload falló" >>"$LOG_FILE"
    systemctl enable warpinstall.service >/dev/null 2>&1 || echo "[warn] systemctl enable falló" >>"$LOG_FILE"

    if [ "$ENABLE_SERVICE" -eq 1 ]; then
      systemctl restart warpinstall.service >/dev/null 2>&1 || echo "[warn] systemctl restart falló" >>"$LOG_FILE"
    fi
  fi

  ui_success "Instalación completada y SSH sigue disponible."
  exit 0
else
  # No hay sesiones establecidas -> posible pérdida de conexión remota
  # Intentar desconectar WARP inmediatamente para recuperar conectividad
  warp-cli disconnect >/dev/null 2>&1 || true
  systemctl restart sshd >/dev/null 2>&1 || true
  ui_error "Instalación aplicada pero no se detectan sesiones SSH establecidas. Se intentó un rollback automático. Revisa $LOG_FILE para detalles."
fi

