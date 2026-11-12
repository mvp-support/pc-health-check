<#
.SYNOPSIS
  TheMVP bench collector: reads what the PC already recorded (crashes, power loss,
  hardware errors, disk health, temps, drivers) into one JSON file for /bench.

.DESCRIPTION
  Read-only: changes nothing on the PC. Run from the bench USB stick as admin:

    powershell -ExecutionPolicy Bypass -File E:\bench\bench_collect.ps1

  Optional tools, picked up from the script's folder, an x64 subfolder, or PATH:
    smartctl.exe   (smartmontools)        -> SMART health per drive
    cdb.exe        (Debugging Tools)      -> faulting driver from each minidump
  Temperatures come from LibreHardwareMonitor if it is running (it publishes
  sensors to WMI). Without these, the rest still works.

  PC won't boot Windows? Boot WinPE (with the PowerShell component) and point
  -Windows at the installed Windows folder, e.g. -Windows D:\Windows — event logs
  and minidumps are read from there.

.PARAMETER Ticket   TheMVP ticket number, e.g. SID000616. It is written into the report and the
                    zip name (themvp-diag-<ticket>-<PC>-<date>-<time>.zip) so the service desk
                    can check the report belongs to the ticket it was sent on.
.PARAMETER Days     How far back to read event logs (default 30).
.PARAMETER Out      Output folder (default: a "reports" folder next to the script).
.PARAMETER Server   Optional bench server URL, e.g. http://192.168.1.10:8000
.PARAMETER Token    Bench token (with -Server).
.PARAMETER JobId    Bench job number to attach the report to (with -Server).
.PARAMETER PerfSeconds  Seconds to sample CPU / DPC / disk / memory counters (default 20,
                        0 = skip). Leave the PC idle while it samples - the bench rules
                        read the numbers as idle load.
.PARAMETER Trace    Seconds to record a Windows Performance Recorder trace (wpr.exe, built
                    into Windows 10/11) for "slow but benchmarks fine" cases. Reproduce the
                    slowness while it records; open the .etl in Windows Performance
                    Analyzer. 0 = off (default).
#>
param(
    [string]$Ticket = "",
    [int]$Days = 30,
    [string]$Windows = $env:SystemRoot,
    [string]$Out = (Join-Path $PSScriptRoot "reports"),
    [string]$Server = "",
    [string]$Token = "",
    [int]$JobId = 0,
    [int]$PerfSeconds = 20,
    [int]$Trace = 0
)
$ErrorActionPreference = "SilentlyContinue"
$CollectorVersion = "1.1"
$Ticket = $Ticket -replace '[^A-Za-z0-9]', ''   # it becomes part of the zip name
$since = (Get-Date).AddDays(-$Days)
$offline = ($Windows.TrimEnd('\') -ne $env:SystemRoot.TrimEnd('\'))

function Find-Tool($name) {
    # next to the script, or in an x64\ subfolder (Debuggers\x64 copied as a folder)
    foreach ($local in (Join-Path $PSScriptRoot $name), (Join-Path $PSScriptRoot "x64\$name")) {
        if (Test-Path $local) { return $local }
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-LogEvents([string]$log, [hashtable]$filter) {
    # live: by log name; WinPE (-Windows): straight from the offline .evtx file
    if ($offline) { $filter["Path"] = Join-Path $Windows ("System32\winevt\Logs\" + ($log -replace "/", "%4") + ".evtx") }
    else { $filter["LogName"] = $log }
    $filter["StartTime"] = $since
    @(Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue)
}
function Get-SysEvents([hashtable]$filter) { Get-LogEvents "System" $filter }
function Get-EventData($e) {
    $h = @{}
    foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { $h[$d.Name] = $d.'#text' }
    $h
}

function Gb($bytes) { if ($bytes) { [math]::Round($bytes / 1GB, 1) } else { 0 } }

# Device filter, dump-header read and the Raptor Lake microcode check are adapted from
# StressLab (c) 2025-2026 Cincy Power Computers, LLC - MIT License.
function Get-DumpCode($path) {
    # kernel dump header (minidumps and live kernel reports): "PAGEDU64" -> bugcheck
    # code at 0x38, "PAGEDUMP" (32-bit) -> 0x20. Works without cdb.exe.
    try {
        $fs = [IO.File]::Open($path, "Open", "Read", "ReadWrite")
        try { $b = New-Object byte[] 64; [void]$fs.Read($b, 0, 64) } finally { $fs.Close() }
    } catch { return $null }
    $sig = [Text.Encoding]::ASCII.GetString($b, 0, 8)
    if ($sig -eq "PAGEDU64") { $code = [BitConverter]::ToUInt32($b, 0x38) }
    elseif ($sig -eq "PAGEDUMP") { $code = [BitConverter]::ToUInt32($b, 0x20) }
    else { return $null }
    if ($code -gt 0 -and $code -lt 0x100000) { return ("0x{0:x}" -f $code) }
    return $null
}

Write-Host "TheMVP bench collector - reading the last $Days days..."
Write-Host "Read-only: it changes nothing and does not open personal files. A plain-English summary opens at the end."
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host "WARNING: not running as administrator - boot timings, crash-dump analysis and the trace will be missing. Re-run from an Admin terminal." -ForegroundColor Yellow }

# --- machine -------------------------------------------------------------------
$cs   = Get-CimInstance Win32_ComputerSystem
$bb   = Get-CimInstance Win32_BaseBoard
$bios = Get-CimInstance Win32_BIOS
$os   = Get-CimInstance Win32_OperatingSystem
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1

$computer = [ordered]@{
    manufacturer = "$($cs.Manufacturer)".Trim()
    model        = "$($cs.Model)".Trim()
    board        = ("$($bb.Manufacturer) $($bb.Product)").Trim()
    bios_version = "$($bios.SMBIOSBIOSVersion)".Trim()
    bios_date    = $(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString("yyyy-MM-dd") } else { "" })
    os           = "$($os.Caption)".Trim()
    os_build     = "$($os.BuildNumber)"
    uptime_hours = $(if ($os.LastBootUpTime) { [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1) } else { $null })
}

$cpuInfo = [ordered]@{ cores = $cpu.NumberOfCores; threads = $cpu.NumberOfLogicalProcessors; max_mhz = $cpu.MaxClockSpeed }

# Win32_VideoController.AdapterRAM is 32-bit (tops out at 4 GB): the display driver's registry key has the real size
$vram = @{}
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*" -ErrorAction SilentlyContinue | ForEach-Object {
    $q = $_."HardwareInformation.qwMemorySize"
    if ($q -is [byte[]]) { $q = [BitConverter]::ToUInt64($q, 0) }
    if ($q) { $vram["$($_.DriverDesc)".Trim()] = $q }
}
$gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object {
    $name = "$($_.Name)".Trim()
    [ordered]@{
        name           = $name
        vram_gb        = Gb $(if ($vram[$name]) { $vram[$name] } else { $_.AdapterRAM })
        driver_version = "$($_.DriverVersion)"
        driver_date    = $(if ($_.DriverDate) { $_.DriverDate.ToString("yyyy-MM-dd") } else { "" })
    }
})

$mem = @(Get-CimInstance Win32_PhysicalMemory)
$ddr = $null
$memType = ($mem | Select-Object -First 1).SMBIOSMemoryType
if (26, 30 -contains $memType) { $ddr = 4 } elseif (34, 35 -contains $memType) { $ddr = 5 }   # (LP)DDR4 / (LP)DDR5
$ram = [ordered]@{
    total_gb = Gb (($mem | Measure-Object Capacity -Sum).Sum)
    ddr      = $ddr
    modules  = @($mem | ForEach-Object {
        [ordered]@{
            slot           = "$($_.DeviceLocator)"
            capacity_gb    = Gb $_.Capacity
            speed_mts      = $_.Speed
            configured_mts = $_.ConfiguredClockSpeed
            part           = "$($_.PartNumber)".Trim()
        }
    })
}

# --- drives ----------------------------------------------------------------------
$disks = @(Get-PhysicalDisk | ForEach-Object {
    [ordered]@{
        model   = "$($_.FriendlyName)".Trim()
        media   = "$($_.MediaType)"
        bus     = "$($_.BusType)"
        size_gb = Gb $_.Size
        health  = "$($_.HealthStatus)"
        smart   = $null
    }
})

# --- PC configuration, shown first: console now, top of the customer copy later ----------
$speeds = @($ram.modules | ForEach-Object { $_.configured_mts } | Where-Object { $_ })
$config = @(
    @("Computer",    "$($computer.manufacturer) $($computer.model)"),
    @("Motherboard", "$($computer.board) (BIOS $($computer.bios_version), $($computer.bios_date))"),
    @("Processor",   "$("$($cpu.Name)".Trim()) - $($cpuInfo.cores) cores / $($cpuInfo.threads) threads, $([math]::Round($cpuInfo.max_mhz / 1000, 1)) GHz base"),
    @("Memory",      ("{0} GB{1} - {2} stick(s): {3}{4}" -f $ram.total_gb, $(if ($ddr) { " DDR$ddr" } else { "" }), $ram.modules.Count,
                      (($ram.modules | ForEach-Object { "$($_.capacity_gb) GB" }) -join " + "),
                      $(if ($speeds) { ", running at $(($speeds | Measure-Object -Maximum).Maximum) MT/s" } else { "" })))
) + @($gpus | ForEach-Object { , @("Graphics", "$($_.name)$(if ($_.vram_gb) { " - $($_.vram_gb) GB" })") }) `
  + @($disks | ForEach-Object { , @("Storage", ("{0} - {1} GB {2} {3}" -f $_.model, $_.size_gb, $_.bus, $(if ($_.media -ne "Unspecified") { $_.media })).Trim()) }) `
  + @(, @("Windows", "$($computer.os) (build $($computer.os_build))"))
Write-Host "`nThis PC:"
$config | ForEach-Object { Write-Host ("  {0,-12} {1}" -f $_[0], $_[1]) }
Write-Host ""
$smartctl = Find-Tool "smartctl.exe"
if ($smartctl) {
    $scan = (& $smartctl --scan -j | Out-String | ConvertFrom-Json).devices
    foreach ($dev in $scan) {
        $r = & $smartctl -a -j $dev.name | Out-String | ConvertFrom-Json
        if (-not $r) { continue }
        $attr = @{}
        foreach ($a in $r.ata_smart_attributes.table) { $attr[[int]$a.id] = [int64]$a.raw.value }
        $nv = $r.nvme_smart_health_information_log
        $smart = [ordered]@{
            device       = "$($r.model_name)"
            passed       = $r.smart_status.passed
            reallocated  = $attr[5]
            pending      = $attr[197]
            media_errors = $(if ($nv) { $nv.media_errors } else { $null })
            percent_used = $(if ($nv) { $nv.percentage_used } else { $null })
            temp_c       = $r.temperature.current
        }
        # attach to the matching drive by model name, else list it on its own
        $match = $disks | Where-Object { $_.model -and $smart.device -and $_.model -like "*$($smart.device)*" } | Select-Object -First 1
        if ($match) { $match.smart = $smart } else { $disks += [ordered]@{ model = $smart.device; health = ""; smart = $smart } }
    }
}
$volumes = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    [ordered]@{ drive = $_.DeviceID; size_gb = Gb $_.Size; free_gb = Gb $_.FreeSpace }
})

# --- event log ---------------------------------------------------------------------
$kp41 = Get-SysEvents @{ ProviderName = "Microsoft-Windows-Kernel-Power"; Id = 41 }
$wer1001 = Get-SysEvents @{ ProviderName = "Microsoft-Windows-WER-SystemErrorReporting"; Id = 1001 }
$bugchecks = @()
foreach ($e in $kp41) {
    $code = [int64]$e.Properties[0].Value         # BugcheckCode; 0 = no blue screen
    if ($code -ne 0) { $bugchecks += ("0x{0:x}" -f $code) }
}
foreach ($e in $wer1001) {
    if ($e.Message -match "0x([0-9a-fA-F]{8})") { $bugchecks += ("0x{0:x}" -f [Convert]::ToInt64($Matches[1], 16)) }
}
$wheaEv = Get-SysEvents @{ ProviderName = "Microsoft-Windows-WHEA-Logger" }
$whea = [ordered]@{}
$wheaEv | Group-Object Id | ForEach-Object { $whea["$($_.Name)"] = $_.Count }
$ev6008 = Get-SysEvents @{ ProviderName = "EventLog"; Id = 6008 }
$diskEv = Get-SysEvents @{ ProviderName = "disk"; Id = 7, 51, 153 }
$ntfsEv = @(Get-SysEvents @{ Id = 55 } | Where-Object { $_.ProviderName -match "Ntfs" })
$tdrEv  = Get-SysEvents @{ ProviderName = "Display"; Id = 4101 }
$thr37  = Get-SysEvents @{ ProviderName = "Microsoft-Windows-Kernel-Processor-Power"; Id = 37 }

$events = [ordered]@{
    days             = $Days
    kp41             = $kp41.Count
    kp41_no_bugcheck = @($kp41 | Where-Object { [int64]$_.Properties[0].Value -eq 0 }).Count
    kp41_power_button = @($kp41 | Where-Object { (Get-EventData $_).LongPowerButtonPressDetected -eq "true" }).Count   # held power button = it froze, not a power loss
    unexpected_6008  = $ev6008.Count
    whea             = $whea
    disk             = $diskEv.Count
    ntfs             = $ntfsEv.Count
    display_tdr      = $tdrEv.Count
    cpu_throttle_37  = $thr37.Count
}

# --- boot performance: Windows times every boot and names what slowed it ------------------
$diagLog = "Microsoft-Windows-Diagnostics-Performance/Operational"
$bootTimes = @(Get-LogEvents $diagLog @{ Id = 100 } | Select-Object -First 10 |
    ForEach-Object { [int64](Get-EventData $_).BootTime })
$kinds = @{ 101 = "app"; 102 = "driver"; 103 = "service"; 109 = "device" }
$culprits = @(Get-LogEvents $diagLog @{ Id = 101, 102, 103, 109 } | ForEach-Object {
        $d = Get-EventData $_
        [pscustomobject]@{ type = $kinds[$_.Id]; name = $(if ($d.FriendlyName) { $d.FriendlyName } else { $d.Name }); ms = [int64]$d.DegradationTime }
    } | Where-Object { $_.name } | Group-Object type, name | ForEach-Object {
        [ordered]@{ type = $_.Group[0].type; name = $_.Group[0].name; times = $_.Count
                    degradation_ms = [int64](($_.Group | Measure-Object ms -Sum).Sum) }
    } | Sort-Object { $_.degradation_ms } -Descending | Select-Object -First 8)
$boot = [ordered]@{
    last_ms   = $(if ($bootTimes.Count) { $bootTimes[0] } else { $null })
    recent_ms = $bootTimes
    culprits  = $culprits
}

# --- settings that make a healthy PC feel slow ------------------------------------------
$settings = $null
if (-not $offline) {
    $scheme = (powercfg /getactivescheme) -join " "
    $sysDisk = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') | Get-Disk).Number
    $settings = [ordered]@{
        power_plan         = $(if ($scheme -match "\((.+)\)") { $Matches[1] } else { "" })
        power_plan_guid    = $(if ($scheme -match "([0-9a-f]{8}-[0-9a-f-]{27})") { $Matches[1] } else { "" })
        startup_apps       = @(Get-CimInstance Win32_StartupCommand).Count
        antivirus          = @(Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName AntiVirusProduct |
                               ForEach-Object { $_.displayName } | Select-Object -Unique)
        system_drive_media = "$((Get-PhysicalDisk | Where-Object { $_.DeviceId -eq "$sysDisk" }).MediaType)"
        reboot_pending     = (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") -or
                             (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")
    }
}

# --- crash dumps ---------------------------------------------------------------------
$cdb = Find-Tool "cdb.exe"
$dumps = @(Get-ChildItem (Join-Path $Windows "Minidump\*.dmp") | Sort-Object LastWriteTime -Descending |
    Select-Object -First 5 | ForEach-Object {
        $d = [ordered]@{ file = $_.Name; date = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm"); size_kb = [int]($_.Length / 1KB)
                         bugcheck = (Get-DumpCode $_.FullName) }
        if ($cdb) {
            # Offline is fine: without symbols !analyze still names the bugcheck and
            # usually the faulting driver module.
            $txt = & $cdb -z $_.FullName -c "!analyze -v; q" 2>$null | Out-String
            if ($txt -match "BUGCHECK_CODE:\s+([0-9a-fA-F]+)") { $d.bugcheck = "0x" + $Matches[1] }
            if ($txt -match "MODULE_NAME:\s+(\S+)") { $d.module = $Matches[1] }
            if ($txt -match "IMAGE_NAME:\s+(\S+)") { $d.image = $Matches[1] }
        }
        $d
    })

# Live kernel reports: Windows recovered without a blue screen (graphics driver hang = WATCHDOG,
# USB / network hangs) but saved a dump. Not crashes - kept apart from $dumps.
$liveDumps = @(Get-ChildItem (Join-Path $Windows "LiveKernelReports") -Recurse -Filter *.dmp |
    Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime -Descending | Select-Object -First 10 |
    ForEach-Object { [ordered]@{ folder = $_.Directory.Name; file = $_.Name; date = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                                 bugcheck = (Get-DumpCode $_.FullName) } })

# --- CPU microcode: 13th/14th-gen Intel instability fix ----------------------------------
$cpuReg = Get-ItemProperty "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0"
$ucode = $null
$u = $cpuReg.'Update Revision'
if ($u -is [byte[]] -and $u.Length -ge 4) {
    # 8-byte MSR image: Intel keeps the revision in the high dword, AMD in the low one
    $hi = $(if ($u.Length -ge 8) { [BitConverter]::ToUInt32($u, 4) } else { 0 })
    $ucode = $(if ($hi) { $hi } else { [BitConverter]::ToUInt32($u, 0) })
}
$fms = $(if ("$($cpuReg.Identifier)" -match "Family (\d+) Model (\d+) Stepping (\d+)") { "$($Matches[1])/$($Matches[2])/$($Matches[3])" } else { "" })
# Only Raptor Lake B0 silicon (CPUID 6/183/1: i5-13600K and up, i7, i9, HX) has the Vmin Shift
# bug; non-K 13th/14th-gen i5/i3 are Alder Lake dies and must not be compared to 0x12B.
$raptorB0 = ($cpuReg.VendorIdentifier -eq "GenuineIntel") -and ($fms -eq "6/183/1")
$cpuFirmware = [ordered]@{
    microcode = $(if ($ucode) { "0x{0:x}" -f $ucode } else { "" })
    cpuid     = $fms
    raptor_b0 = $raptorB0
    vmin_fix  = $(if ($raptorB0 -and $ucode) { $ucode -ge 0x12B } else { $null })
}

# --- Windows activation, TPM, Secure Boot (live Windows only) ------------------------------
$security = $null
if (-not $offline) {
    $tpm = Get-CimInstance -Namespace "root/cimv2/Security/MicrosoftTpm" -ClassName Win32_Tpm
    $sbState = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State").UEFISecureBootEnabled
    $lic = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
        ForEach-Object { [int]$_.LicenseStatus })
    $security = [ordered]@{
        # Win32_Tpm needs admin: without it the TPM state is unknown, not "missing"
        tpm_ready   = $(if ($tpm) { [bool]($tpm.IsEnabled_InitialValue -and $tpm.IsActivated_InitialValue) } elseif ($isAdmin) { $false } else { $null })
        tpm_version = $(if ($tpm.SpecVersion) { "$($tpm.SpecVersion)".Split(",")[0].Trim() } else { "" })
        secure_boot = $(if ($null -ne $sbState) { $sbState -eq 1 } else { $null })   # no value = legacy BIOS boot
        activated   = $(if ($lic.Count) { $lic -contains 1 } else { $null })           # LicenseStatus 1 = licensed
    }
}

# --- devices with errors ---------------------------------------------------------------
# Not faults: 22 disabled on purpose, 24 not present (ghost entry), 45 not connected (unplugged USB);
# utility drivers that sit "degraded" until their app opens them (LHM, Razer, ASUS/MSI tools).
$benignDev = "pawnio|winring0|openhardwaremonitor|ohmkernel|rzudd|iqvw64e|asusio|asmtxhci|msio|amdpsp"
$deviceErrors = @(Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.ConfigManagerErrorCode -notin 0, 22, 24, 45 -and "$($_.Name)" -notmatch $benignDev } |
    ForEach-Object { [ordered]@{ name = "$($_.Name)"; code = $_.ConfigManagerErrorCode } })

# --- temperatures (LibreHardwareMonitor running) -----------------------------------------
$temps = $null
$sensors = @(Get-CimInstance -Namespace "root/LibreHardwareMonitor" -ClassName Sensor |
    Where-Object { $_.SensorType -eq "Temperature" })
if ($sensors.Count) {
    $cpuT = $sensors | Where-Object { $_.Identifier -match "cpu" } | Measure-Object Max -Maximum
    $gpuT = $sensors | Where-Object { $_.Identifier -match "gpu" } | Measure-Object Max -Maximum
    $temps = [ordered]@{ cpu_max_c = $cpuT.Maximum; gpu_max_c = $gpuT.Maximum }
}

# --- live performance sample (+ optional WPR trace) --------------------------------------
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$stamp = "{0}-{1}" -f $env:COMPUTERNAME, (Get-Date -Format "yyyyMMdd-HHmm")
$traceFile = $null
if ($Trace -gt 0 -and -not $isAdmin) { Write-Host "Skipping -Trace: Windows Performance Recorder needs an Admin terminal." -ForegroundColor Yellow }
elseif ($Trace -gt 0 -and -not $offline) {
    $traceFile = Join-Path $Out "trace-$stamp.etl"
    wpr -cancel 2>$null | Out-Null                                  # clear any stale session
    wpr -start GeneralProfile -start CPU -start DiskIO -filemode | Out-Null
    Write-Host "Recording a $Trace s performance trace - reproduce the slowness NOW..."
}
$perf = $null
if ($PerfSeconds -gt 0 -and -not $offline) {
    if (-not $traceFile) { Write-Host "Sampling performance for $PerfSeconds s - leave the PC idle..." }
    $counters = "\Processor(_Total)\% Processor Time", "\Processor(_Total)\% DPC Time",
                "\Processor(_Total)\% Interrupt Time", "\PhysicalDisk(_Total)\% Idle Time",
                "\PhysicalDisk(_Total)\Avg. Disk sec/Read", "\PhysicalDisk(_Total)\Avg. Disk sec/Write",
                "\Memory\Available MBytes", "\Process(*)\% Processor Time"
    $samples = @((Get-Counter -Counter $counters -SampleInterval 1 -MaxSamples $PerfSeconds).CounterSamples)
    if ($samples.Count) {
        function Avg($pattern) { ($samples | Where-Object { $_.Path -like $pattern } | Measure-Object CookedValue -Average).Average }
        $cores = [Environment]::ProcessorCount
        $perf = [ordered]@{
            seconds       = $PerfSeconds
            traced        = [bool]$traceFile
            cpu_pct       = [math]::Round((Avg "*\processor(_total)\% processor time"), 1)
            dpc_pct       = [math]::Round((Avg "*\% dpc time"), 2)
            interrupt_pct = [math]::Round((Avg "*\% interrupt time"), 2)
            disk_busy_pct = [math]::Round(100 - (Avg "*\% idle time"), 1)
            disk_read_ms  = [math]::Round((Avg "*\avg. disk sec/read") * 1000, 1)
            disk_write_ms = [math]::Round((Avg "*\avg. disk sec/write") * 1000, 1)
            avail_mem_mb  = [int](Avg "*\available mbytes")
            top_cpu       = @($samples | Where-Object { $_.Path -like "*\process(*" -and $_.InstanceName -notin "_total", "idle" } |
                Group-Object InstanceName | ForEach-Object {
                    # all processes sharing a name (27x brave) summed per second, as % of the whole CPU
                    [ordered]@{ name = $_.Name; pct = [math]::Round((($_.Group | Measure-Object CookedValue -Sum).Sum) / $PerfSeconds / $cores, 1) }
                } | Sort-Object { $_.pct } -Descending | Select-Object -First 5)
            top_mem       = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
                ForEach-Object { [ordered]@{ name = $_.ProcessName; mb = [int]($_.WorkingSet64 / 1MB) } })
        }
    }
}
if ($traceFile) {
    $left = $Trace - [math]::Max(0, $PerfSeconds)
    if ($left -gt 0) { Start-Sleep -Seconds $left }
    wpr -stop $traceFile | Out-Null
    if (Test-Path $traceFile) { Write-Host "Trace saved: $traceFile (open it in Windows Performance Analyzer)" }
    else { Write-Host "Trace failed - wpr could not record (another trace running?)." -ForegroundColor Yellow; $traceFile = $null }
}

# --- plain-English summary: the customer's copy (HTML below) and the service report ------
$summary = New-Object System.Collections.ArrayList
function Add-Check($area, $ok, $good, $bad) {
    [void]$summary.Add([ordered]@{ area = $area; status = $(if ($ok) { "ok" } else { "attention" }); text = $(if ($ok) { $good } else { $bad }) })
}
$codes = @(@($bugchecks) + @($dumps | ForEach-Object { $_.bugcheck }) | Where-Object { $_ } | Select-Object -Unique)   # event log + dump files
Add-Check "Blue-screen crashes" (-not $codes.Count) "No blue-screen crashes recorded in the last $Days days." `
    ("Windows crashed with a blue screen (error code: {0}). The saved crash files help us find the cause." -f ($codes -join ", "))
$lost = [math]::Max(0, $events.kp41_no_bugcheck - $events.kp41_power_button)
Add-Check "Sudden power loss" (-not $lost) "No sudden power cuts recorded." `
    "The PC switched off suddenly $lost time(s) without shutting down - usually the power supply, a power cable or the wall socket."
Add-Check "Freezes" (-not $events.kp41_power_button) "No forced shutdowns recorded." `
    "The PC had to be forced off with the power button $($events.kp41_power_button) time(s) because it froze."
$wheaN = [int](($whea.Values | Measure-Object -Sum).Sum)
$fatal = [int]$whea["18"]
# a few corrected errors (17/19/47) are normal; fatal 18s or a steady stream are not
Add-Check "Hardware error reports" (-not $fatal -and $wheaN -lt 10) `
    $(if ($wheaN) { "$wheaN minor hardware warning(s), all corrected automatically by the hardware." } else { "The processor, memory and expansion slots reported no errors." }) `
    $(if ($fatal) { "The processor, memory or an expansion card reported $fatal serious hardware error(s)." } else { "$wheaN hardware warnings - corrected, but this many points to a part starting to fail." })
foreach ($d in $disks) {
    $s = $d.smart
    $badSectors = $(if ($s) { [int64]$s.reallocated + [int64]$s.pending + [int64]$s.media_errors } else { 0 })
    $ok = ($d.health -in "", "Healthy") -and -not ($s -and ($s.passed -eq $false -or $badSectors))
    $wear = $(if ($s -and $s.percent_used -ne $null) { " ($($s.percent_used)% of its rated life used)" } else { "" })
    Add-Check "Drive: $($d.model)" $ok "Healthy$wear." "Showing errors or wear ($badSectors bad sectors / errors). Your data may be at risk - back it up."
}
if ($events.disk + $events.ntfs) {
    Add-Check "Drive errors in the log" $false "" "Windows logged $($events.disk + $events.ntfs) error(s) while reading or writing the drive."
}
foreach ($v in $volumes) {
    if ($v.size_gb) {
        Add-Check "Free space on $($v.drive)" ($v.free_gb / $v.size_gb -ge 0.1) "$($v.free_gb) GB free of $($v.size_gb) GB." `
            "Only $($v.free_gb) GB free of $($v.size_gb) GB - Windows slows down and updates fail when the drive is this full."
    }
}
# a driver reset usually logs event 4101 AND saves a WATCHDOG live dump: count the larger, not both
$gpuHangs = [math]::Max([int]$events.display_tdr, @($liveDumps | Where-Object { $_.folder -eq "WATCHDOG" }).Count)
Add-Check "Graphics driver" (-not $gpuHangs) "The graphics driver ran without resets." `
    "The graphics driver stopped responding and had to restart $gpuHangs time(s)."
if ($temps) {
    Add-Check "Temperatures" (-not ($temps.cpu_max_c -gt 90 -or $temps.gpu_max_c -gt 85)) `
        "Processor $($temps.cpu_max_c) C, graphics $($temps.gpu_max_c) C - normal." `
        "Running hot: processor $($temps.cpu_max_c) C, graphics $($temps.gpu_max_c) C. Cooling needs attention."
}
if ($null -ne $cpuFirmware.vmin_fix) {
    Add-Check "Processor firmware" $cpuFirmware.vmin_fix `
        "Has Intel's fix for the known 13th/14th-gen processor instability (microcode $($cpuFirmware.microcode))." `
        "Missing Intel's fix for the known 13th/14th-gen processor instability (microcode $($cpuFirmware.microcode), fix is 0x12B or later). A BIOS update is needed to protect the processor."
}
if ($security -and $null -ne $security.activated) {
    Add-Check "Windows activation" $security.activated "Windows is activated." "Windows is not activated."
}
if ($security -and ($null -ne $security.tpm_ready -or $null -ne $security.secure_boot)) {
    # $null = not readable (TPM without admin): left out of both lists
    $on  = @(@($(if ($security.tpm_ready -eq $true) { "The TPM security chip" }), $(if ($security.secure_boot -eq $true) { "Secure Boot" })) | Where-Object { $_ })
    $off = @(@($(if ($security.tpm_ready -eq $false) { "The TPM security chip" }), $(if ($security.secure_boot -eq $false) { "Secure Boot" })) | Where-Object { $_ })
    Add-Check "Security features" (-not $off.Count) ("{0} {1} on." -f ($on -join " and "), $(if ($on.Count -gt 1) { "are" } else { "is" })) `
        ("{0} {1} off. Windows 11 and some games' anti-cheat (e.g. Valorant) need {2}." -f ($off -join " and "), $(if ($off.Count -gt 1) { "are" } else { "is" }), $(if ($off.Count -gt 1) { "them" } else { "it" }))
}
Add-Check "Devices" (-not $deviceErrors.Count) "All devices are working." `
    ("{0} device(s) not working properly: {1}." -f $deviceErrors.Count, (($deviceErrors | ForEach-Object { $_.name }) -join ", "))
if ($boot.last_ms) {
    Add-Check "Start-up time" ($boot.last_ms -le 60000) ("Windows started in {0:N0} seconds." -f ($boot.last_ms / 1000)) `
        ("Windows took {0:N0} seconds to start. Slowed by: {1}." -f ($boot.last_ms / 1000), (($culprits | Select-Object -First 3 | ForEach-Object { $_.name }) -join ", "))
}
if ($perf) {
    Add-Check "Background load" ($perf.cpu_pct -le 15) "The processor was quiet while idle ($($perf.cpu_pct)% busy)." `
        ("The processor was {0}% busy with nothing open. Busiest: {1}." -f $perf.cpu_pct, (($perf.top_cpu | Select-Object -First 3 | ForEach-Object { $_.name }) -join ", "))
}

$report = [ordered]@{
    collector     = "themvp-bench/1"
    collector_version = $CollectorVersion
    ticket        = $Ticket
    host          = $env:COMPUTERNAME
    collected_at  = (Get-Date).ToString("s")
    offline       = $offline
    admin         = $isAdmin
    tools         = [ordered]@{ smartctl = [bool]$smartctl; cdb = [bool]$cdb; temps = [bool]$temps }
    computer      = $computer
    config        = @($config | ForEach-Object { [ordered]@{ item = $_[0]; value = $_[1] } })
    cpu           = "$($cpu.Name)".Trim()
    cpu_info      = $cpuInfo
    gpus          = $gpus
    ram           = $ram
    disks         = $disks
    volumes       = $volumes
    events        = $events
    bugchecks     = @($bugchecks | Select-Object -Unique)
    dumps         = $dumps
    live_dumps    = $liveDumps
    cpu_firmware  = $cpuFirmware
    security      = $security
    device_errors = $deviceErrors
    temps         = $temps
    boot          = $boot
    settings      = $settings
    perf          = $perf
    trace         = $(if ($traceFile) { Split-Path $traceFile -Leaf } else { $null })
    summary       = @($summary)
}

$file = Join-Path $Out "bench-$stamp.json"
$json = $report | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($file, $json, (New-Object Text.UTF8Encoding $false))
Write-Host "Saved $file"

# Customer copy: what this tool did (and did not do) + the results in plain words.
function Enc($s) { [Net.WebUtility]::HtmlEncode("$s") }   # not "H": that is the Get-History alias
$rows = ($summary | ForEach-Object {
    $mark = $(if ($_.status -eq "ok") { '<td class="ok">&#10003; OK</td>' } else { '<td class="bad">! Needs attention</td>' })
    "<tr>$mark<td><b>$(Enc $_.area)</b><br>$(Enc $_.text)</td></tr>"
}) -join "`n"
$specs = ($config | ForEach-Object { "<tr><td><b>$(Enc $_[0])</b></td><td>$(Enc $_[1])</td></tr>" }) -join "`n"
$htmlFile = Join-Path $Out "bench-$stamp.html"
$page = @"
<!doctype html><html><head><meta charset="utf-8"><title>PC health check - TheMVP</title>
<style>body{font:15px/1.5 Segoe UI,Arial,sans-serif;max-width:820px;margin:24px auto;padding:0 16px;color:#231f20}
h1{border-bottom:4px solid #fecf0a;padding-bottom:6px}table{border-collapse:collapse;width:100%}
td{border-top:1px solid #ddd;padding:8px;vertical-align:top}.ok{color:#11722e;white-space:nowrap}.bad{color:#b3261e;font-weight:bold;white-space:nowrap}
.box{background:#f6f6f6;border-radius:8px;padding:10px 16px}.muted{color:#666;font-size:13px}</style></head><body>
<h1>PC health check</h1>
<p>$(Enc $computer.manufacturer) $(Enc $computer.model) &middot; $(Get-Date -Format "dd MMM yyyy, HH:mm") &middot; covers the last $Days days</p>
<h2>Your PC</h2><table>$specs</table>
<div class="box" style="margin-top:16px"><b>What this check did</b> - it only <b>read</b> information Windows already keeps about itself:
<ul><li>Windows' own logs of crashes, power cuts, freezes and hardware errors</li>
<li>Drive health reports and free space</li><li>The parts list, driver and processor firmware versions, and devices with errors</li>
<li>Whether Windows is activated and the TPM security chip and Secure Boot are on</li>
<li>Start-up time and, for $PerfSeconds seconds, how busy the PC was (program names only)</li></ul>
<b>What it did NOT do</b>: it did not open your documents, photos, e-mails or browser history, did not read
passwords, and did not install, change or delete anything. $(if ($Server) { "The results went only to TheMVP's service desk." } else { "Nothing was sent anywhere." })</div>
<h2>Results</h2><table>$rows</table>
<div class="box" style="margin-top:16px"><b>Need help with what this found?</b> Email <a href="mailto:support@themvp.in">support@themvp.in</a> or visit <a href="https://themvp.in">themvp.in</a>.</div>
<p class="muted">TheMVP service centre. Full technical data for our technicians: $(Enc (Split-Path $file -Leaf))</p>
</body></html>
"@
[IO.File]::WriteAllText($htmlFile, $page, (New-Object Text.UTF8Encoding $false))
Write-Host "Customer summary: $htmlFile"
if (-not $offline) { Start-Process $htmlFile }   # show the customer right away (WinPE has no browser)
Write-Host ("Kernel-Power 41: {0} (no bugcheck: {1}) | WHEA: {2} | disk errors: {3} | bugchecks: {4} | device errors: {5}" -f `
    $events.kp41, $events.kp41_no_bugcheck, (($whea.Values | Measure-Object -Sum).Sum), $events.disk, `
    ($report.bugchecks -join ","), $deviceErrors.Count)
if ($boot.last_ms) { Write-Host ("Last boot: {0:N1} s | slowed by: {1}" -f ($boot.last_ms / 1000), (($culprits | ForEach-Object { $_.name }) -join ", ")) }
if ($perf) { Write-Host ("Idle CPU {0}% | DPC {1}% | interrupts {2}% | disk busy {3}% | free RAM {4} MB" -f `
    $perf.cpu_pct, $perf.dpc_pct, $perf.interrupt_pct, $perf.disk_busy_pct, $perf.avail_mem_mb) }

# --- raw evidence + one zip to send ------------------------------------------------------
# The service desk recounts every figure above from these raw event lines instead of
# trusting the JSON totals, so each count can be traced to the Windows record behind it.
function Format-Event($e) {
    $msg = "$($e.Message)" -replace "\s+", " "
    if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) + "..." }
    $extra = ""
    if ($e.ProviderName -eq "Microsoft-Windows-Kernel-Power" -and $e.Id -eq 41) {
        $d = Get-EventData $e
        $extra = " [BugcheckCode=$($d.BugcheckCode) PowerButton=$($d.LongPowerButtonPressDetected)]"
    }
    "{0} | {1} | {2} | {3} | {4}{5}" -f $e.TimeCreated.ToString("yyyy-MM-ddTHH:mm:ss"), $e.LevelDisplayName, $e.ProviderName, $e.Id, $msg, $extra
}
$raw = Join-Path $Out "raw"
New-Item -ItemType Directory -Force -Path $raw | Out-Null
$utf8 = New-Object Text.UTF8Encoding $false
$counted = @(@($kp41) + @($wer1001) + @($wheaEv) + @($ev6008) + @($diskEv) + @($ntfsEv) + @($tdrEv) + @($thr37)) |
    Where-Object { $_ } | Sort-Object TimeCreated
$sysLines = @("# System events counted in the report, last $Days days (time | level | source | event id | message)") +
    @($counted | ForEach-Object { Format-Event $_ })
[IO.File]::WriteAllLines((Join-Path $raw "system-events.txt"), [string[]]$sysLines, $utf8)
$appEv = @(Get-LogEvents "Application" @{ Level = 1, 2 } | Select-Object -First 2000)
$appLines = @("# Application errors, last $Days days, newest first (max 2000)") + @($appEv | ForEach-Object { Format-Event $_ })
[IO.File]::WriteAllLines((Join-Path $raw "application-events.txt"), [string[]]$appLines, $utf8)
$bcLines = @("# Blue-screen codes: Kernel-Power 41 / WER 1001 events, then crash dump files") +
    @(@($kp41 | Where-Object { [int64]$_.Properties[0].Value -ne 0 }) + @($wer1001) | Where-Object { $_ } | ForEach-Object { Format-Event $_ }) +
    @(@($dumps) + @($liveDumps) | Where-Object { $_ } | ForEach-Object { ($_ | ConvertTo-Json -Compress -Depth 3) })
[IO.File]::WriteAllLines((Join-Path $raw "bugchecks.txt"), [string[]]$bcLines, $utf8)
$drvLines = @("# Drivers: device | version | date | provider")
if (-not $offline) {
    $drvLines += @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName } | Sort-Object DeviceName | ForEach-Object {
        "{0} | {1} | {2} | {3}" -f $_.DeviceName, $_.DriverVersion, $(if ($_.DriverDate) { $_.DriverDate.ToString("yyyy-MM-dd") }), $_.DriverProviderName })
} else { $drvLines += "(not available when run from WinPE)" }
[IO.File]::WriteAllLines((Join-Path $raw "drivers.txt"), [string[]]$drvLines, $utf8)
[IO.File]::WriteAllText((Join-Path $raw "disks.txt"), (@{ disks = $disks; volumes = $volumes } | ConvertTo-Json -Depth 6), $utf8)

$zip = $null
if ($Ticket) {
    $pc = $env:COMPUTERNAME -replace '[^A-Za-z0-9._-]', ''
    $zip = Join-Path (Split-Path $Out -Parent) ("themvp-diag-{0}-{1}-{2}.zip" -f $Ticket, $pc, (Get-Date -Format "yyyyMMdd-HHmmss"))
    Compress-Archive -Path (Join-Path $Out "*") -DestinationPath $zip -Force
    if (Test-Path $zip) { Write-Host "Report to send: $zip" } else { $zip = $null; Write-Host "Could not create the zip - please send the files in $Out" }
}

if ($Server -and $JobId) {
    $body = @{ token = $Token; job_id = $JobId; evidence = $report } | ConvertTo-Json -Depth 8
    $res = Invoke-RestMethod -Method Post -Uri ($Server.TrimEnd('/') + "/api/bench/evidence") `
        -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body))
    if ($res.ok) { Write-Host "Attached to bench job #$JobId" } else { Write-Host "Upload failed: $($res.error)" }
}
