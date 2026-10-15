#!/bin/bash
# bcm-logs.sh - zbiera logi po nieudanej instalacji (K8s / Run:ai) na klastrze BCM,
# np. przed cofnięciem snapshotu VM. TYLKO ODCZYT - niczego nie zmienia.
# Działa także wtedy, gdy cmsh/cmd nie działa (wtedy pomija zapytania cmsh).
#
# Użycie (jako root na head node):
#   ./bcm-logs.sh [--node N]... [--no-nodes] [--days D]
#
#   --node N     zbierz też logi z węzła N (można powtarzać); domyślnie wszystkie węzły UP z cmsh
#   --no-nodes   tylko head node
#   --days D     okno analizy instalacji/usunięć pakietów (domyślnie 3 dni)
#
# Wynik (obok siebie, domyślnie w /root):
#   bcm-logs-<host>-<data>/            report.txt (wnioski) + head/ + nodes/<węzeł>/
#   bcm-logs-<host>-<data>.tgz         sekrety zamaskowane - to można wysłać
#   bcm-logs-<host>-<data>-SECRET.tgz  oryginalne configi kreatorów i deploy.env (chmod 600) -
#                                      NIE wysyłaj; służą do ponownego 'cm-kubernetes-setup -c' po revercie

set -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -r "$SCRIPT_DIR/lib/common.sh" ] || { echo "Brak $SCRIPT_DIR/lib/common.sh - sklonuj całe repozytorium." >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

NODES=; NO_NODES=0; DAYS=3
while [ $# -gt 0 ]; do
  case $1 in
    --node) NODES="$NODES $2"; shift;;
    --no-nodes) NO_NODES=1;;
    --days) DAYS=$2; shift;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0;;
    *) echo "Nieznana opcja: $1 (zob. --help)" >&2; exit 2;;
  esac; shift
done
[[ $DAYS =~ ^[0-9]+$ ]] || die "--days: liczba dni"
[ "$(id -u)" = 0 ] || die "Uruchom jako root."
have cmsh || { [ -x /cm/local/apps/cmd/bin/cmsh ] && PATH=$PATH:/cm/local/apps/cmd/bin; }
detect_os

HOST=$(hostname -s); TS=$(date +%Y%m%d-%H%M%S)
NAME=bcm-logs-$HOST-$TS
OUT=${BCM_OUT_DIR:-/root}
WORKDIR=$OUT/$NAME; H=$WORKDIR/head; SECFILES=()
mkdir -p "$H" "$WORKDIR/nodes"; chmod 700 "$WORKDIR"
LOG_FILE=$WORKDIR/collect.log; REPORT=$WORKDIR/report.txt
export WORKDIR LOG_FILE REPORT
{ echo "BCM - logi po instalacji: $HOST, $(date -Is), okno analizy: $DAYS dni"; echo; } >"$REPORT"
info "Zbieram do $WORKDIR"

# ------------------------------------------------------------- narzędzia -----
# cmdout <plik> <komenda powłoki>   (wynik zamaskowany, z limitem czasu)
cmdout() { local f=$1; shift; mkdir -p "$(dirname "$f")"; { echo "### $*"; tmo 120 bash -c "$*" 2>&1; } | mask_secrets >"$f"; }
# cpmask <źródło> <katalog docelowy> [ostatnie N linii]  (tekst maskowany, .gz kopiowane bez zmian)
cpmask() {
  local s=$1 d=$2 n=${3:-} b; [ -r "$s" ] || return 0
  mkdir -p "$d"; b=$(basename "$s")
  case $s in
    *.gz|*.xz|*.zst) cp -p "$s" "$d/";;
    *) if [ -n "$n" ]; then tail -n "$n" "$s" | mask_secrets >"$d/$b"; else mask_secrets <"$s" >"$d/$b"; fi;;
  esac
}
# zcat wszystkich rotacji pliku, najstarsze pierwsze
zall() { local f; for f in $(ls -1r "$1".*.gz 2>/dev/null) "$1".1 "$1"; do [ -r "$f" ] && zcat -f "$f"; done; }
SINCE=$(date -d "-$DAYS days" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 0000-00-00)

# ------------------------------------------------------------ head: pliki ----
hdr "Head node: logi systemowe i pakietów"
for f in /var/log/apt/history.log* /var/log/apt/term.log* /var/log/dpkg.log* \
         /var/log/dnf.log* /var/log/dnf.rpm.log* /var/log/yum.log*; do cpmask "$f" "$H/pkg"; done
for f in /var/log/cm-*setup*.log*; do cpmask "$f" "$H/wizard"; done
cpmask /var/log/cmdaemon "$H/cmd" 20000
for f in /var/log/cmdaemon.*; do case $f in *.gz) cpmask "$f" "$H/cmd";; esac; done
cpmask /var/log/syslog "$H/sys" 20000; cpmask /var/log/messages "$H/sys" 20000
cpmask /var/log/node-installer "$H/sys" 5000

hdr "Head node: configi kreatorów i wdrożenia"
# shellcheck disable=SC2086
CONFS=$(find ${BCM_CONF_DIRS:-/root /root/bcm-deploy /cm/shared/runai} -maxdepth 1 -type f \( -name 'cm-*setup*.conf' -o -name 'deploy.env' \) 2>/dev/null | sort -u)
for f in $CONFS; do
  cpmask "$f" "$H/wizard-conf"; mv "$H/wizard-conf/$(basename "$f")" "$H/wizard-conf/$(basename "$f").masked" 2>/dev/null
  SECFILES+=("${f#/}")
done
[ -n "$CONFS" ] && info "Configi: $(echo "$CONFS" | xargs)"
for f in /root/bcm-deploy/*.log /root/bcm-deploy/answers-*.txt /root/bcm-deploy/state; do cpmask "$f" "$H/bcm-deploy"; done
for d in /root/bcm-containerd-fix-* /root/bcm-nvlink-fix-*; do
  [ -d "$d" ] || continue
  mkdir -p "$H/scripts/$(basename "$d")"
  for f in "$d"/report.txt "$d"/raw/*; do cpmask "$f" "$H/scripts/$(basename "$d")"; done
done
for f in /root/bcm-containerd-fix-*.log /root/bcm-nvlink-fix-*.log; do cpmask "$f" "$H/scripts"; done
last_collect=$(ls -1dt /root/bcm-collect-*/ 2>/dev/null | head -1)
[ -n "$last_collect" ] && cpmask "${last_collect}report.txt" "$H/scripts/$(basename "$last_collect")"
for f in /cm/local/apps/containerd/var/etc/config.toml /cm/local/apps/containerd/var/etc/conf.d/*.toml /etc/containerd/config.toml; do
  [ -r "$f" ] && { mkdir -p "$H/containerd"; mask_secrets <"$f" >"$H/containerd/$(echo "${f#/}" | tr / _)"; }
done

# --------------------------------------------------------- head: komendy -----
hdr "Head node: stan systemu, pakiety, biblioteki, usługi"
cmdout "$H/system.txt" 'uname -a; cat /etc/os-release; uptime; echo; free -m; echo; df -hT; echo; df -i; echo; systemd-detect-virt 2>/dev/null; echo; ps aux --sort=-rss | head -30'
case $PKG in
  dpkg) cmdout "$H/pkg/dpkg-l.txt" 'dpkg -l'; cmdout "$H/pkg/holds-audit.txt" 'apt-mark showhold; echo "--- dpkg --audit"; dpkg --audit';;
  *)    cmdout "$H/pkg/rpm-qa.txt" 'rpm -qa --last'; cmdout "$H/pkg/dnf-history.txt" 'dnf history list 2>/dev/null | head -50';;
esac
CMSH_BIN=$(command -v cmsh 2>/dev/null)
CMD_BIN=$(systemctl show cmd -p ExecStart --value 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1)
[ -x "${CMD_BIN:-}" ] || CMD_BIN=$(ls /cm/local/apps/cmd/sbin/cmd 2>/dev/null)
cmdout "$H/libs.txt" "for b in $CMSH_BIN $CMD_BIN; do echo \"== \$b\"; ldd \"\$b\" 2>&1 | grep -E 'not found|dcgm' ; done
echo '== libdcgm*'; find / -xdev -name 'libdcgm*.so*' 2>/dev/null
echo '== ldconfig -p | dcgm'; ldconfig -p 2>/dev/null | grep -i dcgm
echo '== pakiety dcgm'; (dpkg -l 2>/dev/null || rpm -qa 2>/dev/null) | grep -iE 'dcgm|datacenter-gpu-manager'"
cmdout "$H/services.txt" 'systemctl --failed --no-pager; for u in cmd containerd kubelet etcd docker nvidia-dcgm dcgm nv-hostengine; do echo; systemctl status "$u" --no-pager -l 2>&1 | head -25; done'
for u in cmd containerd kubelet etcd; do cmdout "$H/journal/$u.txt" "journalctl -u $u -b --no-pager -n 3000 -o short-iso"; done
cmdout "$H/journal/kernel.txt" 'journalctl -k -b --no-pager -o short-iso | tail -n 3000'
cmdout "$H/journal/errors.txt" 'journalctl -b -p err --no-pager -o short-iso | tail -n 3000'
cmdout "$H/journal/boots.txt" 'journalctl --list-boots --no-pager | tail -10'

CMSH_OK=0
if [ -n "$CMSH_BIN" ] && tmo 30 cmsh -c "device; status" >"$H/cmsh-device-status.txt" 2>&1 && ! grep -qiE 'error while loading|cannot open shared|unable to connect' "$H/cmsh-device-status.txt"; then
  CMSH_OK=1
  hdr "Head node: zapytania cmsh"
  cmdout "$H/cmsh.txt" 'for c in "device; list" "kubernetes; list" "configurationoverlay; list" "main; versioninfo"; do echo "=== $c"; timeout 60 cmsh -c "$c"; done'
  for n in $(awk '/\[/{print $1}' "$H/cmsh-device-status.txt"); do
    cmdout "$H/cmsh-services/$n.txt" "timeout 60 cmsh -c 'device; use $n; services; status'"
  done
else
  warn "cmsh nie działa - pomijam zapytania cmsh ($(head -2 "$H/cmsh-device-status.txt" 2>/dev/null | tr '\n' ' '))"
fi
if have kubectl || [ -d /cm/local/apps/kubernetes ]; then
  cmdout "$H/k8s.txt" 'export KUBECONFIG=${KUBECONFIG:-/root/.kube/config}; command -v kubectl >/dev/null || { . /etc/profile.d/modules.sh 2>/dev/null; module load kubernetes 2>/dev/null; }
    for a in "get nodes -o wide" "get pods -A -o wide" "get events -A --sort-by=.lastTimestamp"; do echo "=== kubectl $a"; kubectl --request-timeout=15s $a 2>&1 | tail -200; done'
fi

# ------------------------------------------------------------------ węzły ----
if [ "$NO_NODES" = 0 ]; then
  if [ -z "$NODES" ] && [ "$CMSH_OK" = 1 ]; then
    NODES=$(awk -v h="$HOST" '/\[/ && $1!=h && /\[ *UP *\]/ {print $1}' "$H/cmsh-device-status.txt" | xargs)
  fi
  [ -n "$NODES" ] || info "Brak listy węzłów (cmsh nie działa?) - podaj --node N, żeby zebrać logi z węzłów"
  for n in $NODES; do
    hdr "Węzeł $n"
    D=$WORKDIR/nodes/$n; mkdir -p "$D"
    if ! nssh "$n" true 2>/dev/null; then warn "$n: brak ssh - pomijam"; echo "brak ssh" >"$D/UNREACHABLE"; continue; fi
    nssh "$n" 'uname -a; uptime; free -m; df -hT / /var /run 2>/dev/null; echo; systemctl --failed --no-pager; for u in containerd kubelet; do echo; systemctl status $u --no-pager -l 2>&1 | head -20; done; echo; lsmod | grep -E "^(overlay|br_netfilter) "' 2>&1 | mask_secrets >"$D/system.txt"
    for u in containerd kubelet; do nssh "$n" "journalctl -u $u -b --no-pager -n 2000 -o short-iso" 2>&1 | mask_secrets >"$D/journal-$u.txt"; done
    nssh "$n" 'journalctl -k -b --no-pager -o short-iso | tail -n 1500' 2>&1 | mask_secrets >"$D/journal-kernel.txt"
    nssh "$n" 'tail -n 500 /var/log/apt/history.log 2>/dev/null; tail -n 300 /var/log/dpkg.log 2>/dev/null; tail -n 300 /var/log/dnf.rpm.log 2>/dev/null' >"$D/pkg-logs.txt" 2>&1
    nssh "$n" 'cat /cm/local/apps/containerd/var/etc/config.toml' 2>/dev/null | mask_secrets >"$D/containerd-config.toml"
  done
fi

# ---------------------------------------------------------------- wnioski ----
hdr "Wnioski"
printf '%-5s | %-45s | %s\n' STAN SPRAWDZENIE SZCZEGÓŁY >>"$REPORT"

# 1. brakujące biblioteki cmsh/cmd
miss=$(grep -v '^###' "$H/libs.txt" | grep 'not found' | awk '{print $1}' | sort -u | xargs)
if [ -n "$miss" ]; then check FAIL "Biblioteki cmsh/cmd" "brak: $miss (zob. head/libs.txt)"
else check PASS "Biblioteki cmsh/cmd" "ldd bez braków"; fi
[ "$CMSH_OK" = 1 ] && check PASS "cmsh" "działa" || check FAIL "cmsh" "nie działa: $(grep -m1 -iE 'error|cannot|unable' "$H/cmsh-device-status.txt" 2>/dev/null | cut -c1-150)"
st=$(systemctl is-active cmd 2>/dev/null); [ "$st" = active ] && check PASS "Usługa cmd" "active" || check FAIL "Usługa cmd" "${st:-?}"

# 2. operacje pakietowe w oknie analizy (apt history.log)
if [ "$PKG" = dpkg ]; then
  zall "${BCM_APT_HISTORY:-/var/log/apt/history.log}" | awk -v since="$SINCE" '
    /^Start-Date:/ { d=$2" "$3; cmd=""; req=""; next }
    /^Commandline:/ { sub(/^Commandline: /,""); cmd=$0; next }
    /^Requested-By:/ { sub(/^Requested-By: /,""); req=$0; next }
    /^(Remove|Purge|Install|Upgrade|Downgrade|Reinstall):/ {
      if (d < since) next
      op=$1; sub(/:$/,"",op); $1=""
      printf "%s|%s|%s|%s|%s\n", d, op, cmd, req, $0 }' >"$WORKDIR/pkg-ops.txt"
  {
    echo "Operacje apt od $SINCE (data | operacja | polecenie | kto | pakiety):"
    cut -c1-600 "$WORKDIR/pkg-ops.txt"
  } >"$WORKDIR/pkg-ops-readable.txt"
  rem=$(awk -F'|' '$2=="Remove" || $2=="Purge"' "$WORKDIR/pkg-ops.txt")
  crit='(^|[ ,])(cm-[a-z0-9.-]+|cmdaemon|datacenter-gpu-manager[a-z0-9.-]*|[a-z0-9.-]*dcgm[a-z0-9.-]*|nvidia-[a-z0-9.-]+|libnvidia-[a-z0-9.-]+|cuda-[a-z0-9.-]+)[: ]'
  if [ -z "$rem" ]; then check PASS "Usunięcia pakietów (apt, $DAYS dni)" "brak"
  else
    while IFS='|' read -r d op c r p; do
      hit=$(grep -oE "$crit" <<<" $p" | sed -E 's/^[ ,]//; s/[: ]$//' | sort -u | xargs)
      if [ -n "$hit" ]; then check FAIL "$op $d" "polecenie: '${c:-?}'${r:+ ($r)} usunęło: $hit"
      else check WARN "$op $d" "polecenie: '${c:-?}' usunęło $(awk -F'\\), ' '{print NF}' <<<"$p") pakiet(ów) (zob. pkg-ops-readable.txt)"; fi
    done <<<"$rem"
  fi
  dg=$(zall /var/log/dpkg.log | awk -v since="$SINCE" '($1" "$2) >= since' | grep -iE ' (remove|purge|upgrade|install) [^ ]*(dcgm|datacenter-gpu-manager)' | tail -5)
  [ -n "$dg" ] && check WARN "dpkg: zmiany DCGM" "$(tr '\n' ';' <<<"$dg" | cut -c1-400)"
else
  check INFO "Operacje pakietowe" "RHEL: zob. head/pkg/dnf-history.txt i dnf.rpm.log"
fi

# 3. OOM
oom=$(grep -iE 'out of memory|oom-kill|killed process' "$H/journal/kernel.txt" | grep -oE 'Killed process [0-9]+ \([^)]+\)|task=[^ ,]+' | sort | uniq -c | sort -rn | head -5 | xargs)
[ -n "$oom" ] && check FAIL "OOM (head)" "jądro zabijało procesy: $oom" || check PASS "OOM (head)" "brak"

# 4. kreator
wl=$(ls -1t /var/log/cm-kubernetes-setup.log 2>/dev/null | head -1)
if [ -n "$wl" ]; then
  check INFO "Kreator K8s: ostatni etap" "$(grep -E '#### stage:' "$wl" | tail -1 | sed 's/^#* *//')"
  e=$(grep -iE 'error|failed|not ready|timed out|timeout' "$wl" | grep -vi 'ignore' | tail -3 | cut -c1-200 | tr '\n' ';')
  [ -n "$e" ] && check WARN "Kreator K8s: ostatnie błędy" "$e"
fi

# 5. containerd i usługi
for u in containerd kubelet etcd; do
  s=$(systemctl is-active "$u" 2>/dev/null); [ -n "$s" ] && [ "$s" != inactive ] && check INFO "$u (head)" "$s"
done
f=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | xargs)
[ -n "$f" ] && check WARN "Nieudane jednostki systemd (head)" "$f"
for n in $NODES; do
  D=$WORKDIR/nodes/$n; [ -f "$D/UNREACHABLE" ] && { check WARN "$n" "brak ssh"; continue; }
  s=$(grep -m1 -E 'Active:' "$D/system.txt" 2>/dev/null | sed 's/^ *//'); check INFO "$n: containerd" "${s:-?}"
  oomn=$(grep -ciE 'out of memory|oom-kill' "$D/journal-kernel.txt" 2>/dev/null); [ "${oomn:-0}" -gt 0 ] && check WARN "$n: OOM" "$oomn wpisów"
done

# ---------------------------------------------------------------- archiwa ----
hdr "Archiwa"
tar czf "$OUT/$NAME.tgz" -C "$OUT" "$NAME" && ok "Do wysłania (sekrety zamaskowane): $OUT/$NAME.tgz ($(du -h "$OUT/$NAME.tgz" | cut -f1))"
SECTGZ=
if [ "${#SECFILES[@]}" -gt 0 ]; then
  ( umask 077; tar czf "$OUT/$NAME-SECRET.tgz" -C / "${SECFILES[@]}" ) && chmod 600 "$OUT/$NAME-SECRET.tgz" && SECTGZ=$OUT/$NAME-SECRET.tgz
  warn "Oryginalne configi (z hasłami/kluczami): $OUT/$NAME-SECRET.tgz - NIE wysyłaj; skopiuj na jump host przed revertem."
  info "Po revercie: tar xzf $NAME-SECRET.tgz -C /   (odtwarza pliki pod ich ścieżkami), potem cm-kubernetes-setup -c /root/cm-kubernetes-setup.conf"
fi
echo
cat "$REPORT"
info "Skopiuj na jump host (np. WinSCP): $OUT/$NAME.tgz${SECTGZ:+ i $SECTGZ}"
