#!/bin/bash
# lib/common.sh - wspólne funkcje dla bcm-collect.sh i bcm-deploy.sh
#
# Zasada: NICZEGO nie zakładamy o klastrze. Nazwy węzłów, liczba GPU, sieci,
# adresy IP, wersja BCM i dystrybucja są wykrywane. Każdą wartość można
# nadpisać zmienną środowiskową / flagą skryptu.
#
# Biblioteka jest "sourcowana" - nie wywołuje exit (poza die()).

# ---------------------------------------------------------------- logowanie --
if [ -t 1 ]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_0=$'\e[0m'; C_BOLD=$'\e[1m'
else
  C_R=; C_G=; C_Y=; C_B=; C_0=; C_BOLD=
fi
LOG_FILE=${LOG_FILE:-/dev/null}

_log()  { printf '%s\n' "$*" | tee -a "$LOG_FILE" >&2; }
info()  { _log "${C_B}[INFO]${C_0} $*"; }
ok()    { _log "${C_G}[ OK ]${C_0} $*"; }
warn()  { _log "${C_Y}[WARN]${C_0} $*"; }
err()   { _log "${C_R}[FAIL]${C_0} $*"; }
die()   { err "$*"; exit 1; }
hdr()   { _log ""; _log "${C_BOLD}===== $* =====${C_0}"; }

have()  { command -v "$1" >/dev/null 2>&1; }
# in_list <element> <lista...>
in_list() { local x=$1; shift; local e; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }

# Potwierdzenie (YES=1 -> zawsze tak)
confirm() {
  [ "${YES:-0}" = 1 ] && return 0
  local a; read -r -p "$* [t/N] " a </dev/tty || return 1
  [[ $a =~ ^[TtYy] ]]
}

# ------------------------------------------------------------ werdykty -------
# check <PASS|WARN|FAIL|INFO> "<nazwa>" "<szczegóły>"  -> dopisuje do $REPORT
CNT_PASS=0; CNT_WARN=0; CNT_FAIL=0
REPORT=${REPORT:-/dev/null}
check() {
  local st=$1 name=$2 det=${3:-}
  case $st in
    PASS) CNT_PASS=$((CNT_PASS+1)); ok   "$name${det:+ - $det}";;
    WARN) CNT_WARN=$((CNT_WARN+1)); warn "$name${det:+ - $det}";;
    FAIL) CNT_FAIL=$((CNT_FAIL+1)); err  "$name${det:+ - $det}";;
    *)    info "$name${det:+ - $det}";;
  esac
  printf '%-5s | %-45s | %s\n' "$st" "$name" "$det" >>"$REPORT"
}

# ------------------------------------------------------------- narzędzia -----
# Uruchomienie z limitem czasu (timeout może nie istnieć na starych systemach)
tmo() { local t=$1; shift; if have timeout; then timeout "$t" "$@"; else "$@"; fi; }

cmsh_q() { tmo 120 cmsh -c "$1" 2>&1; }

# ssh do węzła bez pytań; zwraca kod ssh
nssh() { local n=$1; shift; tmo 30 ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$n" "$@"; }

# ver_ge A B  -> prawda gdy A >= B (porównanie wersji)
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

# -------------------------------------------------------- matematyka IPv4 ----
ip2int() { local IFS=.; set -- $1; echo $(( ($1<<24) + ($2<<16) + ($3<<8) + $4 )); }
int2ip() { local i=$1; echo "$(( (i>>24)&255 )).$(( (i>>16)&255 )).$(( (i>>8)&255 )).$(( i&255 ))"; }
is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
# cidr_overlap 10.0.0.0/16 10.0.5.0/24 -> prawda gdy zakresy się nakładają
cidr_overlap() {
  local a=${1%/*} am=${1#*/} b=${2%/*} bm=${2#*/} m
  m=$(( am < bm ? am : bm ))
  local mask=$(( m == 0 ? 0 : (0xFFFFFFFF << (32-m)) & 0xFFFFFFFF ))
  [ $(( $(ip2int "$a") & mask )) -eq $(( $(ip2int "$b") & mask )) ]
}
# Sieć "wszystko" (globalnet BCM 0.0.0.0/0, trasa default) - pomijana przy kolizjach CIDR
is_default_net() { case $1 in */0|0.0.0.0/*|default) return 0;; esac; return 1; }

# ------------------------------------------------------------ dystrybucja ----
detect_os() {
  OS_ID=unknown; OS_VER=; OS_FAMILY=unknown; PKG=unknown
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release; OS_ID=${ID:-unknown}; OS_VER=${VERSION_ID:-}
    case " ${ID:-} ${ID_LIKE:-} " in
      *" debian "*|*" ubuntu "*) OS_FAMILY=debian;;
      *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*) OS_FAMILY=rhel;;
      *" sles "*|*" suse "*) OS_FAMILY=suse;;
    esac
  fi
  case $OS_FAMILY in debian) PKG=dpkg;; rhel|suse) PKG=rpm;; esac
  # Ścieżki BIND zależne od dystrybucji
  if [ "$OS_FAMILY" = debian ]; then
    NAMED_CONF=/etc/bind/named.conf; NAMED_INCLUDE=/etc/bind/named.conf.include; ZONE_DIR=/etc/bind
  else
    NAMED_CONF=/etc/named.conf; NAMED_INCLUDE=/etc/named.conf.include; ZONE_DIR=/var/named
  fi
}

# pkg_ver <pakiet>  -> wersja albo pusty string
pkg_ver() {
  case $PKG in
    dpkg) dpkg-query -W -f='${Status} ${Version}\n' "$1" 2>/dev/null | awk '/install ok installed/{print $4}';;
    rpm)  rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$1" 2>/dev/null | grep -v 'not installed';;
  esac
}
# pkg_list <wzorzec-regex> -> "nazwa wersja" dla zainstalowanych pakietów
pkg_list() {
  case $PKG in
    dpkg) dpkg-query -W -f='${Status} ${Package} ${Version}\n' 2>/dev/null | awk '/install ok installed/{print $4, $5}' | grep -E "$1";;
    rpm)  rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 2>/dev/null | grep -E "$1";;
  esac
}
# pkg_candidate <pakiet> -> czy pakiet jest dostępny w repo (do instalacji)
pkg_candidate() {
  case $PKG in
    dpkg) apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}' | grep -v '(none)';;
    rpm)  (dnf -q list --available "$1" 2>/dev/null || yum -q list available "$1" 2>/dev/null) | awk 'NR>1{print $2}' | head -1;;
  esac
}

# -------------------------------------------------------------- wersja BCM ---
# Ustawia: BCM_RELEASE (np. 11.34, 11.32.1, 10.24.09), BCM_MAJOR, BCM_FLOW
#   flow_bcm11_split  - BCM >= 11.33.1: cm-kubernetes-setup + cm-runai-setup (Kgateway)
#   flow_bcm11_single - BCM 11.0 .. 11.32.x: Run:ai w cm-kubernetes-setup (Ingress NGINX)
#   flow_bcm10_helm   - BCM 10.x: K8s z kreatora, Run:ai przez Helm (BCM 10.32+ nie ma integracji)
#   flow_unknown
detect_bcm() {
  BCM_RELEASE=; BCM_SRC=
  if have cm-package-release-info; then
    # format: "cmdaemon  164704  11.32.1" (kolumna Release(s) może zawierać kilka wydań)
    BCM_RELEASE=$(cm-package-release-info -f cm-setup,cmdaemon 2>/dev/null \
      | awk '$1=="cmdaemon"{$1="";$2="";print}' | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V | tail -1)
    [ -n "$BCM_RELEASE" ] && BCM_SRC=cm-package-release-info
  fi
  if [ -z "$BCM_RELEASE" ] && have cmsh; then
    BCM_RELEASE=$(cmsh_q "main; versioninfo" | grep -iE 'cluster manager|cmdaemon|version' \
      | grep -Eo '\b(9|10|11|12)\.[0-9]+(\.[0-9]+)?\b' | head -1)
    [ -n "$BCM_RELEASE" ] && BCM_SRC="cmsh versioninfo"
  fi
  if [ -z "$BCM_RELEASE" ]; then
    # np. 11.0-164704-cm11.0-... -> znamy tylko gałąź główną
    BCM_RELEASE=$(pkg_ver cmdaemon | grep -Eo 'cm[0-9]+\.[0-9]+' | tr -d cm | head -1)
    [ -n "$BCM_RELEASE" ] && BCM_SRC="pakiet cmdaemon (tylko gałąź)"
  fi
  BCM_MAJOR=${BCM_RELEASE%%.*}
  if [ -n "${FORCE_FLOW:-}" ]; then BCM_FLOW=$FORCE_FLOW; return; fi
  case $BCM_MAJOR in
    11) if [ "$BCM_SRC" = "pakiet cmdaemon (tylko gałąź)" ]; then
          # Brak numeru wydania - rozstrzygamy po obecności kreatora cm-runai-setup (od 11.33.1)
          if have cm-runai-setup; then BCM_FLOW=flow_bcm11_split; else BCM_FLOW=flow_bcm11_single; fi
          BCM_FLOW_GUESSED=1
        elif ver_ge "$BCM_RELEASE" 11.33.1; then BCM_FLOW=flow_bcm11_split
        else BCM_FLOW=flow_bcm11_single; fi;;
    10) BCM_FLOW=flow_bcm10_helm;;
    *)  BCM_FLOW=flow_unknown;;
  esac
}

flow_desc() {
  case $1 in
    flow_bcm11_split)  echo "BCM >= 11.33.1: cm-kubernetes-setup (K8s + operatory, Kgateway) -> cm-runai-setup (Run:ai 2.25)";;
    flow_bcm11_single) echo "BCM 11.0-11.32.x: jeden kreator cm-kubernetes-setup z opcją 'Run:ai (self-hosted)' (Ingress NGINX, Run:ai 2.23/2.22)";;
    flow_bcm10_helm)   echo "BCM 10.x: cm-kubernetes-setup dla K8s, Run:ai self-hosted przez Helm (BCM 10.32+ nie integruje Run:ai)";;
    *)                 echo "nieznana / nieobsługiwana wersja BCM";;
  esac
}

# Ile adresów LoadBalancer (MetalLB) potrzebuje dana ścieżka
flow_lb_count() {
  case $1 in
    flow_bcm11_split) echo 3;;   # bcm-gateway (Kgateway), Run:ai gateway, Kourier (inference)
    *)                echo 2;;   # ingress Run:ai, inference
  esac
}

# --------------------------------------------------------------- urządzenia --
# Parsuje "cmsh device; list" do pliku TSV: type host mac category ip network
# (kolumna kategorii bywa pusta dla head node, dlatego IP szukamy regexem)
discover_devices() {
  local out=${1:-$WORKDIR/devices.tsv}
  cmsh_q "device; list" | awk '
    /^(Type|-)/ || NF<2 {next}
    {
      type=$1; host=$2; mac=""; cat=""; ip=""; net=""; ipidx=0
      # bez interwałów {n} w regexach - mawk (domyślny awk w Ubuntu) ich nie obsługuje
      for (i=3;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {ip=$i; ipidx=i; break}
      if ($3 ~ /^[0-9A-Fa-f:]+$/ && $3 ~ /:/) mac=$3
      start = (mac=="") ? 3 : 4
      if (ipidx>start) cat=$start
      if (ipidx>0 && ipidx<NF && $(ipidx+1) !~ /^\[/) net=$(ipidx+1)
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", type, host, mac, cat, ip, net
    }' >"$out"
}

# Status węzłów: host<TAB>STATUS (UP/DOWN/INSTALLING/...)
discover_status() {
  local out=${1:-$WORKDIR/status.tsv}
  cmsh_q "device; status" | awk '
    /\[/ { s=$0; sub(/^[^[]*\[ */,"",s); sub(/ *\].*$/,"",s); print $1"\t"s }' >"$out"
}

# Typ dla węzłów obliczeniowych w BCM: PhysicalNode / CloudNode / LiteNode ...
is_compute_type() { case $1 in PhysicalNode|CloudNode|LiteNode|Node) return 0;; esac; return 1; }

# GPU na węźle: wypisuje "count|model|driver|nvswitch|lspci_count"
gpu_probe() {
  local n=$1 cmd
  # shellcheck disable=SC2016
  cmd='c=0; m=; d=; if command -v nvidia-smi >/dev/null 2>&1; then
         q=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)
         c=$(printf "%s\n" "$q" | grep -c .); m=$(printf "%s\n" "$q" | head -1 | cut -d, -f1 | sed "s/^ *//");
         d=$(printf "%s\n" "$q" | head -1 | cut -d, -f2 | tr -d " "); fi
       l=0; s=0; if command -v lspci >/dev/null 2>&1; then
         l=$(lspci -nd 10de: 2>/dev/null | grep -Eci "0300|0302"); s=$(lspci -d 10de: 2>/dev/null | grep -ci "bridge"); fi
       echo "$c|$m|$d|$s|$l"'
  if [ "$n" = "$(hostname -s)" ] || [ "$n" = "$(hostname)" ]; then bash -c "$cmd"; else nssh "$n" "$cmd" 2>/dev/null; fi
}

# nrun <węzeł>  (skrypt bash na stdin) - lokalnie na head node albo przez ssh na węźle
nrun() {
  local n=$1
  if [ "$n" = "$(hostname -s)" ] || [ "$n" = "$(hostname)" ]; then tmo 180 bash -s
  else tmo 180 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$n" 'bash -s'; fi
}

# kv_get <klucz> <tekst "klucz=wartość" w liniach>
kv_get() { sed -n "s/^$1=//p" <<<"$2" | head -1; }

# CPU i RAM węzła: "rdzenie RAM_GB"
node_res() {
  nrun "$1" 2>/dev/null <<'EOS'
echo "$(nproc) $(awk '/MemTotal/{printf "%d", $2/1048576+0.5}' /proc/meminfo)"
EOS
}

# Health checki BCM w stanie FAIL: linie "measurable|parametr|info"
health_fails() {
  cmsh_q "device; use $1; latesthealthdata" | awk '
    { for (i=2;i<=NF;i++) if ($i=="FAIL") {
        p = (i>=4) ? $2 : ""
        j = i+1; while (j<=NF && $j ~ /^[0-9]+[smhdw]$/) j++   # pomiń wiek próbki, np. "1m 21s"
        info=""; for (; j<=NF; j++) info = info (info=="" ? "" : " ") $j
        print $1 "|" p "|" info; break } }'
}

# Sonda GPU/NVLink na węźle: linie klucz=wartość
#   virt vmode pci_gpus nvswitch smi_gpus drv link_total link_active link_inactive nv_topo err_sum fm_state fm_ver
_gpu_link_probe_script() {
  cat <<'EOS'
v=$(systemd-detect-virt 2>/dev/null); echo "virt=${v:-unknown}"
g=0; s=0
if command -v lspci >/dev/null 2>&1; then
  g=$(lspci -nd 10de: 2>/dev/null | grep -Ec ' 030[02]: ')
  s=$(lspci -nd 10de: 2>/dev/null | grep -c ' 0680: ')
fi
echo "pci_gpus=$g"; echo "nvswitch=$s"
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "smi_gpus=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ')"
  echo "drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')"
  echo "vmode=$(nvidia-smi -q 2>/dev/null | awk -F: '/Virtualization Mode *:/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
  st=$(nvidia-smi nvlink -s 2>/dev/null)
  echo "link_total=$(grep -Ec 'Link [0-9]+:' <<<"$st")"
  echo "link_inactive=$(grep -Eic 'Link [0-9]+:.*inactive' <<<"$st")"
  echo "link_active=$(grep -Ec 'Link [0-9]+:.*GB/s' <<<"$st")"
  if nvidia-smi topo -m 2>/dev/null | awk '/^GPU[0-9]/{for(i=2;i<=NF;i++) if($i ~ /^NV[0-9]+$/) f=1} END{exit !f}'; then
    echo nv_topo=yes; else echo nv_topo=no; fi
  echo "err_sum=$(nvidia-smi nvlink -e 2>/dev/null | grep -Eio '(replay|recovery|crc)[^:]*errors?[^:]*: *[0-9]+' | grep -Eo '[0-9]+$' | awk '{s+=$1} END{print s+0}')"
fi
echo "fm_state=$(systemctl is-active nvidia-fabricmanager 2>/dev/null)"
fm=$(dpkg-query -W -f='${Version}\n' 'nvidia-fabricmanager*' 2>/dev/null | grep . | head -1)
[ -n "$fm" ] || fm=$(rpm -qa --qf '%{VERSION}\n' 'nvidia-fabric*manager*' 2>/dev/null | head -1)
echo "fm_ver=$fm"
EOS
}
gpu_link_probe() { _gpu_link_probe_script | nrun "$1" 2>/dev/null; }

# ------------------------------------------------------------------ sieci ----
# network_info <nazwa> -> ustawia NET_BASE NET_BITS NET_DYN_S NET_DYN_E NET_GW NET_DOMAIN
network_info() {
  local o
  o=$(cmsh_q "network; use $1; get baseaddress; get netmaskbits; get dynamicrangestart; get dynamicrangeend; get gateway; get domainname")
  # shellcheck disable=SC2034
  { read -r NET_BASE; read -r NET_BITS; read -r NET_DYN_S; read -r NET_DYN_E; read -r NET_GW; read -r NET_DOMAIN; } <<<"$o"
  is_ipv4 "$NET_BASE" && [[ $NET_BITS =~ ^[0-9]+$ ]]
}

# Wszystkie sieci BCM jako "nazwa base/bits domena"
list_bcm_networks() {
  local n
  for n in $(cmsh_q "network; list" | awk '!/^(Name|-)/ && NF{print $1}'); do
    if network_info "$n"; then echo "$n $NET_BASE/$NET_BITS ${NET_DOMAIN:-}"; fi
  done
}

# Wszystkie IPv4 znane BCM (urządzenia + ich interfejsy) - jeden na linię
bcm_used_ips() {
  local h
  awk -F'\t' '$5!=""{print $5}' "$WORKDIR/devices.tsv"
  for h in $(awk -F'\t' '{print $2}' "$WORKDIR/devices.tsv"); do
    cmsh_q "device; use $h; interfaces; list" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}'
  done
  # adresy LoadBalancer już przydzielone w istniejącym K8s
  if have kubectl; then
    kubectl get svc -A -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[*].ip}{"\n"}{end}' 2>/dev/null
    kubectl get ipaddresspools.metallb.io -A -o jsonpath='{range .items[*]}{.spec.addresses[*]}{"\n"}{end}' 2>/dev/null | tr ' ' '\n'
  fi
}

ip_in_use() {
  local ip=$1
  ping -c1 -W1 "$ip" >/dev/null 2>&1 && return 0
  if have arping && [ -n "${LB_IFACE:-}" ]; then
    tmo 3 arping -c1 -w1 -I "$LB_IFACE" "$ip" >/dev/null 2>&1 && return 0
  fi
  ip neigh show "$ip" 2>/dev/null | grep -qE 'lladdr' && return 0
  return 1
}

# find_free_ips <base> <bits> <dynS> <dynE> <gw> <ile> <plik_zajętych>
# Szuka od góry podsieci w dół; pomija dynamic range, bramę, adresy BCM i odpowiadające
find_free_ips() {
  local base=$1 bits=$2 ds=$3 de=$4 gw=$5 need=$6 used=$7
  local net bcast i ip found=0 dsi=0 dei=0
  net=$(ip2int "$base"); bcast=$(( net + (1 << (32-bits)) - 1 ))
  is_ipv4 "$ds" && dsi=$(ip2int "$ds"); is_ipv4 "$de" && dei=$(ip2int "$de")
  for (( i=bcast-1; i>net && found<need; i-- )); do
    ip=$(int2ip "$i")
    (( dsi && i>=dsi && i<=dei )) && continue
    [ "$ip" = "$gw" ] && continue
    grep -qxF "$ip" "$used" && continue
    ip_in_use "$ip" && continue
    echo "$ip"; found=$((found+1))
  done
}

# Interfejs lokalny w danej podsieci (dla arping)
iface_for_net() {
  local cidr=$1 line dev addr
  while read -r dev addr; do
    cidr_overlap "${addr%/*}/32" "$cidr" && { echo "$dev"; return; }
  done < <(ip -o -4 addr show | awk '{print $2, $4}')
}

# ------------------------------------------------------------- kubernetes ----
k8s_clusters() { cmsh_q "kubernetes; list" | awk '!/^(Name|-)/ && NF && $1!~/Unable|Unknown|error/ {print $1}'; }

k8s_env() {
  local c=${1:-}
  have kubectl && kubectl version --request-timeout=5s >/dev/null 2>&1 && return 0
  # shellcheck disable=SC1091
  [ -r /etc/profile.d/modules.sh ] && . /etc/profile.d/modules.sh
  if have module; then
    if [ -n "$c" ]; then module load "kubernetes/$c" 2>/dev/null || module load kubernetes 2>/dev/null
    else module load kubernetes 2>/dev/null; fi
  fi
  have kubectl
}

# Operatory wymagane przez Run:ai dla danej ścieżki: "etykieta|regex dla helm list / ns / crd"
runai_required_components() {
  case $1 in
    flow_bcm11_split) cat <<'EOF'
NVIDIA GPU Operator|gpu-operator
Grafana Operator|grafana-operator
Kgateway|kgateway
Knative Operator (Serving)|knative
Kubeflow Training Operator|training-operator|kubeflow-training
Kubernetes Metrics Server|metrics-server
Kubernetes MPI Operator|mpi-operator
Kube State Metrics|kube-state-metrics|kube-prometheus
LeaderWorkerSet Operator|lws
MetalLB|metallb
Prometheus Operator Stack|kube-prometheus|prometheus-operator
Prometheus Adapter|prometheus-adapter
EOF
    ;;
    flow_bcm11_single) cat <<'EOF'
NVIDIA GPU Operator|gpu-operator
Grafana Operator|grafana-operator
Ingress NGINX Controller|ingress-nginx
Knative Operator (Serving)|knative
Kubeflow Training Operator|training-operator|kubeflow-training
Kubernetes Metrics Server|metrics-server
Kubernetes MPI Operator|mpi-operator
Kube State Metrics|kube-state-metrics|kube-prometheus
LeaderWorkerSet Operator|lws
MetalLB|metallb
Prometheus Operator Stack|kube-prometheus|prometheus-operator
Prometheus Adapter|prometheus-adapter
EOF
    ;;
    *) cat <<'EOF'
NVIDIA GPU Operator|gpu-operator
Kubernetes Metrics Server|metrics-server
Kubernetes MPI Operator|mpi-operator
Kubeflow Training Operator|training-operator|kubeflow-training
Kube State Metrics|kube-state-metrics|kube-prometheus
MetalLB|metallb
Prometheus Operator Stack|kube-prometheus|prometheus-operator
Prometheus Adapter|prometheus-adapter
EOF
    ;;
  esac
}

# --------------------------------------------------------------- maskowanie --
# Maskuje sekrety w plikach konfiguracyjnych kreatorów przed zapisaniem do raportu
mask_secrets() {
  sed -E \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\    ***MASKED PRIVATE KEY***' \
    -e 's/^([[:space:]-]*[A-Za-z0-9_.-]*(password|passwd|secret|token|apikey|api_key|ngc_key|ngckey|credential|credentials)[A-Za-z0-9_.-]*[[:space:]]*[:=][[:space:]]*)([^/[:space:]"'"'"'].*|"[^/].*|'"'"'[^/].*)$/\1"***MASKED***"/I' \
    -e 's/(nvapi-)[A-Za-z0-9_-]+/\1***MASKED***/g'
}

# ----------------------------------------------------- wykrywanie roli kubelet
# Znajduje overlay (lub kategorię), z którego węzeł-worker dostaje rolę kubelet.
# Wypisuje: "configurationoverlay <nazwa>" albo "category <nazwa>" albo "device <węzeł>"
find_kubelet_role_owner() {
  local node=$1 cluster=${2:-} cat ov line
  cat=$(awk -F'\t' -v h="$node" '$2==h{print $4}' "$WORKDIR/devices.tsv")
  line=$(cmsh_q "device; use $node; roles; list" | grep -Ei '\bkubelet\b' | head -1)
  if [[ $line =~ \[overlay:([^]]+)\] ]]; then echo "configurationoverlay ${BASH_REMATCH[1]}"; return; fi
  if [ -n "$cat" ]; then
    line=$(cmsh_q "category; use $cat; roles; list" | grep -Ei '\bkubelet\b' | head -1)
    if [[ $line =~ \[overlay:([^]]+)\] ]]; then echo "configurationoverlay ${BASH_REMATCH[1]}"; return; fi
    [ -n "$line" ] && { echo "category $cat"; return; }
  fi
  for ov in "kube-${cluster:-default}-worker" $(cmsh_q "configurationoverlay; list" | awk '!/^(Name|-)/ && $1 ~ /^kube-.*-worker$/ {print $1}'); do
    cmsh_q "configurationoverlay; use $ov; roles; list" | grep -qEi '\bkubelet\b' && { echo "configurationoverlay $ov"; return; }
  done
  [ -n "$line" ] && echo "device $node"
}

# ------------------------------------------------------- wybór wersji K8s ----
# choose_k8s_version <flow> <lista wersji z --list-versions>
# Run:ai 2.25 wspiera K8s 1.33-1.35 (przewodnik BCM testowany na 1.34);
# Run:ai 2.23 (BCM 11.32.1) - przewodnik na 1.34. Preferujemy 1.34.
choose_k8s_version() {
  local flow=$1 list=$2 v best=
  printf '%s\n' $list | grep -qx 1.34 && { echo 1.34; return; }
  for v in $(printf '%s\n' $list | grep -E '^1\.[0-9]+$' | sort -V); do
    case $flow in
      flow_bcm11_single) ver_ge 1.34 "$v" && best=$v;;
      *) ver_ge "$v" 1.33 && ver_ge 1.35 "$v" && best=$v;;
    esac
  done
  echo "${best:-1.34}"
}

# ------------------------------------------------- pełne wykrycie środowiska -
# Ustawia zmienne D_* i zapisuje je do $WORKDIR/discovered.env
discover_all() {
  local h t s probe c m d sw l
  detect_os; detect_bcm
  discover_devices; discover_status

  D_HEAD_NODES=$(awk -F'\t' '$1=="HeadNode"{print $2}' "$WORKDIR/devices.tsv" | xargs)
  D_ACTIVE_HEAD=$(hostname -s)
  D_HA=no; [ "$(wc -w <<<"$D_HEAD_NODES")" -ge 2 ] && D_HA=yes

  D_GPU_NODES=; D_GPU_COUNTS=; D_CPU_NODES=; D_DOWN_NODES=; D_GPU_MODELS=; D_DRIVERS=
  D_NVSWITCH=no; D_DRIVER_FROM_IMAGE=yes; D_GPU_TOTAL=0
  : >"$WORKDIR/gpus.tsv"
  while IFS=$'\t' read -r t h _ _ _ _; do
    is_compute_type "$t" || continue
    s=$(awk -F'\t' -v h="$h" '$1==h{print $2}' "$WORKDIR/status.tsv")
    if [ "${s%% *}" != UP ]; then D_DOWN_NODES="$D_DOWN_NODES $h(${s:-?})"; continue; fi
    probe=$(gpu_probe "$h")
    IFS='|' read -r c m d sw l <<<"${probe:-0||||0}"
    c=${c:-0}; l=${l:-0}
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$h" "$c" "$m" "$d" "$sw" "$l" >>"$WORKDIR/gpus.tsv"
    if [ "$c" -gt 0 ] || [ "$l" -gt 0 ]; then
      D_GPU_NODES="$D_GPU_NODES $h"; D_GPU_COUNTS="$D_GPU_COUNTS $h:$(( c>0 ? c : l ))"
      D_GPU_TOTAL=$(( D_GPU_TOTAL + (c>0 ? c : l) ))
      [ -n "$m" ] && D_GPU_MODELS="$D_GPU_MODELS $h:${m// /_}"
      [ -n "$d" ] && D_DRIVERS="$D_DRIVERS $h:$d"
      [ "${sw:-0}" -gt 0 ] && D_NVSWITCH=yes
      # GPU widoczne w lspci, ale nvidia-smi nie działa -> sterownika nie ma w obrazie
      [ "$c" -eq 0 ] && D_DRIVER_FROM_IMAGE=no
    else
      D_CPU_NODES="$D_CPU_NODES $h"
    fi
  done <"$WORKDIR/devices.tsv"
  D_GPU_COUNTS=$(xargs <<<"$D_GPU_COUNTS"); D_GPU_MODELS=$(xargs <<<"$D_GPU_MODELS"); D_DRIVERS=$(xargs <<<"$D_DRIVERS")
  D_GPU_NODES=$(xargs <<<"$D_GPU_NODES"); D_CPU_NODES=$(xargs <<<"$D_CPU_NODES"); D_DOWN_NODES=$(xargs <<<"$D_DOWN_NODES")

  # Workery: domyślnie wszystkie węzły UP z GPU (nadpisywalne WORKERS="a b")
  D_WORKERS=${WORKERS:-$D_GPU_NODES}
  local w1; w1=$(awk '{print $1}' <<<"$D_WORKERS")
  D_WORKER_CATEGORIES=$(for h in $D_WORKERS; do awk -F'\t' -v h="$h" '$2==h{print $4}' "$WORKDIR/devices.tsv"; done | sort -u | xargs)
  # Węzły w kategoriach workerów, które NIE będą workerami (np. DOWN) - ważne dla cm-runai-setup
  D_CATEGORY_EXTRA=
  for c in $D_WORKER_CATEGORIES; do
    for h in $(awk -F'\t' -v c="$c" '$4==c{print $2}' "$WORKDIR/devices.tsv"); do
      in_list "$h" $D_WORKERS || D_CATEGORY_EXTRA="$D_CATEGORY_EXTRA $h"
    done
  done
  D_CATEGORY_EXTRA=$(xargs <<<"$D_CATEGORY_EXTRA")

  # CPU/RAM aktywnego head node i workerów: "host:rdzenie/RAM_GB"
  D_NODE_RES=
  for h in $(printf '%s\n' "$D_ACTIVE_HEAD" $D_WORKERS | awk 'NF && !s[$0]++'); do
    read -r c m <<<"$(node_res "$h")"
    [ -n "$c" ] && D_NODE_RES="$D_NODE_RES $h:$c/${m:-0}"
  done
  D_NODE_RES=$(xargs <<<"$D_NODE_RES")

  # Sieć węzłów (z niej idą adresy MetalLB L2)
  D_NODE_NET=${LB_NETWORK:-$(awk -F'\t' -v h="${w1:-$D_ACTIVE_HEAD}" '$2==h{print $6}' "$WORKDIR/devices.tsv")}
  [ -z "$D_NODE_NET" ] && D_NODE_NET=internalnet
  if network_info "$D_NODE_NET"; then
    D_NET_CIDR="$NET_BASE/$NET_BITS"; D_NET_GW=$NET_GW; D_NET_DOMAIN=$NET_DOMAIN
    D_NET_DYN="${NET_DYN_S:-}-${NET_DYN_E:-}"
  else
    D_NET_CIDR=; D_NET_GW=; D_NET_DOMAIN=; D_NET_DYN=
  fi
  D_HEAD_IP=$(awk -F'\t' -v h="$D_ACTIVE_HEAD" '$2==h{print $5}' "$WORKDIR/devices.tsv")

  # Skąd łączy się użytkownik (jump host) - czy widzi sieć węzłów bez routingu?
  D_CLIENT_IP=${SSH_CLIENT%% *}; D_CLIENT_IN_NET=unknown
  if is_ipv4 "${D_CLIENT_IP:-}" && [ -n "$D_NET_CIDR" ]; then
    if cidr_overlap "$D_CLIENT_IP/32" "$D_NET_CIDR"; then D_CLIENT_IN_NET=yes; else D_CLIENT_IN_NET=no; fi
  fi

  # Wolne adresy LoadBalancer
  D_LB_NEED=$(flow_lb_count "$BCM_FLOW")
  if [ -n "${LB_IPS:-}" ]; then
    D_LB_IPS=$LB_IPS
  elif [ -n "$D_NET_CIDR" ]; then
    bcm_used_ips | sort -u >"$WORKDIR/used-ips.txt"
    LB_IFACE=$(iface_for_net "$D_NET_CIDR")
    D_LB_IPS=$(find_free_ips "$NET_BASE" "$NET_BITS" "$NET_DYN_S" "$NET_DYN_E" "$NET_GW" "$D_LB_NEED" "$WORKDIR/used-ips.txt" | xargs)
  fi

  # CIDR-y K8s bez kolizji z sieciami BCM i trasami
  list_bcm_networks >"$WORKDIR/networks.txt"
  ip -o -4 route 2>/dev/null | awk '{print $1}' | grep '/' >"$WORKDIR/networks.txt.routes"
  D_SVC_CIDR=${SVC_CIDR:-$(pick_free_cidr 10.150.0.0/16 10.152.0.0/16 10.154.0.0/16 10.160.0.0/16 172.30.0.0/16)}
  D_POD_CIDR=${POD_CIDR:-$(pick_free_cidr 172.29.0.0/16 172.31.0.0/16 10.170.0.0/16 10.180.0.0/16)}

  # Istniejące K8s i dostępne wersje
  D_K8S_CLUSTERS=$(have cmsh && k8s_clusters | xargs)
  D_K8S_VERSIONS=
  have cm-kubernetes-setup && D_K8S_VERSIONS=$(tmo 180 cm-kubernetes-setup --list-versions 2>/dev/null | grep -Eo '^ *1\.[0-9]+' | xargs)
  D_K8S_VERSION=${K8S_VERSION:-$(choose_k8s_version "$BCM_FLOW" "$D_K8S_VERSIONS")}

  # Domena / FQDN Run:ai (nadpisywalne DOMAIN=, RUNAI_FQDN=)
  D_DOMAIN=${DOMAIN:-${D_ACTIVE_HEAD}.internal}
  D_RUNAI_FQDN=${RUNAI_FQDN:-runai.$D_DOMAIN}
  D_INFERENCE_WILDCARD="*.inference.$D_DOMAIN"

  write_discovered_env "$WORKDIR/discovered.env"
}

pick_free_cidr() {
  local c n hit
  for c in "$@"; do
    hit=0
    while read -r _ n _; do [ -n "$n" ] && ! is_default_net "$n" && cidr_overlap "$c" "$n" && hit=1; done <"$WORKDIR/networks.txt"
    while read -r n; do [ -n "$n" ] && ! is_default_net "$n" && cidr_overlap "$c" "$n" && hit=1; done <"$WORKDIR/networks.txt.routes"
    [ $hit = 0 ] && { echo "$c"; return; }
  done
  echo "$1"
}

write_discovered_env() {
  {
    echo "# Wygenerowane przez $(basename "$0") $(date -Is) na $(hostname)"
    for v in BCM_RELEASE BCM_SRC BCM_FLOW OS_ID OS_VER OS_FAMILY \
             D_HEAD_NODES D_ACTIVE_HEAD D_HA D_HEAD_IP D_GPU_NODES D_GPU_COUNTS D_GPU_TOTAL D_GPU_MODELS D_DRIVERS \
             D_NVSWITCH D_DRIVER_FROM_IMAGE D_CPU_NODES D_DOWN_NODES D_WORKERS D_WORKER_CATEGORIES D_CATEGORY_EXTRA D_NODE_RES \
             D_NODE_NET D_NET_CIDR D_NET_GW D_NET_DOMAIN D_NET_DYN D_CLIENT_IP D_CLIENT_IN_NET \
             D_LB_NEED D_LB_IPS D_SVC_CIDR D_POD_CIDR D_K8S_CLUSTERS D_K8S_VERSIONS D_K8S_VERSION \
             D_DOMAIN D_RUNAI_FQDN D_INFERENCE_WILDCARD; do
      printf '%s=%q\n' "$v" "${!v:-}"
    done
  } >"$1"
}
