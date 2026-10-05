# pmpro-stack installer for Windows — runs the Linux installer inside WSL.
#
#   irm https://github.com/strangerstudios/pmpro-stack/releases/latest/download/install.ps1 | iex
#
# pmpro-stack (bash + Ansible) needs a Linux environment. On Windows that is
# WSL (Windows Subsystem for Linux). This script installs WSL + Ubuntu if
# missing, then runs install.sh inside it. Afterwards, use pmpro-stack from a
# WSL shell (type `wsl` in PowerShell, or open "Ubuntu" from the Start menu).

$ErrorActionPreference = 'Stop'
$installUrl = 'https://github.com/strangerstudios/pmpro-stack/releases/latest/download/install.sh'

function Has-WslDistro {
    try {
        $out = & wsl.exe --list --quiet 2>$null
        return ($LASTEXITCODE -eq 0) -and (($out | Where-Object { $_ -and $_.Trim() }) | Measure-Object).Count -gt 0
    } catch { return $false }
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue) -or -not (Has-WslDistro)) {
    Write-Host 'WSL with a Linux distro is required. Installing WSL + Ubuntu (needs admin; a reboot may be required)...'
    & wsl.exe --install -d Ubuntu
    Write-Host ''
    Write-Host 'When WSL finishes (reboot if asked and create your Linux username/password), re-run this installer.'
    exit 0
}

Write-Host 'Running the pmpro-stack installer inside WSL...'
& wsl.exe -e bash -lc "curl -fsSL '$installUrl' | bash"
if ($LASTEXITCODE -ne 0) { throw "install.sh exited with code $LASTEXITCODE" }

Write-Host ''
Write-Host 'Done. Open a WSL shell (run `wsl`) and use:'
Write-Host '  nano ~/.pmpro-stack.env          # add your DigitalOcean + Cloudflare tokens'
Write-Host '  pmpro-stack create --domain members.example.com --le-email you@example.com'
