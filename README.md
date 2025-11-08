# Instalación y uso — warpinstall.sh

Este repositorio contiene el instalador automatizado de Cloudflare WARP en modo DNS-only (DoH) para sistemas Ubuntu (22.04 / 24.04). El script principal es `warpinstall.sh` y está diseñado para ser no interactivo, silencioso y seguro: solo mostrará mensajes cortos `SUCCESS:` o `ERROR:` al usuario. Todo el detalle y trazas se escriben en `/var/log/warpinstall.log`.

## Requisitos

- Ubuntu 22.04 o 24.04 (o derivadas compatibles con `apt`).
- Acceso root (el script se relanzará con `sudo` si no se ejecuta como root).
- Arquitectura amd64.
- Conexión a Internet para descargar paquetes y la clave GPG de Cloudflare.

> Nota sobre Windows: el script no es nativo de Windows. Para usarlo desde Windows, instala y usa WSL2 con una distro Ubuntu y ejecuta el script dentro de WSL. Ejemplo desde PowerShell:

```powershell
wsl sudo bash /mnt/c/Users/ADMIN/Desktop/Github/warpinstall.sh
# o con clave WARP+
wsl sudo bash /mnt/c/Users/ADMIN/Desktop/Github/warpinstall.sh --warp-key TU_CLAVE
```

## Uso

Copiar o clonar el repositorio en una máquina Ubuntu o en WSL, y ejecutar como root.

- Sin clave WARP+ (versión gratuita):

```bash
sudo bash warpinstall.sh
```

- Con clave WARP+ (no interactivo):

```bash
sudo bash warpinstall.sh --warp-key TU_CLAVE_WARP_PLUS
```

El script imprimirá únicamente un mensaje del tipo:

- `SUCCESS: Instalación completada y SSH sigue disponible.`
- `ERROR: <mensaje descriptivo>`

Todos los detalles y salidas de comandos se guardan en `/var/log/warpinstall.log`.

## Instalar en Ubuntu (clone o wget)

Puedes instalar desde Git clonando el repositorio o descargando directamente el script con wget.

Usando git clone (recomendado si quieres mantener el repo actualizado):

```bash
git clone https://github.com/sysdevfiles/warp.git
cd warp
sudo bash warpinstall.sh
```

Con clave WARP+ y comprobación de puerto SSH alternativo:

```bash
sudo bash warpinstall.sh --warp-key TU_CLAVE_WARP_PLUS --ssh-port 2222
```

Instalar y generar la unidad systemd automáticamente (opcional):

```bash
# Genera /etc/default/warpinstall y /etc/systemd/system/warpinstall.service y habilita la unidad (no la arranca)
sudo bash warpinstall.sh --install-service

# Genera e instala la unidad y además la arranca/activa ahora
sudo bash warpinstall.sh --install-service --enable-service
```

Modo de prueba (no aplicará cambios, útil para verificar entorno):

```bash
sudo bash warpinstall.sh --dry-run
```

Usando wget para descargar solo el script y ejecutarlo directamente:

```bash
wget -O warpinstall.sh https://raw.githubusercontent.com/sysdevfiles/warp/main/warpinstall.sh
chmod +x warpinstall.sh
sudo bash warpinstall.sh
```

Nota: si tu servidor usa un puerto SSH distinto al 22, usa `--ssh-port` para que el script compruebe ese puerto y evite rollback innecesarios.

## Instalar como servicio systemd

Si quieres que la instalación se gestione vía systemd (por ejemplo para ejecutar el instalador automáticamente al arrancar o desde la unidad), el repositorio incluye una unidad de ejemplo `warpinstall.service` y un helper `install_service.sh` que realiza la instalación.

Pasos desde Ubuntu (ejecutar como root o con sudo):

```bash
# Desde la carpeta donde clonaste el repo:
sudo bash install_service.sh

# Verificar estado del servicio:
systemctl status warpinstall.service

# Para deshabilitar/parar:
systemctl disable --now warpinstall.service
```

Notas:
- `install_service.sh` copia `warpinstall.sh` a `/usr/local/bin/warpinstall.sh` y la unidad a `/etc/systemd/system/warpinstall.service`.
- Si quieres pasar argumentos (por ejemplo `--warp-key` o `--ssh-port`), edita `/etc/systemd/system/warpinstall.service` y añade los flags en la línea `ExecStart`, luego ejecuta `systemctl daemon-reload` y `systemctl restart warpinstall.service`.
- El servicio está configurado como `Type=oneshot` y `RemainAfterExit=yes` — ejecuta el script una vez y queda marcado como activo.


## Comportamiento de seguridad y rollback

- Para evitar perder acceso SSH durante la instalación (caso común al activar WARP), el script crea un pequeño script de rollback (`/usr/local/bin/warp-rollback.sh`) y lo programa para que se ejecute aproximadamente 60 segundos después de empezar la instalación.
- Si en ese lapso se detecta al menos una conexión SSH establecida en el puerto 22, el script considera que la instalación no ha roto la sesión y crea `/tmp/warp-rollback-ok` para anular el rollback.
- Si no se detectan sesiones SSH establecidas, el rollback intentará desconectar WARP y reiniciar el servicio `sshd` para restablecer el acceso.

IMPORTANTE: el script detecta conexiones SSH en el puerto 22. Si tu servidor usa un puerto SSH distinto (por ejemplo 2222), el mecanismo no detectará la sesión y podrá intentar rollback. Si ese es tu caso, solicita que añada la opción `--ssh-port` al script o edita temporalmente el patrón de comprobación (ver sección "Personalizar puerto SSH").

## Logs y diagnóstico

- Archivo principal de trazas: `/var/log/warpinstall.log` (toda la salida está ahí).
- Mensajes cortos de usuario siguen saliendo por la salida estándar (ej. `SUCCESS:` / `ERROR:`).

Comandos útiles para diagnóstico (ejecutar en la máquina Ubuntu):

```bash
sudo tail -n 200 /var/log/warpinstall.log
sudo systemctl status warp-svc
warp-cli status
sudo journalctl -u warp-svc -n 200
sudo systemctl status sshd
# Comprueba sesiones SSH establecidas (reemplaza 22 por tu puerto si usas otro)
ss -tn state established | grep ':22' || true
```

## Puerto SSH y comprobación (si usas otro puerto)

El script ahora acepta la opción `--ssh-port <PUERTO>` para que compruebe explícitamente el puerto SSH que uses y evite rollbacks innecesarios.

Ejemplos:

```bash
# Usar puerto 2222 en vez de 22
sudo bash warpinstall.sh --ssh-port 2222

# Con clave WARP+ y puerto personalizado
sudo bash warpinstall.sh --warp-key TU_CLAVE_WARP_PLUS --ssh-port 2222
```

Si por alguna razón prefieres editar el script manualmente, sigue teniendo cuidado y haz una copia de seguridad antes de cambiarlo.

## Fallos comunes y soluciones

- ERROR: `No se pudo habilitar/arrancar warp-svc.`
  - Revisa `/var/log/warpinstall.log` y `journalctl -u warp-svc`. Puede faltar dependencia o el paquete es incompatible para tu distribución.

- ERROR: `Error al importar la clave GPG.`
  - Verifica conectividad y que `gpg` está instalado. El script instala `gnupg` automáticamente; revisa el log para ver la causa exacta.

- ERROR: `Instalación aplicada pero no se detectan sesiones SSH establecidas.`
  - El script intentó rollback. Si estabas usando un puerto distinto a 22, modifica el script o pídeme que agregue la opción `--ssh-port`.

- Si la instalación falla al descargar el paquete `.deb` con versión hardcodeada, el script intenta una ruta fallback; de todas formas revisa el log y, si quieres, puedo mejorar la detección de la versión más reciente.

## Buenas prácticas

- Ejecuta el script desde una sesión local o con una consola que puedas reiniciar (si es posible). Si trabajas exclusivamente vía SSH, asegúrate de un método de recuperación (consola KVM, panel cloud) por si algo falla.
- Considera probar primero en una máquina de staging o en una VM antes de ejecutarlo en producción.

## Próximos pasos recomendados

- Si quieres, puedo:
  - Añadir `--ssh-port` y `--dry-run` como opciones del script.
  - Añadir comprobación de suma/firmas para cualquier `.deb` descargado.
  - Ejecutar `shellcheck` y aplicar correcciones de estilo Shell.

Dime qué prefieres y lo implemento.

---

Autor: Script proporcionado en este repositorio
Fecha: Nov 2025
