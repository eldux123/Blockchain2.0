# ============================================================================
#  setup-demo.ps1 — Prepara TODO para la demo de votación con un solo clic.
# ----------------------------------------------------------------------------
#  Qué hace, en orden:
#    1. Arranca la red local de Aptos (en una ventana aparte, con faucet).
#    2. Espera a que la API (http://localhost:8080) esté lista.
#    3. Fondea las 3 cuentas de demo (admin, votante1, votante2).
#    4. Publica el contrato Voting.
#    5. Inicializa la elección con 2 candidatos (0x1 y 0x2).
#    6. Abre frontend/demo.html en el navegador.
#
#  Este script vive en la carpeta  scripts/  del proyecto.
#  Uso:  clic derecho sobre el archivo -> "Ejecutar con PowerShell"
#        o en una terminal:   ./scripts/setup-demo.ps1
#
#  Para empezar de CERO (borrar votos previos):   ./setup-demo.ps1 -Reset
# ============================================================================

param(
    [switch]$Reset  # Si se pasa -Reset, reinicia la red local desde cero.
)

# NOTA: el CLI de aptos escribe mensajes informativos ("Compiling...") a stderr.
# Con ErrorActionPreference='Stop' PowerShell los trataria como error y abortaria.
# Por eso lo dejamos en 'Continue' y validamos cada paso leyendo su salida.
$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

# --- Rutas y constantes ---------------------------------------------------
# Este script vive en  <proyecto>\scripts\ , asi que el proyecto es un nivel arriba.
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$AptosBin   = Join-Path $env:USERPROFILE ".aptoscli\bin"
$env:PATH  += ";$AptosBin"
$NodeApi    = "http://localhost:8080/v1"
$AdminAddr  = "0x82e85f5a4b543ee051869e43f0f4af091d35ac15ffc787554c325105ef241246"
$HtmlFile   = Join-Path $ProjectDir "frontend\demo.html"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    !!  $msg" -ForegroundColor Yellow }

Set-Location $ProjectDir

# --- 0. ¿Está la red ya corriendo? ----------------------------------------
function Test-Node {
    try { Invoke-RestMethod -Uri $NodeApi -TimeoutSec 3 | Out-Null; return $true }
    catch { return $false }
}

$nodeUp = Test-Node

# --- 1. Arrancar la red local ---------------------------------------------
if ($nodeUp -and -not $Reset) {
    Write-Step "La red local ya esta corriendo. (Usa -Reset para reiniciarla desde cero.)"
} else {
    Write-Step "Arrancando la red local de Aptos en una ventana nueva..."
    $restartFlag = ""
    if ($Reset) {
        $restartFlag = "--force-restart --assume-yes"
        Write-Warn "Modo -Reset: se borrara el estado anterior (votos previos)."
    }
    # Lanza el nodo en una ventana PowerShell separada que queda abierta.
    # El titulo ayuda a identificar la ventana; NO cerrarla durante la demo.
    $nodeCmd = "`$Host.UI.RawUI.WindowTitle = 'APTOS NODE - no cerrar durante la demo'; " +
               "`$env:PATH += ';$AptosBin'; cd '$ProjectDir'; " +
               "aptos node run-local-testnet --with-faucet $restartFlag"
    Start-Process powershell -ArgumentList "-NoExit", "-Command", $nodeCmd | Out-Null
    Write-Ok "Ventana del nodo lanzada. NO la cierres durante la demo."
}

# --- 2. Esperar a que la API responda -------------------------------------
# El PRIMER arranque puede tardar (descarga dependencias y genera la cadena),
# por eso damos un margen amplio.
Write-Step "Esperando a que la API del nodo este lista (http://localhost:8080)..."
$maxWait = 180
$waited  = 0
while (-not (Test-Node)) {
    Start-Sleep -Seconds 2
    $waited += 2
    Write-Host "." -NoNewline
    if ($waited -ge $maxWait) {
        Write-Host ""
        Write-Warn "El nodo no respondio en $maxWait s."
        Write-Warn "Revisa la ventana titulada 'APTOS NODE'. Si quedo abierta y sin"
        Write-Warn "errores, espera unos segundos mas y vuelve a ejecutar el script"
        Write-Warn "(detectara que la red ya esta arriba y continuara el resto)."
        exit 1
    }
}
Write-Host ""
Write-Ok "Nodo listo."

# Pequeña pausa extra para que el faucet termine de inicializar.
Start-Sleep -Seconds 3

# --- 3. Fondear las cuentas -----------------------------------------------
Write-Step "Fondeando las 3 cuentas de demo..."
foreach ($p in @("default", "votante1", "votante2")) {
    try {
        aptos account fund-with-faucet --account $p --profile $p 2>&1 | Out-Null
        Write-Ok "Cuenta '$p' fondeada."
    } catch {
        Write-Warn "No se pudo fondear '$p' (quiza ya tenia fondos): $_"
    }
}

# --- 4. Publicar el contrato ----------------------------------------------
Write-Step "Publicando el contrato Voting..."
$publish = aptos move publish --named-addresses my_addrx=default --profile default --assume-yes 2>&1 | Out-String
if ($publish -match '"success":\s*true') {
    Write-Ok "Contrato publicado."
} elseif ($publish -match "EMODULE_ADDR|already exists|DUPLICATE|backward") {
    Write-Warn "El contrato ya estaba publicado (se reutiliza el existente)."
} else {
    Write-Warn "Publicacion con resultado inesperado. Detalle:"
    Write-Host $publish
}

# --- 5. Inicializar la eleccion (si no existe ya) -------------------------
function Test-Initialized {
    try {
        $url = "$NodeApi/accounts/$AdminAddr/resource/$AdminAddr" + "::Voting::CandidateList"
        Invoke-RestMethod -Uri $url -TimeoutSec 4 | Out-Null
        return $true
    } catch { return $false }
}

Write-Step "Inicializando la eleccion..."
if (Test-Initialized) {
    Write-Warn "La eleccion ya estaba inicializada. (Usa -Reset para empezar de cero.)"
} else {
    aptos move run --function-id default::Voting::initialize_with_candidate `
        --args address:0x1 --assume-yes --profile default 2>&1 | Out-Null
    Write-Ok "Eleccion inicializada con el candidato 0x1."
    aptos move run --function-id default::Voting::add_candidate `
        --args address:0x2 --assume-yes --profile default 2>&1 | Out-Null
    Write-Ok "Candidato 0x2 agregado."
}

# --- 6. Mostrar el estado y abrir el HTML ---------------------------------
Write-Step "Estado actual del contrato:"
try {
    $url = "$NodeApi/accounts/$AdminAddr/resource/$AdminAddr" + "::Voting::CandidateList"
    $state = Invoke-RestMethod -Uri $url -TimeoutSec 4
    foreach ($e in $state.data.candidate_list.data) {
        Write-Host ("    Candidato {0} -> {1} votos" -f $e.key, $e.value)
    }
    $w = $state.data.winner
    if ($w -match '^0x0+$') { Write-Host "    Ganador: (ninguno todavia)" }
    else                    { Write-Host "    Ganador: $w" }
} catch {
    Write-Warn "No se pudo leer el estado: $_"
}

Write-Step "Abriendo demo.html en el navegador..."
Start-Process $HtmlFile
Write-Ok "Listo. La interfaz deberia ponerse en VERDE y mostrar los candidatos."
Write-Host "`nRecuerda: deja abierta la ventana del nodo durante toda la demo.`n" -ForegroundColor Cyan
