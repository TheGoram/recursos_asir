#!/bin/bash
# ==============================================================================
# SCRIPT DE GESTIÓN ASIR: RRHH Y ESTRUCTURA DE ACTIVE DIRECTORY
# AUTOR: Diego Solleiro Arancón
# INCLUYE: ONBOARDING, OFFBOARDING, DEPARTAMENTOS, RESET CLAVES Y DIRECTORIO
# ==============================================================================

# --- AUTORREPARACIÓN ZERO-TOUCH ---
if grep -q $'\r' "$0"; then
    echo -e "\033[1;33m[!] Detectado formato de Windows. Autocorrigiendo el script...\033[0m"
    sed -i 's/\r$//' "$0"
    exec bash "$0" "$@"
fi

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[1;31m[ERROR] Ejecuta este script como root (sudo).\033[0m"
  exit 1
fi

LOG_FILE="/var/log/asir_gestion_usuarios.log"
BASE_DIR="/srv/samba/compartidas"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

registrar_log() {
    local FECHA=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$FECHA] $1" >> "$LOG_FILE"
}

VERDE='\033[1;32m'; AZUL='\033[1;34m'; ROJO='\033[1;31m'; AMARILLO='\033[1;33m'; CYAN='\033[1;36m'; NC='\033[0m'

# --- 1. FUNCIÓN: CREAR USUARIO ---
crear_usuario() {
    echo -e "\n${CYAN}--- ALTA DE NUEVO EMPLEADO ---${NC}"
    
    read -p " > Identificador de inicio de sesión (ej. 71234567A): " USERNAME
    read -p " > Nombre real del empleado (ej. Ana): " NOMBRE_REAL
    read -p " > Apellidos (ej. López García): " APELLIDOS
    
    echo -e "${AMARILLO}[INFO] La contraseña debe tener mayúsculas, minúsculas, números y +7 caracteres.${NC}"
    read -s -p " > Contraseña temporal: " PASSWORD
    echo ""

    echo -e "\n${AZUL}[*] Departamentos disponibles:${NC}"
    ls "$BASE_DIR" | grep -v "lost+found" | awk '{print " - " $1}'
    echo ""

    VALIDO=0
    while [ $VALIDO -eq 0 ]; do
        read -p "Escribe el departamento EXACTO al que pertenece: " GRUPO
        if [ -d "$BASE_DIR/$GRUPO" ] && [ -n "$GRUPO" ]; then
            VALIDO=1
        else
            echo -e "${ROJO}[ERROR] El departamento no existe. Si es nuevo, créalo primero en el menú principal.${NC}"
        fi
    done

    read -p "[?] ¿Dar privilegios de Administrador del Dominio? (s/n): " ES_ADMIN

    echo -e "\n${AMARILLO}[*] Procesando en Active Directory...${NC}"
    
    # --must-change-at-next-login obliga al usuario a cambiar la clave al entrar
    samba-tool user create "$USERNAME" "$PASSWORD" --given-name="$NOMBRE_REAL" --surname="$APELLIDOS" --use-username-as-cn --must-change-at-next-login > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "${VERDE}[OK] Usuario '$USERNAME' creado en AD.${NC}"
        registrar_log "SUCCESS: Usuario '$USERNAME' creado."
    else
        echo -e "${ROJO}[ERROR] Fallo al crear el usuario. Abortando.${NC}"
        return
    fi

    samba-tool group addmembers "$GRUPO" "$USERNAME" > /dev/null 2>&1
    echo -e "${VERDE}[OK] Añadido al grupo '$GRUPO'.${NC}"
    
    if [[ "$ES_ADMIN" == "s" || "$ES_ADMIN" == "S" ]]; then
        samba-tool group addmembers "Domain Admins" "$USERNAME" > /dev/null 2>&1
        echo -e "${VERDE}[!] Privilegios de Domain Admin concedidos.${NC}"
    fi

    echo -e "${AMARILLO}[*] Obteniendo SIDs directamente desde Winbind...${NC}"
    sleep 2 # Breve pausa de sincronización
    
    # LA MAGIA: Traducimos nombre a SID, y SID a Identificador Numérico (UID/GID)
    USER_SID=$(wbinfo -n "$USERNAME" | cut -d' ' -f1)
    USER_UID=$(wbinfo -S "$USER_SID" 2>/dev/null)
    
    ADMIN_SID=$(wbinfo -n "Domain Admins" | cut -d' ' -f1)
    ADMIN_GID=$(wbinfo -Y "$ADMIN_SID" 2>/dev/null)

    CARPETA_USUARIO="$BASE_DIR/$GRUPO/$USERNAME"
    mkdir -p "$CARPETA_USUARIO"
    
    if [ -n "$USER_UID" ] && [ -n "$ADMIN_GID" ]; then
        # Aplicamos los permisos NUMÉRICOS, infalible para Linux
        chown -R $USER_UID:$ADMIN_GID "$CARPETA_USUARIO"
        chmod 750 "$CARPETA_USUARIO"
        echo -e "${VERDE}[OK] Carpeta personal montada (Dueño UID: $USER_UID).${NC}"
        echo -e "${VERDE}[OK] El usuario deberá cambiar su contraseña en el primer inicio de sesión.${NC}"
    else
        echo -e "${ROJO}[ERROR] Fallo al resolver SIDs. Carpeta creada sin permisos asignados.${NC}"
    fi
    
    read -p "Presiona Enter para continuar..."
}

# --- 2. FUNCIÓN: BORRAR USUARIO (OFFBOARDING) ---
borrar_usuario() {
    echo -e "\n${CYAN}--- BAJA DE EMPLEADO ---${NC}"
    read -p " > Identificador del usuario a eliminar (ej. 71234567A): " USER_DEL

    echo -e "${AMARILLO}[*] Buscando en Active Directory...${NC}"
    samba-tool user delete "$USER_DEL" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${VERDE}[OK] Usuario '$USER_DEL' eliminado del Dominio.${NC}"
        registrar_log "SUCCESS: Usuario '$USER_DEL' eliminado del sistema."

        USER_DIR=$(find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type d -name "$USER_DEL" 2>/dev/null)
        if [ -n "$USER_DIR" ]; then
            echo -e "${AMARILLO}[INFO] Carpeta personal detectada en: $USER_DIR${NC}"
            read -p "[?] ¿Deseas DESTRUIR también su carpeta y todos sus archivos? (s/n): " DEL_DIR
            if [[ "$DEL_DIR" == "s" || "$DEL_DIR" == "S" ]]; then
                rm -rf "$USER_DIR"
                echo -e "${VERDE}[OK] Carpeta eliminada permanentemente.${NC}"
                registrar_log "INFO: Carpeta de '$USER_DEL' destruida."
            else
                echo -e "${AZUL}[INFO] Carpeta conservada por auditoría.${NC}"
            fi
        fi
    else
        echo -e "${ROJO}[ERROR] El usuario '$USER_DEL' no existe.${NC}"
    fi
    read -p "Presiona Enter para volver al menú..."
}

# --- 3. FUNCIÓN: CREAR DEPARTAMENTO ---
crear_departamento() {
    echo -e "\n${CYAN}--- NUEVO DEPARTAMENTO ---${NC}"
    read -p " > Nombre del nuevo departamento: " NUEVO_DEP

    if [ -d "$BASE_DIR/$NUEVO_DEP" ]; then
        echo -e "${ROJO}[ERROR] El departamento '$NUEVO_DEP' ya existe.${NC}"
        read -p "Presiona Enter para volver al menú..."
        return
    fi

    echo -e "\n${AMARILLO}[*] Creando estructura organizativa...${NC}"
    samba-tool group add "$NUEVO_DEP" > /dev/null 2>&1
    echo -e "${VERDE}[OK] Grupo '$NUEVO_DEP' creado en Active Directory.${NC}"

    ADMIN_SID=$(wbinfo -n "Domain Admins" | cut -d' ' -f1)
    ADMIN_GID=$(wbinfo -Y "$ADMIN_SID" 2>/dev/null)

    mkdir -p "$BASE_DIR/$NUEVO_DEP"
    if [ -n "$ADMIN_GID" ]; then
        chown root:$ADMIN_GID "$BASE_DIR/$NUEVO_DEP"
        chmod 755 "$BASE_DIR/$NUEVO_DEP"
        echo -e "${VERDE}[OK] Carpeta raíz asegurada en el Servidor de Archivos.${NC}"
    else
        chmod 755 "$BASE_DIR/$NUEVO_DEP"
        echo -e "${AMARILLO}[WARNING] Carpeta creada, pero no se pudo asignar el grupo Domain Admins.${NC}"
    fi
    
    registrar_log "SUCCESS: Departamento '$NUEVO_DEP' creado."
    read -p "Presiona Enter para continuar..."
}

# --- 4. FUNCIÓN: BORRAR DEPARTAMENTO ---
borrar_departamento() {
    echo -e "\n${CYAN}--- CIERRE DE DEPARTAMENTO ---${NC}"
    echo -e "${AZUL}[*] Departamentos actuales:${NC}"
    ls "$BASE_DIR" | grep -v "lost+found" | awk '{print " - " $1}'
    echo ""
    read -p " > Nombre del departamento a ELIMINAR: " DEP_DEL

    if [ -d "$BASE_DIR/$DEP_DEL" ]; then
        echo -e "${ROJO}[WARNING] ¡ALERTA CRÍTICA! Vas a destruir el grupo en AD y TODAS las carpetas de '$DEP_DEL'.${NC}"
        read -p "[?] Escribe 'CONFIRMAR' en mayúsculas para proceder: " CONFIRMACION
        
        if [ "$CONFIRMACION" == "CONFIRMAR" ]; then
            samba-tool group delete "$DEP_DEL" > /dev/null 2>&1
            rm -rf "$BASE_DIR/$DEP_DEL"
            echo -e "${VERDE}[OK] Departamento '$DEP_DEL' fulminado.${NC}"
            registrar_log "WARNING: Departamento '$DEP_DEL' eliminado."
        else
            echo -e "${AMARILLO}[INFO] Operación abortada por seguridad.${NC}"
        fi
    else
        echo -e "${ROJO}[ERROR] El departamento no existe.${NC}"
    fi
    read -p "Presiona Enter para volver al menú..."
}

# --- 5. FUNCIÓN: CAMBIAR CONTRASEÑA ---
cambiar_password() {
    echo -e "\n${CYAN}--- RESET DE CONTRASEÑA ---${NC}"
    read -p " > Identificador EXACTO del usuario (ej. 71234567A): " USER_PWD

    if samba-tool user list | grep -qw "^${USER_PWD}$"; then
        read -s -p " > Nueva Contraseña: " NEW_PASSWORD
        echo ""
        read -s -p " > Repite la Contraseña: " NEW_PASSWORD_CONFIRM
        echo ""

        if [ "$NEW_PASSWORD" == "$NEW_PASSWORD_CONFIRM" ]; then
            echo -e "\n${AMARILLO}[*] Aplicando cambios...${NC}"
            samba-tool user setpassword "$USER_PWD" --newpassword="$NEW_PASSWORD" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo -e "${VERDE}[OK] Contraseña actualizada.${NC}"
                registrar_log "SUCCESS: Contraseña reseteada ($USER_PWD)."
            else
                echo -e "${ROJO}[ERROR] Contraseña rechazada. ¿Cumple las políticas de seguridad?${NC}"
            fi
        else
            echo -e "${ROJO}[ERROR] Las contraseñas no coinciden.${NC}"
        fi
    else
        echo -e "${ROJO}[ERROR] El identificador no existe.${NC}"
    fi
    read -p "Presiona Enter para volver al menú..."
}

# --- 6. FUNCIÓN: LISTAR EMPLEADOS ---
listar_usuarios() {
    echo -e "\n${CYAN}--- DIRECTORIO DE EMPLEADOS ---${NC}"
    
    LISTA_USUARIOS=$(samba-tool user list 2>/dev/null | grep -Evi '^(administrator|krbtgt|guest|dns-)|\$')
    
    if [ -z "$LISTA_USUARIOS" ]; then
        echo -e "${ROJO}[INFO] No hay empleados estándar.${NC}"
    else
        echo -e "${VERDE}[OK] Usuarios registrados:${NC}"
        echo -e "------------------------------------------------"
        echo "$LISTA_USUARIOS" | awk '{print "  > " $0}'
        echo -e "------------------------------------------------"
        TOTAL=$(echo "$LISTA_USUARIOS" | wc -l)
        echo -e "${AZUL}[INFO] Total: $TOTAL${NC}"
    fi
    echo ""
    read -p "Presiona Enter para volver al menú..."
}

# --- MENÚ PRINCIPAL ---
while true; do
    clear
    echo -e "${AZUL}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${AZUL}║       PANEL DE CONTROL DE RRHH E INFRAESTRUCTURA       ║${NC}"
    echo -e "${AZUL}╚════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${VERDE}1)${NC} [+] Dar de ALTA a un nuevo Empleado"
    echo -e "  ${VERDE}2)${NC} [-] Dar de BAJA a un Empleado"
    echo -e "  ${VERDE}3)${NC} [+] Crear un nuevo Departamento"
    echo -e "  ${VERDE}4)${NC} [-] Eliminar un Departamento"
    echo -e "  ${VERDE}5)${NC} [*] Resetear Contraseña de Empleado"
    echo -e "  ${VERDE}6)${NC} [?] Consultar Directorio de Empleados"
    echo -e "  ${VERDE}7)${NC} [<] Salir"
    echo -e "${AZUL}────────────────────────────────────────────────────────${NC}"
    read -p "Elige una opción (1-7): " OPCION

    case $OPCION in
        1) crear_usuario ;;
        2) borrar_usuario ;;
        3) crear_departamento ;;
        4) borrar_departamento ;;
        5) cambiar_password ;;
        6) listar_usuarios ;;
        7) echo -e "${VERDE}[OK] Saliendo...${NC}"; exit 0 ;;
        *) echo -e "${ROJO}[ERROR] Opción no válida.${NC}"; sleep 1 ;;
    esac
done