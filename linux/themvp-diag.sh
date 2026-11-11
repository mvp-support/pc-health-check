#!/usr/bin/env bash
# =============================================================================
#  TheMVP.in - Workstation Hang / Crash Diagnostic Collector  (Linux)
#  Version: 1.2  (2026-11-06)  - ticket ID required in the file name, full previous-boot log
#           1.1  (2026-10-31)  - adds idle / load / cooldown temperature logging
#
#  Usage:   sudo bash themvp-diag.sh <TICKET_ID> [--stress MIN] [--gpu-stress MIN] [--days N] [--no-install]
#  Example: sudo bash themvp-diag.sh SID000616                         (logs + idle temps, ~4 min)
#           sudo bash themvp-diag.sh SID000616 --stress 15 --gpu-stress 15   (+ CPU/RAM and GPU load, temps every 5 s)
#  Install as a command (once):  sudo install -m 755 themvp-diag.sh /usr/local/bin/themvp-diag
#                         then:  sudo themvp-diag SID000616
#
#  Output:  ~/themvp-diag-<TICKET>-<host>-<timestamp>.tar.gz
#           (summary.txt with RED/AMBER/GREEN flags, summary.json, temps.csv, raw logs)
#  Read-only: changes nothing on the system except optionally installing
#  smartmontools / rasdaemon / lm-sensors / stress-ng / gpu-burn (skip with --no-install).
# =============================================================================

VERSION="1.2"
TICKET="${1:-NOTICKET}"; shift || true
TICKET="$(printf '%s' "$TICKET" | tr -cd 'A-Za-z0-9')"; [ -n "$TICKET" ] || TICKET=NOTICKET   # it becomes part of the file name
STRESS_MIN=0; GPU_STRESS_MIN=0; DAYS=30; INSTALL=1
while [ $# -gt 0 ]; do
  case "$1" in
    --stress) STRESS_MIN="${2:-10}"; shift 2 ;;
    --gpu-stress) GPU_STRESS_MIN="${2:-10}"; shift 2 ;;
    --days) DAYS="${2:-30}"; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    *) shift ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo:  sudo bash $0 $TICKET"; exit 1
fi

HOST="$(hostname -s 2>/dev/null || echo host)"
TS="$(date +%Y%m%d-%H%M%S)"
REAL_HOME="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"; [ -d "$REAL_HOME" ] || REAL_HOME=/root
OUT="$REAL_HOME/themvp-diag-${TICKET}-${HOST}-${TS}"
RAW="$OUT/raw"; mkdir -p "$RAW"
SUM="$OUT/summary.txt"
FLAGS="$OUT/.flags"; : > "$FLAGS"

have() { command -v "$1" >/dev/null 2>&1; }
run()  { # run <file> <cmd...>   capture output, never fail
  local f="$RAW/$1"; shift
  { echo "### $*"; timeout 120 "$@" 2>&1; } >> "$f" 2>&1 || true
}
flag() { # flag RED|AMBER|GREEN <code> <message>
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FLAGS"
}
step() { printf '  [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
# Real machine-check lines only: AMD prints "MCE: In-kernel MCE decoding enabled." every boot,
# and CPU thermal-throttle notices can carry the "mce:" prefix.
mce_lines() { grep -iE 'mce:|machine check|hardware error' "$@" | grep -viE 'decoding enabled|temperature|throttl|MCE banks'; }

echo "TheMVP diagnostic collector v$VERSION  -  ticket $TICKET"
echo "Output: $OUT"

# ---------------------------------------------------------------- 0. tools
if [ "$INSTALL" -eq 1 ] && have apt-get; then
  step "Installing helper tools (smartmontools, rasdaemon, lm-sensors, pciutils, dmidecode)"
  NEED=""
  have smartctl  || NEED="$NEED smartmontools"
  have ras-mc-ctl|| NEED="$NEED rasdaemon"
  have sensors   || NEED="$NEED lm-sensors"
  have lspci     || NEED="$NEED pciutils"
  have dmidecode || NEED="$NEED dmidecode"
  [ "$STRESS_MIN" -gt 0 ] && ! have stress-ng && NEED="$NEED stress-ng"
  if [ -n "$NEED" ]; then
    DEBIAN_FRONTEND=noninteractive timeout 300 apt-get install -y -qq $NEED >"$RAW/install.log" 2>&1 \
      || echo "    (install failed / offline - continuing with what is available)"
  fi
elif [ "$INSTALL" -eq 1 ] && have dnf; then
  timeout 300 dnf install -y -q smartmontools rasdaemon lm_sensors pciutils dmidecode stress-ng >"$RAW/install.log" 2>&1 || true
fi

# ---------------------------------------------------------------- 0b. PC configuration (shown first)
step "Reading this PC's configuration"
SYS_MODEL="$(dmidecode -s system-manufacturer 2>/dev/null | head -1) $(dmidecode -s system-product-name 2>/dev/null | head -1)"
BIOS_VER="$(dmidecode -s bios-version 2>/dev/null | head -1)"
BIOS_DATE="$(dmidecode -s bios-release-date 2>/dev/null | head -1)"
BOARD="$(dmidecode -s baseboard-manufacturer 2>/dev/null | head -1) $(dmidecode -s baseboard-product-name 2>/dev/null | head -1)"
KERNEL="$(uname -r)"
OS="$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")"
CPU_NAME="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//; s/ *$//')"
CPU_THREADS=$(nproc --all)
CPU_CORES=$(lscpu -p=core,socket 2>/dev/null | grep -v '^#' | sort -u | wc -l)
CPU_MAX_GHZ=$(lscpu 2>/dev/null | awk -F: '/^CPU max MHz/{printf "%.1f", $2/1000}')

DIMM_TABLE="$OUT/.dimms"; : > "$DIMM_TABLE"
if have dmidecode; then
  dmidecode -t 17 2>/dev/null | awk -F': ' '
    /^Memory Device/ {if (loc!="") print loc"|"size"|"speed"|"cfg"|"part"|"serial; loc="";size="";speed="";cfg="";part="";serial=""}
    /^\tLocator:/ {loc=$2}
    /^\tSize:/ {size=$2}
    /^\tSpeed:/ {speed=$2}
    /^\tConfigured Memory Speed:/ {cfg=$2}
    /^\tPart Number:/ {gsub(/ +$/,"",$2); part=$2}
    /^\tSerial Number:/ {serial=$2}
    END {if (loc!="") print loc"|"size"|"speed"|"cfg"|"part"|"serial}' \
    | grep -v 'No Module Installed' > "$DIMM_TABLE"
fi
DIMM_COUNT=$(wc -l < "$DIMM_TABLE")
CFG_MAX=$(cut -d'|' -f4 "$DIMM_TABLE" | grep -oE '[0-9]+' | sort -n | tail -1)
DDR_TYPE="$(dmidecode -t 17 2>/dev/null | awk -F': ' '/^\tType:/ && $2!="Unknown"{print $2; exit}')"
# dmidecode sizes are "16 GB" or "16384 MB"; no DIMM table (VM, no dmidecode) -> what the kernel sees
STICKS_GB=$(awk -F'|' '{split($2,a," "); printf "%s%g GB", (NR>1 ? " + " : ""), (a[2]=="MB" ? a[1]/1024 : a[1])}' "$DIMM_TABLE")
RAM_GB=$(awk -F'|' '{split($2,a," "); s += (a[2]=="MB" ? a[1]/1024 : a[1])} END{if (s) printf "%g", s}' "$DIMM_TABLE")
[ -z "$RAM_GB" ] && RAM_GB=$(awk '/^MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo)
MEM_DETAIL=""
[ "$DIMM_COUNT" -gt 0 ] && MEM_DETAIL=" - $DIMM_COUNT stick(s): $STICKS_GB${CFG_MAX:+, running at $CFG_MAX MT/s}"

CONFIG="$OUT/config.txt"
dcol() { lsblk -dno "$2" "/dev/$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }   # one column per call: empty TRAN/MODEL can't shift the rest
{
  echo "Computer|$SYS_MODEL"
  echo "Motherboard|$BOARD (BIOS $BIOS_VER, $BIOS_DATE)"
  echo "Processor|$CPU_NAME - $CPU_CORES cores / $CPU_THREADS threads${CPU_MAX_GHZ:+, up to $CPU_MAX_GHZ GHz}"
  echo "Memory|$RAM_GB GB${DDR_TYPE:+ $DDR_TYPE}$MEM_DETAIL"
  have lspci && lspci -mm 2>/dev/null | awk -F'"' '$2 ~ /VGA|3D|Display/ {print "Graphics|" $4 " " $6}'
  have nvidia-smi && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/Graphics memory|/'
  for name in $(lsblk -dno NAME -e 1,7,11 2>/dev/null); do   # skip ramdisks, loop devices, CD drives
    case "$name" in zram*) continue ;; esac                   # compressed swap in RAM, not a drive
    model=$(dcol "$name" MODEL); tran=$(dcol "$name" TRAN)
    case "$tran" in nvme) kind="NVMe SSD" ;; usb) kind="USB drive" ;; *) [ "$(dcol "$name" ROTA)" = 1 ] && kind="HDD" || kind="SSD" ;; esac
    echo "Storage|${model:-$name} - $(dcol "$name" SIZE) $kind"
  done
  echo "Operating system|$OS (kernel $KERNEL)"
} > "$CONFIG"
echo; echo "This PC:"
while IFS='|' read -r k v; do printf '  %-17s %s\n' "$k" "$v"; done < "$CONFIG"
echo

# ---------------------------------------------------------------- T. temperature helpers
TEMPCSV="$OUT/temps.csv"
echo "time,phase,cpu_pkg_c,cpu_core_max_c,cpu_mhz_avg,cpu_watts,gpu_temp_max_c,gpu_power_w,gpu_sm_mhz,gpu_util_pct,gpu_fan_pct,gpu_thermal_slowdown" > "$TEMPCSV"
modprobe coretemp 2>/dev/null; modprobe k10temp 2>/dev/null
RAPL=/sys/class/powercap/intel-rapl:0/energy_uj; [ -r "$RAPL" ] || RAPL=""
PREV_E=""; PREV_T=""; GPU_EV=""
if have nvidia-smi; then
  if   nvidia-smi --query-gpu=clocks_event_reasons.hw_thermal_slowdown --format=csv,noheader >/dev/null 2>&1; then GPU_EV="clocks_event_reasons"
  elif nvidia-smi --query-gpu=clocks_throttle_reasons.hw_thermal_slowdown --format=csv,noheader >/dev/null 2>&1; then GPU_EV="clocks_throttle_reasons"; fi
fi
thr_count() { local t=0 f; for f in /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do [ -r "$f" ] && t=$(( t + $(cat "$f") )); done; echo $t; }
cpu_temps() { # -> "pkg,coremax" in C (Intel coretemp / AMD k10temp)
  local pkg="" core="" d n l v f
  for d in /sys/class/hwmon/hwmon*; do
    [ -r "$d/name" ] || continue; n=$(cat "$d/name")
    case "$n" in coretemp|k10temp|zenpower) ;; *) continue ;; esac
    for f in "$d"/temp*_input; do
      [ -r "$f" ] || continue
      l=$(cat "${f%_input}_label" 2>/dev/null); v=$(( $(cat "$f") / 1000 ))
      case "$l" in
        Package*|Tctl|Tdie) { [ -z "$pkg" ] || [ "$v" -gt "$pkg" ]; } && pkg=$v ;;
        Core*|Tccd*)        { [ -z "$core" ] || [ "$v" -gt "$core" ]; } && core=$v ;;
      esac
    done
  done
  echo "${pkg},${core}"
}
sample() { # sample <phase>  -> appends one CSV row
  local now ct mhz w="" g=",,,,," e q
  now=$(date +%s); ct=$(cpu_temps)
  mhz=$(awk '/^cpu MHz/{s+=$4;n++} END{if(n) printf "%.0f", s/n}' /proc/cpuinfo)
  if [ -n "$RAPL" ]; then
    e=$(cat "$RAPL" 2>/dev/null)
    if [ -n "$PREV_E" ] && [ "$now" -gt "$PREV_T" ] && [ "$e" -ge "$PREV_E" ]; then w=$(( (e - PREV_E) / 1000000 / (now - PREV_T) )); fi
    PREV_E=$e; PREV_T=$now
  fi
  if have nvidia-smi; then
    q="temperature.gpu,power.draw,clocks.sm,utilization.gpu,fan.speed"
    [ -n "$GPU_EV" ] && q="$q,$GPU_EV.hw_thermal_slowdown,$GPU_EV.sw_thermal_slowdown"
    g=$(nvidia-smi --query-gpu="$q" --format=csv,noheader,nounits 2>/dev/null | awk -F', *' '
      {if($1+0>t)t=$1+0; p+=$2; if($3+0>c)c=$3+0; if($4+0>u)u=$4+0; f=$5; if($6=="Active"||$7=="Active")th="yes"}
      END{if(NR) printf "%d,%.0f,%d,%d,%s,%s", t,p,c,u,f,(th?th:"no")}')
    [ -z "$g" ] && g=",,,,,"
  fi
  echo "$(date +%H:%M:%S),$1,$ct,$mhz,$w,$g" >> "$TEMPCSV"; sync
}
tstat() { # tstat <phase> <column> <avg|max|min>
  awk -F, -v p="$1" -v c="$2" -v a="$3" 'NR>1 && $2==p && $c!="" && $c+0==$c {v=$c+0; n++; s+=v; if(n==1||v>mx)mx=v; if(n==1||v<mn)mn=v}
    END{if(!n) exit; if(a=="avg") printf "%.0f", s/n; else if(a=="max") print mx; else print mn}' "$TEMPCSV"
}

step "Idle temperature baseline (35 s) - please do not use the PC"
for i in 1 2 3 4 5 6 7 8; do sample idle; [ "$i" -lt 8 ] && sleep 5; done

# ---------------------------------------------------------------- 1. system
step "System, BIOS, board"
run system.txt uname -a
run system.txt cat /etc/os-release
run system.txt uptime
run system.txt cat /proc/cmdline
have dmidecode && run system.txt dmidecode -t bios -t system -t baseboard
PENDING_UPD="n/a"
if have apt-get; then PENDING_UPD="$(apt list --upgradable 2>/dev/null | grep -c upgradable)"; fi

# ---------------------------------------------------------------- 2. CPU
step "CPU, microcode, core map"
run cpu.txt lscpu
run cpu.txt lscpu -e
grep -m1 -E 'microcode' /proc/cpuinfo > "$RAW/microcode.txt" 2>/dev/null
CPU_FAM="$(grep -m1 '^cpu family' /proc/cpuinfo | awk -F: '{print $2+0}')"
CPU_MODEL="$(grep -m1 '^model[[:space:]]*:' /proc/cpuinfo | awk -F: '{print $2+0}')"
UCODE="$(grep -m1 microcode /proc/cpuinfo | awk -F: '{gsub(/ /,"",$2); print $2}')"
UCODE_DEC=$(( ${UCODE:-0} ))
# Thermal throttle counters
THROTTLE=$(thr_count)

# Raptor Lake check: family 6, model 183 (0xB7) = 13th/14th gen desktop i5-13600K and up (affected die)
RAPTOR=0
if [ "$CPU_FAM" = "6" ] && [ "$CPU_MODEL" = "183" ]; then
  RAPTOR=1
  if [ "$UCODE_DEC" -lt $((0x12F)) ]; then
    flag RED UCODE_OLD "Raptor Lake CPU ($CPU_NAME) on microcode $UCODE - below 0x12F. Update BIOS before anything else."
  else
    flag GREEN UCODE_OK "Raptor Lake CPU on microcode $UCODE (>= 0x12F). Note: microcode prevents new damage, it does not repair a degraded CPU."
  fi
fi
[ "$THROTTLE" -gt 1000 ] && flag AMBER THERMAL "CPU thermal throttle events since boot: $THROTTLE - check cooler mount / pump / paste."

# ---------------------------------------------------------------- 3. Memory
step "Memory modules"
have dmidecode && run memory.txt dmidecode -t memory
run memory.txt free -h
PARTS_UNIQ=$(cut -d'|' -f5 "$DIMM_TABLE" | sort -u | grep -vc '^$')
[ "$PARTS_UNIQ" -gt 1 ] && flag AMBER RAM_MIXED "Mixed RAM part numbers installed ($(cut -d'|' -f5 "$DIMM_TABLE" | sort -u | tr '\n' ' ')) - verify against build sheet."
if [ -n "$CFG_MAX" ]; then
  if { [ "$DDR_TYPE" = "DDR5" ] && [ "$CFG_MAX" -gt 5600 ]; } || { [ "$DDR_TYPE" = "DDR4" ] && [ "$CFG_MAX" -gt 3200 ]; }; then
    flag AMBER XMP_ON "RAM running at $CFG_MAX MT/s ($DDR_TYPE) - XMP/EXPO is ON. For stability triage set JEDEC default."
  fi
fi
[ "$DIMM_COUNT" -eq 4 ] && [ "$DDR_TYPE" = "DDR5" ] && flag AMBER DDR5_4DIMM "4 x DDR5 DIMMs - reduce speed (<= 5200 MT/s) or test with 2 DIMMs."

# ---------------------------------------------------------------- 4. Kernel logs
step "Kernel logs: MCE, segfaults, GPU Xid, PCIe AER, NVMe, panics (last $DAYS days)"
JPERSIST="no"; [ -d /var/log/journal ] && JPERSIST="yes"
KLOG="$RAW/kernel_${DAYS}d.log"
if have journalctl; then
  journalctl -k --no-pager --since "-${DAYS} days" > "$KLOG" 2>/dev/null
  journalctl --list-boots --no-pager > "$RAW/boots.txt" 2>/dev/null
  journalctl -b -1 -n 80 --no-pager > "$RAW/previous_boot_last80.txt" 2>/dev/null
  # whole previous boot (capped): shows what the PC was doing in the hours before a hang, not only the last minute
  journalctl -b -1 --no-pager 2>/dev/null | tail -n 20000 > "$RAW/previous_boot_full.txt"
else
  dmesg -T > "$KLOG" 2>/dev/null
fi
dmesg -T > "$RAW/dmesg_current.txt" 2>/dev/null
# Replay mode (training / re-analysis): THEMVP_KLOG=/path/to/saved_kernel.log sudo -E bash themvp-diag.sh ...
[ -n "${THEMVP_KLOG:-}" ] && [ -r "$THEMVP_KLOG" ] && cp "$THEMVP_KLOG" "$KLOG"
[ "$JPERSIST" = "no" ] && flag AMBER NO_PERSIST_JOURNAL "Journal is not persistent - crash history is lost on every reboot. Run: sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald"

mce_lines "$KLOG" > "$RAW/mce_lines.txt"
MCE_N=$(grep -c . "$RAW/mce_lines.txt")
SEGV_N=$(grep -c 'segfault at' "$KLOG")
GPF_N=$(grep -ciE 'general protection fault|invalid opcode' "$KLOG")
XID_N=$(grep -c 'NVRM: Xid' "$KLOG")
AER_N=$(grep -ciE 'AER:|PCIe Bus Error' "$KLOG")
NVME_ERR_N=$(grep -ciE 'nvme.*(timeout|reset|I/O error|controller is down)' "$KLOG")
OOM_N=$(grep -ciE 'out of memory|oom-kill' "$KLOG")
# Case-sensitive on purpose: with -i, "BUG:" matches "debug:" and "CE" matches "device".
LOCKUP_RE='[Kk]ernel panic|BUG:|soft lockup|hard LOCKUP|hung_task|rcu.*detected stall'
PANIC_N=$(grep -cE "$LOCKUP_RE" "$KLOG")
EDAC_N=$(grep -cE 'EDAC.*\<(CE|UE)\>|[Cc]orrected [Ee]rror' "$KLOG")

grep 'segfault at' "$KLOG" > "$RAW/segfaults.txt"
grep 'NVRM: Xid' "$KLOG" > "$RAW/gpu_xid.txt"
grep -iE 'AER:|PCIe Bus Error' "$KLOG" > "$RAW/pcie_aer.txt"
grep -E "$LOCKUP_RE" "$KLOG" > "$RAW/lockups.txt"

# Segfault -> physical core concentration (the Raptor Lake fingerprint)
grep -oE 'likely on CPU [0-9]+ \(core [0-9]+' "$RAW/segfaults.txt" \
  | sed -E 's/likely on CPU ([0-9]+) \(core ([0-9]+)/core \2 (cpu \1)/' \
  | sort | uniq -c | sort -rn > "$RAW/segfault_core_map.txt"
SEGV_PROGS=$(grep -oE '[a-zA-Z0-9_.-]+\[[0-9]+\]: segfault' "$RAW/segfaults.txt" | sed 's/\[.*//' | sort -u | tr '\n' ' ')
SEGV_LIBS=$(grep -oE ' in [^ []+' "$RAW/segfaults.txt" | sed 's/ in //' | sort -u | tr '\n' ' ')
SEGV_PROG_N=$(echo "$SEGV_PROGS" | wc -w)
TOP_CORE_LINE="$(awk '{c[$3]+=$1} END{for(k in c) print c[k], k}' "$RAW/segfault_core_map.txt" | sort -rn | head -1)"
TOP_CORE_HITS=$(echo "$TOP_CORE_LINE" | awk '{print $1+0}')
TOP_CORE=$(echo "$TOP_CORE_LINE" | awk '{print $2}')
CORE_SHARE=0; [ "$SEGV_N" -gt 0 ] && CORE_SHARE=$(( TOP_CORE_HITS * 100 / SEGV_N ))
# all physical cores that appear in segfaults
SEGV_CORES=$(grep -oE 'core [0-9]+' "$RAW/segfault_core_map.txt" | awk '{print $2}' | sort -un | tr '\n' ' ')

[ "$MCE_N" -gt 0 ] && flag RED MCE "$MCE_N machine-check / hardware-error lines in kernel log. Decode with: sudo ras-mc-ctl --errors"
if [ "$SEGV_N" -ge 3 ] && [ "$CORE_SHARE" -ge 60 ] && [ "$SEGV_PROG_N" -ge 2 ]; then
  flag RED CORE_FAULT "$SEGV_N segfaults across $SEGV_PROG_N different programs, ${CORE_SHARE}% on physical core $TOP_CORE (cores seen: $SEGV_CORES). Same core, unrelated software = CPU fault signature."
elif [ "$SEGV_N" -ge 3 ]; then
  flag AMBER SEGFAULTS "$SEGV_N segfaults (programs: $SEGV_PROGS) - not concentrated on one core; check software/driver first."
fi
[ "$GPF_N" -gt 0 ] && flag AMBER GPF "$GPF_N general-protection / invalid-opcode faults."
[ "$XID_N" -gt 0 ] && flag RED GPU_XID "$XID_N NVIDIA Xid errors - see raw/gpu_xid.txt (Xid 79/48/119 = hardware/PCIe/power; 13/31/43 = usually app/driver)."
[ "$AER_N" -gt 5 ] && flag AMBER PCIE_AER "$AER_N PCIe AER errors - reseat GPU/NVMe, check riser, try PCIe Gen4 forced in BIOS."
[ "$NVME_ERR_N" -gt 0 ] && flag RED NVME_IO "$NVME_ERR_N NVMe timeout/reset/I/O errors in kernel log."
[ "$OOM_N" -gt 0 ] && flag AMBER OOM "$OOM_N out-of-memory kills - workload exceeds RAM, not hardware."
[ "$PANIC_N" -gt 0 ] && flag RED LOCKUP "$PANIC_N kernel panic / lockup / hung-task lines - see raw/lockups.txt."
[ "$EDAC_N" -gt 0 ] && flag RED EDAC "$EDAC_N EDAC memory error lines."

if have ras-mc-ctl; then
  run ras.txt ras-mc-ctl --summary
  run ras.txt ras-mc-ctl --errors
fi

# ---------------------------------------------------------------- 5. Storage
step "Storage SMART"
UNSAFE_TOTAL=0; PCYC_TOTAL=0
if have smartctl; then
  smartctl --scan > "$RAW/smart_scan.txt" 2>&1
  while read -r dev _; do
    [ -z "$dev" ] && continue
    n="$(basename "$dev")"
    smartctl -x "$dev" > "$RAW/smart_${n}.txt" 2>&1
    H=$(grep -m1 -iE 'overall-health|SMART Health Status' "$RAW/smart_${n}.txt" | awk -F: '{print $2}' | xargs)
    MED=$(grep -m1 -i 'Media and Data Integrity Errors' "$RAW/smart_${n}.txt" | awk -F: '{gsub(/[ ,]/,"",$2);print $2+0}')
    US=$(grep -m1 -i 'Unsafe Shutdowns' "$RAW/smart_${n}.txt" | awk -F: '{gsub(/[ ,]/,"",$2);print $2+0}')
    PC=$(grep -m1 -i 'Power Cycles' "$RAW/smart_${n}.txt" | awk -F: '{gsub(/[ ,]/,"",$2);print $2+0}')
    PU=$(grep -m1 -i 'Percentage Used' "$RAW/smart_${n}.txt" | awk -F: '{gsub(/[ %]/,"",$2);print $2+0}')
    REAL=$(grep -m1 -iE 'Reallocated_Sector_Ct' "$RAW/smart_${n}.txt" | awk '{print $NF+0}')
    echo "$dev health=$H media_err=${MED:-0} unsafe=${US:-0} cycles=${PC:-0} used=${PU:-0}% realloc=${REAL:-0}" >> "$OUT/.disks"
    [ -n "$H" ] && ! echo "$H" | grep -qiE 'PASSED|OK' && flag RED SMART_FAIL "$dev SMART health: $H"
    [ "${MED:-0}" -gt 0 ] && flag RED NVME_MEDIA "$dev has ${MED} media/data-integrity errors."
    [ "${REAL:-0}" -gt 0 ] && flag AMBER REALLOC "$dev has ${REAL} reallocated sectors."
    [ "${PU:-0}" -ge 80 ] && flag AMBER SSD_WEAR "$dev wear ${PU}% used."
    UNSAFE_TOTAL=$(( UNSAFE_TOTAL + ${US:-0} )); PCYC_TOTAL=$(( PCYC_TOTAL + ${PC:-0} ))
  done < <(awk '{print $1}' "$RAW/smart_scan.txt")
fi
if [ "$PCYC_TOTAL" -gt 20 ]; then
  RATIO=$(( UNSAFE_TOTAL * 100 / PCYC_TOTAL ))
  [ "$RATIO" -ge 30 ] && flag AMBER UNSAFE_SHUTDOWN "Unsafe shutdowns $UNSAFE_TOTAL of $PCYC_TOTAL power cycles (${RATIO}%) - confirms repeated hard resets / power loss."
fi
run storage.txt lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINT
run storage.txt df -hT

# ---------------------------------------------------------------- 6. GPU
step "GPU"
GPU_SUMMARY="none detected"
if have nvidia-smi; then
  run gpu.txt nvidia-smi
  run gpu.txt nvidia-smi -q
  GPU_SUMMARY="$(nvidia-smi --query-gpu=name,driver_version,temperature.gpu,power.draw,power.limit,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader 2>/dev/null | tr '\n' ';')"
  RETIRED=$(nvidia-smi -q -d ROW_REMAPPER,PAGE_RETIREMENT 2>/dev/null | grep -iE 'Pending.*Yes|Remapping Failure Occurred.*Yes' | wc -l)
  [ "$RETIRED" -gt 0 ] && flag RED GPU_MEM "GPU memory row-remap failure / pending retirement reported."
fi
have lspci && run pci.txt lspci -nnk
have lspci && run pci.txt lspci -vv

# ---------------------------------------------------------------- 7. Sensors / power
step "Sensors"
have sensors && run sensors.txt sensors
run power.txt cat /sys/class/power_supply/*/uevent

# ---------------------------------------------------------------- 8. Optional load tests + temperature logging
LOAD_RAN=0
if [ "$STRESS_MIN" -gt 0 ] || [ "$GPU_STRESS_MIN" -gt 0 ]; then
  BEFORE_MCE=$(dmesg | mce_lines | grep -c .); BEFORE_THR=$(thr_count); BEFORE_XID=$(dmesg | grep -c 'NVRM: Xid')
  SPID=""; GPID=""; GBDIR=""
  # CPU + RAM load
  if [ "$STRESS_MIN" -gt 0 ]; then
    if have stress-ng; then
      stress-ng --cpu 0 --cpu-method all --vm 2 --vm-bytes 60% --verify \
        --timeout "${STRESS_MIN}m" --metrics-brief > "$RAW/stress.txt" 2>&1 &
      SPID=$!
    else
      flag AMBER STRESS_SKIPPED "stress-ng not available - CPU load test skipped."
    fi
  fi
  # GPU load (gpu-burn: https://github.com/wilicc/gpu-burn)
  if [ "$GPU_STRESS_MIN" -gt 0 ]; then
    if ! have nvidia-smi; then
      flag AMBER GPU_STRESS_SKIPPED "No NVIDIA GPU / driver - GPU load test skipped."
    else
      for d in "$(dirname "$(command -v gpu_burn 2>/dev/null)")" "$REAL_HOME/gpu-burn" /opt/gpu-burn "$PWD"; do
        [ -n "$d" ] && [ -x "$d/gpu_burn" ] && { GBDIR="$d"; break; }
      done
      if [ -z "$GBDIR" ] && [ "$INSTALL" -eq 1 ] && have git && have make && { have nvcc || [ -x /usr/local/cuda/bin/nvcc ]; }; then
        step "Building gpu-burn (one-time, ~1 min)"
        export PATH="$PATH:/usr/local/cuda/bin"
        git clone -q https://github.com/wilicc/gpu-burn "$REAL_HOME/gpu-burn" >"$RAW/gpu_burn_build.txt" 2>&1 \
          && make -C "$REAL_HOME/gpu-burn" >>"$RAW/gpu_burn_build.txt" 2>&1 && GBDIR="$REAL_HOME/gpu-burn"
      fi
      if [ -n "$GBDIR" ]; then
        ( cd "$GBDIR" && ./gpu_burn $(( GPU_STRESS_MIN*60 )) ) > "$RAW/gpu_burn.txt" 2>&1 &
        GPID=$!
      else
        flag AMBER GPU_STRESS_SKIPPED "gpu-burn not found and could not be built (needs CUDA toolkit nvcc + git). Install it at ~/gpu-burn, or test GPU with the customer's own workload."
      fi
    fi
  fi
  if [ -n "$SPID$GPID" ]; then
    LOAD_RAN=1
    MAXMIN=$STRESS_MIN; [ "$GPU_STRESS_MIN" -gt "$MAXMIN" ] && MAXMIN=$GPU_STRESS_MIN
    step "LOAD TEST running ${MAXMIN} min: CPU/RAM=${STRESS_MIN:-0} min GPU=${GPU_STRESS_MIN:-0} min. Temps logged every 5 s. If the PC hangs, restart and send the folder ~/$(basename "$OUT")"
    DEADLINE=$(( $(date +%s) + MAXMIN*60 + 60 ))
    while { [ -n "$SPID" ] && kill -0 "$SPID" 2>/dev/null; } || { [ -n "$GPID" ] && kill -0 "$GPID" 2>/dev/null; }; do
      sample load
      [ "$(date +%s)" -gt "$DEADLINE" ] && { kill "$SPID" "$GPID" 2>/dev/null; break; }
      sleep 5
    done
    RC=0; [ -n "$SPID" ] && { wait "$SPID"; RC=$?; }
    [ -n "$GPID" ] && wait "$GPID"
    step "Cooldown (60 s)"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do sample cooldown; sleep 5; done
    AFTER_MCE=$(dmesg | mce_lines | grep -c .); AFTER_THR=$(thr_count); AFTER_XID=$(dmesg | grep -c 'NVRM: Xid')
    NEW_MCE=$((AFTER_MCE-BEFORE_MCE)); NEW_THR=$((AFTER_THR-BEFORE_THR)); NEW_XID=$((AFTER_XID-BEFORE_XID))
    echo "stress_exit=$RC new_mce=$NEW_MCE new_cpu_throttle_events=$NEW_THR new_gpu_xid=$NEW_XID" >> "$RAW/stress.txt"
    if [ -n "$SPID" ]; then
      if [ "$RC" -ne 0 ] || grep -qiE 'failed: [1-9]|verification (error|fail)|unsuccessful' "$RAW/stress.txt" || [ "$NEW_MCE" -gt 0 ]; then
        flag RED STRESS_FAIL "CPU/RAM load test failed (exit $RC, new MCE $NEW_MCE) during ${STRESS_MIN}-min run."
      else
        flag GREEN STRESS_PASS "CPU/RAM ${STRESS_MIN}-min load test passed with no new errors."
      fi
    fi
    if [ -n "$GPID" ]; then
      if grep -qE 'FAULTY|errors: [1-9]' "$RAW/gpu_burn.txt" || [ "$NEW_XID" -gt 0 ]; then
        flag RED GPU_BURN_FAIL "GPU load test reported compute errors or new Xid ($NEW_XID) - GPU fault."
      else
        flag GREEN GPU_BURN_PASS "GPU ${GPU_STRESS_MIN}-min load test passed with no compute errors."
      fi
    fi
    [ "$NEW_THR" -gt 0 ] && flag AMBER CPU_THROTTLED_LOAD "CPU hit thermal throttling $NEW_THR times during load test."
  fi
fi

# ---------------------------------------------------------------- 8b. Temperature evaluation
CPU_COL=3; [ -z "$(tstat idle 3 max)" ] && CPU_COL=4
T_CPU_IDLE=$(tstat idle $CPU_COL avg);   T_CPU_LOAD=$(tstat load $CPU_COL max)
T_CORE_LOAD=$(tstat load 4 max);        T_CPU_COOL=$(tstat cooldown $CPU_COL min)
W_CPU_IDLE=$(tstat idle 6 avg);         W_CPU_LOAD=$(tstat load 6 max)
MHZ_IDLE=$(tstat idle 5 avg);           MHZ_LOAD_MIN=$(tstat load 5 min); MHZ_LOAD_AVG=$(tstat load 5 avg)
T_GPU_IDLE=$(tstat idle 7 avg);         T_GPU_LOAD=$(tstat load 7 max)
W_GPU_IDLE=$(tstat idle 8 avg);         W_GPU_LOAD=$(tstat load 8 max)
GPU_CLK_LOAD_MIN=$(tstat load 9 min);   GPU_UTIL_LOAD=$(tstat load 10 avg)
GPU_THERM_SLOW=$(awk -F, 'NR>1 && $2=="load" && $12=="yes"{n++} END{print n+0}' "$TEMPCSV")

[ -z "$T_CPU_IDLE" ] && flag AMBER NO_CPU_SENSOR "CPU temperature sensor not readable (coretemp/k10temp) - install lm-sensors and run sensors-detect."
[ -n "$T_CPU_IDLE" ] && [ "$T_CPU_IDLE" -ge 60 ] && flag AMBER CPU_IDLE_HOT "CPU idle at ${T_CPU_IDLE}C (expected < 50C) - check cooler pump, mounting, paste, background load."
if [ -n "$T_CPU_LOAD" ]; then
  if   [ "$T_CPU_LOAD" -ge 100 ]; then flag RED CPU_LOAD_TJMAX "CPU reached ${T_CPU_LOAD}C under load (TjMax) - throttling. Check cooler, power limits (Intel Default Settings)."
  elif [ "$T_CPU_LOAD" -ge 90 ];  then flag AMBER CPU_LOAD_HOT "CPU peaked at ${T_CPU_LOAD}C under load - limited headroom for 24x7 use."
  else flag GREEN CPU_TEMP_OK "CPU temps OK: idle ${T_CPU_IDLE}C, load peak ${T_CPU_LOAD}C."; fi
fi
[ -n "$T_GPU_IDLE" ] && [ "$T_GPU_IDLE" -ge 55 ] && flag AMBER GPU_IDLE_HOT "GPU idle at ${T_GPU_IDLE}C - check fan, case airflow, background process."
if [ -n "$T_GPU_LOAD" ] && [ "$LOAD_RAN" -eq 1 ] && [ "$GPU_STRESS_MIN" -gt 0 ]; then
  if   [ "$T_GPU_LOAD" -ge 88 ] || [ "$GPU_THERM_SLOW" -gt 0 ]; then flag RED GPU_LOAD_HOT "GPU peaked at ${T_GPU_LOAD}C under load, thermal slowdown samples: $GPU_THERM_SLOW - airflow / fan / blower issue."
  elif [ "$T_GPU_LOAD" -ge 83 ]; then flag AMBER GPU_LOAD_WARM "GPU peaked at ${T_GPU_LOAD}C under load - close to slowdown point."
  else flag GREEN GPU_TEMP_OK "GPU temps OK: idle ${T_GPU_IDLE}C, load peak ${T_GPU_LOAD}C."; fi
fi

# ---------------------------------------------------------------- 9. Summary
step "Writing summary"
RED_N=$(grep -c '^RED|' "$FLAGS"); AMB_N=$(grep -c '^AMBER|' "$FLAGS")
if   [ "$RED_N" -gt 0 ]; then VERDICT="RED - hardware fault evidence found"
elif [ "$AMB_N" -gt 0 ]; then VERDICT="AMBER - warnings, needs engineer review"
else VERDICT="GREEN - no hardware fault evidence in logs"; fi

# Suggested likely cause (rule-based)
CAUSE="Inconclusive - engineer review"
if grep -q '|CORE_FAULT|' "$FLAGS" || { grep -q '|MCE|' "$FLAGS" && [ "$RAPTOR" -eq 1 ]; }; then
  CAUSE="CPU instability/degradation (core-specific faults). Next: SOP step 3A core-offline test, BIOS/microcode, then CPU swap."
elif grep -q '|GPU_XID|\|GPU_MEM|\|GPU_BURN_FAIL|' "$FLAGS"; then
  CAUSE="GPU / PCIe / GPU power. Next: Xid code lookup, reseat, PSU cables, swap GPU."
elif grep -q '|NVME_IO|\|NVME_MEDIA|\|SMART_FAIL|' "$FLAGS"; then
  CAUSE="Storage. Next: firmware update, reseat, clone and replace drive."
elif grep -q '|EDAC|' "$FLAGS" || grep -q '|XMP_ON|\|RAM_MIXED|' "$FLAGS"; then
  CAUSE="Memory config/RAM. Next: JEDEC speed, one DIMM at a time, MemTest86 (UEFI)."
elif grep -q '|CPU_LOAD_TJMAX|\|GPU_LOAD_HOT|\|CPU_IDLE_HOT|' "$FLAGS"; then
  CAUSE="Thermal / cooling. Next: check cooler pump and mount, repaste, fans and case airflow, power limits."
elif grep -q '|OOM|' "$FLAGS"; then
  CAUSE="Workload exceeds RAM (software sizing), not a hardware fault."
fi

{
echo "=============================================================="
echo " TheMVP.in Diagnostic Summary        collector v$VERSION"
echo "=============================================================="
echo " Ticket       : $TICKET"
echo " Host         : $HOST"
echo " Collected    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo " VERDICT      : $VERDICT   (RED=$RED_N  AMBER=$AMB_N)"
echo " Likely cause : $CAUSE"
echo "--------------------------------------------------------------"
echo " PC CONFIGURATION"
while IFS='|' read -r k v; do printf '   %-17s %s\n' "$k" "$v"; done < "$CONFIG"
echo "--------------------------------------------------------------"
echo " Pending updates: $PENDING_UPD"
echo " CPU          :$CPU_NAME  fam $CPU_FAM model $CPU_MODEL  microcode $UCODE  raptor_lake=$RAPTOR"
echo " Throttle cnt : $THROTTLE (since boot)"
echo " TEMPERATURES (C)            idle avg   load peak   cooldown"
printf '   CPU package/core        %-10s %-11s %s\n' "${T_CPU_IDLE:--}" "${T_CPU_LOAD:-not run}" "${T_CPU_COOL:--}"
printf '   GPU                     %-10s %-11s\n' "${T_GPU_IDLE:--}" "${T_GPU_LOAD:-not run}"
echo "   CPU power W idle/load  : ${W_CPU_IDLE:--} / ${W_CPU_LOAD:--}    CPU MHz idle / load avg / load min: ${MHZ_IDLE:--} / ${MHZ_LOAD_AVG:--} / ${MHZ_LOAD_MIN:--}"
echo "   GPU power W idle/load  : ${W_GPU_IDLE:--} / ${W_GPU_LOAD:--}    GPU util load avg: ${GPU_UTIL_LOAD:--}%  SM MHz load min: ${GPU_CLK_LOAD_MIN:--}  thermal-slowdown samples: $GPU_THERM_SLOW"
[ "$LOAD_RAN" -eq 0 ] && echo "   (no load test run - add: --stress 15 --gpu-stress 15)"
echo "   Full 5-second log: temps.csv"
echo " RAM ($DIMM_COUNT DIMM, $DDR_TYPE):"
while IFS='|' read -r l s sp c p sn; do echo "   - $l : $s, rated $sp, running $c, P/N $p, S/N $sn"; done < "$DIMM_TABLE"
echo " GPU          : $GPU_SUMMARY"
echo " Disks        :"; [ -f "$OUT/.disks" ] && sed 's/^/   - /' "$OUT/.disks"
echo " Journal      : persistent=$JPERSIST, window=${DAYS}d, boots logged=$(grep -c . "$RAW/boots.txt" 2>/dev/null)"
echo "--------------------------------------------------------------"
echo " Kernel counts: MCE=$MCE_N segfault=$SEGV_N GPF=$GPF_N GPU_Xid=$XID_N AER=$AER_N NVMe_err=$NVME_ERR_N OOM=$OOM_N lockup/panic=$PANIC_N EDAC=$EDAC_N"
if [ "$SEGV_N" -gt 0 ]; then
  echo " Segfault core map (count, physical core, logical cpu):"; sed 's/^/   /' "$RAW/segfault_core_map.txt"
  echo " Crashing programs: $SEGV_PROGS"
  echo " Crashing in libs : $SEGV_LIBS"
fi
echo "--------------------------------------------------------------"
echo " FLAGS"
for lvl in RED AMBER GREEN; do
  grep "^$lvl|" "$FLAGS" | while IFS='|' read -r L C M; do printf ' [%-5s] %-18s %s\n' "$L" "$C" "$M"; done
done
echo "=============================================================="
} > "$SUM"

# JSON for Odoo / automation
json_esc() { sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '; }
{
echo "{"
echo "  \"collector_version\": \"$VERSION\", \"ticket\": \"$TICKET\", \"host\": \"$HOST\", \"collected\": \"$(date -Iseconds)\","
echo "  \"verdict\": \"$(echo "$VERDICT" | cut -d' ' -f1)\", \"likely_cause\": \"$(echo "$CAUSE" | json_esc)\","
echo "  \"cpu\": \"$(echo "$CPU_NAME" | json_esc)\", \"microcode\": \"$UCODE\", \"raptor_lake\": $RAPTOR,"
echo "  \"bios\": \"$(echo "$BIOS_VER $BIOS_DATE" | json_esc)\", \"board\": \"$(echo "$BOARD" | json_esc)\", \"kernel\": \"$KERNEL\","
echo "  \"counts\": {\"mce\": $MCE_N, \"segfault\": $SEGV_N, \"gpu_xid\": $XID_N, \"pcie_aer\": $AER_N, \"nvme_err\": $NVME_ERR_N, \"oom\": $OOM_N, \"lockup\": $PANIC_N, \"edac\": $EDAC_N, \"unsafe_shutdowns\": $UNSAFE_TOTAL, \"power_cycles\": $PCYC_TOTAL},"
echo "  \"segfault_top_core\": \"${TOP_CORE:-}\", \"segfault_top_core_pct\": $CORE_SHARE,"
echo "  \"temps\": {\"load_test_ran\": $LOAD_RAN, \"cpu_idle_c\": \"${T_CPU_IDLE:-}\", \"cpu_load_peak_c\": \"${T_CPU_LOAD:-}\", \"cpu_load_watts_peak\": \"${W_CPU_LOAD:-}\", \"cpu_load_mhz_min\": \"${MHZ_LOAD_MIN:-}\", \"gpu_idle_c\": \"${T_GPU_IDLE:-}\", \"gpu_load_peak_c\": \"${T_GPU_LOAD:-}\", \"gpu_load_watts_peak\": \"${W_GPU_LOAD:-}\", \"gpu_thermal_slowdown_samples\": $GPU_THERM_SLOW},"
echo "  \"ram_parts\": \"$(cut -d'|' -f5 "$DIMM_TABLE" | json_esc)\","
echo "  \"config\": ["
awk -F'|' 'BEGIN{n=0} {for (i=1;i<=2;i++) {gsub(/\\/,"\\\\",$i); gsub(/"/,"\\\"",$i)} printf "%s    {\"item\":\"%s\",\"value\":\"%s\"}", (n++?",\n":""), $1,$2} END{print ""}' "$CONFIG"
echo "  ],"
echo "  \"flags\": ["
awk -F'|' 'BEGIN{n=0} {gsub(/\\/,"\\\\",$3); gsub(/"/,"\\\"",$3); printf "%s    {\"level\":\"%s\",\"code\":\"%s\",\"msg\":\"%s\"}", (n++?",\n":""), $1,$2,$3} END{print ""}' "$FLAGS"
echo "  ]"
echo "}"
} > "$OUT/summary.json"

rm -f "$OUT/.dimms" "$OUT/.disks"; mv "$FLAGS" "$RAW/flags.txt"
[ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER" "$OUT"
tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$OUT.tar.gz"

echo
cat "$SUM"
echo
if [ "$TICKET" = "NOTICKET" ]; then
  echo "NOTE: no ticket number was given. Please run it again with your ticket number, e.g.  sudo bash $0 SID000616"
fi
echo "DONE. Please email this file to support by replying to your ticket email:"
echo "   $OUT.tar.gz"
