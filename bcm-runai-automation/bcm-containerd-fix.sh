#!/bin/bash
# bcm-containerd-fix.sh - diagnoza i naprawa błędu "containerd socket not ready"
# z cm-kubernetes-setup (BCM 10/11: pakiet cm-containerd, rola generic::containerd,
# config /cm/local/apps/containerd/var/etc/config.toml + conf.d/*.toml).
#
# Domyślnie TYLKO DIAGNOZA - niczego nie zmienia.
#
# Użycie (jako root na aktywnym head node):
#   ./bcm-containerd-fix.sh [--node N]... [--fix] [--resume] [--conf PLIK] [--yes]
#
#   --node N    węzeł do sprawdzenia (można powtarzać); domyślnie ten head node + wszystkie węzły,
#               dla których cmd ma usługę containerd (rola generic::containerd z kreatora)
#   --fix       napraw wykrytą przyczynę (każdy krok z potwierdzeniem), potem diagnoza od nowa
#   --resume    gdy containerd działa: wznów instalację K8s z zapisanego configu kreatora
#               (najpierw --remove częściowo utworzonego klastra, potem cm-kubernetes-setup -c)
#   --conf P    config kreatora (domyślnie szukany w /root i $BCM_DEPLOY_BASE)
#   --yes       bez pytań (nie dotyczy --remove klastra)
#
# Werdykty:
#   NOT_INSTALLED    brak cm-containerd (binarki BCM)              -> --fix: instalacja pakietu (head)
#   FOREIGN_RUNTIME  unit/socket należy do containerd z Dockera/dystrybucji albo CRI wyłączony
#                    w /etc/containerd/config.toml                 -> --fix: wyłączenie i usunięcie obcych pakietów
#   CONFIG_INVALID   containerd nie parsuje configu / drop-inu     -> --fix: obcy drop-in do backupu
#   DISK_FULL        brak miejsca/inodów (/, /var, /run, root containerd) -> --fix: apt/dnf clean, journal vacuum
#   STALE_SOCKET     plik socketu bez procesu nasłuchującego       -> --fix: usunięcie pliku + restart
#   KERNEL_MODULES   brak modułu overlay                           -> --fix: modprobe + modules-load.d
#   ROLE_MISSING     cmd nie ma usługi containerd dla węzła (kreator nie przypisał roli) -> --resume
#   SERVICE_DOWN     usługa masked/failed/inactive albo socket nie odpowiada -> --fix: unmask/reset-failed/restart
#   CRI_BROKEN       containerd działa, plugin CRI nie              -> --fix: restart; dalej: journal
#   CMD_NOT_UP       systemd: containerd działa, ale cmd pokazuje usługę jako nie-UP (na to czeka kreator:
#                    "all containerd services are active")       -> --fix: restart przez cmd
#   NODE_DOWN        węzeł z rolą containerd nie jest UP w BCM    -> włącz/napraw węzeł
#   SOCKET_MISMATCH  kreator czeka na inny socket niż ten, na którym słucha containerd
#   OK               containerd i CRI działają (był timeout)        -> --resume
#
# Wynik: /root/bcm-containerd-fix-<data>/report.txt (+ raw/), log obok.

set -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -r "$SCRIPT_DIR/lib/common.sh" ] || { echo "Brak $SCRIPT_DIR/lib/common.sh - sklonuj całe repozytorium." >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

NODES=; FIX=0; RESUME=0; CONF=; YES=0
while [ $# -gt 0 ]; do
  case $1 in
    --node) NODES="$NODES $2"; shift;;
    --fix) FIX=1;;
    --resume) RESUME=1;;
    --conf) CONF=$2; shift;;
    --yes) YES=1;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0;;
    *) echo "Nieznana opcja: $1 (zob. --help)" >&2; exit 2;;
  esac; shift
done
export YES

[ "$(id -u)" = 0 ] || die "Uruchom jako root."
have cmsh || { [ -x /cm/local/apps/cmd/bin/cmsh ] && PATH=$PATH:/cm/local/apps/cmd/bin; }
have cmsh || die "Nie znaleziono cmsh - to nie wygląda na head node BCM."
detect_os

BCM_CTD=/cm/local/apps/containerd
BASE=${BCM_DEPLOY_BASE:-/root/bcm-deploy}
K8S_SETUP_LOG=${K8S_SETUP_LOG:-/var/log/cm-kubernetes-setup.log}
TS=$(date +%Y%m%d-%H%M%S)
WORKDIR=${BCM_OUT_DIR:-/root}/bcm-containerd-fix-$TS
mkdir -p "$WORKDIR/raw"; chmod 700 "$WORKDIR"
LOG_FILE=$WORKDIR.log; REPORT=$WORKDIR/report.txt
export WORKDIR LOG_FILE REPORT
info "Log: $LOG_FILE"

HEAD=$(hostname -s)
is_local() { [ "$1" = "$HEAD" ] || [ "$1" = "$(hostname)" ]; }
# Kreator czeka na containerd na WSZYSTKICH węzłach z rolą generic::containerd - bez --node
# bierzemy ten head node i każdy węzeł, dla którego cmd ma usługę containerd.
discover_devices; discover_status
dev_status() { awk -F'\t' -v h="$1" '$1==h{print $2; exit}' "$WORKDIR/status.tsv"; }
if [ -z "$NODES" ]; then
  NODES=$HEAD
  while IFS=$'\t' read -r _ h _; do
    [ -n "$h" ] && [ "$h" != "$HEAD" ] || continue
    cmsh_q "device; use $h; services; list" | awk '$1=="containerd"{f=1} END{exit !f}' && NODES="$NODES $h"
  done <"$WORKDIR/devices.tsv"
  info "Węzły z usługą containerd w BCM: $NODES"
fi
NODES=$(echo "$NODES" | xargs -n1 | awk '!s[$0]++' | xargs)

# --------------------------------------------------------------- sonda -------
# Wynik: linie klucz=wartość, potem sekcje @@CFGERR, @@STATUS, @@JOURNAL.
_ctd_probe_script() {
  echo "B=$BCM_CTD"
  cat <<'PROBE'
export LC_ALL=C PATH=$PATH:/usr/sbin:/sbin
kv() { printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//')"; }
owner() {
  [ -e "$1" ] || return
  if command -v dpkg-query >/dev/null 2>&1; then { dpkg -S "$1" 2>/dev/null || dpkg -S "${1#/usr}" 2>/dev/null; } | head -1 | cut -d: -f1
  elif command -v rpm >/dev/null 2>&1; then rpm -qf --qf '%{NAME}\n' "$1" 2>/dev/null | grep -v 'not owned' | head -1; fi
}
for p in LoadState ActiveState SubState UnitFileState Result NRestarts FragmentPath DropInPaths; do
  kv "u_$p" "$(systemctl show containerd -p "$p" --value 2>/dev/null)"
done
frag=$(systemctl show containerd -p FragmentPath --value 2>/dev/null)
kv unit_owner "$(owner "$frag")"
es=$(systemctl show containerd -p ExecStart --value 2>/dev/null)
bin=$(sed -n 's/.*path=\([^ ;]*\).*/\1/p' <<<"$es" | head -1)
argv=$(sed -n 's/.*argv\[\]=\([^;]*\).*/\1/p' <<<"$es" | head -1)
kv exec "$argv"
[ -x "$B/current/bin/containerd" ] && kv bcm_bin yes || kv bcm_bin no
is_elf() { [ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; }
# ścieżki "/.../containerd" (bez shim/ctr) i pliki .toml w tekście
ctd_paths() { grep -oE '(^|[ =:"'\''`(])/[^ ;"'\''`$(){}]*/containerd([ ;"'\''`)]|$)' | sed -E 's/^[ =:"'\''`(]//; s/[ ;"'\''`)]$//'; }
toml_of()  { grep -oE -- '(--config|-c)[ =]+["'\'']?/[^ "'\'';]+\.toml' | head -1 | sed -E 's/^(--config|-c)[ =]+["'\'']?//'; }
# BCM uruchamia containerd przez wrapper (np. /bin/bash -c '...' albo skrypt) - rozwiń do prawdziwej binarki
src=execstart; wrap=; txt=$argv
case ${bin##*/} in bash|sh|dash|zsh|env|ksh)
  wrap=$bin; src=wrapper
  for t in $(grep -oE '/[^ ;"'\''`$()]+' <<<"$argv"); do      # skrypt wywołany przez powłokę
    [ "$t" = "$wrap" ] && continue
    [ -f "$t" ] && [ "$(head -c2 "$t" 2>/dev/null)" = '#!' ] && { wrap="$wrap $t"; txt="$txt
$(cat "$t" 2>/dev/null)"; }
  done
  bin=
  for t in $(ctd_paths <<<"$txt"); do [ -x "$t" ] && { bin=$t; break; }; done;;
esac
if [ "$src" = execstart ] && [ -f "$bin" ] && ! is_elf "$bin"; then
  # ExecStart to sam skrypt (nie ELF) - szukaj binarki w jego treści
  [ -f "$bin" ] && { wrap=$bin; src=wrapper; txt="$txt
$(cat "$bin" 2>/dev/null)"; bin=; for t in $(ctd_paths <<<"$txt"); do [ -x "$t" ] && { bin=$t; break; }; done; }
fi
if [ -z "$bin" ]; then                                       # z działającego procesu
  for p in $(pgrep -x containerd 2>/dev/null); do bin=$(readlink -f "/proc/$p/exe"); [ -n "$bin" ] && { src=process; break; }; done
fi
[ -n "$bin" ] || { src=default; [ -x "$B/current/bin/containerd" ] && bin=$B/current/bin/containerd || bin=$(command -v containerd); }
kv wrapper "$wrap"; kv bin_src "$src"
cfg=$(toml_of <<<"$txt")
[ -z "$cfg" ] && [ -n "$wrap" ] && grep -q "$B" <<<"$txt" && cfg=$B/var/etc/config.toml
if [ -z "$cfg" ]; then
  case $bin in "$B"/*) cfg=$B/var/etc/config.toml;; *) cfg=/etc/containerd/config.toml;; esac
fi
kv bin "$bin"; kv bin_owner "$(owner "$bin")"
[ -x "$bin" ] && kv bin_ver "$(timeout 10 "$bin" --version 2>/dev/null | head -1)"
kv cfg "$cfg"; [ -f "$cfg" ] && kv cfg_exists yes || kv cfg_exists no
top() { awk -v k="$1" '/^[[:space:]]*\[/{exit} $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {sub(/^[^=]*=[[:space:]]*/,""); gsub(/["\047]/,""); print; exit}' "$cfg" 2>/dev/null; }
root=$(top root); state=$(top state); root=${root:-/var/lib/containerd}; state=${state:-/run/containerd}
sock=$(awk '/^[[:space:]]*\[/{s=$0} s ~ /^[[:space:]]*\[grpc\]/ && /^[[:space:]]*address[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/,""); gsub(/["\047]/,""); print; exit}' "$cfg" 2>/dev/null)
sock=${sock#unix://}; sock=${sock:-/run/containerd/containerd.sock}
kv root "$root"; kv state "$state"; kv sock "$sock"
drop=
for g in $(grep -E '^[[:space:]]*imports' "$cfg" 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"'); do
  for f in $g; do [ -f "$f" ] && drop="$drop $f"; done
done
kv dropins "$drop"
# shellcheck disable=SC2086
kv cri_disabled_in "$(grep -lE 'disabled_plugins.*"(cri|io\.containerd\.grpc\.v1\.cri)"' "$cfg" $drop /etc/containerd/config.toml 2>/dev/null | sort -u)"
cerr=$(mktemp); crc=
if [ -x "$bin" ] && [ -f "$cfg" ]; then timeout 20 "$bin" --config "$cfg" config dump >/dev/null 2>"$cerr"; crc=$?; fi
kv cfg_rc "$crc"
# socket
if [ -S "$sock" ]; then kv sock_exists socket; elif [ -e "$sock" ]; then kv sock_exists other; else kv sock_exists no; fi
lpid=$(ss -xlpn 2>/dev/null | awk -v s="$sock" 'index($0, " "s" ")' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
kv lst_pid "$lpid"; [ -n "$lpid" ] && kv lst_exe "$(readlink -f "/proc/$lpid/exe")"
pr=; for p in $(pgrep -x containerd 2>/dev/null); do pr="$pr $p:$(readlink -f /proc/$p/exe)"; done
kv procs "$pr"
# działanie
C=$B/current/bin/ctr; [ -x "$C" ] || C=$(command -v ctr)
kv ctr "$C"
if [ -n "$C" ] && [ -S "$sock" ]; then
  v=$(timeout 10 "$C" --address "$sock" version 2>&1); kv ctr_rc $?
  kv srv_ver "$(awk '/Server:/{f=1} f && /Version:/{print $2; exit}' <<<"$v")"
  pl=$(timeout 10 "$C" --address "$sock" plugins ls 2>/dev/null)
  kv cri "$(awk '$2=="cri" || $1 ~ /\.cri\./ {printf "%s:%s ", $2, $NF}' <<<"$pl")"
  kv snap_overlay "$(awk '$1 ~ /snapshotter/ && $2=="overlayfs" {print $NF}' <<<"$pl")"
else kv ctr_rc none; fi
if command -v crictl >/dev/null 2>&1 && [ -S "$sock" ]; then timeout 15 crictl --runtime-endpoint "unix://$sock" info >/dev/null 2>&1; kv crictl_rc $?; fi
# pakiety
pk=
for p in cm-containerd containerd containerd.io docker.io docker-ce docker-ce-cli moby-engine moby-containerd podman-docker runc; do
  if command -v dpkg-query >/dev/null 2>&1; then v=$(dpkg-query -W -f='${Status} ${Version}' "$p" 2>/dev/null | awk '/install ok installed/{print $4}')
  else v=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$p" 2>/dev/null | grep -v 'not installed'); fi
  [ -n "$v" ] && pk="$pk $p=$v"
done
kv pkgs "$pk"
kv docker_state "docker.service:$(systemctl is-active docker.service 2>/dev/null) docker.socket:$(systemctl is-active docker.socket 2>/dev/null)"
dc=0; systemctl is-active -q docker.service 2>/dev/null && command -v docker >/dev/null 2>&1 && dc=$(timeout 10 docker ps -q 2>/dev/null | wc -l)
kv docker_containers "$dc"
# zasoby
dk=
for p in / /var /run /cm/local "$root" "$state"; do
  q=$p; while [ ! -e "$q" ]; do q=$(dirname "$q"); done
  l=$(df -Pk "$q" 2>/dev/null | awk 'NR==2{printf "%s:%d:%s", $6, $4/1024, $5}')
  i=$(df -Pi "$q" 2>/dev/null | awk 'NR==2{print $5}')
  dk="$dk $p:$l:${i:--}:$(stat -f -c %T "$q" 2>/dev/null)"
done
kv disk "$dk"
q=$root; while [ ! -e "$q" ]; do q=$(dirname "$q"); done
rfs=$(stat -f -c %T "$q" 2>/dev/null); kv root_fs "$rfs"
[ "$rfs" = xfs ] && command -v xfs_info >/dev/null 2>&1 && kv root_ftype "$(xfs_info "$(df -P "$q" | awk 'NR==2{print $6}')" 2>/dev/null | grep -oE 'ftype=[01]')"
mm=; for m in overlay br_netfilter; do [ -d "/sys/module/$m" ] || grep -qw "$m" /proc/filesystems 2>/dev/null || mm="$mm $m"; done
kv mods_missing "$mm"
k=$(uname -r); kv kernel "$k"
[ -d "/lib/modules/$k" ] && kv kmod_dir yes || kv kmod_dir no
kv kernels "$(ls /lib/modules 2>/dev/null | xargs)"
kv ko_overlay "$(modinfo -n overlay 2>/dev/null)"
kv ko_br_netfilter "$(modinfo -n br_netfilter 2>/dev/null)"
kv mp_overlay "$(modprobe -n -v overlay 2>&1 | tail -1)"
if command -v dpkg-query >/dev/null 2>&1; then
  kv kmod_pkg "linux-modules-$k:$(dpkg-query -W -f='${Status}' "linux-modules-$k" 2>/dev/null | awk '{print $3}')"
  kv kmod_cand "$(apt-cache policy "linux-modules-$k" 2>/dev/null | awk '/Candidate:/{print $2}')"
else
  kv kmod_pkg "$(rpm -q "kernel-modules-core-$k" "kernel-core-$k" 2>/dev/null | grep -v 'not installed' | head -1)"
fi
kv mem_avail_mb "$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')"
command -v getenforce >/dev/null 2>&1 && kv selinux "$(getenforce 2>/dev/null)"
echo "@@CFGERR"; tail -n 8 "$cerr"; rm -f "$cerr"
echo "@@STATUS"; systemctl status containerd --no-pager -l 2>&1 | head -25
echo "@@JOURNAL"; journalctl -u containerd -b --no-pager -n 150 -o short-iso 2>&1
PROBE
}

probe_file() { echo "$WORKDIR/raw/probe-$1.txt"; }
# pv <węzeł> <klucz>
pv() { awk -v k="$2" '/^@@/{exit} index($0, k"=")==1 {print substr($0, length(k)+2); exit}' "$(probe_file "$1")"; }
# psec <węzeł> <sekcja>
psec() { awk -v s="@@$2" '$0==s{f=1; next} /^@@/{f=0} f' "$(probe_file "$1")"; }

probe() {
  local n=$1 f k; f=$(probe_file "$n")
  k=$(( ${PROBE_CNT[$n]:-0} + 1 )); PROBE_CNT[$n]=$k
  [ "$k" -gt 1 ] && cp "$f" "${f%.txt}.$((k-1)).txt"
  # CTD_PROBE_DIR: gotowe wyniki sondy (testy): probe-<węzeł>.<runda>.txt albo probe-<węzeł>.txt
  local m=
  if [ -n "${CTD_PROBE_DIR:-}" ]; then
    for j in $(seq "$k" -1 1); do [ -r "$CTD_PROBE_DIR/probe-$n.$j.txt" ] && { m=$CTD_PROBE_DIR/probe-$n.$j.txt; break; }; done
    [ -n "$m" ] || { [ -r "$CTD_PROBE_DIR/probe-$n.txt" ] && m=$CTD_PROBE_DIR/probe-$n.txt; }
  fi
  if [ -n "$m" ]; then cp "$m" "$f"; else _ctd_probe_script | nrun "$n" >"$f" 2>&1; fi
  grep -q '^u_LoadState=' "$f"
}

# Strona BCM: usługa w cmd, overlaye z rolą containerd, pliki zarządzane przez rolę
bcm_side() {
  local n=$1 o
  o=$(cmsh_q "device; use $n; services; list"); echo "$o" >"$WORKDIR/raw/cmsh-services-$n.txt"
  if grep -qiE 'not found|unknown|error' <<<"$o" && ! grep -qw containerd <<<"$o"; then SVC_CMD[$n]=unknown
  elif awk '$1=="containerd"{f=1} END{exit !f}' <<<"$o"; then SVC_CMD[$n]=yes; else SVC_CMD[$n]=no; fi
  cmsh_q "device; use $n; services; status" >"$WORKDIR/raw/cmsh-services-status-$n.txt"
  SVC_STAT[$n]=$(cmd_svc_status "$n" "$WORKDIR/raw/cmsh-services-status-$n.txt")
}
# Stan usługi containerd tak, jak widzi go cmd (na to czeka kreator): UP / FAILED / STOPPED / ...
cmd_svc_status() {
  local f=${2:-}
  [ -n "$f" ] || { f=$WORKDIR/raw/cmsh-svc-now-$1.txt; cmsh_q "device; use $1; services; status" >"$f"; }
  awk 'tolower($0) ~ /^[[:space:]]*containerd[ .:]/ {
         if (match($0, /\[[^]]*\]/)) { s=substr($0, RSTART+1, RLENGTH-2); gsub(/^ +| +$/, "", s); print s }
         else { $1=""; sub(/^ +/, ""); print }
         exit }' "$f"
}
managed_files() {
  [ -n "${MANAGED+x}" ] && { echo "$MANAGED"; return; }
  local ov nm fn
  MANAGED=
  cmsh_q "configurationoverlay; list" >"$WORKDIR/raw/cmsh-overlays.txt"
  for ov in $(awk 'tolower($0) ~ /containerd/ {print $1}' "$WORKDIR/raw/cmsh-overlays.txt"); do
    for nm in $(cmsh_q "configurationoverlay; use $ov; roles; use generic::containerd; configurations; list" | awk 'NR>1 && $1!~/^-+$/ && $1!="Name" {print $1}'); do
      fn=$(cmsh_q "configurationoverlay; use $ov; roles; use generic::containerd; configurations; use $nm; get filename" | head -1)
      [ -n "$fn" ] && MANAGED="$MANAGED $ov:$nm:$fn"
    done
  done
  echo "$MANAGED"
}

# Ścieżka socketu, na który czeka kreator (z jego logu)
wizard_sock() { [ -r "$K8S_SETUP_LOG" ] && grep -i 'containerd' "$K8S_SETUP_LOG" | grep -oE '(unix://)?/[^ "'\'',)]+\.sock' | sed 's|^unix://||' | tail -1; }

# ------------------------------------------------------------- werdykt -------
declare -A VERDICT WHY SVC_CMD SVC_STAT PROBE_CNT TRIED
# CRI zgłoszony przez ctr i wszystkie jego pluginy "ok"
cri_ok() { local c; c=$(pv "$1" cri | tr ' ' '\n' | grep .); [ -n "$c" ] && ! grep -qvE '^[^ ]+:ok$' <<<"$c"; }
# Pliki wyłączające CRI, które containerd faktycznie czyta (config z ExecStart + jego imports)
active_nocri() {
  local f c; c=" $(pv "$1" cfg) $(pv "$1" dropins) "
  for f in $(pv "$1" cri_disabled_in); do [[ $c == *" $f "* ]] && echo "$f"; done
}
disk_full() {  # -> lista "ścieżka(mount): wolne/użycie/inody" dla zapełnionych FS
  local e p m a u i num='^[0-9]+$'
  for e in $(pv "$1" disk); do
    IFS=: read -r p m a u i _ <<<"$e"
    u=${u%\%}; i=${i%\%}
    [[ $a =~ $num ]] || a=999999; [[ $u =~ $num ]] || u=0; [[ $i =~ $num ]] || i=0
    [ "$a" -lt 500 ] || [ "$u" -ge 98 ] || [ "$i" -ge 95 ] || continue
    echo "$m: wolne ${a}MB, zajęte ${u}%, inody ${i}% ($p)"
  done | awk -F: '!s[$1]++'
}
verdict() {
  local n=$1 bin act sock lex foreign="" cri dis f full
  local W; W=$(pv "$n" wrapper)
  bin=$(pv "$n" bin); act=$(pv "$n" u_ActiveState); sock=$(pv "$n" sock); lex=$(pv "$n" lst_exe)
  [ -n "$lex" ] && [[ $lex != "$BCM_CTD"/* ]] && foreign="socket $sock trzyma $lex (pid $(pv "$n" lst_pid))"
  [ "$(pv "$n" bcm_bin)" = yes ] && [ -n "$bin" ] && [[ $bin != "$BCM_CTD"/* ]] && [ "$(pv "$n" bin_src)" != default ] \
    && ! [[ ${bin##*/} =~ ^(bash|sh|dash|zsh|ksh|env)$ ]] \
    && foreign="${foreign:+$foreign; }unit containerd ($(pv "$n" u_FragmentPath), pakiet $(pv "$n" unit_owner)) uruchamia $bin${W:+ (przez $W)} zamiast binarki BCM"
  dis=$(active_nocri "$n")
  for f in $dis; do [ "$f" = "$(pv "$n" cfg)" ] && [[ $f != "$BCM_CTD"/* ]] && foreign="${foreign:+$foreign; }aktywny config $f wyłącza plugin CRI (domyślny config containerd.io/Dockera)"; done
  full=$(disk_full "$n")
  cri=$(pv "$n" cri)
  if [ "$(pv "$n" bcm_bin)" != yes ]; then VERDICT[$n]=NOT_INSTALLED; WHY[$n]="brak $BCM_CTD/current/bin/containerd (pakiet cm-containerd); pakiety: $(pv "$n" pkgs)"
  elif [ -n "$foreign" ]; then VERDICT[$n]=FOREIGN_RUNTIME; WHY[$n]=$foreign
  elif [ "$(pv "$n" cfg_exists)" != yes ]; then VERDICT[$n]=CONFIG_INVALID; WHY[$n]="brak pliku $(pv "$n" cfg) (tworzy go cmd z roli generic::containerd)"
  elif [ -n "$(pv "$n" cfg_rc)" ] && [ "$(pv "$n" cfg_rc)" != 0 ]; then VERDICT[$n]=CONFIG_INVALID; WHY[$n]="containerd config dump: $(psec "$n" CFGERR | grep -v '^$' | tail -2 | tr '\n' ' ')"
  elif [ -n "$dis" ]; then VERDICT[$n]=CONFIG_INVALID; WHY[$n]="disabled_plugins z \"cri\" w: $dis"
  elif [ -n "$full" ]; then VERDICT[$n]=DISK_FULL; WHY[$n]=$(echo "$full" | tr '\n' ';')
  elif [ "$(pv "$n" sock_exists)" != no ] && [ -z "$(pv "$n" lst_pid)" ] && [ "$act" != active ]; then VERDICT[$n]=STALE_SOCKET; WHY[$n]="$sock istnieje ($(pv "$n" sock_exists)), ale nikt na nim nie słucha"
  elif [[ " $(pv "$n" mods_missing) " == *" overlay "* ]] && ! { [ "$(pv "$n" snap_overlay)" = ok ] && cri_ok "$n"; }; then
    VERDICT[$n]=KERNEL_MODULES; WHY[$n]="moduł jądra overlay niezaładowany (kernel $(pv "$n" kernel)) - snapshotter overlayfs i CRI nie działają"
    if [ "$(pv "$n" kmod_dir)" = no ]; then
      WHY[$n]="${WHY[$n]}; BRAK /lib/modules/$(pv "$n" kernel): działający kernel nie ma modułów (kernel zaktualizowany bez rebootu albo usunięty pakiet modułów). Zainstalowane: $(pv "$n" kernels)"
    elif [ -z "$(pv "$n" ko_overlay)" ]; then
      WHY[$n]="${WHY[$n]}; pliku overlay.ko nie ma dla tego kernela (pakiet $(pv "$n" kmod_pkg)); modprobe: $(pv "$n" mp_overlay)"
    else WHY[$n]="${WHY[$n]}; moduł jest ($(pv "$n" ko_overlay)) - wystarczy go załadować"; fi
  elif [ "${SVC_CMD[$n]}" = no ] && [ "$act" != active ]; then VERDICT[$n]=ROLE_MISSING; WHY[$n]="cmd nie ma usługi containerd dla $n (rola generic::containerd nieprzypisana) i usługa nie działa"
  elif [ "$(pv "$n" u_LoadState)" = masked ] || [ "$act" != active ] || [ "$(pv "$n" ctr_rc)" != 0 ]; then
    VERDICT[$n]=SERVICE_DOWN; WHY[$n]="unit $(pv "$n" u_LoadState)/$act/$(pv "$n" u_SubState), wynik $(pv "$n" u_Result), restartów $(pv "$n" u_NRestarts), socket $(pv "$n" sock_exists), ctr rc=$(pv "$n" ctr_rc)"
  elif ! cri_ok "$n"; then VERDICT[$n]=CRI_BROKEN; WHY[$n]="pluginy CRI: ${cri:-brak w ctr plugins ls}"
  else VERDICT[$n]=OK; WHY[$n]="containerd $(pv "$n" srv_ver) słucha na $sock, CRI: $cri"
  fi
  if [ "${VERDICT[$n]}" = OK ] && [ "${SVC_CMD[$n]}" = yes ] && [ "${SVC_STAT[$n]:-?}" != UP ]; then
    VERDICT[$n]=CMD_NOT_UP; WHY[$n]="systemd: containerd działa, ale cmd pokazuje usługę jako '${SVC_STAT[$n]:-brak statusu}' - kreator czeka na UP w cmd"
  fi
  if [ "${VERDICT[$n]}" = OK ] && is_local "$n"; then
    local ws; ws=$(wizard_sock)
    [ -n "$ws" ] && [ "$ws" != "$sock" ] && { VERDICT[$n]=SOCKET_MISMATCH; WHY[$n]="kreator (log) czeka na $ws, containerd słucha na $sock"; }
  fi
}

# Wzorce z journala -> wskazówki
journal_hints() {
  local n=$1 j; j=$(psec "$n" JOURNAL)
  local -a pat=(
    'failed to load TOML|toml:|invalid.*config|unknown key|failed to parse|config version'
    'address already in use'
    'no space left on device'
    'overlayfs.*(not supported|failed|error)|failed to mount overlay|snapshotter.*(not supported|skip)'
    'permission denied|operation not permitted|apparmor|selinux'
    'context deadline exceeded|timeout|timed out'
    'failed to load plugin|plugin.*(failed|error)|failed to initialize'
    'level=(fatal|error)|containerd: ')
  local -a msg=(
    'błąd parsowania configu (zob. CONFIG_INVALID, raw/probe-*.txt @@CFGERR)'
    'socket zajęty przez inny proces (obcy containerd / Docker)'
    'brak miejsca na dysku'
    'problem z overlayfs (moduł overlay / FS pod root containerd)'
    'odmowa dostępu (AppArmor/SELinux/uprawnienia)'
    'timeout przy starcie (wolny dysk/NFS, przeciążony węzeł)'
    'plugin containerd nie wstał'
    'inne błędy containerd')
  local i l hit=0
  for i in "${!pat[@]}"; do
    [ "$i" -eq 7 ] && [ "$hit" = 1 ] && break
    l=$(grep -iE "${pat[$i]}" <<<"$j" | tail -3)
    [ -n "$l" ] || continue
    hit=1; warn "$n: journal - ${msg[$i]}:"
    sed 's/^/      /' <<<"$l" | cut -c1-260 | tee -a "$LOG_FILE" >&2
  done
  [ "$hit" = 1 ] || info "$n: journal containerd bez typowych błędów (pełny: raw/probe-$n.txt, sekcja @@JOURNAL)"
}

diagnose() {
  local n=$1 W
  hdr "Diagnoza containerd: $n"
  local ds; ds=$(dev_status "$n")
  if ! is_local "$n" && [ -n "$ds" ] && [ "${ds%% *}" != UP ]; then
    VERDICT[$n]=NODE_DOWN; WHY[$n]="węzeł w BCM ma status '$ds' - kreator czeka na containerd na każdym węźle klastra"
    check FAIL "$n: NODE_DOWN" "${WHY[$n]}"; return
  fi
  if ! probe "$n"; then VERDICT[$n]=UNREACHABLE; WHY[$n]="sonda nie zadziałała: $(tail -2 "$(probe_file "$n")" | tr '\n' ' ')"; check FAIL "$n: sonda" "${WHY[$n]}"; return; fi
  bcm_side "$n"; W=$(pv "$n" wrapper)
  info "$n: unit $(pv "$n" u_FragmentPath) (pakiet: $(pv "$n" unit_owner)), stan $(pv "$n" u_LoadState)/$(pv "$n" u_ActiveState)/$(pv "$n" u_SubState), restartów $(pv "$n" u_NRestarts)"
  info "$n: ExecStart: $(pv "$n" exec)${W:+ -> wrapper: $W}"
  info "$n: binarka $(pv "$n" bin) (źródło: $(pv "$n" bin_src)) [$(pv "$n" bin_ver)], config $(pv "$n" cfg), drop-iny: $(pv "$n" dropins)"
  info "$n: socket $(pv "$n" sock) - $(pv "$n" sock_exists), nasłuch: pid=$(pv "$n" lst_pid) $(pv "$n" lst_exe); procesy containerd: $(pv "$n" procs)"
  info "$n: kernel $(pv "$n" kernel), /lib/modules: $(pv "$n" kmod_dir), overlay.ko: $(pv "$n" ko_overlay), brak modułów:$(pv "$n" mods_missing)"
  info "$n: ctr version rc=$(pv "$n" ctr_rc) serwer=$(pv "$n" srv_ver); CRI: $(pv "$n" cri); snapshotter overlayfs: $(pv "$n" snap_overlay); crictl rc=$(pv "$n" crictl_rc)"
  info "$n: pakiety:$(pv "$n" pkgs); $(pv "$n" docker_state)"
  info "$n: usługa containerd w cmd: ${SVC_CMD[$n]}, stan w cmd: ${SVC_STAT[$n]:-?}; dysk:$(pv "$n" disk); RAM wolne $(pv "$n" mem_avail_mb) MB"
  verdict "$n"
  local w
  [ -n "$(pv "$n" pkgs | grep -oE '(^| )(containerd|containerd\.io|docker\.io|docker-ce|moby-engine)=')" ] \
    && [ "${VERDICT[$n]}" != FOREIGN_RUNTIME ] && warn "$n: zainstalowane pakiety Dockera/containerd spoza BCM:$(pv "$n" pkgs) - mogą kolidować z cm-containerd"
  [ -n "$(pv "$n" mods_missing)" ] && [ "${VERDICT[$n]}" != KERNEL_MODULES ] && warn "$n: niezaładowane moduły jądra:$(pv "$n" mods_missing) (Kubernetes wymaga overlay i br_netfilter; overlay.ko: $(pv "$n" ko_overlay))"
  local rmb; rmb=$(pv "$n" disk | tr ' ' '\n' | awk -F: -v r="$(pv "$n" root)" '$1==r{print $3}')
  [ -n "$rmb" ] && [ "$rmb" -lt 10240 ] 2>/dev/null && warn "$n: pod $(pv "$n" root) tylko ${rmb} MB wolnego - obrazy K8s/Run:ai potrzebują kilkunastu GB"
  [ "$(pv "$n" root_fs)" = nfs ] && warn "$n: root containerd ($(pv "$n" root)) jest na NFS - overlayfs nie działa na NFS"
  [ "$(pv "$n" root_ftype)" = ftype=0 ] && warn "$n: XFS pod $(pv "$n" root) ma ftype=0 - overlayfs wymaga ftype=1"
  [ "${SVC_CMD[$n]}" = no ] && [ "${VERDICT[$n]}" != ROLE_MISSING ] && warn "$n: cmd nie zarządza usługą containerd (brak roli generic::containerd)"
  w=$(pv "$n" crictl_rc); [ -n "$w" ] && [ "$w" != 0 ] && [ "${VERDICT[$n]}" = OK ] && warn "$n: crictl info rc=$w"
  case ${VERDICT[$n]} in
    OK) check PASS "$n: containerd" "${WHY[$n]}";;
    CMD_NOT_UP) check FAIL "$n: ${VERDICT[$n]}" "${WHY[$n]}"
        info "      szczegóły w cmd: cmsh -c \"device; use $n; services; use containerd; show\"; log cmd na $n: /var/log/cmdaemon (grep -i containerd)";;
    *)  check FAIL "$n: ${VERDICT[$n]}" "${WHY[$n]}"; journal_hints "$n";;
  esac
}

# ------------------------------------------------------------- naprawy -------
# nexec <węzeł> <opis>  (skrypt bash na stdin)
nexec() {
  local n=$1 d=$2; info "$n: $d"
  if is_local "$n"; then bash -s 2>&1 | tee -a "$LOG_FILE"
  else ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$n" 'bash -s' 2>&1 | tee -a "$LOG_FILE"; fi
  return "${PIPESTATUS[0]}"
}

restart_ctd() {
  local n=$1
  if [ "${SVC_CMD[$n]}" = yes ]; then
    info "$n: restart containerd przez cmd"; cmsh_q "device; use $n; services; restart containerd" | tee -a "$LOG_FILE" >&2
  else
    echo 'systemctl daemon-reload; systemctl reset-failed containerd 2>/dev/null; systemctl restart containerd' | nexec "$n" "systemctl restart containerd"
  fi
}
wait_ctd() {
  local n=$1 i ctr sock; ctr=$(pv "$n" ctr); sock=$(pv "$n" sock)
  [ -n "$ctr" ] || ctr=$BCM_CTD/current/bin/ctr
  for i in $(seq 1 45); do
    printf 'timeout 5 %q --address %q version >/dev/null 2>&1\n' "$ctr" "$sock" | nrun "$n" >/dev/null 2>&1 && break
    sleep 2
  done
  [ "$i" -lt 45 ] || { warn "$n: containerd nie odpowiada na $sock po 90 s"; return 1; }
  ok "$n: containerd odpowiada na $sock"
  [ "${SVC_CMD[$n]}" = yes ] || return 0
  local st
  for i in $(seq 1 30); do st=$(cmd_svc_status "$n"); [ "$st" = UP ] && { ok "$n: cmd: containerd UP"; return 0; }; sleep 2; done
  warn "$n: cmd nadal pokazuje containerd jako '${st:-brak}' po 60 s"; return 1
}

image_hint() {
  local n=$1 what=$2 img path
  img=$(cmsh_q "device; use $n; get softwareimage" | head -1)
  path=$(cmsh_q "softwareimage; use $img; get path" | head -1)
  warn "$n: pakiety węzła pochodzą z obrazu ${img:-?} - zmiana na żywym węźle zniknie po reprowizji. Popraw obraz:"
  cat <<EOF | tee -a "$LOG_FILE" >&2
      cm-chroot-sw-img ${path:-/cm/images/<obraz>}
        $what
        exit
      cmsh -c "device; use $n; imageupdate -w"
EOF
}

pm_install() { case $PKG in dpkg) echo "apt-get install -y $*";; *) echo "(dnf install -y $* || yum install -y $*)";; esac; }

fix_NOT_INSTALLED() {
  local n=$1
  if ! is_local "$n"; then image_hint "$n" "$(pm_install cm-containerd)"; return 1; fi
  confirm "$n: zainstalować cm-containerd?" || return 1
  { case $PKG in dpkg) echo 'apt-get update -q';; esac; pm_install cm-containerd; } | nexec "$n" "instalacja cm-containerd"
}

fix_FOREIGN_RUNTIME() {
  local n=$1 pk p rm="" sim
  [ "$(pv "$n" docker_containers)" -gt 0 ] 2>/dev/null && { err "$n: w Dockerze działa $(pv "$n" docker_containers) kontener(ów) - zatrzymaj je/przenieś, zanim usuniesz Dockera"; return 1; }
  pk=$(pv "$n" pkgs)
  for p in containerd containerd.io docker.io docker-ce docker-ce-cli moby-engine moby-containerd podman-docker; do
    [[ " $pk " == *" $p="* ]] && rm="$rm $p"
  done
  if ! is_local "$n"; then image_hint "$n" "${rm:+$(case $PKG in dpkg) echo "apt-get remove -y$rm";; *) echo "dnf remove -y$rm";; esac)}"; return 1; fi
  if [ -n "$rm" ]; then
    case $PKG in
      dpkg) sim=$(apt-get -s remove $rm 2>&1); grep -E '^Remv ' <<<"$sim" | awk '{print $2}' >"$WORKDIR/remove-sim.txt";;
      *)    sim=$(rpm -e --test $rm 2>&1); grep -oE 'needed by [^ ]+' <<<"$sim" | awk '{print $3}' >"$WORKDIR/remove-sim.txt";;
    esac
    info "$n: usunięcie obcych pakietów:$rm pociągnie: $(xargs <"$WORKDIR/remove-sim.txt")"
    if grep -qE '^cm-|cmdaemon' "$WORKDIR/remove-sim.txt"; then
      err "$n: usunięcie$rm zabrałoby pakiety BCM ($(grep -E '^cm-|cmdaemon' "$WORKDIR/remove-sim.txt" | xargs)) - przerywam, napraw ręcznie"; return 1
    fi
  fi
  confirm "$n: zatrzymać i wyłączyć Dockera / obcy containerd${rm:+, usunąć pakiety$rm} i przeinstalować cm-containerd?" || return 1
  {
    echo 'for u in docker.socket docker.service; do systemctl disable --now "$u" 2>/dev/null; done'
    echo 'systemctl stop containerd 2>/dev/null'
    for p in $(pv "$n" procs); do case ${p#*:} in "$BCM_CTD"/*) ;; *) echo "kill ${p%%:*} 2>/dev/null";; esac; done
    [ -n "$rm" ] && case $PKG in dpkg) echo "DEBIAN_FRONTEND=noninteractive apt-get remove -y$rm";; *) echo "dnf remove -y$rm";; esac
    case $PKG in dpkg) echo 'apt-get install -y --reinstall cm-containerd';; *) echo 'dnf reinstall -y cm-containerd';; esac
    echo 'systemctl daemon-reload'
  } | nexec "$n" "usunięcie obcego runtime"
}

fix_CONFIG_INVALID() {
  local n=$1 bad="" m bk=${BCM_OUT_DIR:-/root}/bcm-containerd-fix-$TS-backup
  printf 'mkdir -p %q && cp -a %q %q/ 2>/dev/null; for f in %s; do cp -a "$f" %q/; done\n' "$bk" "$(pv "$n" cfg)" "$bk" "$(pv "$n" dropins)" "$bk" \
    | nexec "$n" "backup configu containerd do $bk"
  bad=$(psec "$n" CFGERR | grep -oE '/[^ :"]+\.toml' | tail -1)
  [ -n "$bad" ] || bad=$(active_nocri "$n" | grep -vxF "$(pv "$n" cfg)" | head -1)
  if [ -z "$bad" ]; then
    err "$n: nie da się wskazać wadliwego pliku. Błąd: $(psec "$n" CFGERR | tail -3 | tr '\n' ' ')"; return 1
  fi
  m=$(managed_files | xargs -n1 | awk -F: -v f="$bad" '$3==f' | head -1)
  if [ "$bad" = "$(pv "$n" cfg)" ] || [ -n "$m" ]; then
    err "$n: wadliwy plik $bad jest zarządzany przez BCM${m:+ (overlay:konfiguracja ${m%:*})} - popraw go w cmsh, cmd nadpisze ręczne zmiany:"
    [ -n "$m" ] && info "      cmsh -c \"configurationoverlay; use ${m%%:*}; roles; use generic::containerd; configurations; use $(cut -d: -f2 <<<"$m"); show\""
    info "      Błąd: $(psec "$n" CFGERR | tail -3 | tr '\n' ' ')"
    return 1
  fi
  confirm "$n: przenieść drop-in spoza BCM $bad do $bk?" || return 1
  printf 'mv -f %q %q/\n' "$bad" "$bk" | nexec "$n" "przeniesienie $bad"
}

fix_DISK_FULL() {
  local n=$1
  confirm "$n: wyczyścić cache pakietów i journal (do 500 MB)?" || return 1
  { case $PKG in dpkg) echo 'apt-get clean';; *) echo 'dnf clean all 2>/dev/null || yum clean all';; esac
    echo 'journalctl --vacuum-size=500M'
    echo 'df -h / /var /run 2>/dev/null'; } | nexec "$n" "czyszczenie"
  warn "$n: jeśli to nie wystarczy, największe katalogi: du -xsh /var/* /root/* 2>/dev/null | sort -h | tail"
}

fix_STALE_SOCKET() {
  local n=$1
  confirm "$n: usunąć osierocony $(pv "$n" sock) i zrestartować containerd?" || return 1
  printf 'rm -f %q\n' "$(pv "$n" sock)" | nexec "$n" "usunięcie socketu"
}

fix_KERNEL_MODULES() {
  local n=$1 k pkg cand; k=$(pv "$n" kernel)
  if [ -z "$(pv "$n" ko_overlay)" ]; then
    # Brak pliku modułu dla działającego kernela - przeinstaluj pakiet modułów albo reboot do zainstalowanego kernela
    if ! is_local "$n"; then warn "$n: kernel i moduły węzła pochodzą z obrazu - sprawdź kernel obrazu (cmsh: softwareimage; use <obraz>; get kernelversion) i zrób reboot węzła"; return 1; fi
    pkg=$(pv "$n" kmod_pkg); pkg=${pkg%%:*}; cand=$(pv "$n" kmod_cand)
    if [ "$PKG" = dpkg ] && [ -n "$cand" ] && [ "$cand" != "(none)" ]; then
      confirm "$n: zainstalować ponownie $pkg ($cand), żeby przywrócić moduły działającego kernela $k?" || return 1
      echo "apt-get install -y --reinstall $pkg" | nexec "$n" "instalacja $pkg" || return 1
    elif [ "$PKG" = rpm ]; then
      confirm "$n: zainstalować ponownie moduły kernela $k (kernel-modules-core/kernel-core)?" || return 1
      echo "dnf reinstall -y kernel-modules-core-$k 2>/dev/null || dnf reinstall -y kernel-core-$k" | nexec "$n" "reinstalacja modułów kernela" || return 1
    else
      err "$n: pakietu $pkg nie ma w repozytorium - modułów dla działającego kernela $k nie da się odtworzyć."
      info "      Zainstalowane kernele (/lib/modules): $(pv "$n" kernels)"
      info "      Rozwiązanie: reboot do zainstalowanego kernela (head node: zaplanuj okno, potem ./bcm-containerd-fix.sh --resume)"
      return 1
    fi
  fi
  confirm "$n: załadować moduły overlay i br_netfilter (na stałe w /etc/modules-load.d/k8s.conf)?" || return 1
  cat <<'EOF' | nexec "$n" "modprobe overlay br_netfilter" || { err "$n: modprobe overlay nie zadziałał (zob. log powyżej)"; return 1; }
for m in overlay br_netfilter; do
  modprobe -v "$m" || { echo "modprobe $m: błąd"; continue; }
  grep -qx "$m" /etc/modules-load.d/k8s.conf 2>/dev/null || echo "$m" >>/etc/modules-load.d/k8s.conf
done
[ -d /sys/module/overlay ] || grep -qw overlay /proc/filesystems
EOF
  is_local "$n" || warn "$n: na węźle z obrazu ustaw moduły w obrazie/kategorii BCM (kernel modules), inaczej znikną po reprowizji"
}

fix_SERVICE_DOWN() {
  local n=$1
  confirm "$n: odmaskować, zresetować i uruchomić containerd?" || return 1
  echo 'systemctl unmask containerd 2>/dev/null; systemctl reset-failed containerd 2>/dev/null; systemctl daemon-reload; systemctl enable containerd 2>/dev/null' \
    | nexec "$n" "unmask/reset-failed containerd"
}
fix_CRI_BROKEN() { confirm "$1: zrestartować containerd (CRI nie wstał)?"; }

fix_CMD_NOT_UP() { confirm "$1: zrestartować containerd przez cmd, żeby odświeżyć stan usługi (${SVC_STAT[$1]:-?})?"; }
fix_NODE_DOWN() { warn "$1: włącz/napraw węzeł (cmsh -c \"device; status $1\", konsola/BMC) albo usuń go z klastra w kreatorze; potem diagnoza od nowa"; return 1; }
fix_ROLE_MISSING()    { warn "$1: rolę generic::containerd przypisuje kreator - użyj --resume (usunięcie częściowego klastra + cm-kubernetes-setup -c)"; return 1; }
fix_SOCKET_MISMATCH() { warn "$1: containerd działa, ale na innym sockecie niż oczekuje kreator - wyślij raport (raw/probe-$1.txt, raw/wizard-log.txt)"; return 1; }

# ---------------------------------------------------------- uruchomienie -----
hdr "Kreator cm-kubernetes-setup"
if [ -r "$K8S_SETUP_LOG" ]; then
  tail -n 400 "$K8S_SETUP_LOG" >"$WORKDIR/raw/wizard-log.txt"
  info "Ostatni etap: $(grep -E '#### stage:' "$K8S_SETUP_LOG" | tail -1 | sed 's/^#* *//')"
  grep -n -iE 'error|fail|not ready|socket|traceback' "$K8S_SETUP_LOG" | tail -12 | cut -c1-260 | sed 's/^/      /' | tee -a "$LOG_FILE" >&2
  ws=$(wizard_sock); [ -n "$ws" ] && info "Socket, o którym mówi kreator: $ws"
else
  info "Brak $K8S_SETUP_LOG"
fi
CLUSTERS=$(k8s_clusters | xargs)
info "Klastry K8s w BCM: ${CLUSTERS:-brak}"

ROUNDS=1; [ "$FIX" = 1 ] && ROUNDS=3
for r in $(seq 1 "$ROUNDS"); do
  [ "$r" -gt 1 ] && hdr "Diagnoza po naprawie (runda $r)"
  for n in $NODES; do diagnose "$n"; done
  [ "$FIX" = 1 ] || break
  todo=; for n in $NODES; do case ${VERDICT[$n]} in OK|UNREACHABLE|NODE_DOWN) ;; *) todo="$todo $n";; esac; done
  [ -n "$todo" ] || break
  [ "$r" -eq "$ROUNDS" ] && break
  fixed=
  for n in $todo; do
    if [[ " ${TRIED[$n]:-} " == *" ${VERDICT[$n]} "* ]]; then
      warn "$n: naprawa ${VERDICT[$n]} już była i nie pomogła - nie powtarzam (zob. journal powyżej i raw/probe-$n.txt)"; continue
    fi
    TRIED[$n]="${TRIED[$n]:-} ${VERDICT[$n]}"
    hdr "Naprawa $n: ${VERDICT[$n]}"
    if "fix_${VERDICT[$n]}" "$n"; then
      restart_ctd "$n"; wait_ctd "$n"; fixed="$fixed $n"
    else warn "$n: ${VERDICT[$n]} - brak automatycznej naprawy albo przerwano"; fi
  done
  [ -n "$fixed" ] || break
done

# --------------------------------------------------------------- podsumowanie
hdr "Podsumowanie"
ready=1
for n in $NODES; do
  printf '  %-20s %-16s %s\n' "$n" "${VERDICT[$n]}" "${WHY[$n]}" | tee -a "$LOG_FILE" >&2
  case ${VERDICT[$n]} in OK|ROLE_MISSING) ;; *) ready=0;; esac
done
info "Raport: $REPORT, surowe dane: $WORKDIR/raw/"
if [ "$ready" = 0 ]; then
  opts=; for n in $NODES; do [ "$n" = "$HEAD" ] || opts="$opts --node $n"; done
  [ "$FIX" = 1 ] || info "Naprawa: ./bcm-containerd-fix.sh$opts --fix"
  info "Jeśli werdykt jest niejasny, wyślij $REPORT i $WORKDIR/raw/probe-*.txt"
  exit 1
fi

# --------------------------------------------------------------- wznowienie --
find_conf() {
  local f
  [ -n "$CONF" ] && { echo "$CONF"; return; }
  for f in /root/cm-kubernetes-setup.conf "$BASE/cm-kubernetes-setup.conf"; do [ -s "$f" ] && { echo "$f"; return; }; done
  for f in $(find /root /cm/shared/runai -maxdepth 1 -name '*.conf' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-); do
    case $f in *runai-setup*) continue;; esac
    grep -qi kubernetes "$f" 2>/dev/null && { echo "$f"; return; }
  done
}
hdr "Wznowienie instalacji Kubernetes"
CONFF=$(find_conf)
[ -n "$CONFF" ] && [ -s "$CONFF" ] || die "Nie znaleziono zapisanego configu kreatora - podaj --conf PLIK albo przejdź kreator ponownie (Save config & Exit)."
info "Config kreatora: $CONFF"
set -- $CLUSTERS
if [ $# -gt 1 ]; then die "W BCM jest kilka klastrów ($CLUSTERS) - usuń właściwy ręcznie: cm-kubernetes-setup --remove --cluster <nazwa> --yes-i-really-mean-it"; fi
CL=${1:-}
info "Kolejność:"
step=1
[ -n "$CL" ] && { info "  1. cm-kubernetes-setup --remove --cluster $CL --yes-i-really-mean-it   (częściowy klaster '$CL': role i config BCM, bez pakietów)"; step=2; }
info "  $step. cm-kubernetes-setup -c $CONFF"
[ "$RESUME" = 1 ] || { info "Uruchom ze skryptu: ./bcm-containerd-fix.sh --resume${CONF:+ --conf $CONF}  (najlepiej w screen)"; exit 0; }

[ -n "${STY:-}${TMUX:-}" ] || warn "Nie jesteś w screen/tmux - instalacja trwa 30-90 min, zerwanie SSH ją przerwie (screen -S k8s)."
cp -p "$CONFF" "$WORKDIR/$(basename "$CONFF").bak"; chmod 600 "$WORKDIR/$(basename "$CONFF").bak"
if [ -n "$CL" ]; then
  YES=0 confirm "Usunąć częściowo zainstalowany klaster '$CL' (cm-kubernetes-setup --remove)?" || die "Przerwano"
  cm-kubernetes-setup --remove --cluster "$CL" --yes-i-really-mean-it 2>&1 | tee -a "$LOG_FILE" "$WORKDIR/remove.out"
  [ "${PIPESTATUS[0]}" = 0 ] || die "--remove zakończył się błędem (log: $WORKDIR/remove.out)"
  if grep -qi 'reboot' "$WORKDIR/remove.out"; then
    warn "$(grep -i 'reboot' "$WORKDIR/remove.out" | head -2 | xargs)"
    warn "BCM zaleca reboot węzłów (sprzątanie sieci CNI). Bez niego nowa instalacja może trafić na stare interfejsy."
    confirm "Kontynuować instalację BEZ rebootu? (N = przerwij, zrób reboot workerów: cmsh -c \"device; reboot <węzeł>\", potem: cm-kubernetes-setup -c $CONFF)" \
      || { info "Po reboocie: cm-kubernetes-setup -c $CONFF"; exit 0; }
  fi
fi
confirm "Uruchomić cm-kubernetes-setup -c $CONFF?" || die "Przerwano"
cm-kubernetes-setup -c "$CONFF" 2>&1 | tee -a "$LOG_FILE"
rc=${PIPESTATUS[0]}
if [ "$rc" = 0 ] && k8s_clusters | grep -q .; then ok "Kubernetes zainstalowany. Dalej: ./bcm-deploy.sh --phase dns,certs,tune,validate"
elif [ "$rc" = 0 ]; then warn "cm-kubernetes-setup zakończył się (rc=0), ale klastra nie widać w 'cmsh -c \"kubernetes; list\"' - sprawdź $K8S_SETUP_LOG"; exit 1
else err "cm-kubernetes-setup rc=$rc - sprawdź $K8S_SETUP_LOG i uruchom ponownie diagnozę: ./bcm-containerd-fix.sh"; exit 1; fi
