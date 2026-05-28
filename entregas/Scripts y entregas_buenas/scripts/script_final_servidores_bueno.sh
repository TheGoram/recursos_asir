#!/bin/bash
# ==============================================================================
# Script maestro: Alta disponibilidad, segmentacion y seguridad
# Autor: Diego S. Arancón
# PROYECTO: asirDiego.local - DESPLIEGUE AUTOMATIZADO ZERO-TOUCH (VERSIÓN VISUAL)
# ==============================================================================
# Atención: Este script requiere de intervención manual al inicio para elegir rol del servidor
# ==============================================================================

# --- Motor de autorreparación Zero-Touch ---
# Previene errores de sintaxis si el archivo se edito en Windows
if grep -q $'\r' "$0"; then
    echo -e "\033[1;33m[*] Detectado formato de Windows. Autocorrigiendo el script...\033[0m"
    sed -i 's/\r$//' "$0"
    exec bash "$0" "$@"
fi 

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[1;31m[ERROR] Ejecuta este script como root (sudo).\033[0m"
  exit 1
fi

# --- Variables globales ---
DOMINIO="asirdiego.local"               # Nombre DNS del dominio
REALM="ASIRDIEGO.LOCAL"                 # Reino Kerberos
NETBIOS="asirDiego"                     # Nombre corto de red compatible con sistemas Legacy
PASS_ADMIN="Asir1234"                   # Contraseña maestra de Active Directory
BASE_DIR="/srv/samba/compartidas"       # Raíz del File Server para almacenamiento

IF_EXT="enp0s3"                         # Interfaz WAN (Salida NAT a Internet)
IF_LIN="enp0s8"                         # Interfaz LAN para la subred aislada del cliente Zorin
IF_WIN="enp0s9"                         # Interfaz LAN para la subred aislada del cliente Windows

IP_PDC_LIN="192.168.10.10"; IP_SDC_LIN="192.168.10.11"  # Direccionamiento estático Red Linux
IP_PDC_WIN="192.168.20.10"; IP_SDC_WIN="192.168.20.11"  # Direccionamiento estático Red Windows

# --- Variables de monitorización y alertas (Telegram) ---
TG_TOKEN="8619636867:AAGt1g74yk-tFCLUm6INxCaD4w6y49DuYkg"       # Token de la API de del bot de Telegram
TG_CHAT_ID="1442624516"                                         # ID del chat del administrador

LOG_FILE="/var/log/despliegue_asir.log"         # Archivo inmutable de la trazabilidad de logs
touch "$LOG_FILE" && chmod 644 "$LOG_FILE"

# ==============================================================================
# Códigos de escape ANSI para la interfaz visual interactiva
# ==============================================================================
VERDE='\033[1;32m'; AZUL='\033[1;34m'; AMARILLO='\033[1;33m'; ROJO='\033[1;31m'; CYAN='\033[1;36m'; NC='\033[0m'

# ==============================================================================
# Función: registrar_log
# Descripción: Inyecta una traza de auditoria con marca de tiempo en el log centralizado
# ==============================================================================
registrar_log() {
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] [$1] $2" >> "$LOG_FILE"
}

# ==============================================================================
# Función: mostrar_carga
# Descripción: Muestra una barra de progreso mientras el proceso se ejecuta en segundo plano
# ==============================================================================
mostrar_carga() {
    local PID=$!
    local MENSAJE=$1
    local ANCHO=40      
    local VELOCIDAD=0.15 
    local i=0

    tput civis
    echo -ne "${AZUL}[*]${NC} ${MENSAJE}...\n"
    while kill -0 $PID 2>/dev/null; do
        printf "\r  ${CYAN}["
        for ((j=0; j<i; j++)); do printf "█"; done
        for ((j=i; j<ANCHO; j++)); do printf "-"; done
        printf "]${NC}"
        i=$(( (i + 1) % (ANCHO + 1) ))
        sleep $VELOCIDAD
    done
    printf "\r  ${VERDE}["
    for ((j=0; j<ANCHO; j++)); do printf "█"; done
    printf "] 100%%${NC}\n"
    echo -e "${VERDE}[OK]${NC} Tarea completada.\n"
    tput cvvis
}

# ==============================================================================
# INICIO DEL MENÚ
# ==============================================================================
clear
echo -e "${AMARILLO}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${AMARILLO}║  MODO ENTERPRISE: SEGMENTACIÓN, HTTPS, BACKUP Y XRDP   ║${NC}"
echo -e "${AMARILLO}╚════════════════════════════════════════════════════════╝${NC}"
echo -e "Selecciona el rol para este servidor:"
echo -e "  1) Servidor Principal (DC1)"
echo -e "  2) Servidor Secundario (DC2)"
read -p "Opción (1 o 2): " OPCION_ROL

if [ "$OPCION_ROL" == "1" ]; then
    ROL="PDC"; MI_IP_LIN=$IP_PDC_LIN; MI_IP_WIN=$IP_PDC_WIN; MI_HOST="srv-pdc"
else
    ROL="SDC"; MI_IP_LIN=$IP_SDC_LIN; MI_IP_WIN=$IP_SDC_WIN; MI_HOST="srv-sdc"
fi

registrar_log "INFO" "Iniciando despliegue como $ROL"
echo -e "\n${VERDE}[INFO] Iniciando instalación masiva visual...${NC}\n"

# ==============================================================================
# FASE 1: RED SEGMENTADA (NETPLAN) Y PARCHE DNS
# ==============================================================================
# Configura el enrutamiento y aisla las subredes. Resuelve el bug nativo de Ubuntu con systemd-resolved
# que entra en conflicto con el DNS de Samba 4
echo -e "${AZUL}=== [1/10] PREPARACIÓN DE RED Y HOSTS ===${NC}"
(
    hostnamectl set-hostname $MI_HOST
    systemctl disable --now systemd-resolved > /dev/null 2>&1
    unlink /etc/resolv.conf 2>/dev/null
    
    # Inyección de los hosts para la resolucion local inmediata
    echo "127.0.0.1 localhost" > /etc/hosts
    echo "$MI_IP_LIN $MI_HOST.$DOMINIO $MI_HOST" >> /etc/hosts
    
    if [ "$ROL" == "PDC" ]; then
        echo "$IP_SDC_LIN srv-sdc.$DOMINIO srv-sdc" >> /etc/hosts
    else
        echo "$IP_PDC_LIN srv-pdc.$DOMINIO srv-pdc" >> /etc/hosts
    fi

cat <<EOF > /etc/netplan/01-net.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $IF_EXT: { dhcp4: true }
    $IF_LIN: { dhcp4: false, addresses: [$MI_IP_LIN/24] }
    $IF_WIN: { dhcp4: false, addresses: [$MI_IP_WIN/24] }
EOF
    chmod 600 /etc/netplan/01-net.yaml
    netplan apply > /dev/null 2>&1
    
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    
    # Bucle de espera de red activa. Evita que la fase 2 intente descargar paquetes antes de que Netplan haya terminado
    for i in {1..20}; do
        if ping -c 1 ubuntu.com >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
) &
mostrar_carga "Aplicando subredes e identidades de host"
registrar_log "SUCCESS" "Red segmentada."

# ==============================================================================
# FASE 2: PAQUETERÍA (CORE DEL SISTEMA)
# ==============================================================================
# Instalación desatendida de la infraestructura. Hace uso de debconf para pre-contestar a las ventanas
# interactivas de kerberos e iptables
echo -e "\n${AZUL}=== [2/10] CORE DEL SISTEMA Y DEPENDENCIAS ===${NC}"
export DEBIAN_FRONTEND=noninteractive

echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
echo "krb5-config krb5-config/default_realm string $REALM" | debconf-set-selections

systemctl stop unattended-upgrades >/dev/null 2>&1
systemctl disable unattended-upgrades >/dev/null 2>&1
while pgrep -a apt >/dev/null; do sleep 3; done

apt-get update -qq >> "$LOG_FILE" 2>&1 &
mostrar_carga "Actualizando repositorios de Ubuntu"

apt-get install -y -qq virtualbox-guest-utils acl attr samba samba-dsdb-modules winbind libpam-winbind krb5-user isc-dhcp-server rsync apache2 mariadb-server php libapache2-mod-php php-mysql curl openssl iptables-persistent openssh-server xrdp xfce4 cron >> "$LOG_FILE" 2>&1 &
mostrar_carga "Descargando e instalando paquetería crítica (Samba, LAMP, VBox, XRDP)"

if ! command -v samba-tool &> /dev/null; then
    echo -e "\n${ROJO}[ERROR FATAL] La instalación de paquetes ha fallado.${NC}"
    echo -e "${AMARILLO}Revisa el archivo de log para ver el motivo exacto ejecutando:${NC}"
    echo -e "cat $LOG_FILE"
    exit 1
fi

(
    timedatectl set-ntp true
    adduser xrdp ssl-cert > /dev/null 2>&1
    echo "xfce4-session" > /home/diego/.xsession 2>/dev/null
    echo "allowed_users=anybody" > /etc/X11/Xwrapper.config 2>/dev/null
    systemctl enable --now ssh xrdp > /dev/null 2>&1
    
    # Arrancamos el servidor en modo consola
    # El entorno gráfico queda latente solo para conexiones remotas (RDP) ahorrando recursos
    systemctl set-default multi-user.target > /dev/null 2>&1
) &
mostrar_carga "Configurando NTP y Entorno Gráfico Remoto"
registrar_log "SUCCESS" "Paquetería base instalada con éxito."

# ==============================================================================
# FASE 3: ACTIVE DIRECTORY (SAMBA 4 MULTI-SUBRED)
# ==============================================================================
# Provisiona o une el equipo al dominio. Aplica bastionado forzando a Samba a escuchar exclusivamente
# en las interfaces LAN internas, protegiendo el Active Directory
echo -e "\n${AZUL}=== [3/10] ACTIVE DIRECTORY ===${NC}"
(
    systemctl stop smbd nmbd winbind samba-ad-dc > /dev/null 2>&1
    rm -f /etc/samba/smb.conf

    if [ "$ROL" == "PDC" ]; then
        samba-tool domain provision --use-rfc2307 --realm=${REALM} --domain=${NETBIOS^^} --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass=${PASS_ADMIN} > /dev/null 2>&1
    else
        echo "nameserver $IP_PDC_LIN" > /etc/resolv.conf
        samba-tool domain join $DOMINIO DC -U"administrator" --password="${PASS_ADMIN}" > /dev/null 2>&1
    fi

    # Blindaje de escuha e inyección de subredes soportadas
    sed -i "/\[global\]/a \ \ \ \ dns forwarder = 8.8.8.8\n\ \ \ \ bind interfaces only = yes\n\ \ \ \ interfaces = lo $IF_LIN $MI_IP_LIN $IF_WIN $MI_IP_WIN" /etc/samba/smb.conf
    
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    systemctl unmask samba-ad-dc > /dev/null 2>&1
    systemctl mask smbd nmbd winbind > /dev/null 2>&1
    systemctl enable --now samba-ad-dc > /dev/null 2>&1


    # Elimina el registro automático que Samba crea para la IP de NAT (WAN)
    # Esto previene errores de "Timeout" al unir clientes Windows al dominio
    sleep 5
    IP_WAN=$(ip -4 addr show $IF_EXT | awk '/inet / {print $2}' | cut -d/ -f1)
    samba-tool dns delete localhost $DOMINIO $MI_HOST A $IP_WAN -U administrator%"$PASS_ADMIN" > /dev/null 2>&1
    samba-tool dns add localhost $DOMINIO $MI_HOST A $MI_IP_WIN -U administrator%"$PASS_ADMIN" > /dev/null 2>&1
) &
mostrar_carga "Provisionando/Uniendo Base de Datos de Active Directory"
registrar_log "SUCCESS" "AD configurado."

# ==============================================================================
# Fase 4: DHCP FAILOVER MULTI-SUBRED
# ==============================================================================
# Despliega un clúster DHCP mediante el protocolo "failover peer".
# Balancea la carga de concesiones de IPs (split 128) garantizando tolerancia a fallos
echo -e "\n${AZUL}=== [4/10] DHCP HA FAILOVER ===${NC}"
(
    sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$IF_LIN $IF_WIN\"/g" /etc/default/isc-dhcp-server
    
    if [ "$ROL" == "PDC" ]; then
        TIPO="primary"; P_IP_LIN=$IP_SDC_LIN; EX="split 128; mclt 1800;"
    else
        TIPO="secondary"; P_IP_LIN=$IP_PDC_LIN; EX=""
    fi

cat <<EOF > /etc/dhcp/dhcpd.conf
authoritative;
failover peer "dhcp-failover" {
  $TIPO; address $MI_IP_LIN; port 647; peer address $P_IP_LIN; peer port 647;
  max-response-delay 30; max-unacked-updates 10; load balance max seconds 3; $EX
}

subnet 192.168.10.0 netmask 255.255.255.0 {
  option routers $IP_PDC_LIN; option domain-name "$DOMINIO";
  option domain-name-servers $IP_PDC_LIN, $IP_SDC_LIN;
  pool { failover peer "dhcp-failover"; range 192.168.10.100 192.168.10.200; }
}

subnet 192.168.20.0 netmask 255.255.255.0 {
  option routers $IP_PDC_WIN; option domain-name "$DOMINIO";
  option domain-name-servers $IP_PDC_WIN, $IP_SDC_WIN;
  pool { failover peer "dhcp-failover"; range 192.168.20.100 192.168.20.200; }
}
EOF
    systemctl restart isc-dhcp-server > /dev/null 2>&1
) &
mostrar_carga "Configurando Balanceo de Carga DHCP"
registrar_log "SUCCESS" "DHCP configurado."

# ==============================================================================
# FASE 5: ALMACENAMIENTO Y RSYNC
# ==============================================================================
# Crea la estructra del File Server, descarga el branding corporativo de GitHub y configura el motor de
# sincronización (SDC como demonio y PDC mediante Cron)
echo -e "\n${AZUL}=== [5/10] ARCHIVOS COMPARTIDOS Y RSYNC ===${NC}"
(
    mkdir -p "$BASE_DIR"/{Publica,Direccion,Ventas,Tecnicos}
    
    # Inyección de branding corporativo
    wget -qO "$BASE_DIR/Publica/icono_empresa.ico" "https://raw.githubusercontent.com/TheGoram/recursos_asir/refs/heads/main/icono_empresa.ico"
    chmod 644 "$BASE_DIR/Publica/icono_empresa.ico"

    if [ "$ROL" == "SDC" ]; then
        echo -e "[compartidas]\n path=$BASE_DIR\n read only=no\n uid=root\n gid=root" > /etc/rsyncd.conf
        systemctl enable --now rsync > /dev/null 2>&1
    else
        cat <<EOF >> /etc/samba/smb.conf

[compartidas]
    path = $BASE_DIR
    read only = no
    guest ok = no
EOF
        smbcontrol all reload-config > /dev/null 2>&1
        # El PDC empuja los cambios al SDC de forma desatendida mediante sincronización
        (crontab -l 2>/dev/null; echo "* * * * * rsync -a --delete $BASE_DIR/ rsync://$IP_SDC_LIN/compartidas/ > /dev/null 2>&1") | crontab -
    fi
) &
mostrar_carga "Estructurando directorios, sincronía e inyección de Branding"
registrar_log "SUCCESS" "Directorios departamentales, Rsync e Icono Corporativo configurados."

# ==============================================================================
# FASE 6: INTRANET HA Y HTTPS (PHP CON SEGURIDAD Y REDIRECCIÓN DINÁMICA)
# ==============================================================================
# Despliega una intranet corporativa PHP/MySQL previniendo inyección SQL (bind_param)
# Implementa lógica dinamica: Escanea Samba para auto-crear portales departamentales
# Cifra las comunicaciones forzando redirección (HTTP 301) hacia el puerto HTTPS (443)
echo -e "\n${AZUL}=== [6/10] INTRANET SEGURA (HTTPS) ===${NC}"
(
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS intranet_db; CREATE USER IF NOT EXISTS 'webadmin'@'localhost' IDENTIFIED BY 'AsirWeb2026\!'; GRANT ALL PRIVILEGES ON intranet_db.* TO 'webadmin'@'localhost'; FLUSH PRIVILEGES;" > /dev/null 2>&1
    mysql -u root -e "USE intranet_db; CREATE TABLE IF NOT EXISTS registro_visitas (id INT AUTO_INCREMENT PRIMARY KEY, usuario VARCHAR(50), fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP);" > /dev/null 2>&1

cat << 'EOF' > /var/www/html/index.php
<?php
$conn = new mysqli("localhost", "webadmin", "AsirWeb2026!", "intranet_db");
if ($conn->connect_error) { die("Error de conexión a BD: " . $conn->connect_error); }

$grupo_usuario = "";

// Lógica 1: Inserción de un nuevo fichaje y verificación dinámica de grupos
if(isset($_POST["nombre"])){
    $usuario = $_POST["nombre"];
    $s=$conn->prepare("INSERT INTO registro_visitas (usuario) VALUES (?)");
    $s->bind_param("s",$usuario);
    $s->execute();

    // Lógica Zero-Touch: Escanea las carpetas de Samba buscando al usuario
    $base = "/srv/samba/compartidas/";
    $directorios = glob($base . '*', GLOB_ONLYDIR);
    foreach($directorios as $dir) {
        if (is_dir($dir . "/" . $usuario)) {
            $grupo_usuario = basename($dir);
            break;
        }
    }
    if(!$grupo_usuario) $grupo_usuario = "Publica";

    // Creación automática del portal del departamento si no existe
    $file = "/var/www/html/" . strtolower($grupo_usuario) . ".php";
    if (!file_exists($file)) {
        $content = "<h1>Panel de Acceso Restringido: " . strtoupper($grupo_usuario) . "</h1><p>Recursos exclusivos generados automáticamente para el grupo.</p><a href='index.php'>Volver al Fichaje</a>";
        file_put_contents($file, $content);
    }
}

// Lógica 2: Mantenimiento (Purga total protegida)
if(isset($_POST["limpiar"])){
    if($_POST["clave_admin"] === "Asir1234") {
        $conn->query("TRUNCATE TABLE registro_visitas");
        $alerta = "✅ Base de datos purgada correctamente.";
    } else {
        $alerta_error = "❌ Acceso Denegado: Contraseña de IT incorrecta.";
    }
}
?>
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><title>Intranet ASIR - Admin</title>
<style>
body{font-family:Arial,sans-serif; margin:40px; background:#f4f4f9;}
.caja{background:white; padding:20px; border-radius:5px; border:1px solid #ddd; margin-bottom:20px;}
table{border-collapse:collapse; width:100%;} th,td{padding:10px; border:1px solid #ddd; text-align:left;} th{background:#0056b3; color:white;}
.panel-rojo{background:#ffebee; border:1px solid #f44336;}
.btn{padding:10px 15px; color:white; border:none; cursor:pointer; font-weight:bold; border-radius:3px;}
.btn-azul{background:#0056b3;} .btn-rojo{background:#f44336;} .btn-rojo:hover{background:#d32f2f;}
.btn-verde{background:#2e7d32; text-decoration:none; display:inline-block; margin-top:10px;}
.alerta{color:green; font-weight:bold;} .alerta-error{color:red; font-weight:bold;}
</style></head><body>
<h1>🏢 Portal Corporativo ASIR - Fichaje (Zero-Touch)</h1>
<?php if(isset($alerta)) echo "<p class='alerta'>$alerta</p>"; ?>
<?php if(isset($alerta_error)) echo "<p class='alerta-error'>$alerta_error</p>"; ?>

<div class="caja">
    <h3>Fichaje de Empleados</h3>
    <form method="POST"><input type="text" name="nombre" placeholder="Tu identificador..." required style="padding:8px; width:200px;">
    <button type="submit" class="btn btn-azul">Registrar Entrada</button></form>
    
    <?php if($grupo_usuario): ?>
        <div style="margin-top:15px; border-top:1px solid #eee; padding-top:10px;">
            <p>Bienvenido. Se han detectado credenciales para el grupo: <b><?php echo $grupo_usuario; ?></b></p>
            <a href="<?php echo strtolower($grupo_usuario); ?>.php" class="btn btn-verde">Ir a mi Panel de Departamento</a>
        </div>
    <?php endif; ?>
</div>

<div class="caja panel-rojo">
    <h3 style="color:#d32f2f; margin-top:0;">⚙️ Panel de Mantenimiento (DB Admin)</h3>
    <p>Acción crítica: Purgar la tabla <b>registro_visitas</b>. Solo para uso del departamento IT.</p>
    <form method="POST">
        <input type="password" name="clave_admin" placeholder="Contraseña Admin..." required style="padding:8px; width:150px;">
        <input type="hidden" name="limpiar" value="1">
        <button type="submit" class="btn btn-rojo">🗑️ Purgar Base de Datos</button>
    </form>
</div>

<table><tr><th>ID</th><th>Usuario</th><th>Fecha (Timestamp MySQL)</th></tr>
<?php $r=$conn->query("SELECT * FROM registro_visitas ORDER BY fecha DESC LIMIT 15");
if($r->num_rows > 0){ while($row=$r->fetch_assoc()){echo "<tr><td>".$row["id"]."</td><td>".$row["usuario"]."</td><td>".$row["fecha"]."</td></tr>";} }
else { echo "<tr><td colspan='3' style='text-align:center;'>La base de datos está vacía.</td></tr>"; } ?>
</table></body></html>
EOF
    rm -f /var/www/html/index.html
    
    # Aseguro que Apache pueda generar los archivos PHP al vuelo
    chown -R www-data:www-data /var/www/html

    # Generación de certificado SSL autofirmado (X.509)
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/apache-selfsigned.key -out /etc/ssl/certs/apache-selfsigned.crt -subj "/C=ES/ST=Soria/L=Soria/O=ASIR/OU=IT/CN=intranet.$DOMINIO" > /dev/null 2>&1
    a2enmod ssl rewrite > /dev/null 2>&1

cat <<EOF > /etc/apache2/sites-available/000-default.conf
<VirtualHost *:80>
    ServerName intranet.$DOMINIO
    Redirect permanent / https://intranet.$DOMINIO/
</VirtualHost>
<VirtualHost *:443>
    ServerName intranet.$DOMINIO
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/apache-selfsigned.crt
    SSLCertificateKeyFile /etc/ssl/private/apache-selfsigned.key
</VirtualHost>
EOF
    systemctl restart apache2 > /dev/null 2>&1
) &
mostrar_carga "Desplegando Base de Datos y portal web cifrado dinámico"
registrar_log "SUCCESS" "Intranet corporativa y redirección HTTPS operativos."

# ==============================================================================
# FASE 7: AD OBJECTS, ENRUTAMIENTO Y BACKUPS (SOLO PDC)
# ==============================================================================
# Realiza configuraciones exclusivas del servidor principal. Habilita NAT, crea los grupos base y despliega
# el script de copias de seguridad LPAD "online" 
echo -e "\n${AZUL}=== [7/10] PERMISOS AVANZADOS Y ENRUTAMIENTO ===${NC}"
if [ "$ROL" == "PDC" ]; then
    (
        samba-tool domain passwordsettings set --history-length=0 > /dev/null 2>&1
        samba-tool domain passwordsettings set --min-pwd-age=0 > /dev/null 2>&1
        samba-tool domain passwordsettings set --max-pwd-age=0 > /dev/null 2>&1

        for G in "Direccion" "Tecnicos" "Ventas"; do samba-tool group add "$G" > /dev/null 2>&1; done
        samba-tool user create "DiegoJefe" "$PASS_ADMIN" --use-username-as-cn > /dev/null 2>&1
        samba-tool group addmembers "Domain Admins" "DiegoJefe" > /dev/null 2>&1
        
        chown -R root:"domain admins" "$BASE_DIR" 2>/dev/null
        chmod -R 775 "$BASE_DIR"
        chmod 1777 "$BASE_DIR/Publica" # Sticky Bit para evitar borrados ajenos
        
        # Registros DNS Round-Robin para la intranet
        samba-tool dns add localhost $DOMINIO intranet A $IP_PDC_LIN -U administrator --password=$PASS_ADMIN > /dev/null 2>&1
        samba-tool dns add localhost $DOMINIO intranet A $IP_SDC_LIN -U administrator --password=$PASS_ADMIN > /dev/null 2>&1
        
        # Enrutamiento IPv4 (NAT/Gateway)
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-sysctl.conf
        sysctl -p /etc/sysctl.d/99-sysctl.conf > /dev/null 2>&1
        
cat <<'EOF' > /usr/local/bin/backup_total.sh
#!/bin/bash
DIR="/srv/samba/compartidas/Direccion/Backups"
mkdir -p "$DIR"
FECHA=$(date +%Y%m%d_%H%M)
samba-tool domain backup online --targetdir="$DIR" --server=127.0.0.1 -U Administrator%"Asir1234" > /dev/null
mysqldump -u root intranet_db > "$DIR/db_$FECHA.sql"
tar -czf "$DIR/web_$FECHA.tar.gz" /var/www/html/ > /dev/null
find "$DIR" -type f -mtime +7 -delete
EOF
        chmod +x /usr/local/bin/backup_total.sh
        (crontab -l 2>/dev/null; echo "0 3,15 * * * /usr/local/bin/backup_total.sh") | crontab -
    ) &
    mostrar_carga "Configurando Enrutamiento, Grupos y Backups"
    registrar_log "SUCCESS" "Objetos AD, Enrutamiento IPv4 y tareas de Backup configurados."
else
    echo -e "${AMARILLO}[INFO] Saltando Objetos y Backups (Es SDC)${NC}"
    registrar_log "INFO" "Omitiendo creación de Objetos AD y Backups (Rol de ejecución: SDC)."
fi

# Inyección de privilegios sudoers
echo "DiegoJefe ALL=(ALL:ALL) ALL" > /etc/sudoers.d/diego_jefe
chmod 0440 /etc/sudoers.d/diego_jefe

# ==============================================================================
# FASE 8: VIGILANTE TELEGRAM (SOLO SDC)
# ==============================================================================
# Demonio de monitorización continua. Usa un "ESTADO_FILE" para recordar el estado del PDC y evitar
# el envio masivo de mensajes (Anti-Spam)
echo -e "\n${AZUL}=== [8/10] VIGILANCIA PROACTIVA (TELEGRAM) ===${NC}"
if [ "$ROL" == "SDC" ]; then
    (
cat <<EOF > /usr/local/bin/check_pdc.sh
#!/bin/bash
ESTADO_FILE="/tmp/pdc_caido"
if ! ping -c 2 $IP_PDC_LIN > /dev/null 2>&1; then
    if [ ! -f "\$ESTADO_FILE" ]; then
        curl -k -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" -d "text=[ALERTA] ASIR: PDC caído. El SDC asume el control." > /dev/null
        touch "\$ESTADO_FILE"
    fi
else
    if [ -f "\$ESTADO_FILE" ]; then
        curl -k -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" -d "text=[INFO] ASIR: PDC recuperado. Restableciendo normalidad." > /dev/null
        rm -f "\$ESTADO_FILE"
    fi
fi
EOF
        chmod +x /usr/local/bin/check_pdc.sh
        (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/check_pdc.sh") | crontab -
    ) &
    mostrar_carga "Activando demonio de alertas PUSH"
    registrar_log "SUCCESS" "Demonio de vigilancia por Telegram configurado y en ejecución."
else
    echo -e "${AMARILLO}[INFO] Saltando Vigilante (Es PDC)${NC}"
    registrar_log "INFO" "Omitiendo Vigilante de Telegram (Rol de ejecución: PDC)."
fi

# ==============================================================================
# FASE 9: HARDENING Y FIREWALL (iptables)
# ==============================================================================
# Implementa el modelo "Default DROP". Bloquea todo el tráfico externo de base y permite explicitamente
# el trafico LAN y el enmascaramiento de salida (Masquerade)
echo -e "\n${AZUL}=== [9/10] HARDENING Y FIREWALL (iptables) ===${NC}"
(
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -P INPUT DROP
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    iptables -A INPUT -p tcp -s 192.168.10.0/24 -j ACCEPT
    iptables -A INPUT -p tcp -s 192.168.20.0/24 -j ACCEPT
    iptables -A INPUT -p udp -s 192.168.10.0/24 -j ACCEPT
    iptables -A INPUT -p udp -s 192.168.20.0/24 -j ACCEPT
    
    iptables -A INPUT -p icmp -s 192.168.10.0/24 -j ACCEPT
    iptables -A INPUT -p icmp -s 192.168.20.0/24 -j ACCEPT
    
    iptables -t nat -A POSTROUTING -o $IF_EXT -j MASQUERADE

    # Persistencia de reglas tras el reinicio
    if dpkg -l | grep -q iptables-persistent; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        netfilter-persistent save > /dev/null 2>&1
    fi
) &
mostrar_carga "Aplicando bastionado perimetral y reglas de subred"
registrar_log "SUCCESS" "Firewall configurado: Acceso total para subredes .10 y .20."

# ==============================================================================
# FASE 10: REINICIO FINAL
# ==============================================================================
echo -e "\n${AZUL}======================================================================${NC}"

timedatectl set-timezone Europe/Madrid > /dev/null 2>&1
registrar_log "Success" "Zona horaria ajustada a Europa/Madrid"

registrar_log "INFO" "Instalación completada. Reiniciando."
echo -e "${VERDE}[OK] PROCESO FINALIZADO CON ÉXITO.${NC}"
echo -e "${AMARILLO}[*] Reiniciando la máquina en 5 segundos...${NC}"
sleep 5
reboot