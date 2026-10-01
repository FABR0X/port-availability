<#
.SYNOPSIS
    Verifica si un puerto TCP esta ABIERTO o CERRADO (equivalente a check_port.sh).

.DESCRIPTION
    Intenta establecer una conexion TCP contra el host y puerto indicados usando
    System.Net.Sockets.TcpClient con un tiempo de espera (timeout) configurable.
    Es mucho mas rapido que Test-NetConnection porque no espera el informe completo.

.PARAMETER Port
    Puerto TCP a verificar (1-65535). Posicional.

.PARAMETER HostName
    Host o direccion IP destino. Si se omite usa $env:TARGET_HOST y, si no existe,
    127.0.0.1.

.PARAMETER TimeoutSeconds
    Segundos de espera de la conexion. Si se omite usa $env:PORT_CHECK_TIMEOUT o 3.

.PARAMETER Quiet
    Solo imprime el estado final (ABIERTO / CERRADO).

.EXAMPLE
    .\check_port.ps1 80
.EXAMPLE
    .\check_port.ps1 5432 127.0.0.1
.EXAMPLE
    .\check_port.ps1 -Port 443 -HostName google.com -TimeoutSeconds 5
.EXAMPLE
    .\check_port.ps1 -Port 3306 -HostName host.docker.internal -Quiet

.NOTES
    Codigos de salida:
      0 = Puerto ABIERTO
      1 = Puerto CERRADO o filtrado
      2 = Uso incorrecto
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateRange(1, 65535)]
    [int] $Port,

    [Alias('H', 'Host', 'TargetHost')]
    [string] $HostName,

    [Alias('t')]
    [ValidateRange(1, 300)]
    [int] $TimeoutSeconds = 0,

    [Alias('q')]
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:MinPort = 1
$Script:MaxPort = 65535
$Script:ExitOpen    = 0
$Script:ExitClosed  = 1
$Script:ExitBadArgs = 2

# --- Colores (uso nativo de PowerShell para evitar ANSI en PS5.1) ----------
$script:SupportsVT = ($Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected)
$script:PSVersionMajor = [int] $PSVersionTable.PSVersion.Major
$script:UseAnsi = $script:SupportsVT -and $script:PSVersionMajor -ge 6

if ($script:UseAnsi) {
    $script:CReset  = "`e[0m"
    $script:CGreen  = "`e[32m"
    $script:CRed    = "`e[31m"
    $script:CYellow = "`e[33m"
    $script:CCyan   = "`e[36m"
    $script:CBold   = "`e[1m"
} else {
    $script:CReset = $script:CGreen = $script:CRed = ''
    $script:CYellow = $script:CCyan = $script:CBold = ''
}

function Write-Info { param([string] $Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Err  { param([string] $Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Show-Usage {
    if ($script:UseAnsi) {
        $bold = $script:CBold; $reset = $script:CReset
        @"
$bold`nUso:`n$reset
  .\check_port.ps1 [-Port] <PUERTO> [-HostName <HOST>] [-TimeoutSeconds <SEG>] [-Quiet]

$bold`nOpciones:`n$reset
  -Port <int>             Puerto TCP a verificar ($($script:MinPort)-$($script:MaxPort)). Obligatorio.
  -HostName <string>      Host o IP destino. Alias: -H, -Host, -TargetHost.
                          Def.: `$env:TARGET_HOST o 127.0.0.1
  -TimeoutSeconds <int>   Segundos de espera. Alias: -t. Def.: `$env:PORT_CHECK_TIMEOUT o 3
  -Quiet                  Solo imprime el estado final. Alias: -q
  -Help                   Muestra esta ayuda.

$bold`nEjemplos:`n$reset
  .\check_port.ps1 80
  .\check_port.ps1 5432 127.0.0.1
  .\check_port.ps1 -Port 443 -HostName google.com -TimeoutSeconds 5
  `$env:TARGET_HOST = 'host.docker.internal'; .\check_port.ps1 -Port 3306

$bold`nCodigos de salida:`n$reset
  0  Puerto ABIERTO
  1  Puerto CERRADO o filtrado
  2  Uso incorrecto
"@
    } else {
        @"

Uso:

  .\check_port.ps1 [-Port] <PUERTO> [-HostName <HOST>] [-TimeoutSeconds <SEG>] [-Quiet]

Opciones:

  -Port <int>             Puerto TCP a verificar ($($script:MinPort)-$($script:MaxPort)). Obligatorio.
  -HostName <string>      Host o IP destino. Alias: -H, -Host, -TargetHost.
                          Def.: `$env:TARGET_HOST o 127.0.0.1
  -TimeoutSeconds <int>   Segundos de espera. Alias: -t. Def.: `$env:PORT_CHECK_TIMEOUT o 3
  -Quiet                  Solo imprime el estado final. Alias: -q
  -Help                   Muestra esta ayuda.

Ejemplos:

  .\check_port.ps1 80
  .\check_port.ps1 5432 127.0.0.1
  .\check_port.ps1 -Port 443 -HostName google.com -TimeoutSeconds 5
  `$env:TARGET_HOST = 'host.docker.internal'; .\check_port.ps1 -Port 3306

Codigos de salida:

  0  Puerto ABIERTO
  1  Puerto CERRADO o filtrado
  2  Uso incorrecto
"@
    }
}

# --- Argumentos -------------------------------------------------------------
$HostWasGiven = $PSBoundParameters.ContainsKey('HostName')
if (-not $HostWasGiven) {
    $HostName = if ($env:TARGET_HOST) { $env:TARGET_HOST } else { '127.0.0.1' }
}

if (-not $PSBoundParameters.ContainsKey('Port')) {
    Write-Err 'El puerto es obligatorio.'
    Write-Host ''
    Show-Usage
    exit $script:ExitBadArgs
}

if ($TimeoutSeconds -le 0) {
    $TimeoutSeconds = if ($env:PORT_CHECK_TIMEOUT) { [int] $env:PORT_CHECK_TIMEOUT } else { 3 }
}

if ([string]::IsNullOrWhiteSpace($HostName)) {
    Write-Err 'El host no puede estar vacio.'
    exit $script:ExitBadArgs
}

# --- Comprobacion -----------------------------------------------------------
# El estado "abierto" se determina por la excepcion de_socket en la conexion:
# si ConnectAsync completa correctamente, el puerto acepta conexiones TCP.
function Test-TcpPort {
    param(
        [Parameter(Mandatory)] [string]   $ComputerName,
        [Parameter(Mandatory)] [int]      $PortNumber,
        [Parameter(Mandatory)] [int]      $TimeoutSec
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $state = 'Closed'
    $detail = 'No responde o esta filtrado'
    $local  = $null

    function Get-SocketDetail {
        param([System.Management.Automation.ErrorRecord] $ErrorRecord)

        $base = $ErrorRecord.Exception.GetBaseException()
        if ($base -is [System.Net.Sockets.SocketException]) {
            switch ($base.SocketErrorCode) {
                ([System.Net.Sockets.SocketError]::ConnectionRefused) {
                    return 'Conexion rechazada (RST): nada escuchando en ese puerto'
                }
                ([System.Net.Sockets.SocketError]::TimedOut) {
                    return 'Tiempo de espera agotado (host sin respuesta / filtro)'
                }
                ([System.Net.Sockets.SocketError]::HostUnreachable) {
                    return 'Host inalcanzable'
                }
                ([System.Net.Sockets.SocketError]::HostNotFound) {
                    return 'Nombre de host no resuelto'
                }
                default { return $base.Message }
            }
        }
        return $base.Message
    }

    try {
        $connectTask = $client.ConnectAsync($ComputerName, $PortNumber)
        try {
            $completed = $connectTask.Wait($TimeoutSec * 1000)
        } catch [System.AggregateException] {
            $completed = $true
            $detail = Get-SocketDetail -ErrorRecord $_
        }

        if (-not $completed) {
            $detail = "Tiempo de espera agotado tras $TimeoutSec s"
        } elseif ($client.Connected) {
            $state  = 'Open'
            $detail = 'Acepta conexiones TCP'
            $local  = '{0}:{1}' -f $client.Client.LocalEndPoint.Address, $client.Client.LocalEndPoint.Port
        }
    } catch {
        $detail = $_.Exception.Message
    } finally {
        $stopwatch.Stop()
        $client.Dispose()
    }

    [pscustomobject] @{
        ComputerName = $ComputerName
        Port         = $PortNumber
        State        = $state
        Detail       = $detail
        LocalEndPoint = $local
        ElapsedMs    = [int] $stopwatch.ElapsedMilliseconds
    }
}

if ($Quiet) {
    $quietResult = Test-TcpPort -ComputerName $HostName -PortNumber $Port -TimeoutSec $TimeoutSeconds
    Write-Output $(if ($quietResult.State -eq 'Open') { 'ABIERTO' } else { 'CERRADO' })
    exit $(if ($quietResult.State -eq 'Open') { $script:ExitOpen } else { $script:ExitClosed })
}

function Write-Bold { param([string] $Message) if ($script:UseAnsi) { Write-Host "$($script:CBold)$Message$($script:CReset)" } else { Write-Host $Message -ForegroundColor White } }
function Write-Open { param([string] $Message) if ($script:UseAnsi) { Write-Host "$($script:CGreen)$($script:CBold)[ ABIERTO ]$($script:CReset) $Message" } else { Write-Host "[ ABIERTO ] $Message" -ForegroundColor Green } }
function Write-Closed { param([string] $Message) if ($script:UseAnsi) { Write-Host "$($script:CRed)$($script:CBold)[ CERRADO ]$($script:CReset) $Message" } else { Write-Host "[ CERRADO ] $Message" -ForegroundColor Red } }

Write-Bold '=== Verificacion de puerto ==='
Write-Info "Fecha/hora : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Info "Host       : $HostName"
Write-Info "Puerto     : $Port"
Write-Info "Timeout    : ${TimeoutSeconds}s"
Write-Info 'Metodo     : conexion TCP (System.Net.Sockets.TcpClient)'

try {
    $resolved = [System.Net.Dns]::GetHostAddresses($HostName) | Select-Object -First 1
    Write-Info "Resuelve a : $($resolved.IPAddressToString)"
} catch {
    Write-Info 'Resuelve a : (no se pudo resolver el nombre)'
}

Write-Host ''

$result = Test-TcpPort -ComputerName $HostName -PortNumber $Port -TimeoutSec $TimeoutSeconds

if ($result.State -eq 'Open') {
    $msg = "El puerto $Port en $HostName acepta conexiones TCP ($($result.ElapsedMs) ms)."
    Write-Open $msg
    if ($result.LocalEndPoint) {
        Write-Info "Conexion local: $($result.LocalEndPoint)"
    }
    exit $script:ExitOpen
} else {
    $msg = "El puerto $Port en $HostName no acepta conexiones: $($result.Detail) ($($result.ElapsedMs) ms)."
    Write-Closed $msg
    exit $script:ExitClosed
}
