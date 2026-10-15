#!/bin/bash
# bcm-deploy.sh - wdrożenie Kubernetes + NVIDIA Run:ai (self-hosted) na klastrze BCM
#
# Wszystko jest wykrywane (wersja BCM, węzły, GPU, sieć, wolne IP, CIDR-y).
# Każdą wartość można nadpisać flagą albo edytując /root/bcm-deploy/deploy.env
# (powstaje w fazie "plan").
#
# Użycie (root, aktywny head node, najlepiej w screen/tmux):
#   ./bcm-deploy.sh                       # wszystkie fazy po kolei (pomija ukończone)
#   ./bcm-deploy.sh --phase plan          # tylko plan (bezpieczne, nic nie zmienia)
#   ./bcm-deploy.sh --phase dns,certs     # wybrane fazy
#   ./bcm-deploy.sh --dry-run             # pokaż, co byłoby zrobione
#
# Fazy: plan prereq dns certs k8s tune validate pgdb runai verify access cleanup
#
# Opcje:
#   --domain D            domena dla Run:ai (domyślnie <head>.internal)
#   --fqdn F              FQDN Run:ai (domyślnie runai.<domena>)
#   --workers "n1 n2"     workery K8s (domyślnie: wszystkie węzły UP z GPU)
#   --lb-ips "ip1 ip2 .." adresy LoadBalancer (domyślnie: wykryte wolne)
#   --lb-network NAZWA    sieć BCM dla MetalLB L2 (domyślnie: sieć workerów)
#   --cluster-name N      nazwa klastra K8s w BCM (domyślnie: default)
#   --k8s-version V       wersja K8s (domyślnie: wybrana z --list-versions, preferowana 1.34)
#   --max-pods N          maxPods kubeleta na workerach (domyślnie 250)
#   --ngc-key-file F      plik z kluczem NGC API (Run:ai 2.25 / Helm)
#   --runai-credential-file F   plik z tokenem base64 (BCM 11.0-11.32, Run:ai 2.23)
#   --cert F --key F [--ca F]   własny certyfikat (full chain) + klucz (+ CA)
#   --admin-email E       login administratora Run:ai
#   --runai-version V     wersja Run:ai dla ścieżki Helm: 2.26 (najnowsza 2.26.x) albo 2.26.7;
#                         domyślnie najnowsza dostępna w repo NGC
#   --runai-via helm      BCM 11: K8s z kreatora BCM, Run:ai przez Helm (np. 2.26 albo zewnętrzna baza)
#   --pg-in-k8s           baza Run:ai = PostgreSQL 16 w K8s (operator Zalando, namespace runai-db);
#                         wymaga --runai-via helm (kreatory BCM nie mają opcji zewnętrznej bazy)
#   --external-pg H[:P]   baza Run:ai = istniejący PostgreSQL 16 pod adresem H, port P (domyślnie 5432)
#   --pg-size S           rozmiar wolumenu bazy dla --pg-in-k8s (domyślnie 20Gi)
#   --skip-dns            nie twórz strefy BIND (DNS jest zewnętrzny)
#   --force-flow FLOW     wymuś ścieżkę: flow_bcm11_split|flow_bcm11_single|flow_bcm10_helm
#   --replan              wylicz plan od nowa (nadpisze deploy.env)
#   --yes                 nie pytaj o potwierdzenia
#   --dry-run             nic nie zmieniaj, tylko pokaż

set -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -r "$SCRIPT_DIR/lib/common.sh" ] || { echo "Brak lib/common.sh - sklonuj całe repozytorium." >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ALL_PHASES="plan prereq dns certs k8s tune validate pgdb runai verify access cleanup"
PHASES=; DRY=0; YES=0; REPLAN=0; SKIP_DNS=0
CLI_VARS=   # zmienne podane flagą - mają pierwszeństwo przed deploy.env (load_env)
while [ $# -gt 0 ]; do
  case $1 in
    --phase) PHASES=${2//,/ }; shift;;
    --domain) DOMAIN=$2; shift;;
    --fqdn) RUNAI_FQDN=$2; shift;;
    --workers) WORKERS=$2; shift;;
    --lb-ips) LB_IPS=$2; shift;;
    --lb-network) LB_NETWORK=$2; shift;;
    --cluster-name) CLUSTER_NAME=$2; CLI_VARS+=" CLUSTER_NAME"; shift;;
    --k8s-version) K8S_VERSION=$2; CLI_VARS+=" K8S_VERSION"; shift;;
    --max-pods) MAX_PODS=$2; CLI_VARS+=" MAX_PODS"; shift;;
    --ngc-key-file) NGC_KEY_SRC=$2; shift;;
    --runai-credential-file) RUNAI_CRED_SRC=$2; shift;;
    --cert) USER_CERT=$2; CLI_VARS+=" USER_CERT"; shift;;
    --key) USER_KEY=$2; CLI_VARS+=" USER_KEY"; shift;;
    --ca) USER_CA=$2; CLI_VARS+=" USER_CA"; shift;;
    --admin-email) ADMIN_EMAIL=$2; CLI_VARS+=" ADMIN_EMAIL"; shift;;
    --runai-version) RUNAI_VERSION=$2; CLI_VARS+=" RUNAI_VERSION"; shift;;
    --runai-via) RUNAI_VIA=$2; CLI_VARS+=" RUNAI_VIA"; shift;;
    --pg-in-k8s) PG_MODE=k8s; CLI_VARS+=" PG_MODE";;
    --external-pg) PG_MODE=external; PG_HOST=${2%%:*}; PG_PORT=${2#*:}; [ "$PG_PORT" = "$2" ] && PG_PORT=5432
                   CLI_VARS+=" PG_MODE PG_HOST PG_PORT"; shift;;
    --pg-size) PG_SIZE=$2; CLI_VARS+=" PG_SIZE"; shift;;
    --skip-dns) SKIP_DNS=1; CLI_VARS+=" SKIP_DNS";;
    --force-flow) FORCE_FLOW=$2; shift;;
    --replan) REPLAN=1;;
    --yes) YES=1;;
    --dry-run) DRY=1;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0;;
    *) echo "Nieznana opcja: $1 (zob. --help)" >&2; exit 2;;
  esac; shift
done
export DOMAIN RUNAI_FQDN WORKERS LB_IPS LB_NETWORK K8S_VERSION FORCE_FLOW YES

[ "$(id -u)" = 0 ] || die "Uruchom jako root."
have cmsh || { [ -x /cm/local/apps/cmd/bin/cmsh ] && PATH=$PATH:/cm/local/apps/cmd/bin; }
have cmsh || die "Nie znaleziono cmsh - to nie wygląda na head node BCM."

BASE=${BCM_DEPLOY_BASE:-/root/bcm-deploy}
WORKDIR=$BASE/work
STATE=$BASE/state
ENVF=$BASE/deploy.env
mkdir -p "$WORKDIR"; chmod 700 "$BASE"; touch "$STATE"
LOG_FILE=$BASE/deploy-$(date +%Y%m%d-%H%M%S).log
REPORT=$BASE/checks.txt
export WORKDIR LOG_FILE REPORT

# run <opis> <komenda...> - wykonuje albo (dry-run) tylko wypisuje
run() {
  local d=$1; shift
  if [ "$DRY" = 1 ]; then info "[dry-run] $d: $*"; return 0; fi
  info "$d"; "$@" 2>&1 | tee -a "$LOG_FILE"; return "${PIPESTATUS[0]}"
}
done_phase() { [ "$DRY" = 1 ] || { grep -qx "$1" "$STATE" || echo "$1" >>"$STATE"; }; }
is_done()    { grep -qx "$1" "$STATE"; }

load_env() {
  local f=$ENVF
  [ "$DRY" = 1 ] && [ ! -r "$f" ] && [ -r "$ENVF.dry-run" ] && f=$ENVF.dry-run
  [ -r "$f" ] || die "Brak $ENVF - uruchom najpierw: $0 --phase plan"
  local v saved=
  for v in $CLI_VARS; do saved+=$(printf '%s=%q;' "$v" "${!v}"); done
  # shellcheck disable=SC1090
  . "$f"
  # Flagi z linii poleceń wygrywają z planem i są w nim zapisywane na kolejne uruchomienia
  if [ -n "$saved" ]; then
    eval "$saved"
    if [ "$DRY" != 1 ] && [ "$f" = "$ENVF" ]; then
      for v in $CLI_VARS; do
        grep -v "^$v=" "$ENVF" >"$ENVF.tmp"; printf '%s=%q\n' "$v" "${!v}" >>"$ENVF.tmp"
        mv "$ENVF.tmp" "$ENVF"; chmod 600 "$ENVF"
      done
    fi
  fi
  detect_os
  RUNAI_IP=${LB_RUNAI_GW:-$LB_RUNAI_INGRESS}
  [ "$FLOW" = flow_bcm10_helm ] && RUNAI_VIA=helm
  RUNAI_VIA=${RUNAI_VIA:-wizard}; PG_MODE=${PG_MODE:-bundled}
  # Ścieżka Helm: inference idzie przez ten sam ingress HAProxy co Run:ai (docs 2.26),
  # więc *.inference wskazuje na RUNAI_IP, a Kourier zostaje ClusterIP.
  if [ "$RUNAI_VIA" = helm ]; then INFER_IP=$RUNAI_IP; else INFER_IP=$LB_INFERENCE; fi
  check_runai_mode "$FLOW"
}

# Zestaw operatorów wymaganych przez Run:ai dla bieżącej ścieżki
req_flow() { if [ "$RUNAI_VIA" = helm ] && [ "$FLOW" != flow_bcm10_helm ]; then echo helm_bcm11; else echo "$FLOW"; fi; }

pg_desc() {
  case $PG_MODE in
    k8s)      echo "PostgreSQL 16 w K8s (Zalando): $PG_CLUSTER.$PG_NS, wolumen $PG_SIZE, sslmode=$PG_SSLMODE";;
    external) echo "zewnętrzny PostgreSQL 16: $PG_HOST:$PG_PORT, baza $PG_DB, użytkownik $PG_USER, sslmode=$PG_SSLMODE";;
    *)        echo "wbudowana w chart Run:ai (StatefulSet w runai-backend)";;
  esac
}

in_multiplexer() { [ -n "${STY:-}" ] || [ -n "${TMUX:-}" ]; }

# Klucz NGC / token jako plik (kreatory przyjmują ścieżkę)
secret_file_prompt() {
  local dst=$1 what=$2 k
  [ -s "$dst" ] && return 0
  [ "$DRY" = 1 ] && { info "[dry-run] zapytałbym o: $what -> $dst"; return 0; }
  read -r -s -p "Podaj $what (nie będzie wyświetlany): " k </dev/tty; echo
  [ -n "$k" ] || die "Pusty $what"
  ( umask 077; printf '%s\n' "$k" >"$dst" ); unset k
  ok "Zapisano $dst (chmod 600)"
}

# ====================================================================== plan ==
phase_plan() {
  hdr "PLAN - wykrywanie środowiska"
  if [ -r "$ENVF" ] && [ "$REPLAN" = 0 ]; then
    info "Używam istniejącego $ENVF (wylicz od nowa: --replan)"; load_env; print_plan; return 0
  fi
  discover_all
  [ "$BCM_FLOW" = flow_unknown ] && die "Nie rozpoznano wersji BCM ($BCM_RELEASE). Użyj --force-flow."
  [ -n "$D_WORKERS" ] || die "Brak workerów: nie znaleziono węzłów UP z GPU (podaj --workers)."
  check_runai_mode "$BCM_FLOW"

  local ips=($D_LB_IPS)
  [ "${#ips[@]}" -ge "$D_LB_NEED" ] || die "Za mało wolnych IP LoadBalancer (${#ips[@]}/$D_LB_NEED). Podaj --lb-ips."

  local cat1; cat1=$(awk '{print $1}' <<<"$D_WORKER_CATEGORIES")
  {
    echo "# Plan wdrożenia - wygenerowany $(date -Is). Możesz edytować przed kolejnymi fazami."
    cat "$WORKDIR/discovered.env" | grep -v '^#'
    printf '%s=%q\n' \
      FLOW "$BCM_FLOW" \
      CLUSTER_NAME "${CLUSTER_NAME:-default}" \
      K8S_VERSION "$D_K8S_VERSION" \
      CP_NODES "$( [ "$D_HA" = yes ] && echo "$D_HEAD_NODES" || echo "$D_ACTIVE_HEAD")" \
      ETCD_NODES "$(etcd_nodes)" \
      WORKER_NODES "$D_WORKERS" \
      SVC_CIDR "$D_SVC_CIDR" POD_CIDR "$D_POD_CIDR" \
      DOMAIN "$D_DOMAIN" RUNAI_FQDN "$D_RUNAI_FQDN" \
      RUNAI_DIR "${RUNAI_DIR:-/cm/shared/runai}" \
      RUNAI_CP_CATEGORY "$cat1" \
      MAX_PODS "${MAX_PODS:-250}" \
      GPU_DRIVER_ENABLED "$( [ "$D_DRIVER_FROM_IMAGE" = yes ] && echo no || echo yes)" \
      ADMIN_EMAIL "${ADMIN_EMAIL:-admin@$D_DOMAIN}" \
      RUNAI_VERSION "${RUNAI_VERSION:-}" \
      USER_CERT "${USER_CERT:-}" USER_KEY "${USER_KEY:-}" USER_CA "${USER_CA:-}" \
      SKIP_DNS "$SKIP_DNS" \
      RUNAI_VIA "$( [ "$BCM_FLOW" = flow_bcm10_helm ] && echo helm || echo "${RUNAI_VIA:-wizard}")" \
      PG_MODE "${PG_MODE:-bundled}" PG_SIZE "${PG_SIZE:-20Gi}" \
      PG_NS "${PG_NS:-runai-db}" PG_CLUSTER "${PG_CLUSTER:-runai-pg}" PG_DB "${PG_DB:-runai}" PG_USER "${PG_USER:-runai}" \
      PG_HOST "${PG_HOST:-}" PG_PORT "${PG_PORT:-5432}" PG_SSLMODE "${PG_SSLMODE:-require}"
    case $BCM_FLOW/${RUNAI_VIA:-wizard} in
      flow_bcm11_split/wizard) printf '%s=%q\n' LB_BCM_GW "${ips[0]}" LB_RUNAI_GW "${ips[1]}" LB_INFERENCE "${ips[2]}";;
      *)                       printf '%s=%q\n' LB_RUNAI_INGRESS "${ips[0]}" LB_INFERENCE "${ips[1]}";;
    esac
  } >"$WORKDIR/deploy.env.new"
  if [ "$DRY" = 1 ]; then cp "$WORKDIR/deploy.env.new" "$ENVF.dry-run"; load_env
  else mv "$WORKDIR/deploy.env.new" "$ENVF"; chmod 600 "$ENVF"; load_env; fi
  print_plan
  confirm "Czy plan jest poprawny? (edytuj $ENVF jeśli nie)" || die "Przerwano - popraw $ENVF i uruchom ponownie."
  done_phase plan
}

# Spójność wyboru: ścieżka Run:ai (kreator BCM / Helm) a rodzaj bazy
check_runai_mode() {
  local flow=$1 via=${RUNAI_VIA:-wizard} pg=${PG_MODE:-bundled}
  [ "$flow" = flow_bcm10_helm ] && via=helm
  case $via in helm|wizard) ;; *) die "--runai-via: dozwolone 'helm' albo 'wizard' (jest: $via)";; esac
  case $pg in bundled|k8s|external) ;; *) die "PG_MODE: dozwolone bundled|k8s|external (jest: $pg)";; esac
  if [ "$pg" != bundled ] && [ "$via" != helm ]; then
    die "Zewnętrzna baza (--pg-in-k8s / --external-pg) wymaga --runai-via helm: kreatory BCM (cm-kubernetes-setup, cm-runai-setup) nie mają takiej opcji."
  fi
  [ "$pg" = external ] && [ -z "${PG_HOST:-}" ] && die "--external-pg wymaga adresu: --external-pg host[:port]"
  return 0
}

# etcd wymaga nieparzystej liczby członków (1, 3, 5...). Przy 2 head node'ach (HA)
# dokładamy pierwszy worker, żeby było 3.
etcd_nodes() {
  local heads; heads=$( [ "$D_HA" = yes ] && echo "$D_HEAD_NODES" || echo "$D_ACTIVE_HEAD")
  if [ $(( $(wc -w <<<"$heads") % 2 )) -eq 0 ]; then echo "$heads $(awk '{print $1}' <<<"$D_WORKERS")"; else echo "$heads"; fi
}

print_plan() {
  hdr "Plan wdrożenia ($ENVF)"
  cat <<EOF | tee -a "$LOG_FILE"
  BCM:              $BCM_RELEASE  ->  $FLOW
                    $(flow_desc "$FLOW")$( [ "$RUNAI_VIA" = helm ] && [ "$FLOW" != flow_bcm10_helm ] && printf '\n                    -> tu kreator BCM tylko dla K8s; Run:ai przez Helm (fazy pgdb + runai)')
  OS head node:     $OS_ID $OS_VER ($OS_FAMILY)
  Klaster K8s:      $CLUSTER_NAME, wersja $K8S_VERSION
  Control plane:    $CP_NODES
  etcd:             $ETCD_NODES
  Workery:          $WORKER_NODES   (GPU: $D_GPU_COUNTS)
  Pominięte:        ${D_DOWN_NODES:-brak}
  Sieć LB (L2):     $D_NODE_NET $D_NET_CIDR
  Service / Pod:    $SVC_CIDR / $POD_CIDR
  Run:ai FQDN:      $RUNAI_FQDN  (+ *.${RUNAI_FQDN}, $D_INFERENCE_WILDCARD)
  Adresy LB:        ${LB_BCM_GW:+BCM gateway (Kgateway)=$LB_BCM_GW  }Run:ai=${RUNAI_IP}  inference=$INFER_IP$( [ "$RUNAI_VIA" = helm ] && echo "  (przez HAProxy; zapas: $LB_INFERENCE)")
  Run:ai:           $( [ "$RUNAI_VIA" = helm ] && echo "Helm, wersja ${RUNAI_VERSION:-najnowsza z repo NGC}" || echo "kreator BCM")
  Baza Run:ai:      $(pg_desc)
  Pliki Run:ai:     $RUNAI_DIR
  Run:ai CP kategoria: $RUNAI_CP_CATEGORY
  maxPods worker:   $MAX_PODS
  GPU Operator driver.enabled: $GPU_DRIVER_ENABLED  (no = sterownik z obrazu BCM)
EOF
  if [ -n "$D_CATEGORY_EXTRA" ] && [ "$RUNAI_VIA" != helm ]; then
    warn "Kategoria $RUNAI_CP_CATEGORY zawiera też: $D_CATEGORY_EXTRA (nie-workery). Kreator Run:ai wybiera KATEGORIĘ dla control plane -"
    warn "  jeśli tamte węzły nie działają, przenieś je do innej kategorii przed fazą runai (np. cmsh: category; clone $RUNAI_CP_CATEGORY $RUNAI_CP_CATEGORY-spare)."
  fi
  [ "$D_CLIENT_IN_NET" = no ] && warn "Twój jump host ($D_CLIENT_IP) jest poza $D_NET_CIDR - do UI potrzebna będzie trasa/proxy (zob. faza access)."
  return 0
}

# ==================================================================== prereq ==
phase_prereq() {
  hdr "PREREQ - warunki wstępne"
  load_env
  local fail=0 h fm
  in_multiplexer || warn "Nie jesteś w screen/tmux - instalacja trwa 30-90 min, zerwanie SSH przerwie kreator."
  discover_status
  for h in $WORKER_NODES; do
    awk -F'\t' -v h="$h" '$1==h{print $2}' "$WORKDIR/status.tsv" | grep -q '^UP' || { err "$h nie jest UP"; fail=1; }
    nssh "$h" 'nvidia-smi -L' >/dev/null 2>&1 || { [ "$GPU_DRIVER_ENABLED" = yes ] || { err "$h: nvidia-smi nie działa"; fail=1; }; }
    if [ "$D_NVSWITCH" = yes ]; then
      fm=$(nssh "$h" 'systemctl is-active nvidia-fabricmanager' 2>/dev/null)
      [ "$fm" = active ] || { err "$h: nvidia-fabricmanager = ${fm:-?} (sprawdź wersję FM vs driver - docs rozdz. 2.4)"; fail=1; }
    fi
    nssh "$h" 'curl -sI -m5 https://nvcr.io >/dev/null' || warn "$h: brak dostępu do nvcr.io"
  done
  cmsh_q "softwareimage; islocked" | grep -iE '\byes\b' && warn "Zablokowane obrazy - odblokuj (softwareimage unlock <obraz>), inaczej reboot workera zawiśnie"
  for ip in $LB_BCM_GW $RUNAI_IP $LB_INFERENCE; do
    if ip_in_use "$ip" && ! { k8s_env "$CLUSTER_NAME" && kubectl get svc -A 2>/dev/null | grep -qw "$ip"; }; then
      err "Adres $ip odpowiada w sieci - nie jest wolny"; fail=1
    fi
  done
  case $FLOW in
    flow_bcm11_split)
      have cm-runai-setup || { err "Brak cm-runai-setup (wymagany cm-setup >= 11.33.1)"; fail=1; }
      if [ -z "$(pkg_ver cm-setup-runai-bcm11)" ]; then
        [ -n "$(pkg_candidate cm-setup-runai-bcm11)" ] && info "cm-setup-runai-bcm11 zostanie doinstalowany przez kreator" \
          || warn "cm-setup-runai-bcm11 niedostępny w repo (air-gap?) - zainstaluj ręcznie"
      fi;;
  esac
  have cm-kubernetes-setup || { err "Brak cm-kubernetes-setup"; fail=1; }
  [ $fail = 0 ] || die "Warunki wstępne niespełnione - popraw i uruchom ponownie (szczegóły powyżej)."
  ok "Warunki wstępne OK"
  done_phase prereq
}

# ======================================================================= dns ==
phase_dns() {
  load_env
  hdr "DNS - strefa $DOMAIN w BIND na head node"
  [ "$SKIP_DNS" = 1 ] && { info "Pominięto (--skip-dns). Upewnij się, że zewnętrzny DNS ma rekordy:"; dns_records_txt; done_phase dns; return; }
  [[ $RUNAI_FQDN == *".$DOMAIN" ]] || die "FQDN $RUNAI_FQDN nie leży w domenie $DOMAIN"
  local label=${RUNAI_FQDN%.$DOMAIN} zf="$ZONE_DIR/$DOMAIN.zone" serial
  serial=$(date +%Y%m%d)01
  grep -qs "named.conf.include" "$NAMED_CONF" || warn "$NAMED_CONF nie zawiera include $NAMED_INCLUDE - strefa może nie zostać wczytana"
  local tmp=$WORKDIR/zone.$$
  cat >"$tmp" <<EOF
\$TTL 300
@ IN SOA ns.$DOMAIN. root.$DOMAIN. ($serial 3600 600 86400 300)
@ IN NS ns.$DOMAIN.
ns IN A $D_HEAD_IP
$label IN A $RUNAI_IP
*.$label IN A $RUNAI_IP
*.inference IN A $INFER_IP
EOF
  info "Plik strefy $zf:"; sed 's/^/    /' "$tmp"
  if [ "$DRY" = 1 ]; then info "[dry-run] zapisałbym $zf i dopisał strefę do $NAMED_INCLUDE"; rm -f "$tmp"; return; fi
  [ -f "$zf" ] && cp -p "$zf" "$zf.bak-$(date +%s)"
  install -m 644 "$tmp" "$zf"; rm -f "$tmp"
  [ "$OS_FAMILY" = rhel ] && chown root:named "$zf" 2>/dev/null
  if ! grep -qs "zone \"$DOMAIN\"" "$NAMED_INCLUDE"; then
    cp -p "$NAMED_INCLUDE" "$NAMED_INCLUDE.bak-$(date +%s)" 2>/dev/null
    printf 'zone "%s" {\n    type master;\n    file "%s";\n};\n' "$DOMAIN" "$zf" >>"$NAMED_INCLUDE"
  fi
  named-checkconf || die "named-checkconf zgłasza błąd"
  named-checkzone "$DOMAIN" "$zf" || die "named-checkzone zgłasza błąd"
  systemctl restart named 2>/dev/null || systemctl restart bind9 || die "Nie udało się zrestartować BIND"
  sleep 2
  local r1 r2 r3 w1
  r1=$(resolve "$RUNAI_FQDN"); r2=$(resolve "x.$RUNAI_FQDN"); r3=$(resolve "x.inference.$DOMAIN")
  [ "$r1" = "$RUNAI_IP" ] && ok "$RUNAI_FQDN -> $r1" || die "$RUNAI_FQDN -> '${r1}' (oczekiwano $RUNAI_IP)"
  [ "$r2" = "$RUNAI_IP" ] && ok "*.$RUNAI_FQDN -> $r2" || warn "*.$RUNAI_FQDN -> '$r2'"
  [ "$r3" = "$INFER_IP" ] && ok "*.inference.$DOMAIN -> $r3" || warn "*.inference.$DOMAIN -> '$r3'"
  w1=$(awk '{print $1}' <<<"$WORKER_NODES")
  nssh "$w1" "getent hosts $RUNAI_FQDN" | grep -q "$RUNAI_IP" && ok "$w1 rozwiązuje $RUNAI_FQDN" || warn "$w1 nie rozwiązuje $RUNAI_FQDN (resolv.conf węzła?)"
  done_phase dns
}

# resolve <nazwa> -> pierwszy adres (dig @127.0.0.1, fallback getent)
resolve() {
  if have dig; then dig +short "$1" @127.0.0.1 2>/dev/null | grep -E '^[0-9.]+$' | head -1
  else getent hosts "$1" | awk '{print $1; exit}'; fi
}

dns_records_txt() {
  cat <<EOF
    $RUNAI_FQDN            A  $RUNAI_IP
    *.$RUNAI_FQDN          A  $RUNAI_IP
    *.inference.$DOMAIN    A  $INFER_IP
EOF
}

# ===================================================================== certs ==
phase_certs() {
  load_env
  hdr "CERTS - certyfikat TLS i klucze w $RUNAI_DIR"
  local d=$RUNAI_DIR
  if [ "$DRY" = 1 ]; then info "[dry-run] utworzyłbym $d, CA + cert z SAN $RUNAI_FQDN, *.$RUNAI_FQDN, $D_INFERENCE_WILDCARD"; return; fi
  install -d -m 700 "$d"
  if [ -n "$USER_CERT" ]; then
    [ -r "$USER_CERT" ] && [ -r "$USER_KEY" ] || die "Nie mogę odczytać --cert/--key"
    cert_check "$USER_CERT" "$USER_KEY" || die "Podany certyfikat nie pasuje (SAN/klucz/ważność) - szczegóły powyżej"
    cp "$USER_CERT" "$d/full-chain.pem"; ( umask 077; cp "$USER_KEY" "$d/private.key" )
    [ -n "$USER_CA" ] && cp "$USER_CA" "$d/ca.crt"
  else
    if [ -s "$d/full-chain.pem" ] && [ -s "$d/private.key" ] && cert_check "$d/full-chain.pem" "$d/private.key" 2>/dev/null; then
      ok "Istniejący certyfikat w $d jest poprawny - używam go"
    else
      ( cd "$d" || exit 1
        if [ ! -s ca.key ] || [ ! -s ca.crt ]; then
          openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -keyout ca.key -out ca.crt \
            -subj "/CN=$(hostname -s) Lab Root CA" 2>>"$LOG_FILE" || exit 1
        fi
        for f in private.key runai.csr runai.crt full-chain.pem; do [ -f "$f" ] && mv "$f" "$f.bak-$(date +%s)"; done
        openssl req -newkey rsa:2048 -nodes -keyout private.key -out runai.csr -subj "/CN=$RUNAI_FQDN" 2>>"$LOG_FILE" || exit 1
        printf 'subjectAltName=DNS:%s,DNS:*.%s,DNS:%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' \
          "$RUNAI_FQDN" "$RUNAI_FQDN" "$D_INFERENCE_WILDCARD" >runai.ext
        openssl x509 -req -in runai.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out runai.crt -days 825 -sha256 -extfile runai.ext 2>>"$LOG_FILE" || exit 1
        cat runai.crt ca.crt >full-chain.pem
        chmod 600 ./*.key
        openssl verify -CAfile ca.crt runai.crt ) || die "Generowanie certyfikatu nie powiodło się (log: $LOG_FILE)"
      cert_check "$d/full-chain.pem" "$d/private.key" || die "Wygenerowany certyfikat nie przeszedł weryfikacji"
      ok "Utworzono lokalne CA ($d/ca.crt) i certyfikat ($d/full-chain.pem)"
    fi
  fi
  case $FLOW/$RUNAI_VIA in
    flow_bcm11_single/wizard)
      if [ -n "${RUNAI_CRED_SRC:-}" ]; then ( umask 077; cp "$RUNAI_CRED_SRC" "$d/credential.jwt" )
      else secret_file_prompt "$d/credential.jwt" "token Run:ai (base64, z NVIDIA)"; fi;;
    *)
      if [ -n "${NGC_KEY_SRC:-}" ]; then ( umask 077; cp "$NGC_KEY_SRC" "$d/ngc-api-key" )
      else secret_file_prompt "$d/ngc-api-key" "klucz NGC API (org z uprawnieniem Run:ai)"; fi
      local code
      code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' -u "\$oauthtoken:$(tr -d '\n' <"$d/ngc-api-key")" https://helm.ngc.nvidia.com/nvidia/runai/index.yaml)
      case $code in 200) ok "Klucz NGC działa (helm.ngc.nvidia.com/nvidia/runai: 200)";;
                    000) warn "Brak połączenia z helm.ngc.nvidia.com - nie zweryfikowano klucza";;
                    *) die "Klucz NGC odrzucony (HTTP $code) - sprawdź klucz i uprawnienia org do Run:ai";; esac;;
  esac
  chmod 700 "$d"
  done_phase certs
}

# cert_check <cert> <key> - SAN, zgodność klucza, ważność
cert_check() {
  local c=$1 k=$2 san rc=0 n
  san=$(openssl x509 -in "$c" -noout -ext subjectAltName 2>/dev/null)
  for n in "$RUNAI_FQDN" "*.$RUNAI_FQDN"; do
    grep -qF "DNS:$n" <<<"$san" || { warn "Certyfikat $c nie ma SAN $n"; rc=1; }
  done
  grep -qF "DNS:$D_INFERENCE_WILDCARD" <<<"$san" || warn "Certyfikat bez SAN $D_INFERENCE_WILDCARD (inference po URL nie zadziała)"
  [ "$(openssl x509 -in "$c" -noout -pubkey 2>/dev/null | sha256sum)" = "$(openssl pkey -in "$k" -pubout 2>/dev/null | sha256sum)" ] \
    || { warn "Klucz $k nie pasuje do $c"; rc=1; }
  openssl x509 -in "$c" -noout -checkend 604800 >/dev/null || { warn "Certyfikat wygasa w ciągu 7 dni"; rc=1; }
  # samopodpisany leaf nie jest wspierany przez Run:ai
  [ "$(openssl x509 -in "$c" -noout -subject_hash)" = "$(openssl x509 -in "$c" -noout -issuer_hash)" ] && { warn "Certyfikat samopodpisany (nieobsługiwany) - użyj CA"; rc=1; }
  return $rc
}

# ======================================================================= k8s ==
phase_k8s() {
  load_env
  hdr "K8S - wdrożenie Kubernetes ($FLOW)"
  local existing; existing=$(k8s_clusters | xargs)
  if [ -n "$existing" ]; then
    ok "Klaster K8s już istnieje w BCM: $existing - pomijam instalację."
    check_operators || true
    done_phase k8s; return
  fi
  local conf=$BASE/cm-kubernetes-setup.conf tmpl="$SCRIPT_DIR/templates/cm-kubernetes-setup.$FLOW.yaml.tmpl"
  if [ -r "$tmpl" ]; then
    render_template "$tmpl" "$conf"
    info "Wygenerowano $conf z szablonu"
  else
    answers_k8s >"$BASE/answers-k8s.txt"
    cat "$BASE/answers-k8s.txt"
    info "Ściąga zapisana w $BASE/answers-k8s.txt (otwórz w drugim oknie: less $BASE/answers-k8s.txt)"
    [ "$DRY" = 1 ] && return
    in_multiplexer || warn "Uruchom w screen/tmux! (screen -S k8s)"
    confirm "Uruchomić teraz kreator cm-kubernetes-setup?" || die "Przerwano"
    rm -f "$conf"; touch "$WORKDIR/.k8s-wizard-start"
    cm-kubernetes-setup
    if k8s_clusters | grep -q .; then ok "Kreator wdrożył K8s (Save config & deploy)"; done_phase k8s; return; fi
    if [ ! -s "$conf" ]; then
      # kreator mógł zapisać pod domyślną ścieżką
      local cand; cand=$(find /root /cm/shared/runai -maxdepth 1 -name 'cm-kubernetes-setup*.conf' -newer "$WORKDIR/.k8s-wizard-start" 2>/dev/null | head -1)
      [ -n "$cand" ] && { info "Znaleziono zapisany config: $cand"; cp "$cand" "$conf"; }
    fi
    [ -s "$conf" ] || die "Nie znaleziono zapisanego configu - na ekranie Summary wybierz 'Save config & Exit' (np. $conf)"
  fi
  chmod 600 "$conf"
  confirm "Wdrożyć K8s z $conf (cm-kubernetes-setup -c, workery zostaną zrestartowane)?" || die "Przerwano"
  run "cm-kubernetes-setup -c $conf" cm-kubernetes-setup -c "$conf" || die "cm-kubernetes-setup zakończył się błędem (log: $LOG_FILE)"
  k8s_clusters | grep -q . || die "Po instalacji nie widać klastra w cmsh kubernetes list"
  ok "Kubernetes wdrożony"
  done_phase k8s
}

# Proste podstawienie {{ZMIENNA}} wartościami z deploy.env
render_template() {
  local in=$1 out=$2 v
  cp "$in" "$out.tmp"
  for v in $(grep -oE '\{\{[A-Z0-9_]+\}\}' "$in" | sort -u | tr -d '{}'); do
    local val=${!v:-}
    [ -n "$val" ] || warn "Szablon: pusta wartość $v"
    val=${val//\\/\\\\}; val=${val//&/\\&}; val=${val//|/\\|}
    sed -i "s|{{$v}}|$val|g" "$out.tmp"
  done
  ( umask 077; mv "$out.tmp" "$out" )
}

check_operators() {
  k8s_env "$CLUSTER_NAME" || { warn "kubectl niedostępny"; return 1; }
  local hl miss=; hl=$(helm list -A 2>/dev/null)
  while IFS='|' read -r label pat; do
    grep -qiE "$pat" <<<"$hl" || miss="$miss\n   - $label"
  done < <(runai_required_components "$(req_flow)")
  if [ -n "$miss" ]; then
    warn "Brakuje operatorów wymaganych przez Run:ai:$(printf "$miss")"
    warn "Dodaj je: cm-kubernetes-setup -> Modify operators -> Add operators (bez reinstalacji K8s)."
    warn "Jeśli pojawi się ekran wykluczeń Kyverno - dopisz ',runai*' na końcu KAŻDEJ z 5 list."
    return 1
  fi
  ok "Wszystkie operatory wymagane przez Run:ai są zainstalowane"
}

answers_k8s() {
  local ops k; k=$(req_flow)
  case $k in
    helm_bcm11) ops="NVIDIA GPU Operator, Knative Operator, Kubeflow Training Operator, Kubernetes Metrics Server,
                     Kubernetes MPI Operator, Kube State Metrics, LeaderWorkerSet Operator, MetalLB,
                     Prometheus Operator Stack$( [ "$PG_MODE" = k8s ] && echo ", PostgreSQL Operator (Zalando)")
                     (NIE: Run:ai, Ingress NGINX, Kgateway, Network Operator - Run:ai ${RUNAI_VERSION:-(najnowszą)}
                      i HAProxy instaluje Helm w fazie runai)";;
    flow_bcm11_split) ops="NVIDIA GPU Operator, Grafana Operator, Kgateway, Knative Operator, Kubeflow Training Operator,
                     Kubernetes Metrics Server, Kubernetes MPI Operator, Kube State Metrics, LeaderWorkerSet Operator,
                     MetalLB, Prometheus Adapter, Prometheus Operator Stack
                     (NIE: Ingress NGINX, Network Operator - chyba że multi-node IB/RoCE)";;
    flow_bcm11_single) ops="NVIDIA GPU Operator, Grafana Operator, Ingress NGINX Controller, Knative Operator,
                     Kubeflow Training Operator, Kubernetes Metrics Server, Kubernetes MPI Operator,
                     Kube State Metrics, LeaderWorkerSet Operator, MetalLB, Prometheus Adapter,
                     Prometheus Operator Stack, Run:ai (self-hosted)
                     (NIE: Network Operator - chyba że multi-node IB/RoCE)";;
    *) ops="NVIDIA GPU Operator, MetalLB, Kubernetes Metrics Server, Kube State Metrics,
                     Prometheus Operator Stack, Prometheus Adapter, MPI Operator, Kubeflow Training Operator
                     (Ingress: NIE z kreatora - Run:ai dostanie HAProxy przez Helm w fazie runai)";;
  esac
  cat <<EOF
================================================================================
 ŚCIĄGA: cm-kubernetes-setup   (wyliczona dla $(hostname -s), $(date +%F))
 Ścieżka: $FLOW - $(flow_desc "$FLOW")
================================================================================
 Ekran                               Odpowiedź
 ----------------------------------  ------------------------------------------
 Operacja                            Deploy
 Kubernetes version                  $K8S_VERSION   (jeśli pojawi się "Version conflict" z
                                     inną wersją -> Back i wybierz $K8S_VERSION)
 Docker Hub registry mirror          puste (chyba że masz mirror)
 Cluster name                        $CLUSTER_NAME
 Kubernetes domain name              domyślna (np. cluster.local) - NIE $DOMAIN
 External FQDN                       domyślny (FQDN head node)
 Service network                     $SVC_CIDR
 Pod network                         $POD_CIDR
 Expose API server                   no
 Internal network                    $D_NODE_NET
 Control plane nodes                 $CP_NODES$( [ "$(wc -w <<<"$CP_NODES")" = 1 ] && echo "   (ostrzeżenie o braku HA - OK w labie)")
 Worker categories                   NIC nie zaznaczaj (workery wybieramy pojedynczo)
 Individual worker nodes             $WORKER_NODES
 etcd nodes                          $ETCD_NODES   (liczba nieparzysta!)
 API server proxy port / etcd spool  domyślne (np. 10443 / /var/lib/etcd - lokalny dysk!)
 Network plugin                      Calico
 Kyverno                             no (jeśli pojawi się ekran wykluczeń polityk:
                                     dopisz ',runai*' na końcu KAŻDEJ listy)
 Operatory                           $ops
 GPU Operator version                rekomendowana przez kreator
 GPU Operator: toolkit.enabled       ON
 GPU Operator: driver.enabled        $( [ "$GPU_DRIVER_ENABLED" = no ] && echo "OFF  (sterownik + Fabric Manager są w obrazie BCM)" || echo "ON   (brak sterownika w obrazie)")
 GPU Operator: nfd.enabled           ON
 GPU custom YAML / pre-defined       puste / "Do not use pre-defined"
 MetalLB mode                        L2
EOF
  case $k in
    helm_bcm11) cat <<EOF
 MetalLB IP address pools            ZOSTAW PUSTE (faza runai doda pulę runai-pool: $LB_RUNAI_INGRESS)
 Knative components                  Serving (bez Eventing). Run:ai wymaga Knative 1.19-1.21 -
                                     wybierz taką wersję, jeśli kreator pyta.
 PostgreSQL Operator                 $( [ "$PG_MODE" = k8s ] && echo "ustawienia domyślne (bazę tworzy faza pgdb)" || echo "nie jest potrzebny ($(pg_desc))")
EOF
    ;;
    flow_bcm11_split) cat <<EOF
 BCM gateway (Kgateway) IP           $LB_BCM_GW
 MetalLB IP address pools            ZOSTAW PUSTE (cm-runai-setup doda swoje)
 Expose gateways via head proxy      yes, port 443
 Knative components                  Serving (bez Eventing)
EOF
    ;;
    flow_bcm11_single) cat <<EOF
 Run:ai Registry Credentials         $RUNAI_DIR/credential.jwt
 Run:ai Control Plane FQDN           $RUNAI_FQDN
 Local CA Cert Path                  $RUNAI_DIR/ca.crt   (puste, jeśli cert z publicznego CA)
 Domain Cert Path                    $RUNAI_DIR/full-chain.pem
 Domain Cert Key Path                $RUNAI_DIR/private.key
 Install Run:ai components           yes  (ostrzeżenie o ssh - zignoruj wg docs)
 Run:ai control plane category       $RUNAI_CP_CATEGORY
 Run:ai version                      najnowsza 2.23.x (lub to, co oferuje kreator)
 MetalLB IP address pools            Ok bez zmian
 Ingress IP addresses                Run:ai: $LB_RUNAI_INGRESS   inference: $LB_INFERENCE
 Expose Ingress on default HTTPS     no;  NodePorts: domyślne
 Knative components                  Serving
 A100/H100 network policies          no (chyba że Network Operator)
EOF
    ;;
    *) cat <<EOF
 MetalLB IP address pools            ZOSTAW PUSTE (faza runai doda pulę: $LB_RUNAI_INGRESS, $LB_INFERENCE)
 Ingress Controller (Nginx)          NIE instaluj (Run:ai użyje HAProxy na LoadBalancer)
EOF
    ;;
  esac
  cat <<EOF
 Permission Manager                  no (lab/1 admin) - yes, jeśli wielu użytkowników BCM
 StorageClass                        Local path: enabled + default
 Local path location                 domyślna (/cm/shared/apps/kubernetes/$CLUSTER_NAME/var/volumes)
 Grafana persistent storage          yes (jeśli kreator pyta)
 Summary                             >>> Save config & Exit <<<  zapisz jako:
                                     $BASE/cm-kubernetes-setup.conf
                                     (skrypt sam uruchomi potem: cm-kubernetes-setup -c ...)
================================================================================
 Po zapisaniu prześlij zamaskowaną kopię tego pliku (bcm-collect.sh to robi) -
 posłuży jako szablon templates/cm-kubernetes-setup.$FLOW.yaml.tmpl
 i kolejne wdrożenia pójdą bez kreatora.
================================================================================
EOF
}

# ====================================================================== tune ==
phase_tune() {
  load_env
  hdr "TUNE - maxPods=$MAX_PODS na workerach"
  k8s_env "$CLUSTER_NAME" || die "kubectl niedostępny"
  [ -s "$WORKDIR/devices.tsv" ] || discover_devices
  local w owner kind name show cur f changed=0 done_owners=" "
  for w in $WORKER_NODES; do
    owner=$(find_kubelet_role_owner "$w" "$CLUSTER_NAME")
    [ -n "$owner" ] || { warn "$w: nie znaleziono roli kubelet"; continue; }
    in_list "${owner// /:}" $done_owners && continue
    done_owners="$done_owners ${owner// /:}"
    read -r kind name <<<"$owner"
    local path="$kind; use $name; roles; use kubelet"
    show=$(cmsh_q "$path; show")
    info "$w: rola kubelet z: $kind $name"
    if grep -qi '^ *Max Pods' <<<"$show"; then
      cur=$(grep -i '^ *Max Pods' <<<"$show" | awk '{print $NF}')
      [ "$cur" = "$MAX_PODS" ] && { ok "maxpods już $MAX_PODS"; continue; }
      run "set maxpods $MAX_PODS ($kind $name)" cmsh -c "$path; set maxpods $MAX_PODS; commit" && changed=1
    elif grep -qi 'Custom YAML' <<<"$show"; then
      # customyaml to właściwość typu PLIK: 'set customyaml <ścieżka>' (nie treść!)
      f=$BASE/kubelet-custom-$name.yaml
      cmsh_q "$path; get customyaml" | grep -vE '^\s*$' | grep -viE '^\s*maxPods\s*:' >"$f"
      grep -qiE 'unable|error|unknown' "$f" && : >"$f"
      echo "maxPods: $MAX_PODS" >>"$f"
      info "Nowa treść customyaml:"; sed 's/^/    /' "$f"
      if cmsh_q "$path; get customyaml" | grep -qE "^\s*maxPods:\s*$MAX_PODS\s*$"; then ok "customyaml ma już maxPods: $MAX_PODS"; continue; fi
      run "set customyaml $f ($kind $name)" cmsh -c "$path; set customyaml $f; commit" && changed=1
    else
      warn "Rola kubelet nie ma ani 'Max Pods', ani 'Custom YAML' - ustaw ręcznie (show: $BASE/kubelet-role.txt)"
      printf '%s\n' "$show" >"$BASE/kubelet-role.txt"
    fi
  done
  [ "$DRY" = 1 ] && return
  # Czekamy aż kubelet przejmie zmianę
  local t node pods
  for w in $WORKER_NODES; do
    node=$(kubectl get nodes -o name 2>/dev/null | sed 's|node/||' | grep -E "^$w(\.|$)" | head -1); node=${node:-$w}
    for t in $(seq 1 24); do
      pods=$(kubectl get node "$node" -o jsonpath='{.status.allocatable.pods}' 2>/dev/null)
      [ "$pods" = "$MAX_PODS" ] && break
      [ "$t" = 12 ] && { warn "$w: nadal $pods - restart kubelet"; nssh "$w" 'systemctl restart kubelet'; }
      sleep 10
    done
    [ "$pods" = "$MAX_PODS" ] && ok "$node: allocatable pods = $pods" || warn "$node: allocatable pods = $pods (oczekiwano $MAX_PODS) - sprawdź: ssh $w grep -i maxpods /var/lib/kubelet/config.yaml"
  done
  # Kyverno: wykluczenia runai*
  if helm list -n kyverno 2>/dev/null | grep -q kyverno-policies; then
    helm get values -n kyverno kyverno-policies 2>/dev/null | grep -q 'runai\*' && ok "Kyverno: wykluczenia runai* obecne" \
      || warn "Kyverno policies BEZ runai* - cm-kubernetes-setup -> Modify kyverno policies -> dopisz ',runai*' do każdej z 5 list"
  fi
  for w in $WORKER_NODES; do
    cmsh_q "device; use $w; roles; list" | grep -qi slurmclient && warn "$w ma rolę slurmclient - Slurm może konkurować z Run:ai o GPU"
  done
  [ $changed = 1 ] || true
  done_phase tune
}

# ================================================================== validate ==
phase_validate() {
  hdr "VALIDATE - test Kubernetes"
  load_env
  k8s_env "$CLUSTER_NAME" || die "kubectl niedostępny"
  local bad h exp got node
  kubectl get nodes -o wide | tee -a "$LOG_FILE"
  local kv; kv=$(kubectl version -o json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null)
  kv=${kv#v}; kv=${kv%%[-+]*}
  if [ -n "$kv" ]; then
    if [ "$RUNAI_VIA" = helm ] && ver_ge "$kv" 1.34 && ! ver_ge "$kv" 1.34.2; then
      warn "Kubernetes $kv: Run:ai 2.26 zaleca >= 1.34.2 (błąd wznawiania zawieszonych jobów w starszych 1.34.x)"
    else ok "Kubernetes $kv"; fi
  fi
  bad=$(kubectl get nodes --no-headers | awk '$2!="Ready"' | wc -l)
  [ "$bad" = 0 ] && ok "Wszystkie węzły Ready" || warn "$bad węzłów nie-Ready"
  for h in $D_GPU_COUNTS; do
    in_list "${h%%:*}" $WORKER_NODES || continue
    node=$(kubectl get nodes -o name | sed 's|node/||' | grep -E "^${h%%:*}(\.|$)" | head -1)
    exp=${h##*:}; got=$(kubectl get node "${node:-${h%%:*}}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
    [ "$got" = "$exp" ] && ok "${h%%:*}: nvidia.com/gpu = $got" || warn "${h%%:*}: nvidia.com/gpu = '${got}' (oczekiwano $exp)"
  done
  bad=$(kubectl get pods -A --no-headers | grep -vcE 'Running|Completed')
  [ "$bad" = 0 ] && ok "Brak podów w złym stanie" || { warn "$bad podów w złym stanie:"; kubectl get pods -A --no-headers | grep -vE 'Running|Completed' | head -20; }
  helm list -A 2>/dev/null | awk 'NR>1 && $8!="deployed"{print "   helm: "$1" ("$2") = "$8}' | tee -a "$LOG_FILE"
  check_operators || true
  kubectl get ipaddresspools.metallb.io,l2advertisements.metallb.io -A 2>&1 | tee -a "$LOG_FILE"
  if [ "$FLOW" = flow_bcm11_split ]; then
    kubectl get gateway -A 2>&1 | tee -a "$LOG_FILE"
    local c; c=$(curl -sk -o /dev/null -m5 -w '%{http_code}' "https://$LB_BCM_GW")
    [ "$c" != 000 ] && ok "BCM gateway $LB_BCM_GW odpowiada (HTTP $c)" || warn "BCM gateway $LB_BCM_GW nie odpowiada"
    kubectl get knativeserving -A 2>&1 | tee -a "$LOG_FILE"
  fi
  kubectl top nodes >/dev/null 2>&1 && ok "Metrics Server działa (kubectl top)" || warn "kubectl top nie działa"
  kubectl get sc | grep -q '(default)' && ok "Domyślny StorageClass: $(kubectl get sc | awk '/\(default\)/{print $1}')" || warn "Brak domyślnego StorageClass"
  [ "$DRY" = 1 ] && return
  info "Test GPU + PVC (pobranie obrazu CUDA może potrwać kilka minut)"
  kubectl delete pod bcm-gpu-smoke --ignore-not-found >/dev/null 2>&1; kubectl delete pvc bcm-smoke-pvc --ignore-not-found >/dev/null 2>&1
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: bcm-smoke-pvc}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: bcm-gpu-smoke}
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
    command: ["sh","-c","nvidia-smi -L && echo storage-ok > /data/t && cat /data/t"]
    resources: {limits: {nvidia.com/gpu: 1}}
    volumeMounts: [{name: d, mountPath: /data}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: bcm-smoke-pvc}}]
YAML
  if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/bcm-gpu-smoke --timeout=600s >/dev/null 2>&1; then
    kubectl logs bcm-gpu-smoke | tee -a "$LOG_FILE"; ok "Test GPU + storage OK"
  else
    warn "Test GPU nie przeszedł:"; kubectl describe pod bcm-gpu-smoke | tail -20
  fi
  kubectl delete pod bcm-gpu-smoke --ignore-not-found >/dev/null; kubectl delete pvc bcm-smoke-pvc --ignore-not-found >/dev/null
  done_phase validate
}

# ===================================================================== runai ==
phase_runai() {
  load_env
  hdr "RUNAI - instalacja Run:ai ($FLOW)"
  k8s_env "$CLUSTER_NAME" || die "kubectl niedostępny"
  if kubectl get ns runai >/dev/null 2>&1 && kubectl get pods -n runai --no-headers 2>/dev/null | grep -q .; then
    ok "Namespace runai już istnieje - Run:ai wygląda na zainstalowany. Przejdź do --phase verify."
    done_phase runai; return
  fi
  if [ "$RUNAI_VIA" = helm ]; then runai_helm; return; fi
  case $FLOW in
    flow_bcm11_split)  runai_bcm11_split;;
    flow_bcm11_single) runai_bcm11_single;;
    flow_bcm10_helm)   runai_helm;;
  esac
}

runai_bcm11_split() {
  check_operators || die "Najpierw dodaj brakujące operatory (Modify operators), potem uruchom ponownie --phase runai"
  local conf=/root/cm-runai-setup.conf tmpl="$SCRIPT_DIR/templates/cm-runai-setup.$FLOW.yaml.tmpl"
  if [ -r "$tmpl" ]; then
    local ADMIN_PASSWORD
    [ "$DRY" = 1 ] || { read -r -s -p "Hasło administratora Run:ai ($ADMIN_EMAIL): " ADMIN_PASSWORD </dev/tty; echo; }
    export ADMIN_PASSWORD
    render_template "$tmpl" "$conf"; unset ADMIN_PASSWORD
  else
    answers_runai >"$BASE/answers-runai.txt"; cat "$BASE/answers-runai.txt"
    [ "$DRY" = 1 ] && return
    in_multiplexer || warn "Uruchom w screen/tmux! (screen -S runai)"
    confirm "Uruchomić teraz kreator cm-runai-setup?" || die "Przerwano"
    local before=0; [ -f "$conf" ] && before=$(stat -c %Y "$conf")
    cm-runai-setup
    [ -f "$conf" ] && [ "$(stat -c %Y "$conf")" -gt "$before" ] || {
      kubectl get ns runai >/dev/null 2>&1 && { ok "Kreator wdrożył Run:ai"; done_phase runai; return; }
      die "Nie zapisano $conf - na ekranie Summary wybierz 'Save & Exit'"; }
  fi
  chmod 600 "$conf"
  confirm "Wdrożyć Run:ai z $conf (cm-runai-setup -c)?" || die "Przerwano"
  run "cm-runai-setup -c $conf" cm-runai-setup -c "$conf" || die "cm-runai-setup zakończył się błędem (log: $LOG_FILE)"
  done_phase runai
}

answers_runai() {
  cat <<EOF
================================================================================
 ŚCIĄGA: cm-runai-setup   (wyliczona dla $(hostname -s), $(date +%F))
================================================================================
 Ekran                                 Odpowiedź
 ------------------------------------  ----------------------------------------
 Deployment type                       self-hosted
 Run:ai NGC API Key (key or file)      $RUNAI_DIR/ngc-api-key
 Control Plane Domain Name (FQDN)      $RUNAI_FQDN
 Local CA Cert Path                    $RUNAI_DIR/ca.crt  (puste przy publicznym CA)
 Domain Cert Path                      $RUNAI_DIR/full-chain.pem
 Domain Cert Key Path                  $RUNAI_DIR/private.key
 Tenants Manager Admin Username        $ADMIN_EMAIL
 Tenants Manager Admin Password        min. 8 znaków, duża litera, cyfra, znak specjalny
 Deploy Run:ai cluster                 yes
 Control plane node category           $RUNAI_CP_CATEGORY
 Run:ai version                        2.25.x (najnowsza oferowana)
 Basic DNS configuration check         powinien być "passed" ($RUNAI_FQDN -> $LB_RUNAI_GW)
 Gateway IP address                    $LB_RUNAI_GW   <<< ZMIEŃ, jeśli kreator podpowiada inny!
                                       (musi się zgadzać z DNS)
 Inference (Kourier) LB IP             $LB_INFERENCE
 Summary                               >>> Save & Exit <<<  (zapis do /root/cm-runai-setup.conf)
                                       skrypt uruchomi: cm-runai-setup -c /root/cm-runai-setup.conf
================================================================================
 Jeśli kreator zatrzyma się na sprawdzaniu operatorów (np. Kubeflow Training,
 LeaderWorkerSet): wyjdź, dodaj je przez cm-kubernetes-setup -> Modify operators
 i uruchom ponownie: $0 --phase runai
================================================================================
EOF
}

runai_bcm11_single() {
  # W BCM 11.0-11.32 Run:ai instaluje cm-kubernetes-setup (operator "Run:ai (self-hosted)")
  if helm list -A 2>/dev/null | grep -qiE 'runai|run-ai'; then ok "Run:ai zainstalowany przez cm-kubernetes-setup"; done_phase runai; return; fi
  warn "Run:ai nie jest zainstalowany. W tej wersji BCM instaluje go cm-kubernetes-setup (operator 'Run:ai (self-hosted)')."
  warn "Spróbuj: cm-kubernetes-setup -> Modify operators -> Add operators -> Run:ai (self-hosted)."
  warn "Odpowiedzi dla ekranów Run:ai są w $BASE/answers-k8s.txt (sekcja Run:ai)."
  answers_k8s >"$BASE/answers-k8s.txt"
  [ "$DRY" = 1 ] && return
  confirm "Uruchomić teraz cm-kubernetes-setup?" && cm-kubernetes-setup
  helm list -A 2>/dev/null | grep -qiE 'runai|run-ai' && done_phase runai
}

# ---- Run:ai self-hosted przez Helm (wg docs Run:ai "Install using Helm")
# BCM 10 zawsze; BCM 11 z --runai-via helm (np. Run:ai 2.26 albo zewnętrzna baza).

# Repo Helm runai (NGC) - klucz tylko w pamięci, nie w argumentach procesów potomnych poza helm
runai_helm_repo() {
  [ -s "$RUNAI_DIR/ngc-api-key" ] || die "Brak $RUNAI_DIR/ngc-api-key - uruchom --phase certs"
  helm repo list 2>/dev/null | awk '{print $1}' | grep -qx runai && { helm repo update runai >/dev/null 2>&1; return 0; }
  local key; key=$(tr -d '\n' <"$RUNAI_DIR/ngc-api-key")
  helm repo add runai https://helm.ngc.nvidia.com/nvidia/runai --force-update --username '$oauthtoken' --password "$key" >/dev/null || die "helm repo runai"
  unset key
  helm repo update runai >/dev/null
}

# pick_runai_version [2.26 | 2.26.7 | puste] -> pełna wersja chartu control-plane
pick_runai_version() {
  local want=$1 all
  all=$(helm search repo runai/control-plane --versions -o json 2>/dev/null \
        | grep -Eo '"version":"[0-9]+\.[0-9]+\.[0-9]+"' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | sort -Vu)
  case $want in
    *.*.*) grep -qx "$want" <<<"$all" && echo "$want";;
    *.*)   grep -E "^${want//./\\.}\.[0-9]+$" <<<"$all" | tail -1;;
    *)     tail -1 <<<"$all";;
  esac
}

# Nazwa bazy, której chart control-plane używa domyślnie (docs jej nie podają)
chart_db_name() {
  helm show values runai/control-plane --version "$1" 2>/dev/null \
    | awk '/^[^ #]/{top=$1} top ~ /^(global|postgresql):$/ && $1=="database:" {gsub(/["\047]/,"",$2); if ($2!="") {print $2; exit}}'
}

# Wartość YAML w apostrofach (hasła mogą mieć dowolne znaki)
yq_str() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }

# Hasła bazy: z sekretów operatora Zalando albo od użytkownika (zewnętrzny serwer)
pg_passwords() {
  PG_PW=; GF_PW=
  case $PG_MODE in
    k8s)
      local sfx="$PG_CLUSTER.credentials.postgresql.acid.zalan.do"
      PG_PW=$(kubectl get secret -n "$PG_NS" "$PG_USER.$sfx" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
      GF_PW=$(kubectl get secret -n "$PG_NS" "grafana.$sfx" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d);;
    external)
      read -r -s -p "Hasło użytkownika $PG_USER w bazie $PG_HOST: " PG_PW </dev/tty; echo
      read -r -s -p "Hasło użytkownika grafana w bazie $PG_HOST: " GF_PW </dev/tty; echo;;
  esac
  [ -n "$PG_PW" ] && [ -n "$GF_PW" ] || die "Brak haseł do bazy ($PG_MODE) - uruchom ponownie --phase pgdb"
}

# =================================================================== pgdb ==
# Baza Run:ai poza chartem control-plane (PG_MODE=k8s|external). Przy bundled nic nie robi.
phase_pgdb() {
  load_env
  hdr "PGDB - baza Run:ai: $(pg_desc)"
  [ "$PG_MODE" = bundled ] && { info "Baza wbudowana w chart Run:ai - nic do zrobienia"; done_phase pgdb; return; }
  k8s_env "$CLUSTER_NAME" || die "kubectl niedostępny"
  # Nazwa bazy: ta, której chart oczekuje domyślnie (jeśli da się ją odczytać)
  local ver dbn
  if [ "$DRY" != 1 ]; then
    runai_helm_repo
    ver=$(pick_runai_version "$RUNAI_VERSION")
    [ -n "$ver" ] && dbn=$(chart_db_name "$ver")
    if [ -n "$dbn" ] && [ "$dbn" != "$PG_DB" ]; then
      info "Chart control-plane $ver używa domyślnie bazy '$dbn' - używam tej nazwy (było: $PG_DB)"
      PG_DB=$dbn; env_set PG_DB "$PG_DB"
    else
      info "Baza Run:ai: $PG_DB${ver:+ (chart $ver)}"
    fi
  fi
  case $PG_MODE in
    external) pgdb_external;;
    k8s)      pgdb_zalando;;
  esac
}

# Zapis jednej zmiennej w deploy.env
env_set() {
  [ "$DRY" = 1 ] && return 0
  grep -v "^$1=" "$ENVF" >"$ENVF.tmp"; printf '%s=%q\n' "$1" "$2" >>"$ENVF.tmp"
  mv "$ENVF.tmp" "$ENVF"; chmod 600 "$ENVF"
}

# pg_psql <pod> [argumenty psql bez spacji]; SQL na stdin. Socket lokalny jako użytkownik postgres.
pg_psql() {
  local pod=$1; shift
  kubectl exec -i -n "$PG_NS" "$pod" -c postgres -- sh -c \
    'if [ "$(id -u)" = 0 ]; then exec su postgres -s /bin/sh -c "psql $*"; else exec psql "$@"; fi' _ -U postgres "$@"
}

pgdb_sql() {
  cat <<EOF
-- Run:ai: baza, rola i schemat Grafany (docs Run:ai, Preparations - external PostgreSQL)
GRANT ALL PRIVILEGES ON DATABASE "$PG_DB" TO "$PG_USER";
CREATE SCHEMA IF NOT EXISTS grafana AUTHORIZATION grafana;
ALTER USER grafana SET search_path='grafana';
EOF
}

pgdb_external() {
  local f=$BASE/runai-pg-init.sql
  cat >"$f" <<EOF
-- Uruchom jako superuser na $PG_HOST:$PG_PORT (psql -h $PG_HOST -p $PG_PORT -U postgres -f $f)
-- i wpisz hasła w miejsce <...>. Wymagany PostgreSQL 16.
CREATE DATABASE "$PG_DB";
CREATE ROLE "$PG_USER" WITH LOGIN PASSWORD '<HASLO_RUNAI>';
CREATE ROLE grafana WITH LOGIN PASSWORD '<HASLO_GRAFANA>';
ALTER DATABASE "$PG_DB" OWNER TO "$PG_USER";
\\c "$PG_DB"
EOF
  pgdb_sql >>"$f"
  info "Skrypt SQL dla zewnętrznego serwera: $f"; sed 's/^/    /' "$f"
  [ "$DRY" = 1 ] && return
  if timeout 5 bash -c "</dev/tcp/$PG_HOST/$PG_PORT" 2>/dev/null; then ok "$PG_HOST:$PG_PORT przyjmuje połączenia TCP (z head node)"
  else warn "$PG_HOST:$PG_PORT nie odpowiada z head node - sprawdź firewall i listen_addresses"; fi
  confirm "Czy skrypt SQL został wykonany na $PG_HOST (baza $PG_DB, role $PG_USER i grafana)?" || die "Wykonaj SQL i uruchom ponownie: $0 --phase pgdb"
  done_phase pgdb
}

pgdb_zalando() {
  [[ $PG_CLUSTER == *-* ]] || die "PG_CLUSTER ($PG_CLUSTER) musi mieć postać <team>-<nazwa> (wymóg operatora Zalando)"
  local cr=$WORKDIR/runai-pg.yaml pod t st dom node
  cat >"$cr" <<EOF
apiVersion: acid.zalan.do/v1
kind: postgresql
metadata:
  name: $PG_CLUSTER
  namespace: $PG_NS
spec:
  teamId: "${PG_CLUSTER%%-*}"
  numberOfInstances: 1
  postgresql:
    version: "16"
  volume:
    size: $PG_SIZE
  users:
    $PG_USER: []
    grafana: []
  databases:
    $PG_DB: $PG_USER
  resources:
    requests: {cpu: 250m, memory: 512Mi}
    limits: {cpu: "1", memory: 2Gi}
EOF
  info "Manifest bazy ($cr):"; sed 's/^/    /' "$cr"
  [ "$DRY" = 1 ] && { info "[dry-run] kubectl apply + SQL:"; pgdb_sql | sed 's/^/    /'; return; }
  kubectl get crd postgresqls.acid.zalan.do >/dev/null 2>&1 \
    || die "Brak operatora Zalando (CRD postgresqls.acid.zalan.do): cm-kubernetes-setup -> Modify operators -> Add -> PostgreSQL Operator"
  kubectl get sc 2>/dev/null | grep -q '(default)' || die "Brak domyślnego StorageClass dla wolumenu bazy"
  kubectl create ns "$PG_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f "$cr" | tee -a "$LOG_FILE" || die "kubectl apply $cr"
  info "Czekam na klaster PostgreSQL $PG_CLUSTER (do 15 min)"
  for t in $(seq 1 90); do
    st=$(kubectl get postgresql "$PG_CLUSTER" -n "$PG_NS" -o jsonpath='{.status.PostgresClusterStatus}' 2>/dev/null)
    pod=$(kubectl get pods -n "$PG_NS" -l "cluster-name=$PG_CLUSTER,spilo-role=master" -o name 2>/dev/null | head -1)
    [ "$st" = Running ] && [ -n "$pod" ] && break
    case $st in *Failed*) break;; esac
    sleep 10
  done
  if [ "$st" != Running ] || [ -z "$pod" ]; then
    warn "Status klastra: '${st:-?}'"
    kubectl get pods,pvc -n "$PG_NS" 2>&1 | tee -a "$LOG_FILE"
    kubectl logs -n "$PG_NS" -l "cluster-name=$PG_CLUSTER" --tail=30 2>&1 | tee -a "$LOG_FILE"
    kubectl logs -n "$(kubectl get pods -A -l name=postgres-operator -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)" \
      -l name=postgres-operator --tail=30 2>&1 | tee -a "$LOG_FILE"
    die "PostgreSQL nie wystartował - szczegóły powyżej (częsta przyczyna: prawa do katalogu wolumenu na NFS)"
  fi
  ok "PostgreSQL $PG_CLUSTER: Running ($pod)"
  st=$(echo 'show server_version;' | pg_psql "$pod" -tA 2>/dev/null | tr -d '[:space:]')
  [[ $st == 16* ]] && ok "Wersja serwera: $st" || die "Wersja serwera '$st' - Run:ai wymaga PostgreSQL 16"
  pgdb_sql | pg_psql "$pod" -d "$PG_DB" -v ON_ERROR_STOP=1 2>&1 | tee -a "$LOG_FILE"
  [ "${PIPESTATUS[1]}" = 0 ] || die "SQL nie przeszedł (log: $LOG_FILE)"
  # Adres usługi z domeną klastra K8s (kubelet clusterDomain, domyślnie cluster.local)
  node=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  dom=$(kubectl get --raw "/api/v1/nodes/$node/proxy/configz" 2>/dev/null \
        | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["kubeletconfig"].get("clusterDomain",""))' 2>/dev/null)
  PG_HOST=$PG_CLUSTER.$PG_NS.svc.${dom:-cluster.local}; PG_PORT=5432
  env_set PG_HOST "$PG_HOST"; env_set PG_PORT "$PG_PORT"
  # Test logowania użytkownikiem Run:ai przez usługę, z TLS (hasło przez stdin, nie w argumentach)
  pg_passwords
  if printf '%s\n' "$PG_PW" | kubectl exec -i -n "$PG_NS" "$pod" -c postgres -- sh -c \
       'read -r PGPASSWORD; export PGPASSWORD; psql "host=$1 port=$2 dbname=$3 user=$4 sslmode=$5" -tAc "select current_user"' \
       _ "$PG_HOST" "$PG_PORT" "$PG_DB" "$PG_USER" "$PG_SSLMODE" 2>&1 | grep -qx "$PG_USER"; then
    ok "Logowanie $PG_USER@$PG_HOST:$PG_PORT/$PG_DB (sslmode=$PG_SSLMODE) działa"
  else
    die "Nie można zalogować się jako $PG_USER do $PG_HOST (sslmode=$PG_SSLMODE)"
  fi
  unset PG_PW GF_PW
  done_phase pgdb
}

# Knative Serving pod Run:ai (docs 2.26: Standard Inference, external access przez HAProxy)
runai_knative() {
  local ks name ver inf_dom=${D_INFERENCE_WILDCARD#\*.} f=$WORKDIR/knative-serving.yaml
  kubectl get crd knativeservings.operator.knative.dev >/dev/null 2>&1 \
    || { warn "Brak operatora Knative - inference nie będzie działać (cm-kubernetes-setup -> Modify operators -> Knative Operator)"; return 1; }
  kubectl create ns knative-serving --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # BCM mógł już utworzyć KnativeServing - aktualizujemy istniejący zamiast tworzyć drugi
  name=$(kubectl get knativeserving -n knative-serving -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  name=${name:-knative-serving}
  cat >"$f" <<EOF
apiVersion: operator.knative.dev/v1beta1
kind: KnativeServing
metadata:
  name: $name
  namespace: knative-serving
spec:
  config:
    config-autoscaler:
      enable-scale-to-zero: "true"
    config-features:
      kubernetes.podspec-affinity: enabled
      kubernetes.podspec-init-containers: enabled
      kubernetes.podspec-persistent-volume-claim: enabled
      kubernetes.podspec-persistent-volume-write: enabled
      kubernetes.podspec-schedulername: enabled
      kubernetes.podspec-securitycontext: enabled
      kubernetes.podspec-tolerations: enabled
      kubernetes.podspec-volumes-emptydir: enabled
      kubernetes.podspec-fieldref: enabled
      kubernetes.containerspec-addcapabilities: enabled
      kubernetes.podspec-nodeselector: enabled
      multi-container: enabled
      kubernetes.podspec-hostipc: enabled
      kubernetes.podspec-hostnetwork: enabled
    domain:
      $inf_dom: ""
    network:
      domainTemplate: '{{.Name}}-{{.Namespace}}.{{.Domain}}'
      ingress-class: kourier.ingress.networking.knative.dev
      default-external-scheme: https
    observability:
      metrics-protocol: "prometheus"
      request-metrics-protocol: "http/protobuf"
      request-metrics-endpoint: "http://prometheus-operated.runai.svc.cluster.local:9090/api/v1/otlp/v1/metrics"
  high-availability:
    replicas: 1
  ingress:
    kourier:
      enabled: true
      service-type: ClusterIP   # ruch z zewnątrz idzie przez HAProxy (Ingress poniżej)
EOF
  kubectl apply -f "$f" | tee -a "$LOG_FILE" || { warn "KnativeServing nie został zastosowany ($f)"; return 1; }
  kubectl -n knative-serving create secret tls runai-cluster-inference-tls-secret \
    --cert "$RUNAI_DIR/full-chain.pem" --key "$RUNAI_DIR/private.key" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f - <<EOF | tee -a "$LOG_FILE"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: knative-serving
  namespace: knative-serving
spec:
  ingressClassName: haproxy
  rules:
  - host: '*.$inf_dom'
    http:
      paths:
      - backend:
          service:
            name: kourier
            port:
              number: 80
        path: /
        pathType: Prefix
  tls:
  - hosts:
    - '*.$inf_dom'
    secretName: runai-cluster-inference-tls-secret
EOF
  kubectl wait --for=condition=Ready "knativeserving/$name" -n knative-serving --timeout=600s >/dev/null 2>&1 \
    && ok "KnativeServing Ready" || warn "KnativeServing nie jest Ready po 10 min (kubectl get knativeserving -n knative-serving)"
  ver=$(kubectl get knativeserving "$name" -n knative-serving -o jsonpath='{.status.version}' 2>/dev/null)
  if [ -n "$ver" ] && { ! ver_ge "$ver" 1.19 || ver_ge "$ver" 1.22; }; then
    warn "Knative Serving $ver - Run:ai 2.26 wspiera 1.19-1.21 (zmień wersję operatora Knative)"
  else
    ok "Knative Serving ${ver:-?}"
  fi
}

runai_helm() {
  local cp_ver helm_extra= pw vals=$BASE/runai-cp-values.yaml
  if [ "$DRY" = 1 ]; then
    info "[dry-run] MetalLB pula runai-pool ($LB_RUNAI_INGRESS), HAProxy ingress na $LB_RUNAI_INGRESS, sekrety TLS/CA,"
    info "[dry-run] helm runai/control-plane ${RUNAI_VERSION:-(najnowsza)} - baza: $(pg_desc),"
    info "[dry-run] Knative Serving + ingress *.${D_INFERENCE_WILDCARD#\*.}, rejestracja klastra przez API, helm runai-cluster"
    return
  fi
  helm version --short 2>/dev/null | grep -q '^v4' && helm_extra="--server-side=false"
  kubectl get crd ipaddresspools.metallb.io >/dev/null 2>&1 || die "Brak MetalLB - dodaj operator MetalLB w cm-kubernetes-setup"
  check_operators || warn "Brakujące operatory (powyżej) - instalacja pójdzie dalej, ale część funkcji Run:ai nie zadziała"
  if [ "$PG_MODE" != bundled ]; then
    is_done pgdb || die "Baza ($PG_MODE) nie jest przygotowana - uruchom najpierw: $0 --phase pgdb"
    [ -n "$PG_HOST" ] || die "Brak PG_HOST w $ENVF - uruchom ponownie: $0 --phase pgdb"
  fi

  info "1/7 MetalLB: pula runai-pool"
  kubectl apply -f - <<EOF || die "MetalLB pool"
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: runai-pool, namespace: metallb-system}
spec:
  addresses: ["$LB_RUNAI_INGRESS/32"]
  autoAssign: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: runai-l2, namespace: metallb-system}
spec: {ipAddressPools: [runai-pool]}
EOF

  info "2/7 Ingress HAProxy (LoadBalancer $LB_RUNAI_INGRESS)"
  helm repo add haproxytech https://haproxytech.github.io/helm-charts --force-update >/dev/null && helm repo update haproxytech >/dev/null
  helm upgrade -i haproxy-kubernetes-ingress haproxytech/kubernetes-ingress -n haproxy-controller --create-namespace $helm_extra \
    --set controller.kind=DaemonSet --set controller.service.type=LoadBalancer \
    --set-string "controller.service.annotations.metallb\.universe\.tf/loadBalancerIPs=$LB_RUNAI_INGRESS" \
    --set-string "controller.service.annotations.metallb\.universe\.tf/address-pool=runai-pool" \
    --wait --timeout 10m | tee -a "$LOG_FILE" || die "HAProxy"

  info "3/7 Namespace'y i sekrety TLS/CA"
  for ns in runai-backend runai; do kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done
  kubectl -n runai-backend create secret tls runai-backend-tls --cert "$RUNAI_DIR/full-chain.pem" --key "$RUNAI_DIR/private.key" --dry-run=client -o yaml | kubectl apply -f -
  local s
  for s in runai-cluster-domain-tls-secret runai-cluster-domain-star-tls-secret; do
    kubectl -n runai create secret tls "$s" --cert "$RUNAI_DIR/full-chain.pem" --key "$RUNAI_DIR/private.key" --dry-run=client -o yaml | kubectl apply -f -
  done
  local ca_set=
  if [ -s "$RUNAI_DIR/ca.crt" ]; then
    for ns in runai-backend runai; do
      kubectl -n "$ns" create secret generic runai-ca-cert --from-file=runai-ca.pem="$RUNAI_DIR/ca.crt" --dry-run=client -o yaml | kubectl apply -f -
    done
    kubectl label secret runai-ca-cert -n runai run.ai/cluster-wide=true run.ai/name=runai-ca-cert --overwrite >/dev/null
    ca_set="--set global.customCA.enabled=true"
  fi

  info "4/7 Control plane (helm runai/control-plane)"
  runai_helm_repo
  cp_ver=$(pick_runai_version "$RUNAI_VERSION")
  [ -n "$cp_ver" ] || die "Nie znaleziono wersji '${RUNAI_VERSION:-najnowsza}' chartu runai/control-plane (helm search repo runai/control-plane --versions)"
  info "Wersja control plane: $cp_ver;  baza: $(pg_desc)"
  read -r -s -p "Hasło administratora Run:ai ($ADMIN_EMAIL; min. 8 znaków, duża i mała litera, cyfra, znak specjalny): " pw </dev/tty; echo
  [ "$PG_MODE" != bundled ] && pg_passwords
  ( umask 077
    {
      cat <<EOF
global:
  domain: "$RUNAI_FQDN"
  ingress:
    ingressClass: haproxy
EOF
      [ "$PG_MODE" != bundled ] && cat <<EOF
  postgresql:
    auth:
      host: "$PG_HOST"
      port: "$PG_PORT"
      username: "$PG_USER"
      password: $(yq_str "$PG_PW")
      dbSslMode: "$PG_SSLMODE"
postgresql:
  enabled: false
grafana:
  dbUser: "grafana"
  dbPassword: $(yq_str "$GF_PW")
EOF
      cat <<EOF
tenantsManager:
  config:
    adminUsername: "$ADMIN_EMAIL"
    adminPassword: $(yq_str "$pw")
EOF
    } >"$vals" )
  unset PG_PW GF_PW
  helm upgrade -i runai-backend runai/control-plane -n runai-backend --version "$cp_ver" -f "$vals" $ca_set $helm_extra --timeout 30m | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  shred -u "$vals" 2>/dev/null || rm -f "$vals"
  [ "$rc" = 0 ] || die "helm control-plane (log: $LOG_FILE)"
  info "Czekam na pody runai-backend (do 20 min)"
  kubectl wait --for=condition=Ready pods --all -n runai-backend --timeout=1200s >/dev/null 2>&1 || warn "Nie wszystkie pody runai-backend są Ready"
  if [ "$PG_MODE" != bundled ]; then
    kubectl get statefulset -n runai-backend 2>/dev/null | grep -qi postgres \
      && warn "W runai-backend jest StatefulSet PostgreSQL - chart nie przyjął postgresql.enabled=false" \
      || ok "Brak wbudowanej bazy w runai-backend (używana: $PG_HOST)"
  fi

  info "5/7 Knative Serving (inference)"
  runai_knative || true

  info "6/7 Rejestracja klastra w control plane (API)"
  local base="https://$RUNAI_FQDN" tok uuid info_json inst cl_ver=${cp_ver%.*}
  tok=$(U="$ADMIN_EMAIL" P="$pw" python3 -I -c 'import json,os; print(json.dumps({"grantType":"password","clientID":"cli","username":os.environ["U"],"password":os.environ["P"]}))' \
        | curl -s --cacert "$RUNAI_DIR/ca.crt" -m 30 -H 'Content-Type: application/json' -X POST "$base/api/v1/token" -d @- \
        | grep -Eo '"accessToken":"[^"]+"' | cut -d'"' -f4)
  unset pw
  if [ -n "$tok" ]; then
    uuid=$(curl -s --cacert "$RUNAI_DIR/ca.crt" -m 30 -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -X POST "$base/api/v1/clusters" \
          -d "{\"name\":\"$CLUSTER_NAME\",\"version\":\"$cl_ver\",\"domain\":\"$base\"}" | grep -Eo '"uuid":"[^"]+"' | head -1 | cut -d'"' -f4)
    [ -n "$uuid" ] && info_json=$(curl -s --cacert "$RUNAI_DIR/ca.crt" -m 30 -H "Authorization: Bearer $tok" "$base/api/v1/clusters/$uuid/cluster-install-info?version=$cl_ver")
    inst=$(printf '%s' "$info_json" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("installationStr",""))' 2>/dev/null)
  fi
  if [ -n "$inst" ]; then
    info "7/7 Instalacja klastra (helm runai-cluster $cl_ver)"
    ( umask 077; printf '%s %s %s\n' "$inst" "$ca_set" "$helm_extra" >"$BASE/runai-cluster-install.sh" )
    bash "$BASE/runai-cluster-install.sh" 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
    shred -u "$BASE/runai-cluster-install.sh" 2>/dev/null || rm -f "$BASE/runai-cluster-install.sh"
    [ "$rc" = 0 ] || die "Instalacja runai-cluster nie powiodła się (log: $LOG_FILE)"
  else
    warn "Automatyczna rejestracja przez API nie powiodła się - dokończ w UI:"
    cat <<EOF
   1. Otwórz https://$RUNAI_FQDN i zaloguj się ($ADMIN_EMAIL)
   2. Resources -> + NEW CLUSTER: nazwa $CLUSTER_NAME, wersja $cl_ver, Cluster URL https://$RUNAI_FQDN
   3. Skopiuj pokazaną komendę helm do pliku, np.:  nano $BASE/runai-cluster-install.sh
      i dopisz na końcu:  $ca_set $helm_extra
   4. Uruchom:  bash $BASE/runai-cluster-install.sh
EOF
  fi
  done_phase runai
}

# ==================================================================== verify ==
phase_verify() {
  hdr "VERIFY - stan Run:ai"
  load_env
  k8s_env "$CLUSTER_NAME" || die "kubectl niedostępny"
  local ns bad t
  for t in $(seq 1 30); do
    bad=$(kubectl get pods -n runai --no-headers 2>/dev/null | grep -vcE 'Running|Completed')
    [ "$bad" = 0 ] && break
    [ "$t" = 1 ] && info "Czekam aż pody runai wystartują (do 15 min)..."
    sleep 30
  done
  for ns in runai-backend runai; do
    kubectl get ns "$ns" >/dev/null 2>&1 || { warn "Brak namespace $ns"; continue; }
    bad=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -vcE 'Running|Completed')
    [ "$bad" = 0 ] && ok "$ns: wszystkie pody Running/Completed" || { warn "$ns: $bad podów w złym stanie"; kubectl get pods -n "$ns" | grep -vE 'Running|Completed'; }
  done
  if [ "$PG_MODE" = k8s ]; then
    local pod sess
    pod=$(kubectl get pods -n "$PG_NS" -l "cluster-name=$PG_CLUSTER,spilo-role=master" -o name 2>/dev/null | head -1)
    sess=$( [ -n "$pod" ] && echo "SELECT usename, count(*) FROM pg_stat_activity WHERE datname='$PG_DB' GROUP BY usename;" | pg_psql "$pod" -tA 2>/dev/null)
    grep -q "^$PG_USER|" <<<"$sess" && ok "Baza $PG_DB ($PG_CLUSTER.$PG_NS): sesje $(echo $sess)" \
      || warn "Brak sesji użytkownika $PG_USER w bazie $PG_DB - sprawdź logi runai-backend"
  fi
  if [ "$PG_MODE" != bundled ] && kubectl get statefulset -n runai-backend 2>/dev/null | grep -qi postgres; then
    warn "W runai-backend działa wbudowany PostgreSQL mimo zewnętrznej bazy ($PG_MODE)"
  fi
  if kubectl get events -n runai 2>/dev/null | grep -q 'Too many pods'; then
    warn "Zdarzenia 'Too many pods' - worker osiągnął limit maxPods: $0 --phase tune"
  fi
  if kubectl get events -n runai 2>/dev/null | grep -qi 'kyverno'; then
    warn "Zdarzenia Kyverno w runai - dopisz ',runai*' do wykluczeń (Modify kyverno policies)"
  fi
  local c; c=$(curl -s --cacert "$RUNAI_DIR/ca.crt" --resolve "$RUNAI_FQDN:443:$RUNAI_IP" -m 10 "https://$RUNAI_FQDN" | grep -io '<title>[^<]*' | head -1)
  [ -n "$c" ] && ok "https://$RUNAI_FQDN odpowiada: $c" || warn "https://$RUNAI_FQDN nie odpowiada na $RUNAI_IP"
  kubectl get svc -A 2>/dev/null | grep -E "$RUNAI_IP|$INFER_IP" | tee -a "$LOG_FILE"
  done_phase verify
}

# ==================================================================== access ==
phase_access() {
  hdr "ACCESS - dostęp z przeglądarki (Windows jump host)"
  load_env
  cat <<EOF | tee "$BASE/access-windows.txt"
 1. Sprawdź trasę (PowerShell):    Test-NetConnection $RUNAI_IP -Port 443
    - True  -> dalej punkt 2
    - False -> brak trasy do $D_NET_CIDR: dodaj trasę, użyj proxy head node (port 443)
               albo tunel SOCKS w MobaXterm (Tools -> MobaSSHTunnel -> Dynamic, port 1080)
 2. Plik hosts (Notatnik jako Administrator, C:\\Windows\\System32\\drivers\\etc\\hosts):
        $RUNAI_IP  $RUNAI_FQDN
    (hosts NIE obsługuje wildcardów - endpointy inference/workspace dopisuj pojedynczo,
     np. $INFER_IP  <nazwa>.inference.$DOMAIN; wygodniej: DNS $D_HEAD_IP dla domeny $DOMAIN)
    Potem:  ipconfig /flushdns ; Test-NetConnection $RUNAI_FQDN -Port 443
 3. Certyfikat CA: pobierz przez SFTP $RUNAI_DIR/ca.crt (NIGDY ca.key!) ->
    dwuklik -> Zainstaluj -> Bieżący użytkownik -> Zaufane główne urzędy certyfikacji.
    Firefox: Ustawienia -> Certyfikaty -> Organy -> Importuj.
 4. Test bez przeglądarki:   curl.exe -sk -o NUL -w "%{http_code}" https://$RUNAI_FQDN   (200/302)
 5. Jeśli curl działa, a przeglądarka nie:
    - wpisz pełny adres https://$RUNAI_FQDN
    - edge://net-internals/#dns -> Clear host cache; #sockets -> Flush socket pools
    - wyłącz "Use secure DNS" (DoH) w edge://settings/privacy
    - proxy/WPAD: msedge.exe --no-proxy-server --user-data-dir=%TEMP%\\runai-edge https://$RUNAI_FQDN
 6. Logowanie: $ADMIN_EMAIL + hasło podane w kreatorze / skrypcie.
EOF
  ok "Instrukcja zapisana: $BASE/access-windows.txt"
  done_phase access
}

# =================================================================== cleanup ==
phase_cleanup() {
  hdr "CLEANUP - pliki z hasłami i kluczami"
  load_env
  local f
  for f in /root/cm-runai-setup.conf "$BASE/cm-kubernetes-setup.conf"; do
    [ -f "$f" ] || continue
    chmod 600 "$f"
    if grep -qiE 'password|apikey|api_key|token' "$f"; then
      confirm "Usunąć $f (zawiera sekrety; zachowam zamaskowaną kopię $f.masked)?" && { [ "$DRY" = 1 ] || { mask_secrets <"$f" >"$f.masked"; shred -u "$f" 2>/dev/null || rm -f "$f"; ok "Usunięto $f"; }; }
    fi
  done
  chmod 700 "$RUNAI_DIR" 2>/dev/null
  ok "Klucz CA ($RUNAI_DIR/ca.key) zostaje na head node - nie kopiuj go nigdzie."
  done_phase cleanup
}

# ===================================================================== main ===
[ -n "$PHASES" ] || PHASES=$ALL_PHASES
for p in $PHASES; do in_list "$p" $ALL_PHASES || die "Nieznana faza: $p (dostępne: $ALL_PHASES)"; done
info "Log: $LOG_FILE"
for p in $PHASES; do
  if [ "${PHASES}" = "$ALL_PHASES" ] && is_done "$p" && [ "$p" != plan ]; then info "Faza $p już ukończona - pomijam (wymuś: --phase $p)"; continue; fi
  "phase_$p"
done
ok "Gotowe: $PHASES"
