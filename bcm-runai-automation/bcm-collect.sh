#!/bin/bash
# bcm-collect.sh - zbiera informacje o klastrze BCM i sprawdza prerequisites
# dla Kubernetes + NVIDIA Run:ai. TYLKO ODCZYT - niczego nie zmienia.
#
# Użycie (jako root na aktywnym head node):
#   ./bcm-collect.sh [--domain lab.internal] [--fqdn runai.lab.internal] [--no-ping] [--quick]
#
# Wynik: /root/bcm-collect-<host>-<data>/ oraz archiwum .tar.gz obok
#   report.txt       - czytelny raport z werdyktami PASS/WARN/FAIL
#   discovered.env   - wartości wykryte automatycznie (czyta je bcm-deploy.sh)
#   raw/             - surowe outputy komend (sekrety zamaskowane)

set -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -r "$SCRIPT_DIR/lib/common.sh" ] || { echo "Brak $SCRIPT_DIR/lib/common.sh - sklonuj całe repozytorium (git clone), nie pojedynczy plik." >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

QUICK=0
while [ $# -gt 0 ]; do
  case $1 in
    --domain) DOMAIN=$2; shift;;
    --fqdn)   RUNAI_FQDN=$2; shift;;
    --workers) WORKERS=$2; shift;;
    --lb-network) LB_NETWORK=$2; shift;;
    --quick)  QUICK=1;;
    -h|--help) sed -n '2,14p' "$0"; exit 0;;
    *) echo "Nieznana opcja: $1" >&2; exit 2;;
  esac; shift
done
export DOMAIN RUNAI_FQDN WORKERS LB_NETWORK

[ "$(id -u)" = 0 ] || die "Uruchom jako root."
have cmsh || { [ -x /cm/local/apps/cmd/bin/cmsh ] && PATH=$PATH:/cm/local/apps/cmd/bin; }
have cmsh || die "Nie znaleziono cmsh - to nie wygląda na head node BCM."

TS=$(date +%Y%m%d-%H%M%S)
WORKDIR=${BCM_OUT_DIR:-/root}/bcm-collect-$(hostname -s)-$TS
RAW=$WORKDIR/raw
mkdir -p "$RAW"; chmod 700 "$WORKDIR"
REPORT=$WORKDIR/report.txt
LOG_FILE=$WORKDIR/collect.log
export WORKDIR REPORT LOG_FILE

# raw <plik> <komenda...> - zapisuje output komendy (z maskowaniem sekretów)
raw() { local f=$1; shift; { echo "### $*"; tmo 180 "$@" 2>&1; } | mask_secrets >"$RAW/$f"; }
rawsh() { local f=$1; shift; { echo "### $*"; tmo 180 bash -c "$*" 2>&1; } | mask_secrets >"$RAW/$f"; }

{
  echo "BCM / Kubernetes / Run:ai - raport kolektora"
  echo "Host: $(hostname)   Data: $(date -Is)   Skrypt: $0"
  echo
  printf '%-5s | %-45s | %s\n' STAN SPRAWDZENIE SZCZEGÓŁY
  printf '%s\n' "------+-----------------------------------------------+---------------------------------------------"
} >"$REPORT"

# ============================================================== discovery ===
hdr "Wykrywanie środowiska (może potrwać kilka minut)"
discover_all

# ======================================================= 1. BCM i system ====
hdr "1. BCM i system operacyjny"
check INFO "System head node" "$OS_ID $OS_VER (rodzina: $OS_FAMILY, pakiety: $PKG), kernel $(uname -r)"
if [ -n "$BCM_RELEASE" ]; then
  check PASS "Wersja BCM" "$BCM_RELEASE (źródło: $BCM_SRC)"
else
  check FAIL "Wersja BCM" "nie udało się ustalić (cm-package-release-info / cmsh versioninfo / pakiet cmdaemon)"
fi
case $BCM_FLOW in
  flow_unknown) check FAIL "Ścieżka wdrożenia" "$(flow_desc "$BCM_FLOW") - wymagane ręczne --force-flow w bcm-deploy.sh";;
  *) check PASS "Ścieżka wdrożenia" "$BCM_FLOW: $(flow_desc "$BCM_FLOW")${BCM_FLOW_GUESSED:+ (ustalona heurystycznie)}";;
esac
[ "$BCM_FLOW" = flow_bcm11_single ] && check WARN "BCM < 11.33.1" "Rozważ aktualizację do >= 11.33.1 (osobny kreator cm-runai-setup, Run:ai 2.25). Zob. docs, rozdz. 2."
[ "$BCM_FLOW" = flow_bcm10_helm ] && check WARN "BCM 10" "Kreator BCM 10.32+ nie instaluje Run:ai - Run:ai zostanie zainstalowany przez Helm."

raw bcm-release.txt cm-package-release-info -f cm-setup,cmdaemon
raw cmsh-versioninfo.txt cmsh -c "main; versioninfo"
rawsh packages-cm.txt "$(declare -f pkg_list); PKG=$PKG; pkg_list '^(cm-|cmdaemon|cuda-|nvidia|libnvidia|kube|containerd|helm)'"

for c in cm-kubernetes-setup cm-runai-setup helm; do
  if have "$c"; then check PASS "Komenda $c" "$(command -v "$c")"
  else
    case $c in
      cm-runai-setup) [ "$BCM_FLOW" = flow_bcm11_split ] && check WARN "Komenda $c" "brak (powinna być w cm-setup >= 11.33.1)" || check INFO "Komenda $c" "brak - normalne dla $BCM_FLOW";;
      helm) check INFO "Komenda helm" "brak w PATH (pojawi się po module load kubernetes)";;
      *) check FAIL "Komenda $c" "brak";;
    esac
  fi
done
if [ "$BCM_FLOW" = flow_bcm11_split ]; then
  v=$(pkg_ver cm-setup-runai-bcm11)
  if [ -n "$v" ]; then check PASS "Pakiet cm-setup-runai-bcm11" "$v"
  else
    cand=$(pkg_candidate cm-setup-runai-bcm11)
    [ -n "$cand" ] && check INFO "Pakiet cm-setup-runai-bcm11" "nie zainstalowany - kreator doinstaluje sam (dostępny: $cand)" \
                   || check WARN "Pakiet cm-setup-runai-bcm11" "nie zainstalowany i brak w repo (air-gap? doinstaluj ręcznie)"
  fi
fi
kpk=$(pkg_list '(^|-)kube(rnetes|adm|let|ctl)' | xargs)
check INFO "Zainstalowane pakiety Kubernetes" "${kpk:-brak}"
check INFO "Wersje K8s w kreatorze" "${D_K8S_VERSIONS:-nie odczytano} -> proponowana: $D_K8S_VERSION"
# Wersje operatorów w kreatorze (Run:ai wymaga m.in. Knative 1.19-1.21, LWS >= 0.7, kube-prometheus-stack)
if have cm-kubernetes-setup && tmo 60 cm-kubernetes-setup --help 2>&1 | grep -q -- '--list-operators-versions'; then
  raw k8s-operators-versions.txt cm-kubernetes-setup --list-operators-versions
  for p in 'knative' 'lws|leader' 'postgres' 'prometheus'; do
    l=$(grep -Ei "$p" "$RAW/k8s-operators-versions.txt" | grep -v '^###' | sed 's/  */ /g; s/^ //' | head -3 | paste -sd ';' | cut -c1-200)
    [ -n "$l" ] && check INFO "Operator w kreatorze: ${p%%|*}" "$l"
  done
fi

# ======================================================= 2. Head node(s) ====
hdr "2. Head node(s)"
check INFO "Head node(s)" "$D_HEAD_NODES (aktywny: $D_ACTIVE_HEAD, HA: $D_HA, IP: ${D_HEAD_IP:-?})"
if [ "$D_HA" = yes ] && have cmha; then
  raw cmha-status.txt cmha status
  cmha status 2>/dev/null | grep -qi "$(hostname -s).*active" || check WARN "HA" "upewnij się, że skrypt działa na AKTYWNYM head node (cmha status)"
fi
free_root=$(df -BG --output=avail /var/lib 2>/dev/null | tail -1 | tr -dc 0-9)
[ "${free_root:-0}" -ge 20 ] && check PASS "Miejsce /var/lib (etcd)" "${free_root}G" || check WARN "Miejsce /var/lib (etcd)" "${free_root:-?}G (zalecane >= 20G, etcd na lokalnym dysku)"
free_sh=$(df -BG --output=avail /cm/shared 2>/dev/null | tail -1 | tr -dc 0-9)
[ "${free_sh:-0}" -ge 100 ] && check PASS "Miejsce /cm/shared (local-path PVC)" "${free_sh}G" || check WARN "Miejsce /cm/shared (local-path PVC)" "${free_sh:-?}G (zalecane >= 100G)"
mem=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)
check INFO "RAM head node" "${mem}G"

# Health checki BCM w stanie FAIL ("health check failed" w device status)
health_report() {
  local n=$1 m p i hint
  rawsh "health-$n.txt" "cmsh -c 'device; use $n; latesthealthdata'"
  while IFS='|' read -r m p i; do
    [ -n "$m" ] || continue
    hint=; grep -qiE 'nvlink|link' <<<"$m $i" && hint=" -> diagnoza/naprawa: ./bcm-nvlink-fix.sh --node $n"
    check FAIL "$n: health ${m}${p:+:$p}" "${i:-bez opisu}$hint"
  done < <(health_fails "$n" | head -20)
}
for h in $D_ACTIVE_HEAD; do health_report "$h"; done

# ============================================================= 3. Węzły =====
hdr "3. Węzły i GPU"
raw cmsh-device-list.txt cmsh -c "device; list"
raw cmsh-device-status.txt cmsh -c "device; status"
raw cmsh-category-list.txt cmsh -c "category; list"
raw cmsh-overlay-list.txt cmsh -c "configurationoverlay; list"
raw cmsh-softwareimage-list.txt cmsh -c "softwareimage; list"
raw cmsh-softwareimage-locked.txt cmsh -c "softwareimage; islocked"
cp "$WORKDIR/devices.tsv" "$WORKDIR/status.tsv" "$WORKDIR/gpus.tsv" "$RAW/" 2>/dev/null

n_compute=$(awk -F'\t' '{print $1}' "$WORKDIR/devices.tsv" | grep -cE '^(PhysicalNode|CloudNode|LiteNode|Node)$')
check INFO "Węzły obliczeniowe w BCM" "$n_compute"
if [ -n "$D_GPU_NODES" ]; then
  check PASS "Węzły GPU (UP)" "$D_GPU_COUNTS (razem $D_GPU_TOTAL GPU)"
else
  check FAIL "Węzły GPU (UP)" "nie znaleziono żadnego działającego węzła z GPU"
fi
# Zasoby: Run:ai cluster (system nodes 10 CPU / 20 GB) + control plane (10 CPU / 12 GB) na jednym K8s
res_ok=0
for r in $D_NODE_RES; do
  c=${r#*:}; m=${c#*/}; c=${c%/*}
  check INFO "Zasoby ${r%%:*}" "$c CPU, $m GB RAM"
  [ "${c:-0}" -ge 20 ] && [ "${m:-0}" -ge 32 ] && res_ok=1
done
if [ -n "$D_NODE_RES" ]; then
  [ $res_ok = 1 ] && check PASS "Zasoby dla Run:ai (control plane + cluster)" "co najmniej jeden węzeł ma >= 20 CPU / 32 GB" \
                  || check WARN "Zasoby dla Run:ai (control plane + cluster)" "żaden węzeł nie ma >= 20 CPU / 32 GB (Run:ai cluster 10/20G + control plane 10/12G) - zwiększ zasoby (VM?) albo dodaj węzły"
fi
[ -n "$D_GPU_MODELS" ] && check INFO "Modele GPU" "$D_GPU_MODELS"
[ -n "$D_DRIVERS" ] && check INFO "Sterownik NVIDIA" "$D_DRIVERS"
[ -n "$D_CPU_NODES" ] && check INFO "Węzły UP bez GPU" "$D_CPU_NODES (nie będą workerami, chyba że --workers)"
[ -n "$D_DOWN_NODES" ] && check WARN "Węzły nie-UP" "$D_DOWN_NODES - zostaną pominięte (nic nie jest przenoszone)"
if [ -n "$D_CATEGORY_EXTRA" ]; then
  case $BCM_FLOW in
    flow_bcm11_*) check WARN "Kategoria workerów zawiera inne węzły" "$D_WORKER_CATEGORIES: $D_CATEGORY_EXTRA - kreator Run:ai wybiera KATEGORIĘ dla control plane; rozważ osobną kategorię dla workerów";;
    *) check INFO "Kategoria workerów zawiera inne węzły" "$D_WORKER_CATEGORIES: $D_CATEGORY_EXTRA (workery K8s wybierane pojedynczo)";;
  esac
fi
if [ "$D_DRIVER_FROM_IMAGE" = yes ]; then
  check INFO "Sterownik GPU" "z obrazu BCM -> w GPU Operator: driver.enabled = OFF"
else
  check WARN "Sterownik GPU" "GPU w lspci, ale nvidia-smi nie działa -> GPU Operator: driver.enabled = ON albo dodaj sterownik do obrazu"
fi

for h in $D_GPU_NODES; do
  hdr "   Węzeł $h"
  img=$(cmsh_q "device; use $h; get softwareimage" | head -1)
  check INFO "$h: obraz" "$img"
  rawsh "node-$h-roles.txt" "cmsh -c 'device; use $h; roles; list'"
  roles=$(cmsh_q "device; use $h; roles; list")
  grep -qi slurmclient <<<"$roles" && check WARN "$h: rola slurmclient" "Slurm i Run:ai mogą konkurować o GPU - rozważ usunięcie Slurma z workerów"
  grep -qi 'Docker::Host' <<<"$roles" && check INFO "$h: rola Docker::Host" "obecna (zwykle nie przeszkadza)"
  cg=$(nssh "$h" 'stat -fc %T /sys/fs/cgroup' 2>/dev/null)
  [ "$cg" = cgroup2fs ] && check PASS "$h: cgroup v2" "$cg" || check WARN "$h: cgroup v2" "${cg:-brak odpowiedzi}"
  nssh "$h" 'df -h /cm/shared' >"$RAW/node-$h-df.txt" 2>&1 && check PASS "$h: /cm/shared zamontowany" || check WARN "$h: /cm/shared" "nie odczytano"
  td=$(( $(nssh "$h" 'date +%s' 2>/dev/null || echo 0) - $(date +%s) )); td=${td#-}
  [ "$td" -le 2 ] && check PASS "$h: zegar" "różnica ${td}s" || check WARN "$h: zegar" "różnica ${td}s względem head node (NTP!)"
  if [ "$QUICK" = 0 ]; then
    rawsh "node-$h-nvidia.txt" "ssh -o BatchMode=yes $h 'nvidia-smi; cat /proc/driver/nvidia/version; nvidia-smi -q | grep -A3 -i \"^ *Fabric\"' "
    rawsh "node-$h-nvlink.txt" "ssh -o BatchMode=yes $h 'systemd-detect-virt; nvidia-smi -q | grep -i \"Virtualization Mode\"; lspci -nd 10de:; nvidia-smi topo -m; nvidia-smi nvlink -s; nvidia-smi nvlink -e' "
  fi
  health_report "$h"
  # Wirtualizacja i NVLink
  lp=$(gpu_link_probe "$h")
  virt=$(kv_get virt "$lp"); vmode=$(kv_get vmode "$lp")
  check INFO "$h: wirtualizacja" "${virt:-?}${vmode:+ (GPU: $vmode)}"
  case $vmode in
    *[Vv][Gg][Pp][Uu]*) check FAIL "$h: tryb GPU" "$vmode - Run:ai nie wspiera vGPU (tylko passthrough / bare metal)";;
    *[Pp]ass*) check PASS "$h: tryb GPU" "$vmode (passthrough - wspierane przez Run:ai)";;
  esac
  lt=$(kv_get link_total "$lp"); la=$(kv_get link_active "$lp"); li=$(kv_get link_inactive "$lp")
  nt=$(kv_get nv_topo "$lp"); es=$(kv_get err_sum "$lp"); ns=$(kv_get nvswitch "$lp")
  if [ "${lt:-0}" -eq 0 ]; then
    check INFO "$h: NVLink" "brak linków w nvidia-smi nvlink -s (GPU PCIe bez NVLink lub sterownik nie raportuje)"
  elif [ "${li:-0}" -gt 0 ]; then
    check WARN "$h: NVLink" "aktywne ${la:-0}/$lt, nieaktywne $li; GPU<->GPU przez NVLink: ${nt:-?}; NVSwitch w systemie: ${ns:-0} -> ./bcm-nvlink-fix.sh --node $h"
  else
    check PASS "$h: NVLink" "aktywne $la/$lt; GPU<->GPU przez NVLink: ${nt:-?}"
  fi
  [ "${es:-0}" -gt 0 ] && check WARN "$h: liczniki błędów NVLink" "suma replay/recovery/CRC = $es (możliwy problem sprzętowy) -> ./bcm-nvlink-fix.sh --node $h"
  sw=$(awk -F'\t' -v h="$h" '$1==h{print $5}' "$WORKDIR/gpus.tsv")
  if [ "${sw:-0}" -gt 0 ]; then
    fm=$(nssh "$h" 'systemctl is-active nvidia-fabricmanager' 2>/dev/null)
    [ "$fm" = active ] && check PASS "$h: Fabric Manager (NVSwitch)" "active" || check FAIL "$h: Fabric Manager (NVSwitch)" "${fm:-?} - CUDA na HGX nie zadziała bez FM"
    drv=$(awk -F'\t' -v h="$h" '$1==h{print $4}' "$WORKDIR/gpus.tsv")
    fmv=$(nssh "$h" "dpkg-query -W -f='\${Version}' nvidia-fabricmanager 2>/dev/null || rpm -q --qf '%{VERSION}' nvidia-fabricmanager 2>/dev/null" 2>/dev/null)
    if [ -n "$drv" ] && [ -n "$fmv" ]; then
      [[ $fmv == "$drv"* ]] && check PASS "$h: wersja FM = sterownik" "$fmv" || check FAIL "$h: wersja FM != sterownik" "FM $fmv vs driver $drv - zob. docs, rozdz. 2.4"
    fi
    fstate=$(nssh "$h" 'nvidia-smi -q 2>/dev/null | grep -A2 -i "^ *Fabric" | grep -E "State" | sort | uniq -c' 2>/dev/null | xargs)
    [ -n "$fstate" ] && check INFO "$h: stan fabric" "$fstate"
  fi
  for net in registry.k8s.io nvcr.io; do
    nssh "$h" "curl -sI -m5 https://$net >/dev/null" && check PASS "$h: internet $net" || check WARN "$h: internet $net" "brak - wdrożenie connected wymaga dostępu (albo air-gap)"
  done
done

# Blokady obrazów (zablokowany obraz = węzeł wisi w "waiting for SYNC provisioning")
if grep -qiE '\byes\b' "$RAW/cmsh-softwareimage-locked.txt" 2>/dev/null; then
  check WARN "Zablokowane obrazy" "$(grep -iE '\byes\b' "$RAW/cmsh-softwareimage-locked.txt" | awk '{print $1}' | xargs) - odblokuj przed rebootem węzłów"
fi
# Pakiety NVIDIA bez blokady w obrazach workerów (lekcja: apt upgrade rozjechał FM vs driver)
for img in $(for h in $D_GPU_NODES; do cmsh_q "device; use $h; get softwareimage" | awk '{print $1}'; done | sort -u); do
  p=$(cmsh_q "softwareimage; use $img; get path" | head -1)
  [ -d "$p" ] || continue
  if [ "$OS_FAMILY" = debian ]; then
    held=$(chroot "$p" apt-mark showhold 2>/dev/null | grep -cE 'nvidia|fabric|nscq|imex')
    [ "${held:-0}" -gt 0 ] && check PASS "Obraz $img: pakiety NVIDIA zablokowane (hold)" "$held" \
                           || check WARN "Obraz $img: pakiety NVIDIA bez apt-mark hold" "apt upgrade w obrazie może rozjechać FM/nscq/imex vs driver"
  fi
done

# ============================================================== 4. Sieć =====
hdr "4. Sieć"
raw cmsh-network-list.txt cmsh -c "network; list"
for n in $(awk '{print $1}' "$WORKDIR/networks.txt"); do raw "cmsh-network-$n.txt" cmsh -c "network; show $n"; done
rawsh ip-addr.txt "ip -o -4 addr; echo; ip route; echo; ip -o link | awk '{print \$2, \$4, \$5}'"
check INFO "Sieć węzłów (MetalLB L2)" "$D_NODE_NET $D_NET_CIDR, brama ${D_NET_GW:-?}, dynamic range ${D_NET_DYN:-?}, domena ${D_NET_DOMAIN:-?}"
case $D_CLIENT_IN_NET in
  yes) check PASS "Jump host w sieci węzłów" "$D_CLIENT_IP należy do $D_NET_CIDR - IP MetalLB będą osiągalne z przeglądarki";;
  no)  check WARN "Jump host poza siecią węzłów" "$D_CLIENT_IP poza $D_NET_CIDR - potrzebna trasa do $D_NET_CIDR, proxy head node (port 443) albo tunel SOCKS";;
  *)   check INFO "Jump host" "nie wykryto SSH_CLIENT";;
esac
nlb=$(wc -w <<<"$D_LB_IPS")
if [ "$nlb" -ge "$D_LB_NEED" ]; then
  check PASS "Wolne IP dla LoadBalancer ($D_LB_NEED szt.)" "$D_LB_IPS (spoza dynamic range, brak w BCM, brak odpowiedzi ping/ARP)"
else
  check FAIL "Wolne IP dla LoadBalancer" "znaleziono $nlb z $D_LB_NEED: ${D_LB_IPS:-brak} - podaj ręcznie --lb-ips"
fi
check INFO "Wolne IP - potwierdzenie" "zapytaj zespół sieciowy, czy $D_LB_IPS nie są używane poza BCM (switche, iDRAC/BMC)"
check INFO "Proponowane CIDR K8s" "service $D_SVC_CIDR, pod $D_POD_CIDR (bez kolizji z sieciami BCM i trasami)"
for n in $(awk '{print $2}' "$WORKDIR/networks.txt"); do
  is_default_net "$n" && continue   # globalnet 0.0.0.0/0 obejmuje wszystko - to nie kolizja
  for c in $D_SVC_CIDR $D_POD_CIDR; do cidr_overlap "$c" "$n" && check FAIL "Kolizja CIDR" "$c z $n"; done
done
mtus=$(ip -o link | awk '{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}' | sort -u | xargs)
check INFO "MTU interfejsów head node" "$mtus"

# ============================================================ 5. Internet ===
hdr "5. Internet / rejestry / proxy"
env | grep -iE '^(https?|no)_proxy=' | mask_secrets >"$RAW/proxy-env.txt"
[ -s "$RAW/proxy-env.txt" ] && check INFO "Zmienne proxy" "$(cut -d= -f1 "$RAW/proxy-env.txt" | xargs)"
for u in https://registry.k8s.io https://nvcr.io https://helm.ngc.nvidia.com https://registry-1.docker.io https://quay.io https://ghcr.io https://github.com https://runai.jfrog.io; do
  code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$u")
  [ "$code" != 000 ] && check PASS "HTTPS $u" "HTTP $code" || check WARN "HTTPS $u" "brak połączenia"
done
if have chronyc; then raw chrony.txt chronyc tracking; elif have timedatectl; then raw timedatectl.txt timedatectl; fi

# ================================================================ 6. DNS ====
hdr "6. DNS"
check INFO "Pliki BIND" "$NAMED_CONF, include: $NAMED_INCLUDE, strefy: $ZONE_DIR"
if [ -r "$NAMED_CONF" ]; then
  grep -q "$(basename "$NAMED_INCLUDE")" "$NAMED_CONF" && check PASS "named.conf zawiera include" "$NAMED_INCLUDE" \
    || check WARN "named.conf bez include" "brak odwołania do $NAMED_INCLUDE"
  cp "$NAMED_INCLUDE" "$RAW/named.conf.include" 2>/dev/null
  grep -E '^\s*zone' "$NAMED_CONF" "$NAMED_INCLUDE" 2>/dev/null | sed 's/{.*//' >"$RAW/named-zones.txt"
else
  check WARN "BIND" "brak $NAMED_CONF (DNS nie z head node?)"
fi
cp /etc/resolv.conf "$RAW/resolv.conf" 2>/dev/null
for n in $D_NET_DOMAIN $(awk '{print $3}' "$WORKDIR/networks.txt"); do
  [ "$n" = "$D_DOMAIN" ] && check FAIL "Domena Run:ai" "$D_DOMAIN to domena sieci BCM - wybierz inną (--domain)"
done
r=$(getent hosts "$D_RUNAI_FQDN" | awk '{print $1}')
check INFO "FQDN Run:ai (proponowany)" "$D_RUNAI_FQDN -> ${r:-nie rozwiązuje się (deploy utworzy strefę BIND)}"

# ======================================================= 7. Kubernetes ======
hdr "7. Istniejący Kubernetes"
raw cmsh-kubernetes-list.txt cmsh -c "kubernetes; list"
if [ -n "$D_K8S_CLUSTERS" ]; then
  check INFO "Klastry K8s w BCM" "$D_K8S_CLUSTERS"
  c1=$(awk '{print $1}' <<<"$D_K8S_CLUSTERS")
  if k8s_env "$c1"; then
    raw k8s-nodes.txt kubectl get nodes -o wide
    raw k8s-pods-bad.txt bash -c "kubectl get pods -A --no-headers | grep -vE 'Running|Completed'"
    raw helm-list.txt helm list -A
    raw k8s-lb-svc.txt bash -c "kubectl get svc -A | grep -i loadbalancer"
    raw k8s-metallb.txt kubectl get ipaddresspools,l2advertisements -A
    raw k8s-gateway.txt bash -c "kubectl get gatewayclass,gateway -A"
    raw k8s-kyverno.txt bash -c "kubectl get clusterpolicy; helm get values -n kyverno kyverno-policies"
    raw k8s-runai.txt bash -c "kubectl get pods -n runai; kubectl get pods -n runai-backend; kubectl get runaiconfig -A"
    raw k8s-events-warn.txt bash -c "kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -60"
    raw k8s-allocatable.txt kubectl get nodes -o custom-columns='NODE:.metadata.name,PODS:.status.allocatable.pods,GPU:.status.allocatable.nvidia\.com/gpu,RUNNING:.status.capacity.pods'
    ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
    all=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    [ "$ready" = "$all" ] && check PASS "Węzły K8s Ready" "$ready/$all" || check WARN "Węzły K8s Ready" "$ready/$all"
    bad=$(grep -vc '^###' "$RAW/k8s-pods-bad.txt")
    [ "$bad" = 0 ] && check PASS "Pody w złym stanie" "brak" || check WARN "Pody w złym stanie" "$bad (raw/k8s-pods-bad.txt)"
    hl=$(helm list -A 2>/dev/null)
    while IFS='|' read -r label pat; do
      grep -qiE "$pat" <<<"$hl" && check PASS "Operator: $label" "jest" || check WARN "Operator: $label" "BRAK (wymagany przez Run:ai dla $BCM_FLOW)"
    done < <(runai_required_components "$BCM_FLOW")
    while read -r node pods; do
      [ "${pods:-0}" -ge 200 ] 2>/dev/null && check PASS "$node: maxPods" "$pods" || check WARN "$node: maxPods" "$pods - pełny stos + Run:ai na 1 workerze przekracza 110 (Too many pods)"
    done < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name} {.status.allocatable.pods}{"\n"}{end}' 2>/dev/null)
    grep -q 'runai\*' "$RAW/k8s-kyverno.txt" 2>/dev/null && check PASS "Kyverno: wykluczenia runai*" "są" \
      || { grep -qi 'disallow' "$RAW/k8s-kyverno.txt" && check WARN "Kyverno: brak wykluczeń runai*" "polityki mogą blokować pody Run:ai"; }
  else
    check WARN "kubectl" "nie udało się załadować modułu kubernetes"
  fi
else
  check INFO "Klastry K8s w BCM" "brak - czysta instalacja"
fi

# ==================================================== 8. Certyfikaty Run:ai ==
hdr "8. Pliki Run:ai i certyfikaty"
RUNAI_DIR=${RUNAI_DIR:-/cm/shared/runai}
if [ -d "$RUNAI_DIR" ]; then
  ls -la "$RUNAI_DIR" >"$RAW/runai-dir.txt" 2>&1
  for f in "$RUNAI_DIR"/*.crt "$RUNAI_DIR"/*.pem; do
    [ -f "$f" ] || continue
    grep -q 'PRIVATE KEY' "$f" && continue
    s=$(openssl x509 -in "$f" -noout -subject -enddate -ext subjectAltName 2>/dev/null | tr '\n' ' ')
    [ -n "$s" ] && check INFO "Cert $(basename "$f")" "$s"
    openssl x509 -in "$f" -noout -checkend 2592000 >/dev/null 2>&1 || check WARN "Cert $(basename "$f")" "wygasa w ciągu 30 dni lub już wygasł"
  done
  if [ -f "$RUNAI_DIR/full-chain.pem" ] && [ -f "$RUNAI_DIR/private.key" ]; then
    a=$(openssl x509 -in "$RUNAI_DIR/full-chain.pem" -noout -pubkey 2>/dev/null | sha256sum)
    b=$(openssl pkey -in "$RUNAI_DIR/private.key" -pubout 2>/dev/null | sha256sum)
    [ "$a" = "$b" ] && check PASS "Klucz pasuje do certyfikatu" "full-chain.pem / private.key" || check FAIL "Klucz NIE pasuje do certyfikatu" "full-chain.pem / private.key"
  fi
  [ -f "$RUNAI_DIR/ngc-api-key" ] && check PASS "Klucz NGC" "$RUNAI_DIR/ngc-api-key (treść nie jest zbierana)"
  perm=$(stat -c %a "$RUNAI_DIR" 2>/dev/null); [ "$perm" = 700 ] || check WARN "Uprawnienia $RUNAI_DIR" "$perm (zalecane 700)"
else
  check INFO "Katalog $RUNAI_DIR" "brak - deploy go utworzy"
fi

# ================================================= 9. Pliki kreatorów =======
hdr "9. Zapisane konfiguracje kreatorów (szablony do automatyzacji -c)"
found=0
for f in /root/cm-kubernetes-setup*.conf /root/cm-runai-setup*.conf /cm/shared/runai/cm-*-setup*.conf /root/cm-*-setup*.yaml; do
  [ -f "$f" ] || continue
  found=1
  mask_secrets <"$f" >"$RAW/wizard-$(basename "$f").masked"
  check INFO "Konfiguracja kreatora" "$f (zamaskowana kopia w raw/)"
  [ "$(stat -c %a "$f")" = 600 ] || check WARN "Uprawnienia $f" "$(stat -c %a "$f") - plik może zawierać hasła/klucze, ustaw chmod 600"
done
[ $found = 0 ] && check INFO "Konfiguracja kreatora" "brak zapisanych plików /root/cm-*-setup*.conf"

# ======================================================== podsumowanie ======
hdr "Podsumowanie"
{
  echo
  echo "PODSUMOWANIE: PASS=$CNT_PASS WARN=$CNT_WARN FAIL=$CNT_FAIL"
  echo
  echo "Wartości proponowane dla wdrożenia (discovered.env):"
  sed -n '2,$p' "$WORKDIR/discovered.env" | sed 's/^/  /'
} >>"$REPORT"
info "PASS=$CNT_PASS WARN=$CNT_WARN FAIL=$CNT_FAIL"

# Jeden plik tekstowy ze wszystkim (raport + discovered.env + raw/), do przesłania jako .txt
ALLTXT=$WORKDIR.txt
MAXL=${BCM_COLLECT_MAX_LINES:-3000}   # limit linii na pojedynczy plik raw (0 = bez limitu)
{
  echo "######## BCM COLLECT: $(hostname) $(date -Is)"
  echo "######## Pliki: report.txt, discovered.env, raw/* (sekrety zamaskowane)"
  echo
  echo "================================================================ report.txt"
  cat "$REPORT"
  echo
  echo "================================================================ discovered.env"
  cat "$WORKDIR/discovered.env"
  for f in $(find "$WORKDIR" -type f ! -name report.txt ! -name discovered.env | sort); do
    grep -qI . "$f" 2>/dev/null || [ ! -s "$f" ] || continue   # pomiń pliki binarne
    n=$(wc -l <"$f")
    echo
    echo "================================================================ ${f#"$WORKDIR"/} ($n linii)"
    if [ "$MAXL" -gt 0 ] && [ "$n" -gt "$MAXL" ]; then
      head -n "$MAXL" "$f"; echo "... [obcięto: $((n - MAXL)) linii; pełna wersja w .tar.gz]"
    else
      cat "$f"
    fi
  done
} | mask_secrets >"$ALLTXT"
chmod 600 "$ALLTXT"

tar -C "$(dirname "$WORKDIR")" -czf "$WORKDIR.tar.gz" "$(basename "$WORKDIR")"
chmod 600 "$WORKDIR.tar.gz"
ok "Raport:   $REPORT"
ok "Wszystko w jednym pliku: $ALLTXT ($(du -h "$ALLTXT" | cut -f1))   <- prześlij ten plik do analizy"
ok "Archiwum: $WORKDIR.tar.gz   (alternatywnie, pełne dane)"
[ "$CNT_FAIL" -gt 0 ] && exit 1 || exit 0
