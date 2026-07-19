#requires -Version 7.0
<#
.SYNOPSIS
  Atlas self-host installer (Track B3). Stands up a NEW household's Atlas stack
  on a fresh Windows + Docker box: checks prerequisites, generates every secret
  with a CSPRNG, writes a fresh .env, creates the data root, brings the stack up,
  and waits for health. Then open /Setup to create the owner account.

.DESCRIPTION
  SAFE BY DESIGN - this is for a brand-new box, not an existing live instance:
    * It REFUSES to run if a .env already exists (the live box has one), so it
      can never clobber a running household's secrets.
    * Every secret is freshly generated; nothing is inherited from any other
      instance. A household's VAULT_MASTER_SECRET encrypts its own credentials,
      so it must be unique per install.

  This is the SERVER installer (run once on the home-server box). The client
  installer (Agent + Desktop MSIs) stays the WiX bundle.

  STATUS: works for the base stack. Full dependency provisioning (Docker/WSL2
  auto-install, Home Assistant Hyper-V VM, Tailscale/Cloudflare remote access)
  is Track B5 and still guided-manual - this script detects and instructs.

.PARAMETER DataRoot
  Host folder for Atlas's persistent volumes (SQL backups, vault, uploads, etc.).
  Defaults to C:\Atlas. Written to ATLAS_DATA_ROOT in the generated .env, which every
  compose volume mount reads (via ${ATLAS_DATA_ROOT:-C:\Atlas}), so a custom root just works.

.PARAMETER BaseUrl
  Public base URL written to APP_BASE_URL. Defaults to the LAN/localhost URL;
  change it in the /Setup wizard once Tailscale/Cloudflare remote access is set up.

.EXAMPLE
  pwsh ./install.ps1
#>
[CmdletBinding()]
param(
    [string]$DataRoot = 'C:\Atlas',
    [string]$BaseUrl  = 'http://localhost/Atlas',   # the self-host Caddy edge serves :80
    [switch]$InstallDocker,  # install Docker Desktop via winget without prompting if it's missing
    [switch]$Build           # build images from source (needs the private source tree); default PULLS public images
)

# The self-host stack = base compose + the overlay that adds the Caddy edge (:80/:443) and the
# opt-in remote-access/GPU profiles. Both files are needed for a working front door.
$ComposeArgs = @('-f', 'docker-compose.yml', '-f', 'docker-compose.selfhost.yml')

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    !   $msg" -ForegroundColor Yellow }
function Fail($msg)       { Write-Host "    X   $msg" -ForegroundColor Red; exit 1 }

# --- Cryptographically strong secret helpers --------------------------------
function New-Secret {
    param([int]$Bytes = 32)
    [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes($Bytes))
}
# SQL Server needs upper+lower+digit+symbol; guarantee complexity with a suffix.
function New-SqlPassword {
    # Base64 minus chars SQL dislikes in a connection string, plus a guaranteed suffix.
    ((New-Secret 24) -replace '[+/=]', '') + 'Aa1!'
}

Write-Host ''
Write-Host 'Atlas self-host installer' -ForegroundColor White
Write-Host '=========================' -ForegroundColor White
Write-Host ''

# --- 0. Self-protection: never clobber an existing install ------------------
$envPath = Join-Path $root '.env'
if (Test-Path $envPath) {
    Fail ".env already exists at $envPath. This box is already configured - refusing to overwrite. Delete .env by hand only if you are certain this is a fresh install."
}

# --- 1. Prerequisites -------------------------------------------------------
Write-Step 'Checking prerequisites'

$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) {
    Write-Warn2 'Docker Desktop (with the compose plugin + WSL2) was not found.'
    $ans = if ($InstallDocker) { 'y' } else { Read-Host '    Install Docker Desktop now via winget? [y/N]' }
    if ($ans -match '^(y|Y)') {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) { Fail 'winget not found. Install Docker Desktop manually (https://www.docker.com/products/docker-desktop) then re-run.' }
        Write-Step 'Installing Docker Desktop via winget (can take several minutes)'
        winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { Fail 'Docker Desktop install failed. Install it manually, then re-run.' }
        Write-Warn2 'Docker Desktop installed. START it and let first-run setup finish (a REBOOT may be needed to enable WSL2/virtualization), then re-run this script.'
        exit 0
    }
    Write-Warn2 'Install Docker Desktop:  winget install Docker.DockerDesktop  (or https://www.docker.com/products/docker-desktop)'
    Fail 'Docker is required.'
}
Write-Ok "docker: $((docker --version) 2>$null)"

try { docker compose version *> $null; Write-Ok 'docker compose plugin present' }
catch { Fail 'docker compose (v2) plugin not found. Update Docker Desktop.' }

try {
    docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw }
    Write-Ok 'Docker engine is running'
} catch {
    Fail 'Docker engine is not running. Start Docker Desktop and re-run.'
}

$wsl = Get-Command wsl -ErrorAction SilentlyContinue
if ($wsl) { Write-Ok 'WSL present' } else { Write-Warn2 'WSL not detected - Docker Desktop needs the WSL2 backend on Windows.' }

# GPU detection -> local-AI tier is opt-in (Track B3 non-GPU default).
$hasGpu = $false
try { if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { nvidia-smi *> $null; $hasGpu = ($LASTEXITCODE -eq 0) } } catch {}
if ($hasGpu) {
    Write-Ok 'NVIDIA GPU detected - you can opt into the local-AI containers later.'
} else {
    Write-Warn2 'No NVIDIA GPU detected. Atlas runs cloud-LLM-first (Haiku), no local voice/LLM. This is fine and the default.'
}

# --- 2. Generate secrets + write .env ---------------------------------------
Write-Step 'Generating secrets and writing .env'

$examplePath = Join-Path $root '.env.example'
if (-not (Test-Path $examplePath)) { Fail ".env.example not found at $examplePath" }

# Fresh, unique-per-install values.
$secrets = @{
    'MSSQL_SA_PASSWORD'               = (New-SqlPassword)
    'JWT_SECRET'                      = (New-Secret)
    'API_KEY'                         = (New-Secret)
    'VAULT_MASTER_SECRET'             = (New-Secret)
    'GMESSAGES_INGEST_SECRET'         = (New-Secret)
    'ATLAS_MUSIC_STREAM_TOKEN_SECRET' = (New-Secret)
    'TURN_SECRET'                     = (New-Secret)
    'APP_BASE_URL'                    = $BaseUrl
    'ATLAS_DATA_ROOT'                 = $DataRoot
    'CLI_BRIDGE_WORKDIR'              = (Join-Path $DataRoot 'repo')
}

$out = foreach ($line in (Get-Content $examplePath)) {
    $m = [regex]::Match($line, '^([A-Z_][A-Z0-9_]*)=')
    if ($m.Success -and $secrets.ContainsKey($m.Groups[1].Value)) {
        "$($m.Groups[1].Value)=$($secrets[$m.Groups[1].Value])"
    } else {
        $line
    }
}
# Write WITHOUT BOM so Docker/compose parse it cleanly.
[System.IO.File]::WriteAllLines($envPath, $out, [System.Text.UTF8Encoding]::new($false))
Write-Ok ".env written with fresh secrets ($($secrets.Count) generated)"
Write-Warn2 'BACK UP .env NOW (especially VAULT_MASTER_SECRET). Losing it makes all stored credentials unrecoverable.'

# --- 3. Data root -----------------------------------------------------------
Write-Step "Creating data root at $DataRoot"
$dirs = @('backups','cli-queue','secrets','uploads','receipts','vault','curriculum',
          'levelsense-spool','voices','downloads','bot-data','plugins')
foreach ($d in $dirs) {
    $p = Join-Path $DataRoot $d
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
Write-Ok "$($dirs.Count) data folders ready"
# docker-compose.yml reads ATLAS_DATA_ROOT (default C:\Atlas), which the generated .env now sets to $DataRoot -
# so a custom data root is honored by every volume mount without editing compose.

# --- 4. Bring the stack up --------------------------------------------------
Write-Step 'Building and starting the core stack (this can take a while on first run)'
Push-Location $root
try {
    # Default: PULL the public images from GHCR (a household has no source). -Build is for
    # the source tree (dev/testing). Compose pulls the `image:` ref when not building.
    if ($Build) { docker compose @ComposeArgs up -d --build }
    else        { docker compose @ComposeArgs up -d }
    if ($LASTEXITCODE -ne 0) { Fail 'docker compose up failed - if you have no source tree, the images must be PUBLIC on GHCR; otherwise re-run with -Build.' }
} finally { Pop-Location }
Write-Ok 'Containers started'

# --- 5. Wait for health -----------------------------------------------------
Write-Step 'Waiting for the API to report healthy'
$pingUrl = ($BaseUrl.TrimEnd('/')) + '/api/ping'
$healthy = $false
foreach ($i in 1..30) {
    try {
        $r = Invoke-WebRequest -Uri $pingUrl -TimeoutSec 4 -SkipHttpErrorCheck
        if ($r.StatusCode -eq 200) { $healthy = $true; break }
    } catch {}
    Start-Sleep -Seconds 4
}
if ($healthy) { Write-Ok "API healthy at $pingUrl" }
else { Write-Warn2 "API not healthy yet at $pingUrl. Check: docker compose logs atlas-api" }

# --- 5b. One-click update task ------------------------------------------------
# Register the Scheduled Task the Admin > System Updates "Apply update" button triggers. It runs
# apply-update.ps1 in this (logged-on) user's session so it has docker/git context, detached from the api.
Write-Step 'Registering the AtlasApplyUpdate scheduled task (powers the one-click core update)'
# A household runs from PUBLIC images, so its one-click update PULLS the new images (apply-update-images.ps1).
# A source build (-Build, dev) uses the git-pull + rebuild updater (apply-update.ps1). Wiring the wrong one
# would point the task at a script the household's bundle doesn't even ship.
$updScript = if ($Build) { Join-Path $root 'scripts\apply-update.ps1' } else { Join-Path $root 'scripts\apply-update-images.ps1' }
if (-not (Test-Path $updScript)) {
    Write-Warn2 "Update script not found at $updScript - one-click update unavailable (update by hand)."
} else {
    try {
        $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
        $act = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updScript`""
        $prin = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
        Register-ScheduledTask -TaskName 'AtlasApplyUpdate' -Action $act -Principal $prin -Settings $set -Force `
            -Description 'Atlas core self-update (snapshot + health-gate + rollback). Triggered from Admin > System Updates.' | Out-Null
        Write-Ok "AtlasApplyUpdate task registered ($(Split-Path $updScript -Leaf))"
    } catch { Write-Warn2 "Could not register the update task: $($_.Exception.Message). One-click update will be unavailable (run $(Split-Path $updScript -Leaf) by hand)." }
}

# --- 6. Next steps ----------------------------------------------------------
Write-Host ''
Write-Host 'Done. Next steps:' -ForegroundColor White
Write-Host "  1. Open $($BaseUrl.TrimEnd('/'))/  - the /Setup wizard creates your owner account." -ForegroundColor White
Write-Host '  2. In Settings, add your Anthropic API key (billed per user).' -ForegroundColor White
Write-Host '  3. Remote access (reach Atlas away from home): Tailscale (private, recommended) or a' -ForegroundColor White
Write-Host '     Cloudflare Tunnel (public) - see deploy/selfhost/README.md. Set ATLAS_DOMAIN in .env' -ForegroundColor White
Write-Host '     to your public host for auto-HTTPS, then re-run this installer to apply.' -ForegroundColor White
Write-Host '  4. Enable the plugins you want in the Plugin Store (Home Assistant, media, etc.).' -ForegroundColor White
Write-Host ''
