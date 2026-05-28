<#
==============================================================================
Script de cliente Windows: Unión, VBS, escritorio y branding
Autor: Diego S. Arancón
==============================================================================
Atención: Este script requiere de intervencion manual en la fase 8
#>

# --- Variables globales ---
$DomainName = "asirdiego.local"
$PdcIP = "192.168.20.10"
$SdcIP = "192.168.20.11"

# --- Configuracion de auditoria y logs ---
$LogDir = "C:\Logs"
$LogPath = "$LogDir\ASIR_Union_Dominio.log"
if (-Not (Test-Path -Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

<#
.SYNOPSIS
Registra eventos en el archivo de logs local
.DESCRIPTION
Añade una linea al archivo ASIR_Union_dominio.log con una marca de tiempo exacta
.PARAMETER Type
El nivel de severidad del mensaje (ej. INFO, SUCCESS, ERROR, WARNING)
.PARAMETER Message
El texto descriptivo de la acción que acaba de procesarse
#>
Function Write-Log {
    Param ([string]$Type, [string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogPath -Value "[$Timestamp] [$Type] $Message"
}

<#
.SYNOPSIS
Genera una barra de progreso visual en la consola
.DESCRIPTION
Detiene la ejecucion del script durante un tiempo determinado mientras muestra una barra de carga
.PARAMETER Mensaje
El texto que aparecerá en la parte superior de la barra
.PARAMETER Segundos
El tiempo total estimado que tardará en completarse el proceso en segundo plano
#>
Function Mostrar-Carga {
    Param ([string]$Mensaje, [int]$Segundos)
    Write-Host "[*] $Mensaje..." -ForegroundColor Cyan
    $pasos = 40
    for ($i = 1; $i -le $pasos; $i++) {
        $porcentaje = [math]::Round(($i / $pasos) * 100)
        Write-Progress -Activity "Aprovisionamiento Zero-Touch" -Status "$Mensaje ($porcentaje%)" -PercentComplete $porcentaje
        Start-Sleep -Milliseconds ($Segundos * 1000 / $pasos)
    }
    Write-Progress -Activity "Aprovisionamiento Zero-Touch" -Completed
    Write-Host "[OK] Tarea completada.`n" -ForegroundColor Green
}

Clear-Host
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "   UNIÓN AUTOMÁTICA AL DOMINIO: $DomainName" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# ==============================================================================
# Fase 1:  Verificacion de privilegios
# ==============================================================================
# Comprueba si la terminal de PowerShell tiene el token de administrador
# Es obligatorio ya que se deben de modificar configuraciones de red y para unir el equipo al dominio
Write-Host "`n[1/8] Comprobando privilegios de Administrador..." -ForegroundColor Yellow
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Debes abrir PowerShell como Administrador." -ForegroundColor Red
    Exit
}

# ==============================================================================
# Fase 2:  Controladores de VirtualBox
# ==============================================================================
# Automatiza la instalacion de las Guest Additions buscando la unidad CD
Write-Host "`n[2/8] Buscando VirtualBox Guest Additions..." -ForegroundColor Yellow
$VBoxDrive = (Get-Volume | Where-Object { $_.FileSystemLabel -match "VBOX" }).DriveLetter
if ($VBoxDrive) {
    Mostrar-Carga "Instalando controladores (esto puede tardar un minuto)" 2
    Start-Process -FilePath "${VBoxDrive}:\VBoxWindowsAdditions.exe" -ArgumentList "/S" -Wait
}

# ==============================================================================
# Fase 3: Enrutamiento y resolucion DNS
# ==============================================================================
# Modifica la tarjeta de red para forzar que el PDC y el SDC sean los unicos resolutores DNS, garantizando que el equipo encuentre el Active Directory
Write-Host "`n[3/8] Configurando red y servidores DNS..." -ForegroundColor Yellow
$Interface = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
if ($Interface) {
    Set-DnsClientServerAddress -InterfaceIndex $Interface.ifIndex -ServerAddresses $PdcIP, $SdcIP
    Set-DnsClient -InterfaceIndex $Interface.ifIndex -ConnectionSpecificSuffix $DomainName
    Clear-DnsClientCache
    Mostrar-Carga "Aplicando cambios de red en $($Interface.Name)" 3
}

# ==============================================================================
# Fase 4: Sincronizacion temporal (Requisito para Kerberos)
# ==============================================================================
# Fuerza una sincronizacion inmediata del reloj para evitar fallos de autenticación (Clock Skew) provocados por los estaod suspendidos de las MV
Write-Host "[4/8] Sincronizando reloj del sistema para Kerberos..." -ForegroundColor Yellow
w32tm /resync /nowait | Out-Null
Mostrar-Carga "Contactando servidor NTP" 2

# ==============================================================================
# Fase 5: Inyección de VBScript para mapeo silencioso
# ==============================================================================
# En lugar de emplear un .bat que abriría una ventana de CMD al inicio, creamos un script de VBS que se ejecuta en segundo plano
# (parametro 0) y monsta la unidad de red corporativa de manera transparente
Write-Host "[5/8] Configurando acceso directo invisible (Unidad H:)..." -ForegroundColor Yellow
$StartupFolder = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
$VbsPath = "$StartupFolder\mapeo_red_H.vbs"
$VbsContent = "Set WshShell = CreateObject(""WScript.Shell"")`nWScript.Sleep 3000`nWshShell.Run ""cmd.exe /c net use H: \\$PdcIP\compartidas /persistent:yes"", 0, False"
Set-Content -Path $VbsPath -Value $VbsContent -Encoding Ascii
Mostrar-Carga "Inyectando VBScript en Inicio automático" 2

# ==============================================================================
# Fase 6: Branding corporativo (Espera activa y bypass del caché de iconos)
# ==============================================================================
Write-Host "[6/8] Configurando Branding (Esperando estabilización de red)..." -ForegroundColor Yellow

$PublicDesktop = [System.IO.Path]::Combine($env:Public, "Desktop")
$ShortcutPath = Join-Path $PublicDesktop "Carpeta Corporativa.lnk"
if (Test-Path $ShortcutPath) { Remove-Item $ShortcutPath -Force }

$RutaIconoLocal = "$env:ProgramData\icono_empresa.ico"
$UrlGithub = "https://raw.githubusercontent.com/TheGoram/recursos_asir/refs/heads/main/icono_empresa.ico"

# Espera activa: Tras modificar los DNS, Windows puede tardar en recuperar Internet
# Asi que invocamos una respuesta de GitHub hasta su confirmación para descargar el icono corporativo
$RedLista = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

for ($i = 1; $i -le 15; $i++) {
    try {
        $null = Invoke-WebRequest -Uri $UrlGithub -UseBasicParsing -Method Head -ErrorAction Stop
        $RedLista = $true
        Write-Host "  -> ¡Conexión establecida con éxito en el intento $i!" -ForegroundColor Green
        break
    } catch {
        Write-Host "  -> La red aún está inicializando. Reintentando en 2 seg... ($i/15)" -ForegroundColor Cyan
        Start-Sleep -Seconds 2
    }
}

try {
    if ($RedLista) {
        if (Test-Path $RutaIconoLocal) { Remove-Item $RutaIconoLocal }
        Invoke-WebRequest -Uri $UrlGithub -OutFile $RutaIconoLocal -UseBasicParsing
    } else {
        Write-Host "  -> [WARNING] Tiempo de espera agotado. No hay salida a Internet." -ForegroundColor Gray
    }

    # Bypass: Windows rechaza insertar iconos personalizados en accesos directos que apuntan a una IP o red. Asi que apuntamos
    # el acceso directo a explorer.exe y le pasamos la red como argumento para engañarle y obligarle a mostrar el icono corporativo
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    
    $Shortcut.TargetPath = "$env:windir\explorer.exe"
    $Shortcut.Arguments = "\\$PdcIP\compartidas"
    $Shortcut.Description = "Carpeta de Red Corporativa ASIR"
    
    # 3. Asignamos el icono puro
    if (Test-Path $RutaIconoLocal) {
        $Shortcut.IconLocation = $RutaIconoLocal
    } else {
        $Shortcut.IconLocation = "shell32.dll, 275"
    }
    
    $Shortcut.Save()
    
    # Refresco del motor gráfico para eliminar cachés anteriores
    ie4uinit.exe -show
    Write-Host "[OK] Acceso directo maestro generado en el Escritorio." -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Fallo crítico al crear el archivo .lnk en el Escritorio." -ForegroundColor Red
}

# ==============================================================================
# Fase 7: Hardening (bastionado) de privacidad
# ==============================================================================
# Oculta la lista visual del ultimo usuario que inició la sesión
Write-Host "[7/8] Aplicando políticas de privacidad corporativa..." -ForegroundColor Yellow
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "dontdisplaylastusername" -Value 1
Mostrar-Carga "Ocultando lista de usuarios" 1

# ==============================================================================
# 8. Unión
# ==============================================================================
Write-Host "[8/8] Conectando con el controlador de dominio..." -ForegroundColor Yellow
Write-Host "[WARNING] ATENCIÓN: Se abrirá una ventana de seguridad." -ForegroundColor Cyan
Write-Host "-> Introduce la contraseña de: administrator" -ForegroundColor Cyan

try {
    Add-Computer -DomainName $DomainName -Credential "$DomainName\administrator" -ErrorAction Stop
    Write-Host "`n[OK] ¡EQUIPO UNIDO CON ÉXITO!" -ForegroundColor Green
    
    Write-Host "`n[*] Reiniciando la máquina en 5 segundos..." -ForegroundColor Yellow
    for ($i = 5; $i -gt 0; $i--) { Write-Host "$i... " -NoNewline; Start-Sleep 1 }
    Restart-Computer -Force
} catch {
    Write-Host "`n[ERROR] El equipo ya está unido o las credenciales son incorrectas." -ForegroundColor Red
}