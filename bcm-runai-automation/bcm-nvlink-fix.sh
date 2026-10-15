#!/bin/bash
# bcm-nvlink-fix.sh - diagnoza i naprawa problemów NVLink zgłaszanych przez BCM/DCGM
# (np. health check gpu_health_nvlink = FAIL: "GPU 0's NvLink link 0 is currently down").
#
# Domyślnie TYLKO DIAGNOZA - niczego nie zmienia. Zmiany wyłącznie z --apply <akcja>.
#
# Użycie (jako root na aktywnym head node):
#   ./bcm-nvlink-fix.sh [--node N]... [--apply AKCJA] [--yes]
#
# Węzły: z --node; bez niej - węzły z FAIL w health checkach NVLink (latesthealthdata),
# a gdy takich nie ma - wszystkie węzły UP z GPU.
#
# Akcje (--apply):
#   mute        wyłącz health check(i) NVLink w BCM (CAŁY KLASTER) - gdy linki nie mogą działać,
#               np. VM z częścią płyty HGX (werdykt VM_PARTIAL_BOARD)
#   unmute      włącz je z powrotem
#   fm-restart  restart nvidia-fabricmanager na węźle (systemy z NVSwitch, werdykt FM_PROBLEM)
#   gpu-reset   reset GPU (nvidia-smi -r) po zatrzymaniu usług trzymających GPU;
#               przerywa, jeśli na GPU działają procesy lub węzeł jest w Kubernetes
#   reboot      reboot węzła przez cmsh i czekanie na UP
#
# Werdykty diagnozy:
#   OK                     wszystkie linki aktywne (FAIL w BCM może być nieaktualny)
#   NO_NVLINK              sterownik nie raportuje linków (GPU PCIe) - health check NVLink nie ma sensu -> mute
#   VM_PARTIAL_BOARD       VM bez NVSwitchy - linki prowadzą do GPU/NVSwitchy poza VM; w VM nienaprawialne -> mute
#   FM_PROBLEM             NVSwitch widoczny, Fabric Manager nie działa albo wersja != sterownik -> fm-restart
#   LINK_DOWN_RECOVERABLE  bare metal, linki nieaktywne, bez błędów -> gpu-reset albo reboot
#   HW_ERRORS              niezerowe liczniki replay/recovery/CRC -> sprzęt (nvidia-bug-report.sh, serwis)

set -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -r "$SCRIPT_DIR/lib/common.sh" ] || { echo "Brak $SCRIPT_DIR/lib/common.sh - sklonuj całe repozytorium." >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

NODES=; ACTION=; YES=0
while [ $# -gt 0 ]; do
  case $1 in
    --node) NODES="$NODES $2"; shift;;
    --apply) ACTION=$2; shift;;
    --yes) YES=1;;
    -h|--help) sed -n '2,32p' "$0"; exit 0;;
    *) echo "Nieznana opcja: $1 (zob. --help)" >&2; exit 2;;
  esac; shift
done
case ${ACTION:-} in ''|mute|unmute|fm-restart|gpu-reset|reboot) ;; *) echo "Nieznana akcja: $ACTION (zob. --help)" >&2; exit 2;; esac
export YES

[ "$(id -u)" = 0 ] || die "Uruchom jako root."
have cmsh || { [ -x /cm/local/apps/cmd/bin/cmsh ] && PATH=$PATH:/cm/local/apps/cmd/bin; }
have cmsh || die "Nie znaleziono cmsh - to nie wygląda na head node BCM."

TS=$(date +%Y%m%d-%H%M%S)
WORKDIR=${BCM_OUT_DIR:-/root}/bcm-nvlink-fix-$TS
mkdir -p "$WORKDIR"; chmod 700 "$WORKDIR"
LOG_FILE=$WORKDIR.log; REPORT=$WORKDIR/report.txt
export WORKDIR LOG_FILE REPORT
info "Log: $LOG_FILE"

is_link_check() { grep -qiE 'nvlink|link' <<<"$*"; }

# ------------------------------------------------------------ wybór węzłów ---
discover_devices; discover_status
up_compute() {
  while IFS=$'\t' read -r t h _; do
    is_compute_type "$t" || continue
    s=$(awk -F'\t' -v h="$h" '$1==h{print $2}' "$WORKDIR/status.tsv")
    [ "${s%% *}" = UP ] && echo "$h"
  done <"$WORKDIR/devices.tsv"
}
if [ -z "$NODES" ]; then
  for h in $(up_compute); do
    health_fails "$h" | while IFS='|' read -r m _ i; do is_link_check "$m $i" && { echo "$h"; break; }; done
  done >"$WORKDIR/nodes"
  NODES=$(sort -u "$WORKDIR/nodes" | xargs)
  if [ -n "$NODES" ]; then
    info "Węzły z FAIL w health checkach NVLink: $NODES"
  else
    for h in $(up_compute); do
      c=$(gpu_probe "$h" | cut -d'|' -f1); [ "${c:-0}" -gt 0 ] && NODES="$NODES $h"
    done
    NODES=$(xargs <<<"$NODES")
    [ -n "$NODES" ] || die "Brak węzłów z GPU w stanie UP (podaj --node)."
    info "Brak FAIL NVLink w BCM - diagnozuję wszystkie węzły UP z GPU: $NODES"
  fi
fi

# ------------------------------------------------------------- diagnoza ------
declare -A VERDICT
diagnose() {
  local n=$1 lp virt vmode pg ns sg drv lt la li nt es fms fmv m p i v
  hdr "Węzeł $n"
  lp=$(gpu_link_probe "$n") || true
  [ -n "$lp" ] || { err "$n: brak odpowiedzi (ssh?)"; VERDICT[$n]=UNREACHABLE; return; }
  virt=$(kv_get virt "$lp"); vmode=$(kv_get vmode "$lp")
  pg=$(kv_get pci_gpus "$lp"); ns=$(kv_get nvswitch "$lp"); sg=$(kv_get smi_gpus "$lp"); drv=$(kv_get drv "$lp")
  lt=$(kv_get link_total "$lp"); la=$(kv_get link_active "$lp"); li=$(kv_get link_inactive "$lp")
  nt=$(kv_get nv_topo "$lp"); es=$(kv_get err_sum "$lp"); fms=$(kv_get fm_state "$lp"); fmv=$(kv_get fm_ver "$lp")
  info "Wirtualizacja: ${virt:-?}${vmode:+ (tryb GPU: $vmode)}"
  info "GPU: lspci ${pg:-0}, nvidia-smi ${sg:-0}; NVSwitch w lspci: ${ns:-0}; sterownik ${drv:-?}"
  info "NVLink: linki ${lt:-0}, aktywne ${la:-0}, nieaktywne ${li:-0}; GPU<->GPU przez NVLink (topo): ${nt:-?}; błędy replay/recovery/CRC: ${es:-0}"
  info "Fabric Manager: ${fms:-brak} ${fmv:+(wersja $fmv)}"
  while IFS='|' read -r m p i; do
    [ -n "$m" ] && is_link_check "$m $i" && warn "BCM health FAIL: ${m}${p:+:$p} - $i"
  done < <(health_fails "$n")

  # surowe dane do logu
  nrun "$n" >>"$LOG_FILE" 2>&1 <<'EOS'
echo "----- nvidia-smi topo -m"; nvidia-smi topo -m
echo "----- nvidia-smi nvlink -s"; nvidia-smi nvlink -s
echo "----- nvidia-smi nvlink -e"; nvidia-smi nvlink -e
echo "----- lspci -nd 10de:"; lspci -nd 10de:
if command -v dcgmi >/dev/null 2>&1; then echo "----- dcgmi discovery -l"; dcgmi discovery -l; fi
EOS

  local vm=no where='bare metal'; case ${virt:-none} in none|unknown|'') ;; *) vm=yes; where="VM $virt";; esac
  if [ "${es:-0}" -gt 0 ]; then v=HW_ERRORS
  elif [ "${ns:-0}" -gt 0 ] && { [ "$fms" != active ] || { [ -n "$fmv" ] && [ -n "$drv" ] && [[ $fmv != "$drv"* ]]; }; }; then v=FM_PROBLEM
  elif [ "${lt:-0}" -eq 0 ]; then v=NO_NVLINK
  elif [ "${li:-0}" -eq 0 ]; then v=OK
  elif [ $vm = yes ] && [ "${ns:-0}" -eq 0 ]; then v=VM_PARTIAL_BOARD
  else v=LINK_DOWN_RECOVERABLE
  fi
  VERDICT[$n]=$v
  case $v in
    OK) ok "Werdykt: OK - wszystkie linki NVLink aktywne. FAIL w BCM może być nieaktualny - sprawdź za kilka minut: cmsh -c 'device; use $n; latesthealthdata'";;
    NO_NVLINK) warn "Werdykt: NO_NVLINK - sterownik nie raportuje linków NVLink (GPU PCIe albo NVLink wyłączony). Health check NVLink nie ma tu sensu -> --apply mute";;
    VM_PARTIAL_BOARD)
      warn "Werdykt: VM_PARTIAL_BOARD - węzeł to VM (${virt}) bez NVSwitchy, a nieaktywne linki NVLink prowadzą do GPU/NVSwitchy płyty, których nie ma w tej VM."
      [ "$nt" = yes ] && info "GPU w VM są połączone NVLinkiem między sobą (aktywne linki: ${la:-0}); nieaktywne prowadzą poza VM."
      info "Tego nie da się naprawić z wnętrza VM. NVLink zadziała tylko na bare metal albo przy passthrough całej płyty (wszystkie GPU + NVSwitche, Fabric Manager w VM)."
      info "Kubernetes i Run:ai działają bez NVLink (komunikacja między GPU przez PCIe). Żeby BCM nie zgłaszał stałego FAIL -> --apply mute";;
    FM_PROBLEM)
      warn "Werdykt: FM_PROBLEM - NVSwitch widoczny (${ns}), Fabric Manager: ${fms:-brak}, wersja FM ${fmv:-?} vs sterownik ${drv:-?}."
      if [ -n "$fmv" ] && [ -n "$drv" ] && [[ $fmv != "$drv"* ]]; then
        local img; img=$(cmsh_q "device; use $n; get softwareimage" | head -1)
        warn "Wersja FM różni się od sterownika - sam restart nie pomoże. Napraw obraz ${img:-<obraz>} (skrypt tego NIE robi automatycznie):"
        cat <<EOF | tee -a "$LOG_FILE" >&2
   cm-chroot-sw-img /cm/images/${img:-<obraz>}
     apt-cache policy 'nvidia-fabricmanager*'          # znajdź pakiet w wersji $drv
     apt-get install --allow-downgrades <pakiet>=<wersja $drv>   # FM (i nscq/imex, jeśli są) = wersja sterownika
     apt-mark hold <pakiet>
     exit
   cmsh -c "device; imageupdate -n $n -w"
   ./bcm-nvlink-fix.sh --node $n --apply fm-restart
EOF
      else
        info "-> --apply fm-restart"
      fi;;
    LINK_DOWN_RECOVERABLE) warn "Werdykt: LINK_DOWN_RECOVERABLE - linki nieaktywne bez błędów ($where). Spróbuj --apply gpu-reset (bez obciążenia GPU), a gdy nie pomoże: --apply reboot";;
    HW_ERRORS) err "Werdykt: HW_ERRORS - liczniki błędów NVLink = $es. Prawdopodobnie problem sprzętowy: uruchom na węźle nvidia-bug-report.sh i zgłoś do serwisu (bez auto-naprawy).";;
  esac
}

for n in $NODES; do diagnose "$n"; done
[ -z "$ACTION" ] && { hdr "Koniec diagnozy"; info "Niczego nie zmieniono. Akcje: --apply mute|unmute|fm-restart|gpu-reset|reboot (zob. --help)"; exit 0; }

# --------------------------------------------------------------- akcje -------
link_measurables() {
  local all names m
  all=$(cmsh_q "monitoring measurable; list healthcheck")
  names=$(for n in $NODES; do health_fails "$n"; done | while IFS='|' read -r m _ i; do is_link_check "$m $i" && echo "$m"; done | sort -u)
  [ -n "$names" ] || names=$(awk 'tolower($1) ~ /nvlink/ {print $1}' <<<"$all" | sort -u)
  for m in $names; do
    if awk -v m="$m" 'tolower($1)==tolower(m){f=1} END{exit !f}' <<<"$all"; then echo "$m"
    else warn "Measurable $m nie występuje w 'monitoring measurable; list healthcheck' - pomijam"; fi
  done
}

act_mute() {
  local val=$1 ms m
  ms=$(link_measurables | xargs)
  [ -n "$ms" ] || die "Nie znaleziono health checków NVLink do zmiany."
  if [ "$val" = yes ]; then
    for n in $NODES; do
      case ${VERDICT[$n]} in VM_PARTIAL_BOARD|NO_NVLINK) ;; *) warn "$n: werdykt ${VERDICT[$n]} - wyciszenie ukryje realny problem, który da się naprawić.";; esac
    done
  fi
  warn "Ustawienie 'disabled $val' dla: $ms dotyczy CAŁEGO KLASTRA (wszystkich węzłów)."
  confirm "Kontynuować?" || die "Przerwano."
  for m in $ms; do
    info "$m: disabled przed = $(cmsh_q "monitoring measurable; use $m; get disabled" | head -1)"
    cmsh_q "monitoring measurable; use $m; set disabled $val; commit" | tee -a "$LOG_FILE" >&2
    ok "$m: disabled teraz = $(cmsh_q "monitoring measurable; use $m; get disabled" | head -1)"
  done
  info "Status węzła odświeży się po kolejnym próbkowaniu (kilka minut): cmsh -c 'device; status'"
  [ "$val" = yes ] && info "Cofnięcie: ./bcm-nvlink-fix.sh --apply unmute"
}

act_fm_restart() {
  local n=$1
  [ "${VERDICT[$n]}" = FM_PROBLEM ] || warn "$n: werdykt ${VERDICT[$n]} - restart FM raczej nie pomoże."
  confirm "$n: zrestartować nvidia-fabricmanager?" || return
  nrun "$n" 2>&1 <<'EOS' | tee -a "$LOG_FILE" >&2
systemctl restart nvidia-fabricmanager; sleep 5
echo "nvidia-fabricmanager: $(systemctl is-active nvidia-fabricmanager)"
journalctl -u nvidia-fabricmanager -n 15 --no-pager 2>/dev/null
EOS
}

act_gpu_reset() {
  local n=$1 rc
  [ "${VERDICT[$n]}" = LINK_DOWN_RECOVERABLE ] || warn "$n: werdykt ${VERDICT[$n]} - reset GPU raczej nie pomoże."
  confirm "$n: zresetować wszystkie GPU (nvidia-smi -r)? Działające obliczenia zostaną przerwane." || return
  nrun "$n" 2>&1 <<'EOS' | tee -a "$LOG_FILE" >&2
p=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -c .)
[ "$p" -gt 0 ] && { echo "PRZERWANO: na GPU działa $p proces(ów) - zatrzymaj je albo użyj --apply reboot"; exit 3; }
systemctl is-active -q kubelet && { echo "PRZERWANO: kubelet działa - pody GPU Operatora trzymają GPU. Zrób drain węzła albo użyj --apply reboot"; exit 3; }
svcs=; for s in nvidia-dcgm dcgm nv-hostengine nvidia-persistenced nvidia-fabricmanager; do systemctl is-active -q "$s" 2>/dev/null && svcs="$svcs $s"; done
echo "Zatrzymuję:${svcs:- (nic)}"; [ -n "$svcs" ] && systemctl stop $svcs
nvidia-smi -r; rc=$?
for s in nvidia-fabricmanager nvidia-persistenced nv-hostengine dcgm nvidia-dcgm; do case " $svcs " in *" $s "*) systemctl start "$s";; esac; done
if [ $rc -ne 0 ]; then echo "Reset nieudany (rc=$rc). Procesy trzymające GPU:"; fuser -v /dev/nvidia* 2>&1 | head -20; fi
exit $rc
EOS
  rc=$?
  [ $rc -eq 0 ] && ok "$n: reset GPU wykonany" || warn "$n: reset GPU nieudany (rc=$rc) - rozważ --apply reboot"
}

act_reboot() {
  local n=$1 i s
  confirm "$n: zrestartować węzeł (cmsh device reboot)?" || return
  cmsh_q "device; reboot $n" | tee -a "$LOG_FILE" >&2
  info "$n: czekam na DOWN, potem UP (do 20 min)"
  sleep 60
  for i in $(seq 1 38); do
    s=$(cmsh_q "device; status $n" | awk -F'[][]' '{gsub(/ /,"",$2); print $2; exit}')
    [ "$s" = UP ] && { ok "$n: UP"; return 0; }
    sleep 30
  done
  warn "$n: nie wrócił do UP w 20 min - sprawdź konsolę/BMC"; return 1
}

hdr "Akcja: $ACTION"
case $ACTION in
  mute)   act_mute yes;;
  unmute) act_mute no;;
  fm-restart|gpu-reset|reboot)
    for n in $NODES; do
      [ "${VERDICT[$n]}" = UNREACHABLE ] && { warn "$n: pomijam (brak odpowiedzi)"; continue; }
      case $ACTION in fm-restart) act_fm_restart "$n";; gpu-reset) act_gpu_reset "$n";; reboot) act_reboot "$n";; esac
    done
    hdr "Ponowna diagnoza"
    for n in $NODES; do diagnose "$n"; done;;
esac
info "Log: $LOG_FILE"
