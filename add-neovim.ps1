#requires -Version 5.1
# add-neovim.ps1
# Installs Neovim (Neovim.Neovim) + the VS Code Neovim extension (asvetliakov.vscode-neovim).
# Companion to setup-homelab.ps1. Run AFTER the main setup, in an Administrator PowerShell:
#   iex (irm https://raw.githubusercontent.com/nagata1634/homelab-setup/main/add-neovim.ps1)

$ErrorActionPreference = 'Continue'

Write-Host '=== add-neovim: Neovim + VS Code Neovim extension ===' -ForegroundColor Cyan

# --- Neovim via winget ---
try {
  Write-Host 'Installing Neovim.Neovim via winget...' -ForegroundColor Cyan
  winget install --id Neovim.Neovim -e --silent --accept-package-agreements --accept-source-agreements
  Write-Host "winget finished (exit code $LASTEXITCODE)" -ForegroundColor Gray
} catch {
  Write-Host "Neovim install warning: $($_.Exception.Message)" -ForegroundColor Yellow
}

# refresh PATH so freshly installed binaries resolve in this session
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')

# --- VS Code extension ---
$code = Get-Command code -ErrorAction SilentlyContinue
if (-not $code) {
  $cand = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'
  if (Test-Path $cand) { $code = $cand }
}
if ($code) {
  Write-Host 'Installing VS Code extension asvetliakov.vscode-neovim...' -ForegroundColor Cyan
  & $code --install-extension asvetliakov.vscode-neovim --force
} else {
  Write-Host 'VS Code CLI not found. Install manually: asvetliakov.vscode-neovim' -ForegroundColor Yellow
}

# --- verify ---
try {
  $nv = & nvim --version 2>&1 | Select-Object -First 1
  Write-Host "nvim: $nv" -ForegroundColor Green
} catch {
  Write-Host 'nvim not on PATH yet - open a new terminal and run: nvim --version' -ForegroundColor Yellow
}

Write-Host '=== add-neovim done. Restart VS Code to activate the extension. ===' -ForegroundColor Green
