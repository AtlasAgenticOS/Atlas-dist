#requires -Version 7.0
<#
.SYNOPSIS
  Downstream update: pull the latest Atlas images from PUBLIC GHCR and restart, driven by
  the public version feed. No source, no build, no git - for households that run from
  published images (the private-source / public-images model).

.DESCRIPTION
  1. Read the version feed (Updates:FeedUrl, default the public Atlas-dist core-version.json)
     to get the target version + image tag.
  2. If already on it, exit.
  3. Back up the DB (best-effort), set ATLAS_IMAGE_TAG to the target, `docker compose pull`
     the Atlas images, and `up -d`.
  4. Health-gate on /healthz; if it doesn't come healthy, roll ATLAS_IMAGE_TAG back to the
     previous tag and restart. Idempotent + safe to schedule.

.PARAMETER FeedUrl   Version feed URL (default: the public Atlas-dist feed).
.PARAMETER Force     Re-pull + restart even if already on the target version.
#>
[CmdletBinding()]
param(
    [string]$FeedUrl = 'https://raw.githubusercontent.com/AtlasAgenticOS/Atlas-dist/main/core-version.json',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$envFile = Join-Path $root '.env'
$Compose = @('docker','compose','-f','docker-compose.yml','-f','docker-compose.selfhost.yml')
$Services = @('atlas-api','atlas-web','atlas-worker','atlas-bot','atlas-music','atlas-gmessages')
function Step($m){ Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "    OK  $m" -ForegroundColor Green }
function Warn($m){ Write-Host "    !   $m" -ForegroundColor Yellow }
function Die($m){ Write-Host "    X   $m" -ForegroundColor Red; exit 1 }

function Get-EnvVal($key, $default='') {
    if (Test-Path $envFile) {
        $m = Select-String -Path $envFile -Pattern "^$key=(.*)$" | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    }
    return $default
}
function Set-EnvVal($key, $val) {
    $lines = (Test-Path $envFile) ? @(Get-Content $envFile) : @()
    if ($lines -match "^$key=") { $lines = $lines -replace "^$key=.*", "$key=$val" }
    else { $lines += "$key=$val" }
    Set-Content $envFile $lines -Encoding utf8
}
function Get-EnvTag { return (Get-EnvVal 'ATLAS_IMAGE_TAG' 'latest') }
function Set-EnvTag($tag) { Set-EnvVal 'ATLAS_IMAGE_TAG' $tag }

# The running core reports its version from the CORE_VERSION env (SystemEndpoints /system/version +
# /system/updates/check) - the image itself is NOT stamped. So swapping ATLAS_IMAGE_TAG alone would run
# the new images but keep REPORTING the old version -> /system/updates/check would show "update available"
# forever. Propagate the feed's version/sha/builtAt into .env alongside the tag so the restarted api
# reports the version it is actually running and the update check clears.
function Set-CoreStamp($version, $sha, $builtAt) {
    if ($version) { Set-EnvVal 'CORE_VERSION'  $version }
    if ($sha)     { Set-EnvVal 'CORE_SHA'      $sha }
    if ($builtAt) { Set-EnvVal 'CORE_BUILT_AT' $builtAt }
}
function Test-Healthy {
    # Use the compose SERVICE (project-aware) not a hardcoded container name - a household's project is its
    # clone-dir name (atlas-dist-atlas-api-1), not the Fielden box's atlas-atlas-api-1.
    Push-Location $root
    try {
        for ($i=0; $i -lt 24; $i++) {
            try { $c = (& $Compose[0] $Compose[1..($Compose.Count-1)] exec -T atlas-api sh -lc "curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:8080/healthz" 2>$null); if ("$c".Trim() -eq '200') { return $true } } catch {}
            Start-Sleep 5
        }
        return $false
    } finally { Pop-Location }
}

Step "Checking the version feed"
try { $feed = Invoke-RestMethod -Uri $FeedUrl -TimeoutSec 20 } catch { Die "could not read feed $FeedUrl : $($_.Exception.Message)" }
$target = if ($feed.imageTag) { "$($feed.imageTag)" } else { "$($feed.version)" }
if (-not $target) { Die 'feed has no imageTag/version' }
$current = Get-EnvTag
# Snapshot the current core stamp so a failed upgrade can roll the reported version back too, not just the tag.
$prevCore = @{ version = (Get-EnvVal 'CORE_VERSION'); sha = (Get-EnvVal 'CORE_SHA'); builtAt = (Get-EnvVal 'CORE_BUILT_AT') }
Ok "current tag=$current, feed target=$target (version $($feed.version))"
if (($current -eq $target) -and -not $Force) { Ok 'Already up to date. Nothing to do.'; exit 0 }

Step 'Backing up the database (best-effort)'
try {
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
    Push-Location $root
    try { & $Compose[0] $Compose[1..($Compose.Count-1)] exec -T sqlserver bash -lc "T=`$(ls /opt/mssql-tools*/bin/sqlcmd | head -1); `"`$T`" -S localhost -U sa -P `"`$MSSQL_SA_PASSWORD`" -C -b -Q `"BACKUP DATABASE [Atlas] TO DISK='/var/opt/mssql/backups/preupdate_$ts.bak' WITH INIT, COMPRESSION`"" 2>$null }
    finally { Pop-Location }
    Ok "DB backed up (preupdate_$ts.bak in the sqlserver backups volume)"
} catch { Warn "DB backup skipped: $($_.Exception.Message)" }

Step "Pulling images :$target and restarting"
Set-EnvTag $target
# Stamp the reported version to match the images we're about to run (see Set-CoreStamp).
Set-CoreStamp $feed.version $feed.sha $feed.builtAt
Push-Location $root
try {
    & $Compose[0] $Compose[1..($Compose.Count-1)] pull @Services
    if ($LASTEXITCODE -ne 0) { Warn 'pull failed - are the images public + the tag valid?'; Set-EnvTag $current; Die 'aborted; tag reverted' }
    & $Compose[0] $Compose[1..($Compose.Count-1)] up -d @Services
} finally { Pop-Location }

Step 'Health-gating'
if (Test-Healthy) { Ok "Updated to $target and healthy." }
else {
    Warn "New version unhealthy - rolling back to $current"
    Set-EnvTag $current
    Set-CoreStamp $prevCore.version $prevCore.sha $prevCore.builtAt
    Push-Location $root
    try { & $Compose[0] $Compose[1..($Compose.Count-1)] up -d @Services } finally { Pop-Location }
    if (Test-Healthy) { Die "Rolled back to $current (it is healthy). The $target image needs investigation." }
    else { Die "Rollback also unhealthy - manual intervention needed. Restore the DB backup if the schema changed." }
}
