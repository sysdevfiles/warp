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
ss -tn state established | grep ':22' || true
```

## Personalizar puerto SSH (si usas otro puerto)

Actualmente el script busca sesiones establecidas en `:22`. Si tu SSH usa otro puerto, hay dos opciones simples:

1. Editar temporalmente el script antes de ejecutarlo: busca la línea con `grep ':22'` y reemplázala por `grep ':PUERTO'` (por ejemplo `':2222'`).
2. Pedirme que añada una opción `--ssh-port <PUERTO>` para que el script verifique automáticamente el puerto correcto. Puedo implementarlo si lo deseas.

Ejemplo rápido (reemplazo directo):

```bash
# Hacer un backup y reemplazar 22 por 2222 (ajusta según tu puerto)
sudo cp warpinstall.sh warpinstall.sh.bak
sudo sed -i "s/:22/:2222/g" warpinstall.sh
sudo bash warpinstall.sh --warp-key TU_CLAVE
```

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
