#!/bin/bash
# ==============================================================================
# Script de cliente Zorin: Unión, montaje y branding
# Autor: Diego S. Arancón
# ==============================================================================
# Atención: Este script requiere de intervención humana en la fase 8
# El sistema realizará un reinicio automático al finalizar con éxito
# ==============================================================================

# Motor de autorreparación
# Descripción: Detecta si el script fue editado desde Windows y posee saltos de carro incorrectos (\r).
#			   En caso positivo los eliminará para evitar que Linux indique errores de sintaxis
if grep -q $'\r' "$0"; then
    sed -i 's/\r$//' "$0"
    exec bash "$0" "$@"
fi 

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[1;31m[ERROR] Ejecuta este script como root (sudo).\033[0m"
  exit 1
fi

# --- Variables globales ---
DOMINIO="asirdiego.local"
IP_PDC="192.168.10.10"
USER_ADMIN="administrator"

# --- Sistema de Auditoría Local ---
LOG_FILE="/var/log/asir_cliente_linux.log"
touch "$LOG_FILE" && chmod 644 "$LOG_FILE"

# Códigos de escape ANSI para dar formato visual y colore a la salida de la consola
VERDE='\033[1;32m'; AZUL='\033[1;34m'; AMARILLO='\033[1;33m'; ROJO='\033[1;31m'; CYAN='\033[1;36m'; NC='\033[0m'

# ==============================================================================
# Comprobación de idempotencia y doble unión
# ==============================================================================
# Verifica si el equipo ya pertenece al dominio leyendo la caché de realmd.
# Si la membresía está activa, aborta para no corromper los tickets de Kerberos.
if realm list | grep -q "$DOMINIO"; then
    echo -e "\n${AMARILLO}[WARNING] El equipo ya pertenece al dominio $DOMINIO.${NC}"
    echo -e "${VERDE}[OK] Abortando la ejecución por seguridad (Idempotencia).${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] Ejecución abortada: Prevención de doble unión (Double-Join)." >> "$LOG_FILE"
    exit 0
fi

#------------------------------------------------------------------------------------------------------------------
# Función: Mostrar_carga
# Descripción: Muestra una barra de progreso mientras se ejecuta un proceso en segundo plano
# Parámetros: $1 (MENSAJE) → Cadena de texto descriptiva que se mostrará sobre la barra de progreso.
#------------------------------------------------------------------------------------------------------------------
mostrar_carga() {
    local PID=$!
    local MENSAJE=$1
    local ANCHO=40      
    local i=0
	
    tput civis # Oculta el cursos de la terminal
    echo -ne "${AZUL}[*]${NC} ${MENSAJE}...\n"
	
	# Bucle activo mientras el proceso siga corriendo
    while kill -0 $PID 2>/dev/null; do
        printf "\r  ${CYAN}["
        for ((j=0; j<i; j++)); do printf "█"; done
        for ((j=i; j<ANCHO; j++)); do printf "-"; done
        printf "]${NC}"
        i=$(( (i + 1) % (ANCHO + 1) ))
        sleep 0.15
    done
	
	# Rellena la barra al 100% al terminal el proceso
    printf "\r  ${VERDE}["
    for ((j=0; j<ANCHO; j++)); do printf "█"; done
    printf "] 100%%${NC}\n"
    tput cvvis # Restaura el cursor de la terminal
}

clear
echo -e "${AMARILLO}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${AMARILLO}║   CLIENTE ZORIN OS: ENROLAMIENTO Y BRANDING NATIVO     ║${NC}"
echo -e "${AMARILLO}╚════════════════════════════════════════════════════════╝${NC}\n"


# ===========================================
# FASE 1: Paqueteria crítica y dependencias
# ===========================================
# Detenemos procesos automáticos de actualización en segundo plano para evitar que bloqueen la base de datos de "dpkg" y provoquen un fallo
(
    systemctl stop unattended-upgrades 2>/dev/null
    systemctl stop packagekit 2>/dev/null
    while pgrep -a apt >/dev/null; do sleep 2; done
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq > /dev/null 2>&1
    apt-get install -y -qq virtualbox-guest-utils virtualbox-guest-x11 realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin oddjob oddjob-mkhomedir packagekit libpam-mount cifs-utils dconf-cli > /dev/null 2>&1
) &
mostrar_carga "Instalando paquetería crítica"

# ===========================================
# FASE 2: Resolución de nombres multicast (mDNS)
# Desactivamos el demonio de avahi porque Linux emplea el protocolo mDNS para resolver dominios terminados 
# en ".local"
# ===========================================
(
    sed -i 's/mdns4_minimal \[NOTFOUND=return\] //' /etc/nsswitch.conf
    systemctl disable --now avahi-daemon 2>/dev/null
) &
mostrar_carga "Desactivando bloqueos mDNS"

# ===========================================
# FASE 3: Enrutamiento DNS hacia el controlador del dominio
# Modificamos systemd-resolved para forzar que las consultas DNS apunten a la IP estática del servidor principal
# ===========================================
(
    sed -i "s/#DNS=/DNS=$IP_PDC/" /etc/systemd/resolved.conf
    sed -i "s/#Domains=/Domains=$DOMINIO/" /etc/systemd/resolved.conf
    systemctl restart systemd-resolved
    sleep 3
) &
mostrar_carga "Forzando DNS al Servidor PDC"

# ===========================================
# FASE 4: Sincronización temporal (Requisito para Kerberos)
# El protocolo Kerberos rechaza la validación de tickets si existe un desfase de más de 5 minutos entre cliente y servidor
# ===========================================
(
    timedatectl set-ntp true
    systemctl restart systemd-timesyncd
) &
mostrar_carga "Sincronizando reloj para Kerberos"

# ===========================================
# FASE 5: Purga de cachés y estados previos
# ===========================================
(
    systemctl stop sssd > /dev/null 2>&1
    rm -f /var/lib/sss/db/* /var/lib/sss/mc/*
) &
mostrar_carga "Limpiando cachés previas"

# ===========================================
# FASE 6: Montaje automático de red
# Configuramos pam_mount para que monte la unidad de red al iniciar sesión
# Se incluyen las variables estrictas %(USERUID) y %(USERGID) para que Linux asigne la propiedad del montaje al usuario de red correcto
# ===========================================
(
cat <<EOF > /etc/security/pam_mount.conf.xml
<?xml version="1.0" encoding="utf-8" ?>
<!DOCTYPE pam_mount SYSTEM "pam_mount.conf.xml.dtd">
<pam_mount>
  <debug enable="0" />
  <volume user="*" fstype="cifs" server="$IP_PDC" path="compartidas" mountpoint="/home/%(USER)/Compartida_H" options="nosuid,nodev,sec=ntlmssp,uid=%(USERUID),gid=%(USERGID),workgroup=asirDiego,vers=3.0" />
  <mntoptions allow="nosuid,nodev,loop,encryption,fsck,nonempty,allow_root,allow_other" />
  <mkmountpoint enable="1" remove="true" />
</pam_mount>
EOF
) &
mostrar_carga "Configurando montaje SSO (Unidad H: compartida)"

# ===========================================
# FASE 7: Hardening del entorno gráfico
# Por privacidad y seguridad corporativa, ocultamos la lista visual de usuarios en la pantalla de inicio de sesión
# ===========================================
(
    mkdir -p /etc/dconf/profile /etc/dconf/db/gdm.d
    echo -e "user-db:user\nsystem-db:gdm\nfile-db:/usr/share/gdm/greeter-dconf-defaults" > /etc/dconf/profile/gdm
    echo -e "[org/gnome/login-screen]\ndisable-user-list=true" > /etc/dconf/db/gdm.d/00-login-screen
    if [ -f /etc/gdm3/greeter.dconf-defaults ]; then sed -i 's/^# disable-user-list=true/disable-user-list=true/g' /etc/gdm3/greeter.dconf-defaults; fi
    dconf update > /dev/null 2>&1
) &
mostrar_carga "Ocultando lista de usuarios"

# ===========================================
# FASE 8: Enrolamiento en Active Directory
# Introducimos manualmente la contraseña del administrador para unir el equipo al dominio
# ===========================================
echo -e "${AZUL}=== [8/9] UNIÓN AL DOMINIO ===${NC}"
echo -e "${AMARILLO}[WARNING] Introduce la contraseña de $USER_ADMIN (Asir1234):${NC}"
realm join -U $USER_ADMIN $DOMINIO

if [ $? -ne 0 ]; then
    echo -e "${ROJO}[ERROR] Fallo en la unión. Revisa la red.${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Fallo crítico al intentar unir el equipo al dominio." >> "$LOG_FILE"
    exit 1
fi

# ===========================================
# FASE 9: Ajustes finales y branding corporativo
# ===========================================
(
    #1. Configuración de SSSD: Limpiamos los nombres (sin sufijo @dominio) y permitimos el uso de la terminal Bash
    sed -i 's/use_fully_qualified_names = True/use_fully_qualified_names = False/g' /etc/sssd/sssd.conf
    sed -i 's/fallback_homedir = \/home\/%u@%d/fallback_homedir = \/home\/%u/g' /etc/sssd/sssd.conf
    sed -i "/\[domain\/$DOMINIO\]/a ad_gpo_access_control = permissive" /etc/sssd/sssd.conf
    sed -i "/\[domain\/$DOMINIO\]/a default_shell = \/bin\/bash" /etc/sssd/sssd.conf
    systemctl restart sssd
    
    # 2. Resolución de conflicto PAM: Forzamos la máxima prioridad (999) para crear la carpeta personal antes
    cat <<EOF > /usr/share/pam-configs/mkhomedir
Name: Create home directory on login
Default: yes
Priority: 999
Session-Type: Additional
Session:
        required        pam_mkhomedir.so umask=0022 skel=/etc/skel
EOF
    # Activamos explicitamente ambas configuraciones de forma forzosa
    pam-auth-update --enable mkhomedir --enable mount --force > /dev/null 2>&1
    
    # 3. Otorgamos permisos locales automáticos a los administradores del dominio
    echo "%domain\ admins ALL=(ALL:ALL) ALL" > /etc/sudoers.d/domain_admins
    chmod 0440 /etc/sudoers.d/domain_admins
    
    # 4. Descargamos el icono corporativo directamente de GitHub
    wget -qO "/usr/share/pixmaps/icono_empresa.ico" "https://raw.githubusercontent.com/TheGoram/recursos_asir/refs/heads/main/icono_empresa.ico"
    chmod 644 "/usr/share/pixmaps/icono_empresa.ico"

    # 5. Creamos el script de inicio del usuario
    # Empleamos la herramienta GIO nativa de Linux para inyectar los metadatos visuales del icono sobre el enlace simbolico en el momento que se genera
    mkdir -p /etc/xdg/autostart
    cat << 'EOF' > /etc/xdg/autostart/acceso_escritorio.desktop
[Desktop Entry]
Type=Application
Name=Carpeta Corporativa
Exec=bash -c 'for i in {1..3}; do sleep 5; if [ -d "$HOME/Compartida_H" ]; then DIR_ESC="$HOME/Escritorio"; [ ! -d "$DIR_ESC" ] && DIR_ESC="$HOME/Desktop"; ln -sf "$HOME/Compartida_H" "$DIR_ESC/Carpeta_Corporativa"; gio set -t string "$DIR_ESC/Carpeta_Corporativa" metadata::custom-icon "file:///usr/share/pixmaps/icono_empresa.ico" 2>/dev/null; break; fi; done'
Icon=folder-remote
X-GNOME-Autostart-enabled=true
EOF
) &
mostrar_carga "Finalizando perfiles, accesos y Branding"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] Equipo aprovisionado y unido al dominio correctamente." >> "$LOG_FILE"

# ===========================================
# Final y reinicio
# ===========================================
echo -e "${VERDE}[FIN] ¡EQUIPO ZORIN CONFIGURADO CON ÉXITO!${NC}"
echo -e "${AMARILLO}[*] Reiniciando la máquina en 5 segundos...${NC}"
sleep 5
reboot