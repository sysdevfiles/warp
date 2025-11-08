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

usage() {
  cat >&3 <<EOF
Usage: sudo bash $(basename "$0") [--warp-key <KEY>]
Instala Cloudflare WARP en modo DNS-only (DoH) de forma automática.
Opciones:
  --warp-key, -k   Clave WARP+ (opcional)
  --help, -h       Mostrar esta ayuda
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --warp-key|-k)
      WARP_KEY="$2"
      shift 2
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
if [ -f "$OK_FILE" ]; then
  exit 0
fi
# Comprobar si hay conexiones SSH establecidas
if ss -tn state established | grep -q ':22'; then
  # Hay al menos una conexión, no hacemos nada
  exit 0
fi
echo "[rollback] No hay conexiones SSH establecidas, revirtiendo WARP..." >>"$LOG"
warp-cli disconnect >/dev/null 2>&1 || true
systemctl restart sshd >/dev/null 2>&1 || true
echo "[rollback] Ejecutado." >>"$LOG"
RB
chmod +x "$ROLLBACK_SCRIPT"

# Programar la ejecución del rollback en ~60s de forma desvinculada
if command -v systemd-run >/dev/null 2>&1; then
  systemd-run --unit=warp-rollback --on-active=1m "$ROLLBACK_SCRIPT" >/dev/null 2>&1 || \
    nohup bash -c "sleep 60; $ROLLBACK_SCRIPT" >/dev/null 2>&1 &
else
  nohup bash -c "sleep 60; $ROLLBACK_SCRIPT" >/dev/null 2>&1 &
fi

# --- Instalar dependencias ---
apt-get update -y || safe_exit_on_error "Error al actualizar repositorios."
apt-get install -y curl gnupg lsb-release wget apt-transport-https ca-certificates || safe_exit_on_error "Error al instalar dependencias."

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
warp-cli connect >/dev/null 2>&1 || safe_exit_on_error "Error al conectar en modo DoH."

# --- Verificar salud del servicio y conectividad SSH local ---
sleep 3

# Si tras la conexión aún hay al menos una sesión SSH establecida, consideramos OK.
if ss -tn state established | grep -q ':22'; then
  # Señalamos al rollback que todo salió bien
  touch /tmp/warp-rollback-ok
  ui_success "Instalación completada y SSH sigue disponible."
  exit 0
else
  # No hay sesiones establecidas -> posible pérdida de conexión remota
  # Intentar desconectar WARP inmediatamente para recuperar conectividad
  warp-cli disconnect >/dev/null 2>&1 || true
  systemctl restart sshd >/dev/null 2>&1 || true
  ui_error "Instalación aplicada pero no se detectan sesiones SSH establecidas. Se intentó un rollback automático. Revisa $LOG_FILE para detalles."
fi

