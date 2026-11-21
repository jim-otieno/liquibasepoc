<#
.SYNOPSIS
  Install the tools the PoC needs on Windows, using winget. Skips anything already installed.

.DESCRIPTION
  Run in PowerShell (not as Administrator unless winget asks):
      powershell -ExecutionPolicy Bypass -File scripts\setup\install-prereqs.ps1
  Add -WhatIf to see what would be installed without installing anything.
  Add -IncludeOptional to also install Java 21 (only needed to build or test the
  app outside Docker) and the GitHub CLI.

  Close and reopen your terminal afterwards so new PATH entries take effect.
#>
param(
    [switch]$IncludeOptional,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "winget not found. Install 'App Installer' from the Microsoft Store, then re-run." -ForegroundColor Red
    exit 1
}

# command to detect | winget id | why the PoC needs it
$tools = @(
    @{ Cmd = 'git';       Id = 'Git.Git';                Why = 'source control + Git Bash (runs the .sh scripts)' },
    @{ Cmd = 'python';    Id = 'Python.Python.3.12';     Why = 'linter, experiment scripts, analysis'; Alt = @('py', 'python3') },
    @{ Cmd = 'docker';    Id = 'Docker.DockerDesktop';   Why = 'Liquibase, PostgreSQL, the app, Prometheus, Grafana' },
    @{ Cmd = 'k6';        Id = 'k6';                     Why = 'availability probe / load during migrations'; ByName = $true },
    @{ Cmd = 'terraform'; Id = 'Hashicorp.Terraform';    Why = 'creates the AWS RDS instance' },
    @{ Cmd = 'aws';       Id = 'Amazon.AWSCLI';          Why = 'AWS access (RDS password, Terraform credentials)' }
)
if ($IncludeOptional) {
    $tools += @{ Cmd = 'java'; Id = 'EclipseAdoptium.Temurin.21.JDK'; Why = 'build/test the app outside Docker (optional)' }
    $tools += @{ Cmd = 'gh';   Id = 'GitHub.cli';                     Why = 'GitHub from the terminal (optional)' }
}

function Test-RealCommand($name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -eq $c) { return $false }
    if ($name -in @('python', 'python3', 'py')) {
        # The Microsoft Store stub and the real Python install manager both live in
        # WindowsApps, so ask the interpreter itself: it must run and be 3.10+.
        try {
            $out = & $name -c "import sys; print(sys.version_info >= (3, 10))" 2>$null
            return ($LASTEXITCODE -eq 0) -and ($out -eq 'True')
        } catch { return $false }
    }
    return $true
}

foreach ($t in $tools) {
    $names = @($t.Cmd) + @($t.Alt | Where-Object { $_ })
    if ($names | Where-Object { Test-RealCommand $_ } | Select-Object -First 1) {
        Write-Host ("[ok]      {0,-10} already installed" -f $t.Cmd) -ForegroundColor Green
        continue
    }
    Write-Host ("[install] {0,-10} {1}  ({2})" -f $t.Cmd, $t.Id, $t.Why) -ForegroundColor Yellow
    if (-not $WhatIf) {
        if ($t.ByName) {
            # k6's own docs install it by name from the winget source.
            winget install $t.Id --source winget --silent --accept-package-agreements --accept-source-agreements
        } else {
            winget install --id $t.Id --exact --silent --accept-package-agreements --accept-source-agreements
        }
    }
}

Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. Close and reopen your terminal (new PATH)."
Write-Host "  2. Start Docker Desktop once and wait until it says 'Engine running'."
Write-Host "  3. Open Git Bash in the repo folder and run:  bash scripts/setup/check-prereqs.sh"
