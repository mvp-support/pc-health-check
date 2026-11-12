# TheMVP PC health check - Windows starter. Paste into Command Prompt or PowerShell:
#   powershell -NoProfile -ExecutionPolicy Bypass -c "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/mvp-support/pc-health-check/main/windows/run.ps1))) -Ticket SID000616"
# Anyone checking their own PC (no ticket): replace  -Ticket SID000616  with  -NoTicket
# It downloads bench_collect.ps1 (same repo) to a temp folder, runs it with admin rights,
# saves the report to a folder on the Desktop plus, with a ticket, one zip to send
# (themvp-diag-<ticket>-<PC>-<date>-<time>.zip), then deletes the downloaded script.
param([string]$Ticket = "", [switch]$NoTicket, [string]$Base = "https://raw.githubusercontent.com/mvp-support/pc-health-check/main")
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Ticket = $Ticket -replace '[^A-Za-z0-9]', ''   # it becomes part of the report and file names
while (-not $Ticket -and -not $NoTicket) {
    $Ticket = (Read-Host "Please type your TheMVP ticket number (for example SID000616)") -replace '[^A-Za-z0-9]', ''
}
$ps1 = Join-Path $env:TEMP "themvp-bench_collect.ps1"
Write-Host "Downloading the TheMVP health check from $Base ..."
Invoke-WebRequest "$Base/windows/bench_collect.ps1" -OutFile $ps1 -UseBasicParsing

$name = "TheMVP-diag-" + $(if ($Ticket) { "$Ticket-" } else { "" }) + (Get-Date -Format "yyyyMMdd-HHmm")
$desktop = [Environment]::GetFolderPath("Desktop")
$out = Join-Path $desktop $name
$argList = "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`" -Out `"$out`"" + $(if ($Ticket) { " -Ticket $Ticket" } else { "" })
$started = Get-Date

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$done = $false
if (-not $isAdmin) {
    Write-Host "Windows will now ask for administrator rights (needed to read crash reports, start-up times and TPM)."
    try { Start-Process powershell -Verb RunAs -Wait -ArgumentList $argList; $done = $true }
    catch { Write-Host "No administrator rights - running anyway, a few checks will be skipped." }
}
if (-not $done) { Start-Process powershell -NoNewWindow -Wait -ArgumentList $argList }
Remove-Item $ps1 -ErrorAction SilentlyContinue

$zip = $null
if ($Ticket) {
    $zip = Get-ChildItem $desktop -Filter "themvp-diag-$Ticket-*.zip" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started } | Sort-Object LastWriteTime | Select-Object -Last 1
}
if (-not $Ticket -and (Get-ChildItem $out -Filter *.json -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "Done. Your results opened in your web browser. A copy is in: $out"
    Write-Host "Need help with what it found? Email support@themvp.in or visit https://themvp.in"
} elseif ($zip) {
    Write-Host ""
    Write-Host "Done. Your report is on the Desktop: $($zip.Name)"
    Write-Host "Please send this ONE file to TheMVP by replying to your ticket email, so it is filed with ticket $Ticket."
    Start-Process explorer "/select,`"$($zip.FullName)`""
} elseif (Get-ChildItem $out -Filter *.json -ErrorAction SilentlyContinue) {
    Write-Host ""
    Write-Host "Done. Your report is in: $out"
    Write-Host "Please send the files in that folder by replying to your ticket email."
    Start-Process explorer $out
} else {
    Write-Host "The check did not finish. Please send TheMVP a screenshot of this window."
}
