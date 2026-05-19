#requires -Version 5.1
# v2: add stage4 dev tools (Node/Java/Rust/Python + CLI tools)
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

function Install-WingetPackage {
  param(
    [Parameter(Mandatory)][string]$Id,
    [ValidateSet('user','machine')][string]$Scope = 'machine',
    [string]$Override = $null,
    [int]$MaxAttempts = 3
  )
  # Check if already installed (idempotent)
  try {
    $listOut = & winget list --id $Id -e --accept-source-agreements 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $listOut -match [Regex]::Escape($Id)) {
      Write-Ok "  [skip] $Id already installed"
      return $true
    }
  } catch {}

  $scopes = @($Scope)
  if ($Scope -eq 'machine') { $scopes += 'user' }  # fallback to user if machine fails

  foreach ($sc in $scopes) {
    for ($i = 1; $i -le $MaxAttempts; $i++) {
      Write-Info ("  [install] {0} (scope={1}, attempt {2}/{3})" -f $Id, $sc, $i, $MaxAttempts)
      $cliArgs = @('install','--id',$Id,'-e','--silent','--accept-package-agreements','--accept-source-agreements','--scope',$sc)
      if ($Override) { $cliArgs += @('--override',$Override) }
      try {
        & winget @cliArgs 2>&1 | ForEach-Object {
          Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8
        }
        $code = $LASTEXITCODE
        # 0 = ok, -1978335189 (0x8A15002B) = already installed
        if ($code -eq 0 -or $code -eq -1978335189) {
          Write-Ok ("  [done] {0} (scope={1})" -f $Id, $sc)
          return $true
        }
        Write-Warn2 ("  attempt {0} failed (exit={1})" -f $i, $code)
      } catch {
        Write-Warn2 ("  attempt {0} exception: {1}" -f $i, $_.Exception.Message)
      }
      Start-Sleep -Seconds 5
    }
    Write-Warn2 ("  scope={0} failed after {1} attempts" -f $sc, $MaxAttempts)
  }
  Write-Warn2 ("  [FAIL] {0}" -f $Id)
  return $false
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

  Save-State -State $State -Stage 'stage4'
  Unregister-ResumeTask
}

# ============================================================
# Stage 4: dev environment (winget + Node/Java/Rust/Python + CLI tools)
# ============================================================
function Invoke-Stage4 {
  param($State)
  Write-Info '=== Stage 4: dev environment via winget ==='

  # ---------- 4-1. winget availability ----------
  Write-Info '--- 4-1. winget availability ---'
  try {
    $wingetVer = & winget --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "winget --version exit code $LASTEXITCODE" }
    Write-Ok ("winget detected: {0}" -f ($wingetVer -join ' '))
  } catch {
    Write-Err 'winget is not available on this machine.'
    Write-Err 'Required: Windows 10 1809 or later, plus Microsoft Store > "App Installer".'
    Write-Err 'Install App Installer from the Microsoft Store, then re-run this script.'
    throw 'winget missing - cannot continue stage4'
  }

  function Update-PathFromMachineAndUser {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
  }

  # ---------- 4-2. winget bulk install ----------
  Write-Info '--- 4-2. winget bulk install ---'
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'

  # ordered list of (id, scope, override)
  $pkgList = @(
    @{ Id = 'Git.Git';                                 Scope = 'machine' }
    @{ Id = 'GitHub.cli';                              Scope = 'machine' }
    @{ Id = 'Microsoft.WindowsTerminal';               Scope = 'machine' }
    @{ Id = 'Microsoft.PowerShell';                    Scope = 'machine' }
    @{ Id = 'Microsoft.VisualStudioCode';              Scope = 'user'    }   # VS Code: user scope forced
    @{ Id = '7zip.7zip';                               Scope = 'machine' }
    @{ Id = 'Schniz.fnm';                              Scope = 'machine' }   # Node version manager
    @{ Id = 'Microsoft.OpenJDK.21';                    Scope = 'machine' }   # Java
    @{ Id = 'Apache.Maven';                            Scope = 'machine' }
    @{ Id = 'Microsoft.VisualStudio.2022.BuildTools';  Scope = 'machine'; Override = '--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended' }
    @{ Id = 'Rustlang.Rustup';                         Scope = 'machine' }
    @{ Id = 'Python.Python.3.12';                      Scope = 'machine' }
    @{ Id = 'astral-sh.uv';                            Scope = 'machine' }
    @{ Id = 'BurntSushi.ripgrep.MSVC';                 Scope = 'machine' }
    @{ Id = 'sharkdp.fd';                              Scope = 'machine' }
    @{ Id = 'sharkdp.bat';                             Scope = 'machine' }
    @{ Id = 'junegunn.fzf';                            Scope = 'machine' }
    @{ Id = 'jqlang.jq';                               Scope = 'machine' }
    @{ Id = 'dandavison.delta';                        Scope = 'machine' }
    @{ Id = 'Starship.Starship';                       Scope = 'machine' }
  )

  $failed = @()
  foreach ($pkg in $pkgList) {
    $ovr = if ($pkg.ContainsKey('Override')) { $pkg.Override } else { $null }
    $ok = $false
    try {
      $ok = Install-WingetPackage -Id $pkg.Id -Scope $pkg.Scope -Override $ovr
    } catch {
      Write-Warn2 ("install exception for {0}: {1}" -f $pkg.Id, $_.Exception.Message)
      $ok = $false
    }
    if (-not $ok) { $failed += $pkg.Id }
    Update-PathFromMachineAndUser
  }

  $ErrorActionPreference = $prevEAP

  if ($failed.Count -gt 0) {
    Write-Warn2 ('--- failed packages ({0}) ---' -f $failed.Count)
    foreach ($f in $failed) { Write-Warn2 ("  - {0}" -f $f) }
  } else {
    Write-Ok 'all winget packages installed (or already present)'
  }

  # ---------- 4-3. language-specific setup ----------
  Write-Info '--- 4-3. language-specific setup ---'
  Update-PathFromMachineAndUser

  # ----- Node.js (fnm) -----
  Write-Info '[Node.js] configuring fnm + LTS'
  try {
    $pwsh7Profile = Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
    $pwsh7Dir = Split-Path $pwsh7Profile -Parent
    if (-not (Test-Path $pwsh7Dir)) {
      New-Item -ItemType Directory -Path $pwsh7Dir -Force | Out-Null
    }
    $fnmInitLine = 'fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression'
    $existing = if (Test-Path $pwsh7Profile) { Get-Content $pwsh7Profile -Raw -Encoding UTF8 } else { '' }
    if ($existing -notmatch [Regex]::Escape('fnm env --use-on-cd')) {
      Add-Content -Path $pwsh7Profile -Value "`r`n# fnm (Node.js) shell init`r`n$fnmInitLine`r`n" -Encoding UTF8
      Write-Ok "fnm init line appended to $pwsh7Profile"
    } else {
      Write-Ok 'fnm init line already present in PowerShell 7 profile'
    }
  } catch {
    Write-Warn2 ("fnm profile update warning: {0}" -f $_.Exception.Message)
  }

  Update-PathFromMachineAndUser
  try {
    $fnmExe = (Get-Command fnm -ErrorAction SilentlyContinue)
    if ($fnmExe) {
      Write-Info 'fnm install --lts'
      & fnm install --lts 2>&1 | ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
      & fnm use lts-latest 2>&1 | ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
      & fnm default lts-latest 2>&1 | ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
      Write-Ok 'fnm LTS installed and set as default'
      # eval fnm env into current shell so node/npm are visible
      try {
        $fnmEnv = & fnm env --shell powershell 2>$null
        if ($fnmEnv) { $fnmEnv | Out-String | Invoke-Expression }
      } catch {}
      try {
        Write-Info 'npm install -g pnpm'
        & npm install -g pnpm 2>&1 | ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
        if ($LASTEXITCODE -ne 0) { Write-Warn2 'pnpm install non-zero exit (continuing)' } else { Write-Ok 'pnpm installed' }
      } catch {
        Write-Warn2 ("pnpm install warning: {0}" -f $_.Exception.Message)
      }
    } else {
      Write-Warn2 'fnm not on PATH yet - LTS install skipped (re-run after new shell)'
    }
  } catch {
    Write-Warn2 ("Node setup warning: {0}" -f $_.Exception.Message)
  }

  # ----- Java -----
  Write-Info '[Java] setting JAVA_HOME'
  try {
    $javaHome = $null
    try {
      $javaHome = Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\JDK\hotspot\MSI' 'Path' -ErrorAction Stop
    } catch {
      $cand = Get-ChildItem 'C:\Program Files\Microsoft\jdk-*' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
      if ($cand) { $javaHome = $cand.FullName }
    }
    if ($javaHome) {
      [System.Environment]::SetEnvironmentVariable('JAVA_HOME', $javaHome, 'Machine')
      $env:JAVA_HOME = $javaHome
      Write-Ok ("JAVA_HOME set to {0}" -f $javaHome)
    } else {
      Write-Warn2 'JDK 21 install path not found - JAVA_HOME not set'
    }
  } catch {
    Write-Warn2 ("JAVA_HOME setup warning: {0}" -f $_.Exception.Message)
  }
  Update-PathFromMachineAndUser
  try {
    $javaOut = & java -version 2>&1
    Write-Info ("java -version: {0}" -f ($javaOut -join ' | '))
  } catch {
    Write-Warn2 'java not on PATH yet (new shell may be required)'
  }

  # ----- Rust -----
  Write-Info '[Rust] running rustup-init'
  Update-PathFromMachineAndUser
  try {
    $rustupInit = (Get-Command rustup-init.exe -ErrorAction SilentlyContinue)
    if ($rustupInit) {
      & rustup-init.exe -y --default-toolchain stable --profile default 2>&1 |
        ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
      Write-Ok 'rustup-init completed'
    } else {
      Write-Warn2 'rustup-init.exe not on PATH - skipping (Rustup install may have failed)'
    }
    # PATH reload: ~/.cargo/bin
    $cargoBin = Join-Path $env:USERPROFILE '.cargoin'
    if (Test-Path $cargoBin) { $env:Path = "$cargoBin;$env:Path" }
    Update-PathFromMachineAndUser
    try {
      $cargoVer = & cargo --version 2>&1
      Write-Ok ("cargo: {0}" -f ($cargoVer -join ' '))
    } catch {
      Write-Warn2 'cargo not callable yet'
    }
    try {
      & rustup component add rust-analyzer 2>&1 |
        ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
      Write-Ok 'rust-analyzer component added'
    } catch {
      Write-Warn2 ("rust-analyzer add warning: {0}" -f $_.Exception.Message)
    }
  } catch {
    Write-Warn2 ("Rust setup warning: {0}" -f $_.Exception.Message)
  }

  # ----- Python -----
  Write-Info '[Python] checking python 3.12 / uv'
  Update-PathFromMachineAndUser
  try {
    $pyVer = & python --version 2>&1
    Write-Info ("python: {0}" -f ($pyVer -join ' '))
  } catch {
    Write-Warn2 'python not on PATH yet'
  }
  try {
    $uvVer = & uv --version 2>&1
    Write-Info ("uv: {0}" -f ($uvVer -join ' '))
  } catch {
    Write-Warn2 'uv not on PATH yet'
  }
  try {
    & python -m ensurepip --upgrade 2>&1 |
      ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
  } catch {
    Write-Warn2 ("ensurepip warning: {0}" -f $_.Exception.Message)
  }

  # ---------- 4-4. VS Code extensions ----------
  Write-Info '--- 4-4. VS Code extensions ---'
  Update-PathFromMachineAndUser
  $codeCmd = Get-Command code -ErrorAction SilentlyContinue
  if (-not $codeCmd) {
    # try the well-known user-scope install location
    $codeCandidate = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Codein\code.cmd'
    if (Test-Path $codeCandidate) { $codeCmd = $codeCandidate }
  }
  if ($codeCmd) {
    $extensions = @(
      'ms-vscode-remote.remote-wsl',
      'ms-python.python',
      'ms-python.vscode-pylance',
      'rust-lang.rust-analyzer',
      'vscjava.vscode-java-pack',
      'ms-azuretools.vscode-docker',
      'dbaeumer.vscode-eslint',
      'esbenp.prettier-vscode',
      'eamodio.gitlens',
      'editorconfig.editorconfig'
    )
    foreach ($ext in $extensions) {
      try {
        Write-Info ("  code --install-extension {0}" -f $ext)
        & code --install-extension $ext --force 2>&1 |
          ForEach-Object { Add-Content -Path $Script:LogPath -Value $_ -Encoding UTF8 }
      } catch {
        Write-Warn2 ("  ext install warning ({0}): {1}" -f $ext, $_.Exception.Message)
      }
    }
    Write-Ok 'VS Code extensions install attempted'
  } else {
    Write-Warn2 'code CLI not found - VS Code extensions skipped'
  }

  # ---------- 4-5. final summary ----------
  Write-Info '--- 4-5. final summary ---'
  Update-PathFromMachineAndUser

  function Get-CmdVersion {
    param([string]$Exe, [string[]]$Args = @('--version'))
    try {
      $out = & $Exe @Args 2>&1
      return (($out | Select-Object -First 3) -join ' | ')
    } catch {
      return '(not available)'
    }
  }

  $vers = [ordered]@{}
  $vers['git']     = Get-CmdVersion -Exe 'git'
  $vers['gh']      = Get-CmdVersion -Exe 'gh'
  $vers['code']    = Get-CmdVersion -Exe 'code'
  $vers['fnm']     = Get-CmdVersion -Exe 'fnm'
  $vers['node']    = Get-CmdVersion -Exe 'node'
  $vers['npm']     = Get-CmdVersion -Exe 'npm'
  $vers['pnpm']    = Get-CmdVersion -Exe 'pnpm'
  $vers['java']    = Get-CmdVersion -Exe 'java' -Args @('-version')
  $vers['mvn']     = Get-CmdVersion -Exe 'mvn'
  $vers['rustc']   = Get-CmdVersion -Exe 'rustc'
  $vers['cargo']   = Get-CmdVersion -Exe 'cargo'
  $vers['python']  = Get-CmdVersion -Exe 'python'
  $vers['uv']      = Get-CmdVersion -Exe 'uv'
  $vers['rg']      = Get-CmdVersion -Exe 'rg'
  $vers['fd']      = Get-CmdVersion -Exe 'fd'
  $vers['bat']     = Get-CmdVersion -Exe 'bat'
  $vers['fzf']     = Get-CmdVersion -Exe 'fzf'
  $vers['jq']      = Get-CmdVersion -Exe 'jq'
  $vers['delta']   = Get-CmdVersion -Exe 'delta'
  $vers['starship']= Get-CmdVersion -Exe 'starship'

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('================================================================')
  [void]$sb.AppendLine(' Stage 4 dev environment  SUCCESS')
  [void]$sb.AppendLine('================================================================')
  foreach ($k in $vers.Keys) {
    [void]$sb.AppendLine(('  {0,-10}: {1}' -f $k, $vers[$k]))
  }
  if ($failed.Count -gt 0) {
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(' Failed winget packages:')
    foreach ($f in $failed) { [void]$sb.AppendLine(('   - {0}' -f $f)) }
  }
  [void]$sb.AppendLine('================================================================')
  $summary4 = $sb.ToString()
  Write-Host $summary4 -ForegroundColor Green
  Add-Content -Path $Script:LogPath -Value $summary4 -Encoding UTF8

  # append to desktop result file (stage3 already wrote stage1-3 result)
  $resultFile = Join-Path $env:USERPROFILE 'Desktop\homelab-setup-result.txt'
  Add-Content -Path $resultFile -Value $summary4 -Encoding UTF8

  # mark completion
  Save-State -State $State -Stage 'done'
  Unregister-ResumeTask
  Write-Ok 'Stage 4 done. Setup fully complete.'
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

  # Loop so non-rebooting stages (3 -> 4 -> done) chain in one invocation.
  # Stages 1 and 2 reboot via Restart-Computer, so the loop terminates there anyway.
  do {
    $loopState = Get-State
    switch ($loopState.stage) {
      'stage1' { Invoke-Stage1 -State $loopState }
      'stage2' { Invoke-Stage2 -State $loopState }
      'stage3' { Invoke-Stage3 -State $loopState }
      'stage4' { Invoke-Stage4 -State $loopState }
      'done'   {
        Write-Ok 'Setup already complete. Nothing to do.'
        Unregister-ResumeTask
      }
      default {
        Write-Warn2 ("Unknown stage '{0}', restarting from stage1" -f $loopState.stage)
        $loopState.stage = 'stage1'
        Invoke-Stage1 -State $loopState
      }
    }
    $loopState = Get-State
  } while ($loopState.stage -notin @('done') -and $loopState.stage -notmatch '_failed$')
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
