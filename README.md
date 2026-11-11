# TheMVP PC Health Check

A read-only check that first lists your PC's parts (processor, graphics card, memory,
drives, motherboard), then collects what your PC has already recorded (crashes, sudden
shutdowns, hardware errors, drive health, temperatures, drivers) into a report you
send to TheMVP support.

**Easiest:** open **https://mvp-support.github.io/pc-health-check/**. It recognises your
system and shows the right command with a Copy button.

## Windows 10 / 11

Press the Windows key, type `cmd`, press Enter, then paste:

```
powershell -NoProfile -ExecutionPolicy Bypass -c "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/mvp-support/pc-health-check/main/windows/run.ps1))) -Ticket SID000616"
```

The same command also works in PowerShell and Windows Terminal. Click **Yes** when
Windows asks for permission. After about a minute, a plain-English summary opens and a
`themvp-diag-<ticket>-<PC>-<date>-<time>.zip` file appears on your Desktop. Send us that
one file by replying to your ticket email. (The `TheMVP-diag-…` folder next to it holds the
same files unzipped.)

## Linux (Ubuntu, Debian, Fedora)

Open a Terminal and paste:

```
u=https://raw.githubusercontent.com/mvp-support/pc-health-check/main/linux/themvp-diag.sh; f=$(mktemp); (curl -fsSL $u || wget -qO- $u) > $f && sudo bash $f SID000616; rm -f $f
```

After about 4 minutes it writes `~/themvp-diag-<ticket>-<host>-<time>.tar.gz`. Send us that file
by replying to your ticket email.
Optional load test: add `--stress 15 --gpu-stress 15` after the ticket number.

To check the script before running it, compare its SHA256 with `linux/themvp-diag.sh.sha256`:

```
curl -fsSL https://raw.githubusercontent.com/mvp-support/pc-health-check/main/linux/themvp-diag.sh | sha256sum
```

After any change to the script, update the checksum: `cd linux && sha256sum themvp-diag.sh > themvp-diag.sh.sha256`.

## What it does not do

- It does not open personal files, photos, browser history or passwords.
- It does not upload anything. You decide whether to send the report.
- Windows: it installs, changes and deletes nothing. The script it downloads is removed again at the end.
- Linux: if missing, it installs standard diagnostic tools (smartmontools, rasdaemon,
  lm-sensors, pciutils, dmidecode, stress-ng) from your distribution's own repository.
  Add `--no-install` to skip that.

## Files

| File | What it is |
|---|---|
| `index.html` | The page that picks the right command for the visitor's system |
| `windows/run.ps1` | Starter: downloads `bench_collect.ps1`, asks for admin rights, saves the report to the Desktop |
| `windows/bench_collect.ps1` | The Windows check |
| `linux/themvp-diag.sh` | The Linux check |

Some Windows checks are adapted from StressLab by Cincy Power Computers, LLC (MIT License).
