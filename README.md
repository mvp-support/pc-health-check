# TheMVP PC Health Check

A free, read-only check for any Windows or Linux PC. It first lists your PC's parts
(processor, graphics card, memory, drives, motherboard), then reads what your PC has
already recorded (crashes, sudden shutdowns, hardware errors, drive health, temperatures,
drivers) and shows you a plain-English summary.

**Easiest:** open **https://mvp-support.github.io/pc-health-check/**. It recognises your
system and shows the right command with a Copy button.

## Check your own PC (no ticket needed)

Nothing is sent anywhere; the results are shown on your screen.

**Windows 10 / 11:** press the Windows key, type `cmd`, press Enter, then paste:

```
powershell -NoProfile -ExecutionPolicy Bypass -c "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/mvp-support/pc-health-check/main/windows/run.ps1))) -NoTicket"
```

Click **Yes** when Windows asks for permission. After about a minute your results open in
your web browser, and a copy is kept in a `TheMVP-diag-…` folder on your Desktop.

**Linux (Ubuntu, Debian, Fedora):** open a Terminal and paste:

```
u=https://raw.githubusercontent.com/mvp-support/pc-health-check/main/linux/themvp-diag.sh; f=$(mktemp); (curl -fsSL $u || wget -qO- $u) > $f && sudo bash $f; rm -f $f
```

After about 4 minutes the results are shown in the Terminal, and a copy is saved as
`~/themvp-diag-NOTICKET-<host>-<time>.tar.gz`.

Need help with what it found? Email support@themvp.in or visit https://themvp.in. We will
give you a ticket number to run the check with (below), so our technicians can read the full report.

## TheMVP customers with a ticket number

Use these when TheMVP Support asks you to. Replace `SID000616` with your ticket number.

### Windows 10 / 11

Press the Windows key, type `cmd`, press Enter, then paste:

```
powershell -NoProfile -ExecutionPolicy Bypass -c "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/mvp-support/pc-health-check/main/windows/run.ps1))) -Ticket SID000616"
```

The same command also works in PowerShell and Windows Terminal. Click **Yes** when
Windows asks for permission. After about a minute, a plain-English summary opens and a
`themvp-diag-<ticket>-<PC>-<date>-<time>.zip` file appears on your Desktop. Send us that
one file by replying to your ticket email. (The `TheMVP-diag-…` folder next to it holds the
same files unzipped.)

### Linux (Ubuntu, Debian, Fedora)

Open a Terminal and paste:

```
u=https://raw.githubusercontent.com/mvp-support/pc-health-check/main/linux/themvp-diag.sh; f=$(mktemp); (curl -fsSL $u || wget -qO- $u) > $f && sudo bash $f SID000616; rm -f $f
```

After about 4 minutes it writes `~/themvp-diag-<ticket>-<host>-<time>.tar.gz`. Send us that file
by replying to your ticket email.
Optional load test: add `--stress 15 --gpu-stress 15` at the end (works with or without a ticket number).

To check the script before running it, compare its SHA256 with `linux/themvp-diag.sh.sha256`:

```
curl -fsSL https://raw.githubusercontent.com/mvp-support/pc-health-check/main/linux/themvp-diag.sh | sha256sum
```

After any change to the script, update the checksum: `cd linux && sha256sum themvp-diag.sh > themvp-diag.sh.sha256`.

## Temperatures

- **Drives and graphics cards on Windows (NVIDIA, AMD, Intel):** read from Windows itself,
  nothing to install. Recommended: SSD and NVMe drives below 70 °C, hard disks below 55 °C, NVIDIA graphics
  below 85 °C, AMD and Intel graphics below 90 °C.
- **Processor on Windows:** Windows cannot read it by itself. Install
  [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) (free),
  leave it open and run the check again: the processor temperature is then included
  (recommended below 90 °C). [HWiNFO](https://www.hwinfo.com) also shows every temperature
  on screen, but the check cannot read its values.
- **Linux:** processor and NVIDIA graphics temperatures are logged every 5 seconds.
- **Virtual machines:** temperatures cannot be read, so the check leaves them out without a warning.

## Blue screens: which driver caused it

The check reads the blue-screen error code from Windows' crash files, but cannot name the
driver behind it without extra tools. To see the driver yourself, open the crash files
(`C:\Windows\Minidump`, and copies in the report's `raw\dumps` folder) in
[BlueScreenView](https://www.nirsoft.net/utils/blue_screen_view.html) (free, no install) or
[WinDbg](https://aka.ms/windbg/download) (free, from Microsoft). The results page shows this tip
whenever crash files are found.

## Ask an AI assistant

You can give the report to an AI assistant that can read files (for example ChatGPT, Claude or
Gemini) and ask it what is wrong with your PC. Start with the one file that holds every result:
`bench-….json` on Windows, `summary.json` on Linux. The `raw` folder has the full logs if the
assistant asks for more. Before you upload it, remember the AI company receives everything in
it, including the details listed under "What the report contains" below.

## Laptops

On a laptop the check also shows how much charge the battery still holds compared with when
it was new (a battery below 70% is worth replacing). TheMVP Support looks after desktop PCs,
not laptops: for help with a laptop, contact its manufacturer.

## What the report contains

Everything stays on your PC unless you send it. Besides the summary, the report folder
holds the details our technicians need, and some of them identify you or your PC:

**Windows**
- The PC's name, its parts list and driver versions.
- Every critical, error and warning event from the System and Application logs for the
  last 30 days, as text and as `.evtx` files. These can name programs and file locations,
  including your Windows user name (for example `C:\Users\your-name\...`).
- The crash files Windows saved after a blue screen: up to 10 minidumps and 3 small live
  kernel reports. Each holds a small snapshot of system memory from the moment of the crash.
- `run.log`: what the check printed while it ran, including your Windows user name.

**Linux**
- The PC's name, its parts list, and the serial numbers of the PC, its memory modules,
  drives and NVIDIA graphics card.
- The kernel log of the last 30 days and the complete system log (journal) of the previous
  start-up, up to 20,000 lines. A system log can include user names, Wi-Fi network names,
  IP addresses and commands that were run with `sudo`.
- Any crash records the kernel saved from an earlier start-up (pstore) in the last 30 days.

## What it does not do

- It does not open personal files, photos, browser history or passwords.
- It does not upload anything. You decide whether to send the report.
- Windows: it installs, changes and deletes nothing. The script it downloads is removed again at the end.
- Linux: it **does install software** if it is missing, from your distribution's own
  repository: smartmontools, rasdaemon, lm-sensors, pciutils and dmidecode (on Fedora also
  stress-ng). These stay installed afterwards, and rasdaemon keeps running as a small
  background service that records hardware errors. With `--stress` it also installs
  stress-ng; with `--gpu-stress` it downloads gpu-burn from GitHub and builds it in
  `~/gpu-burn`. Add `--no-install` to skip all of this.

## Files

| File | What it is |
|---|---|
| `index.html` | The page that picks the right command for the visitor's system |
| `windows/run.ps1` | Starter: downloads `bench_collect.ps1`, asks for admin rights, saves the report to the Desktop |
| `windows/bench_collect.ps1` | The Windows check |
| `linux/themvp-diag.sh` | The Linux check |

## Licence

MIT, see [LICENSE](LICENSE): anyone may use, change and share this tool. Some Windows checks
are adapted from StressLab by Cincy Power Computers, LLC (MIT License, notice included in LICENSE).
