#requires -Version 5.1
<#
.SYNOPSIS
  Windows homelab phase-1 setup: WSL2 + Docker Desktop + buildx multi-arch.
.DESCRIPTION
  Idempotent, resumable across 2 reboots via Task Scheduler "AtLogOn".
  Target: Windows 10 21H2 (build 19044+) / Windows 11.
  Designed to be invoked as: iex (irm <raw url>)
.NOTES
  Logs    : C:\ProgramData\homelab-setup\setup.log
  State   : C:\ProgramData\homelab-setup\state.json
  Resume  : Task Scheduler task "HomelabSetupResume"
#>

# ============================================================
# Constants (edit $SelfUrl if you fork this repo)
# ============================================================
$Script:SelfUrl    = 'https://raw.githubusercontent.com/nagata1634/homelab-setup/main/setup-homelab.ps1'
$Script:WorkDir    = 'C:\ProgramData\homelab-setup'
$Script:ScriptPath = Join-Path $Script:WorkDir 'setup-homelab.ps1'
$Script:StatePath  = Join-Path $Script:WorkDir 'state.json'
$Script:LogPath    = Join-Path $Script:WorkDir 'setup.log'
$Script:TaskName   = 'HomelabSetupResume'

$ErrorActionPreference = 'Stop'

# Force TLS 1.2 (PowerShell 5.1 default is sometimes SSL3/TLS1.0)
try {
  [Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# ============================================================
# Logging
# ============================================================
function Write-Log {
  param(
    [Parameter(Mandatory)][string]$Msg,
    [string]$Level = 'INFO',
    [ConsoleColor]$Color = 'Gray'
  )
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$ts][$Level] $Msg"
  Write-Host $line -ForegroundColor $Color
  try {
    if (-not (Test-Path $Script:WorkDir)) {
      New-Item -ItemType Directory -Path $Script:WorkDir -Force | Out-Null
    }
    Add-Content -Path $Script:LogPath -Value $line -Encoding UTF8
  } catch {}
}
function Write-Info  { param([string]$m) Write-Log -Msg $m -Level 'INFO'  -Color Cyan }
function Write-Ok    { param([string]$m) Write-Log -Msg $m -Level 'OK'    -Color Green }
function Write-Warn2 { param([string]$m) Write-Log -Msg $m -Level 'WARN'  -Color Yellow }
function Write-Err   { param([string]$m) Write-Log -Msg $m -Level 'ERROR' -Color Red }

# ============================================================
# Helpers
# ============================================================
function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory)][scriptblock]$Action,
    [int]$MaxAttempts = 3,
    [int]$DelaySec    = 5
  )
  for ($i = 1; $i -le $MaxAttempts; $i++) {
    try {
      return & $Action
    } catch {
      Write-Warn2 ("Attempt {0}/{1} failed: {2}" -f $i, $MaxAttempts, $_.Exception.Message)
      if ($i -eq $MaxAttempts) { throw }
      Start-Sleep -Seconds $DelaySec
    }
  }
}

function Get-State {
  if (Test-Path $Script:StatePath) {
    try { return Get-Content $Script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  $now = (Get-Date).ToString('o')
  return [pscustomobject]@{
    stage      = 'stage1'
    started_at = $now
    updated_at = $now
  }
}

function Save-State {
  param($State, [string]$Stage)
  $State | Add-Member -NotePropertyName stage      -NotePropertyValue $Stage              -Force
  $State | Add-Member -NotePropertyName updated_at -NotePropertyValue (Get-Date).ToString('o') -Force
  $State | ConvertTo-Json | Set-Content -Path $Script:StatePath -Encoding UTF8
  Write-Info "state -> $Stage"
}

function Register-ResumeTask {
  Write-Info 'Registering Task Scheduler resume task'
  $argLine   = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $Script:ScriptPath)
  $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
  $userId    = "$env:USERDOMAIN\$env:USERNAME"
  $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $userId
  $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Highest -LogonType Interactive
  $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  Register-ScheduledTask -TaskName $Script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

function Unregister-ResumeTask {
  try {
    Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false -ErrorAction Stop
    Write-Info 'Resume task removed'
  } catch {
    Write-Warn2 ("Resume task removal skipped: {0}" -f $_.Exception.Message)
  }
}

function Save-SelfScript {
  # Under `iex (irm ...)` invocation, $PSCommandPath is empty.
  # Always re-download the script to a fixed path so Task Scheduler can re-run it.
  if (-not (Test-Path $Script:WorkDir)) {
    New-Item -ItemType Directory -Path $Script:WorkDir -Force | Out-Null
  }
  Write-Info "Downloading script -> $Script:ScriptPath"
  Invoke-WithRetry -Action {
    Invoke-WebRequest -Uri $Script:SelfUrl -OutFile $Script:ScriptPath -UseBasicParsing
  }
}

function Enable-FeatureIfNeeded {
  param([Parameter(Mandatory)][string]$Name)
  $f = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction SilentlyContinue
  if ($null -eq $f) {
    Write-Warn2 "Feature $Name not present on this SKU, skipping"
    return $false
  }
  if ($f.State -eq 'Enabled') {
    Write-Ok "$Name already enabled"
    return $false
  }
  Write-Info "Enabling $Name"
  Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart -ErrorAction Stop | Out-Null
  return $true
}

# ============================================================
# Stage 1: enable virtualization + install WSL kernel
# ============================================================
function Invoke-Stage1 {
  param($State)
  Write-Info '=== Stage 1: virtualization features + WSL kernel ==='

  $osInfo = Get-CimInstance Win32_OperatingSystem
  Write-Info ("OS: {0}" -f $osInfo.Caption)
  $build = [int]$osInfo.BuildNumber
  Write-Info ("Build: {0}" -f $build)
  if ($build -lt 19044) {
    throw "Windows 10 21H2 (build 19044) or later required. Current build: $build"
  }

  Enable-FeatureIfNeeded -Name 'VirtualMachinePlatform'         | Out-Null
  Enable-FeatureIfNeeded -Name 'Microsoft-Windows-Subsystem-Linux' | Out-Null
  Enable-FeatureIfNeeded -Name 'HypervisorPlatform'             | Out-Null

  Write-Info 'wsl --install --no-distribution'
  try {
    $wslOut = & wsl --install --no-distribution 2>&1
    $wslOut | ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
  } catch {
    Write-Warn2 ("wsl --install non-fatal: {0}" -f $_.Exception.Message)
  }

  Save-State -State $State -Stage 'stage2'
  Register-ResumeTask
  Write-Ok 'Stage 1 done. Rebooting in 10 sec... (script will resume after login)'
  Start-Sleep -Seconds 10
  Restart-Computer -Force
}

# ============================================================
# Stage 2: install Ubuntu + Docker Desktop
# ============================================================
function Invoke-Stage2 {
  param($State)
  Write-Info '=== Stage 2: Ubuntu-24.04 + Docker Desktop ==='

  Write-Info 'Waiting for wsl --status to succeed...'
  $ok = $false
  for ($i = 1; $i -le 5; $i++) {
    try {
      $null = & wsl --status 2>&1
      if ($LASTEXITCODE -eq 0) { $ok = $true; break }
    } catch {}
    Start-Sleep -Seconds 10
  }
  if (-not $ok) { throw 'wsl --status did not succeed within 5 attempts (50s)' }
  Write-Ok 'WSL is responsive'

  try { & wsl --set-default-version 2 2>&1 | Out-Null } catch {}

  $distros = & wsl -l -q 2>$null
  if ($distros -notmatch 'Ubuntu-24\.04') {
    Write-Info 'Installing Ubuntu-24.04 (no-launch)'
    try {
      & wsl --install -d Ubuntu-24.04 --no-launch 2>&1 |
        ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
    } catch {
      Write-Warn2 ("Ubuntu install warning: {0}" -f $_.Exception.Message)
    }
  } else {
    Write-Ok 'Ubuntu-24.04 already registered'
  }

  $dockerExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
  if (Test-Path $dockerExe) {
    Write-Ok 'Docker Desktop already installed'
  } else {
    $installer = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
    Write-Info 'Downloading Docker Desktop installer (~600MB, may take a few minutes)'
    Invoke-WithRetry -Action {
      Invoke-WebRequest `
        -Uri 'https://desktop.docker.com/win/main/amd64/Docker Desktop Installer.exe' `
        -OutFile $installer -UseBasicParsing
    }
    Write-Info 'Running Docker Desktop installer (silent)'
    $p = Start-Process -FilePath $installer `
      -ArgumentList 'install','--quiet','--accept-license','--backend=wsl-2','--always-run-service' `
      -Wait -NoNewWindow -PassThru
    if ($p.ExitCode -ne 0) {
      throw "Docker Desktop installer exit code $($p.ExitCode)"
    }
    Write-Ok 'Docker Desktop installed'
  }

  Save-State -State $State -Stage 'stage3'
  Write-Ok 'Stage 2 done. Rebooting in 10 sec...'
  Start-Sleep -Seconds 10
  Restart-Computer -Force
}

# ============================================================
# Stage 3: start docker, install binfmt, create buildx builder, verify
# ============================================================
function Invoke-Stage3 {
  param($State)
  Write-Info '=== Stage 3: docker engine + buildx multi-arch ==='

  $dockerExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
  if (Test-Path $dockerExe) {
    Write-Info 'Launching Docker Desktop'
    try { Start-Process -FilePath $dockerExe } catch {}
  } else {
    throw 'Docker Desktop.exe not found - stage 2 may have failed'
  }

  Write-Info 'Waiting for docker engine (up to ~180s)'
  $up = $false
  for ($i = 1; $i -le 20; $i++) {
    try {
      $ver = & docker version --format '{{.Server.Version}}' 2>$null
      if ($LASTEXITCODE -eq 0 -and $ver) { $up = $true; break }
    } catch {}
    Start-Sleep -Seconds 9
    Write-Info ("  ...still waiting ({0}/20)" -f $i)
  }
  if (-not $up) {
    throw 'docker engine did not come up within 180s. Open Docker Desktop manually, finish first-run prompts, then re-run this script.'
  }
  Write-Ok 'docker engine ready'

  Write-Info 'docker run --rm hello-world'
  try {
    $hw = & docker run --rm hello-world 2>&1
    $hw | ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
  } catch {
    Write-Warn2 ("hello-world warning: {0}" -f $_.Exception.Message)
  }

  Write-Info 'Installing multi-arch binfmt (tonistiigi/binfmt)'
  & docker run --privileged --rm tonistiigi/binfmt --install all 2>&1 |
    ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }

  Write-Info 'Setting up buildx builder "multi"'
  $existing = & docker buildx ls 2>$null
  if ($existing -match '(?m)^multi\b') {
    & docker buildx use multi | Out-Null
    Write-Ok 'buildx "multi" already exists, switched'
  } else {
    & docker buildx create --name multi --use --bootstrap 2>&1 |
      ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
  }

  $inspect = & docker buildx inspect --bootstrap 2>&1
  $inspect | ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
  if (($inspect -join "`n") -notmatch 'linux/arm64') {
    throw 'buildx multi-arch FAILED: linux/arm64 not advertised by builder'
  }
  Write-Ok 'buildx multi-arch (linux/arm64 + linux/amd64) verified'

  # Desktop docs folder
  $deskDir = Join-Path $env:USERPROFILE 'Desktop\homelab-docs'
  if (-not (Test-Path $deskDir)) {
    New-Item -ItemType Directory -Path $deskDir -Force | Out-Null
  }
  $readmeBody = @"
ここに 01_全体像.md / 02_セットアップ手順.md など、homelab のドキュメントを順次置いてください。
このフォルダは setup-homelab.ps1 (stage3) が初期化した空の入れ物です。

参考:
- 自宅 NAS         : QNAP TS-233 (ARM64 Cortex-A55)
- Windows ホスト   : このマシン (WSL2 + Docker Desktop + buildx multi-arch 済)
- ログ            : C:\ProgramData\homelab-setup\setup.log
"@
  Set-Content -Path (Join-Path $deskDir 'README.txt') -Value $readmeBody -Encoding UTF8

  # Final summary
  $winVer    = ("{0} build {1}" -f (Get-CimInstance Win32_OperatingSystem).Caption,
                                    (Get-CimInstance Win32_OperatingSystem).BuildNumber)
  $wslVer    = (& wsl --version 2>$null) -join "`n"
  $dockerVer = (& docker version --format 'Client: {{.Client.Version}} / Server: {{.Server.Version}}' 2>$null)
  $started   = [DateTime]::Parse($State.started_at)
  $elapsed   = (Get-Date) - $started

  $summary = @"

=============================================================
 Homelab phase-1 setup  SUCCESS
=============================================================
 Windows  : $winVer
 WSL      :
$wslVer
 Docker   : $dockerVer
 Builder  : multi (linux/arm64, linux/amd64)
 Elapsed  : $([int]$elapsed.TotalMinutes) min $($elapsed.Seconds) sec
=============================================================
 Next phase:
   GHCR PAT を作って、Syncthing コンテナを
   linux/arm64 で build & push する手順を
   Claude に指示してください。
=============================================================
"@
  Write-Host $summary -ForegroundColor Green
  Add-Content -Path $Script:LogPath -Value $summary -Encoding UTF8
  $resultFile = Join-Path $env:USERPROFILE 'Desktop\homelab-setup-result.txt'
  $summary | Set-Content -Path $resultFile -Encoding UTF8

  Save-State -State $State -Stage 'done'
  Unregister-ResumeTask
}

# ============================================================
# Main
# ============================================================
try {
  if (-not (Test-IsAdmin)) {
    Write-Host 'ERROR: Administrator privileges required.' -ForegroundColor Red
    Write-Host '       PowerShell を「管理者として実行」で開き直してから再実行してください。' -ForegroundColor Red
    exit 1
  }

  if (-not (Test-Path $Script:WorkDir)) {
    New-Item -ItemType Directory -Path $Script:WorkDir -Force | Out-Null
  }
  try { Start-Transcript -Path (Join-Path $Script:WorkDir 'transcript.log') -Append | Out-Null } catch {}

  Write-Info ("homelab-setup start (user: {0}, host: {1})" -f $env:USERNAME, $env:COMPUTERNAME)
  Save-SelfScript

  $state = Get-State
  Write-Info ("Current stage: {0}" -f $state.stage)

  switch ($state.stage) {
    'stage1' { Invoke-Stage1 -State $state }
    'stage2' { Invoke-Stage2 -State $state }
    'stage3' { Invoke-Stage3 -State $state }
    'done'   {
      Write-Ok 'Setup already complete. Nothing to do.'
      Unregister-ResumeTask
    }
    default {
      Write-Warn2 ("Unknown stage '{0}', restarting from stage1" -f $state.stage)
      $state.stage = 'stage1'
      Invoke-Stage1 -State $state
    }
  }
}
catch {
  Write-Err ("FATAL: {0}" -f $_.Exception.Message)
  Write-Err ($_.ScriptStackTrace)
  try {
    $st = Get-State
    $failedStage = "$($st.stage)_failed"
    Save-State -State $st -Stage $failedStage
  } catch {}
  Write-Host ''
  Write-Host '実行中にエラーが発生しました。' -ForegroundColor Red
  Write-Host ('ログ: {0}' -f $Script:LogPath) -ForegroundColor Yellow
  Write-Host '原因を確認したのち、同じワンライナーを再実行すれば中断したステージから再開します。' -ForegroundColor Yellow
  exit 1
}
finally {
  try { Stop-Transcript | Out-Null } catch {}
}
