#!/usr/bin/env bash
# setup-main.sh — step 3 of 3: the Matrix homeserver (Element Server Suite Community).
#
# Run this LAST, after setup-livekit.sh (and setup-relay.sh in the 3-server
# layout): it asks for the LiveKit address, API key and API secret they printed
# and, in the 3-server layout, for the LiveKit server's own IP.
#
# Installs K3s, Helm, cert-manager and the ESS Helm chart. The call login
# service (JWT) runs here inside ESS; audio/video runs on your LiveKit server.
# Run it again any time: it re-reads essconfig.yaml and upgrades in place.
#
#   usage:  sudo bash setup-main.sh
#
# Settings live in essconfig.yaml next to this script. If the file is missing
# it is created from your answers.
#
# Unattended run (no prompts), first install:
#   sudo SERVER_NAME=example.com ACME_EMAIL=you@example.com LIVEKIT_URL=wss://... \
#        LIVEKIT_KEY=... LIVEKIT_SECRET=... bash setup-main.sh
#   3-server layout: LIVEKIT_URL is the relay; add EXTERNAL_LIVEKIT_IP=<LiveKit server IP>
#                    and EXTERNAL_LIVEKIT_CERT=<"LiveKit certificate" line from setup-livekit.sh>
# Other env: ESS_CONFIG=/path/essconfig.yaml  REMOVE_LEGACY_RTC=1  CERT_MANAGER_VERSION=v1.17.0
#
# TEST=1   install a second, separate copy next to a running one: namespace
#          "ess-test", settings in essconfig-test.yaml. It needs its own server
#          name + DNS records and never touches the existing install.
# DEBUG=1  print every command as it runs (the output will contain secrets).
set -Eeuo pipefail
trap 'echo "FAILED at line $LINENO (see the output above)" >&2' ERR
if [ "${DEBUG:-0}" = 1 ]; then PS4='+ line ${LINENO}: '; set -x; fi
TEST="${TEST:-0}"; SUFFIX=""; [ "$TEST" != 1 ] || SUFFIX="-test"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${ESS_CONFIG:-$SCRIPT_DIR/essconfig$SUFFIX.yaml}"
EXTRA_VALUES="$SCRIPT_DIR/ess-extra-values$SUFFIX.yaml"   # optional: raw Helm values, applied last
STATE_DIR="/etc/ess-setup$SUFFIX"
NAMESPACE="ess$SUFFIX"
RERUN="sudo ${SUFFIX:+TEST=1 }bash setup-main.sh"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.0}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
interactive() { [ -t 0 ]; }
kubectl() { k3s kubectl "$@"; }

ask() {   # ask VAR "question" [default] — keeps VAR if already set (e.g. from env)
  local var=$1 question=$2 default=${3-} answer
  [ -z "${!var-}" ] || return 0
  if interactive; then
    read -r -p "$question${default:+ [$default]}: " answer
    printf -v "$var" '%s' "${answer:-$default}"
  else
    printf -v "$var" '%s' "$default"
  fi
}

confirm() {   # confirm "question" — yes/no, defaults to no; always no when unattended
  local answer
  interactive || return 1
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy] ]]
}

cfg() {   # cfg key [default] — read "key: value" from essconfig.yaml
  local v
  v=$(sed -n "s/^$1:[[:space:]]*//p" "$CONFIG" | head -n1 |
      sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")
  printf '%s' "${v:-${2-}}"
}

is_domain() { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }
is_ipv4()   { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
is_wss_url() { [[ "$1" =~ ^wss://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; }

[ "$(id -u)" -eq 0 ] || die "run as root:  sudo bash $0"
[ "$(uname -s)" = Linux ] || die "this script must run on the Linux server itself"
command -v apt-get >/dev/null || die "Debian / Ubuntu only"
[ "$TEST" != 1 ] || cat <<MSG

*** TEST MODE: a separate copy in namespace "$NAMESPACE", settings in $(basename "$CONFIG").
*** The existing install is not modified. Use a server name that is NOT your
*** live one (e.g. test.example.com) and create its DNS records first.
*** A second copy needs roughly 2 GB of free memory.
MSG

# ------------------------------------------------------------------ packages
log "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-upgrade curl openssl ca-certificates

# -------------------------------------------------------------------- config
if [ ! -f "$CONFIG" ]; then
  log "No $(basename "$CONFIG") found — creating one"
  cat <<'MSG'
Your "server name" is the domain at the end of every user ID (@alice:example.com).
It can NOT be changed later without wiping the server, so choose carefully.
MSG
  SERVER_NAME="${SERVER_NAME:-}"; ACME_EMAIL="${ACME_EMAIL:-}"
  LIVEKIT_URL="${LIVEKIT_URL:-}"; LIVEKIT_KEY="${LIVEKIT_KEY:-}"; LIVEKIT_SECRET="${LIVEKIT_SECRET:-}"
  EXTERNAL_LIVEKIT_IP="${EXTERNAL_LIVEKIT_IP:-}"; EXTERNAL_LIVEKIT_PORT="${EXTERNAL_LIVEKIT_PORT:-}"
  EXTERNAL_LIVEKIT_CERT="${EXTERNAL_LIVEKIT_CERT:-}"
  ask SERVER_NAME "Server name (your domain, e.g. example.com)"
  is_domain "$SERVER_NAME" || die "'$SERVER_NAME' is not a valid domain (unattended run: set SERVER_NAME=example.com)"
  ask ACME_EMAIL "Email for Let's Encrypt expiry notices (optional, Enter to skip)"
  if [ -z "$LIVEKIT_URL" ] && interactive; then
    cat <<'MSG'

Calls: the address call clients connect to.
  2-server layout:  the LiveKit server,  wss://<LiveKit IP>:7443
  3-server layout:  the relay,           wss://<relay IP>:7443
Both are printed at the end of setup-livekit.sh / setup-relay.sh.
Just press Enter to install without calls and add them later.
MSG
    ask LIVEKIT_URL "LiveKit address (wss://...)"
  fi
  if [ -n "$LIVEKIT_URL" ]; then
    is_wss_url "$LIVEKIT_URL" || die "the LiveKit address must look like wss://host or wss://ip:port"
    ask LIVEKIT_KEY "LiveKit API key"
    ask LIVEKIT_SECRET "LiveKit API secret"
    [ -n "$LIVEKIT_KEY" ] && [ -n "$LIVEKIT_SECRET" ] || die "the LiveKit API key and secret are required with a LiveKit address"
    if [ -z "$EXTERNAL_LIVEKIT_IP" ] && interactive; then
      cat <<'MSG'

3-server layout only: the address above is your relay, so also enter the
LiveKit server's own public IP. 2-server layout: just press Enter.
MSG
      ask EXTERNAL_LIVEKIT_IP "LiveKit server IP (3-server layout)"
      if [ -n "$EXTERNAL_LIVEKIT_IP" ]; then
        ask EXTERNAL_LIVEKIT_PORT "LiveKit server port" 7443
        echo "Paste the \"LiveKit certificate\" line from setup-livekit.sh (one long line)."
        ask EXTERNAL_LIVEKIT_CERT "LiveKit certificate"
      fi
    fi
    [ -z "$EXTERNAL_LIVEKIT_IP" ] || is_ipv4 "$EXTERNAL_LIVEKIT_IP" || die "the LiveKit server IP must be an IPv4 address"
  fi
  umask 077
  cat >"$CONFIG" <<EOF
# essconfig.yaml — settings for setup-main.sh.
# Edit, then run "${RERUN}" again to apply.
# Format: one "key: value" per line. This file holds secrets — keep it private.

# The domain in your user IDs (@you:${SERVER_NAME}). Never change after install.
server_name: ${SERVER_NAME}

# Hostnames — each needs a DNS A record pointing at THIS server.
matrix_host: matrix.${SERVER_NAME}
account_host: account.${SERVER_NAME}
admin_host: admin.${SERVER_NAME}
rtc_host: mrtc.${SERVER_NAME}
# Set to e.g. chat.${SERVER_NAME} to also host the Element Web client. Empty = off.
element_web_host:

# Email for Let's Encrypt expiry notices (optional; used at first install).
acme_email: ${ACME_EMAIL}

# Sign-up: "token" = people need an invite token, "closed" = admin creates accounts.
registration: token

# Calls. The values are printed at the end of setup-livekit.sh / setup-relay.sh.
# livekit_url is the address call clients connect to:
#   2-server layout:  the LiveKit server,  wss://<LiveKit IP>:7443
#   3-server layout:  the relay,           wss://<relay IP>:7443
# Leave it empty to keep calls switched off.
livekit_url: ${LIVEKIT_URL}
livekit_key: ${LIVEKIT_KEY}
livekit_secret: ${LIVEKIT_SECRET}

# 3-server layout only: the LiveKit server's own public IP (and TLS port).
# https://<rtc_host>/ is then also routed straight to it.
# Leave the IP empty in the 2-server layout.
external_livekit_ip: ${EXTERNAL_LIVEKIT_IP}
external_livekit_port: ${EXTERNAL_LIVEKIT_PORT:-7443}
# The "LiveKit certificate" line printed by setup-livekit.sh. With it, this
# server only accepts that exact LiveKit server; empty = no check.
external_livekit_cert: $(printf '%s' "${EXTERNAL_LIVEKIT_CERT}" | tr -d '[:space:]')

# Pin the ESS chart version (empty = latest).
ess_chart_version:
EOF
  umask 022
  echo "Created $CONFIG"
fi
chmod 600 "$CONFIG"

SERVER_NAME=$(cfg server_name)
MATRIX_HOST=$(cfg matrix_host "matrix.$SERVER_NAME")
ACCOUNT_HOST=$(cfg account_host "account.$SERVER_NAME")
ADMIN_HOST=$(cfg admin_host "admin.$SERVER_NAME")
RTC_HOST=$(cfg rtc_host "mrtc.$SERVER_NAME")
WEB_HOST=$(cfg element_web_host)
ACME_EMAIL=$(cfg acme_email)
REGISTRATION=$(cfg registration token)
LIVEKIT_URL=$(cfg livekit_url)
EXT_IP=$(cfg external_livekit_ip)
EXT_PORT=$(cfg external_livekit_port 7443)
EXT_CERT=$(cfg external_livekit_cert)
LK_KEY=$(cfg livekit_key)
LK_SECRET=$(cfg livekit_secret)
CHART_VERSION=$(cfg ess_chart_version)

is_domain "$SERVER_NAME" || die "server_name in $CONFIG is missing or not a domain"
for h in "$MATRIX_HOST" "$ACCOUNT_HOST" "$ADMIN_HOST" "$RTC_HOST" ${WEB_HOST:+"$WEB_HOST"}; do
  is_domain "$h" || die "'$h' in $CONFIG is not a valid hostname"
done
[[ "$REGISTRATION" =~ ^(token|closed)$ ]] || die "registration must be 'token' or 'closed'"
[ -z "$LIVEKIT_URL" ] || is_wss_url "$LIVEKIT_URL" || die "livekit_url must look like wss://host or wss://ip:port"
[ -z "$EXT_IP" ] || is_ipv4 "$EXT_IP" || die "external_livekit_ip must be an IPv4 address"
[[ "$EXT_PORT" =~ ^[0-9]+$ ]] || die "external_livekit_port must be a number"
[ -z "$EXT_IP" ] || [ -n "$LIVEKIT_URL" ] || die "external_livekit_ip needs livekit_url (the relay address) as well"
if [ -n "$LIVEKIT_URL" ]; then
  [[ "$LK_KEY" =~ ^[A-Za-z0-9_-]+$ ]] || die "livekit_key in $CONFIG is missing (copy it from setup-livekit.sh)"
  [[ "$LK_SECRET" =~ ^[A-Za-z0-9_-]{32,}$ ]] || die "livekit_secret in $CONFIG is missing or too short (copy it from setup-livekit.sh)"
fi

HOSTS=("$SERVER_NAME" "$MATRIX_HOST" "$ACCOUNT_HOST" "$ADMIN_HOST" "$RTC_HOST")
[ -z "$WEB_HOST" ] || HOSTS+=("$WEB_HOST")

# ------------------------------------------------------------------ DNS check
log "Checking DNS"
PUBLIC_IP=""
for u in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me; do
  ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)
  if is_ipv4 "$ip"; then PUBLIC_IP="$ip"; break; fi
done
dns_bad=0
for h in "${HOSTS[@]}"; do
  resolved=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}' || true)
  if [ -z "$resolved" ]; then
    warn "$h does not resolve yet"; dns_bad=1
  elif [ -n "$PUBLIC_IP" ] && [ "$resolved" != "$PUBLIC_IP" ]; then
    warn "$h points at $resolved, but this server's public IP looks like $PUBLIC_IP"; dns_bad=1
  else
    echo "ok   $h -> $resolved"
  fi
done
if [ "$dns_bad" = 1 ]; then
  cat <<MSG

Every hostname above needs a DNS A record pointing at this server${PUBLIC_IP:+ ($PUBLIC_IP)},
and ports 80 + 443 (TCP) must be open — otherwise Let's Encrypt cannot issue
certificates and the install will sit waiting until it times out.
(Behind a CDN / proxy the IPs differ on purpose; then this warning is harmless.)
MSG
  if interactive; then confirm "Continue anyway?" || die "fix DNS, then run this script again"; fi
fi

# ----------------------------------------------------------------------- K3s
if ! command -v k3s >/dev/null; then
  log "Installing K3s (single-node Kubernetes)"
  curl -sfL https://get.k3s.io | sh -
fi
TRAEFIK_CFG=/var/lib/rancher/k3s/server/manifests/traefik-config.yaml
if [ ! -f "$TRAEFIK_CFG" ] && [ "$TEST" != 1 ]; then   # (changing it restarts Traefik)
  # Traefik settings recommended by the ESS README.
  cat >"$TRAEFIK_CFG" <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        forwardedHeaders:
          trustedIPs:
            - "10.42.0.0/16"
            - "2001:db8:42::/56"
        http:
          encodedCharacters:
            allowEncodedHash: true
            allowEncodedSlash: true
      websecure:
        forwardedHeaders:
          trustedIPs:
            - "10.42.0.0/16"
            - "2001:db8:42::/56"
        http:
          encodedCharacters:
            allowEncodedHash: true
            allowEncodedSlash: true
EOF
fi

log "Waiting for Kubernetes to be ready"
for _ in $(seq 60); do
  kubectl get nodes 2>/dev/null | grep -qw Ready && break
  sleep 5
done
kubectl get nodes | grep -qw Ready || die "K3s did not become ready; check: journalctl -u k3s -e"

# Let the admin user (the one who ran sudo) use kubectl / helm directly too.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  if [ -n "$user_home" ] && [ ! -e "$user_home/.kube/config" ]; then
    install -d -o "$SUDO_USER" -g "$(id -gn "$SUDO_USER")" "$user_home/.kube"
    install -m 600 -o "$SUDO_USER" -g "$(id -gn "$SUDO_USER")" "$KUBECONFIG" "$user_home/.kube/config"
  fi
fi

if ! command -v helm >/dev/null; then
  log "Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if [ "$TEST" = 1 ]; then
  # Two installs answering for the same hostname would break the live one.
  taken=$(kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{range .spec.rules[*]}{.host}{" "}{end}{"\n"}{end}' |
          awk -v ns="$NAMESPACE" '$1 != ns { for (i = 2; i <= NF; i++) print $i }')
  for h in "${HOSTS[@]}"; do
    ! grep -qxF "$h" <<<"$taken" ||
      die "$h is already served by another install on this server. Use different names in $(basename "$CONFIG")."
  done
fi
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

# -------------------------------------------------------------- cert-manager
if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
  log "Installing cert-manager $CERT_MANAGER_VERSION (Let's Encrypt certificates)"
  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace \
    --version "$CERT_MANAGER_VERSION" --set crds.enabled=true --wait
fi
# An issuer that already exists is left alone.
kubectl get clusterissuer letsencrypt-prod >/dev/null 2>&1 || kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
${ACME_EMAIL:+    email: ${ACME_EMAIL}}
    privateKeySecretRef:
      name: letsencrypt-prod-private-key
    solvers:
      - http01:
          ingress:
            class: traefik
EOF

# ---------------------------------------------------------------- ESS values
install -d -m 700 "$STATE_DIR"
VALUES="$STATE_DIR/values.yaml"
{
  cat <<EOF
# Generated by setup-main.sh from $(basename "$CONFIG") — do not edit, it is overwritten.
serverName: ${SERVER_NAME}
certManager:
  clusterIssuer: letsencrypt-prod
synapse:
  ingress:
    host: ${MATRIX_HOST}
elementAdmin:
  ingress:
    host: ${ADMIN_HOST}
matrixAuthenticationService:
  ingress:
    host: ${ACCOUNT_HOST}
EOF
  if [ "$REGISTRATION" = token ]; then
    cat <<'EOF'
  additional:
    auth.yaml:
      config: |
        account:
          password_registration_enabled: true
          registration_token_required: true
          password_registration_email_required: false
          password_change_allowed: true
EOF
  fi
  if [ -n "$WEB_HOST" ]; then
    printf 'elementWeb:\n  ingress:\n    host: %s\n' "$WEB_HOST"
  else
    printf 'elementWeb:\n  enabled: false\n'
  fi
  if [ -n "$LIVEKIT_URL" ]; then
    # ESS runs the call login service; the media server (SFU) is external.
    cat <<EOF
matrixRTC:
  enabled: true
  ingress:
    host: ${RTC_HOST}
  sfu:
    enabled: false
  livekitAuth:
    key: "${LK_KEY}"
    secret:
      value: "${LK_SECRET}"
  extraEnv:
    - name: LIVEKIT_URL
      value: ${LIVEKIT_URL}
EOF
  else
    printf '# Calls are off until livekit_url is set.\nmatrixRTC:\n  enabled: false\n'
  fi
} >"$VALUES"
chmod 600 "$VALUES"

# ------------------------------------------------------- pre-split leftovers
# Older versions of this project ran their own lk-jwt-service and proxied the
# calls host to the LiveKit server. ESS does that itself now; the old objects
# would fight over the same hostname.
if [ -n "$LIVEKIT_URL" ] && { kubectl -n "$NAMESPACE" get ingress combined-rtc-ingress >/dev/null 2>&1 ||
                              kubectl -n "$NAMESPACE" get deployment lk-jwt-service >/dev/null 2>&1; }; then
  if [ "${REMOVE_LEGACY_RTC:-0}" = 1 ] ||
     confirm "Found the old hand-made call setup (lk-jwt-service, combined-rtc-ingress). Replace it now? Calls drop for a few minutes"; then
    kubectl -n "$NAMESPACE" delete --ignore-not-found ingress/combined-rtc-ingress \
      deployment/lk-jwt-service service/lk-jwt-service service/external-livekit endpoints/external-livekit
    kubectl -n "$NAMESPACE" delete --ignore-not-found serverstransport.traefik.io/livekit-tls secret/livekit-ca || true
  else
    die "the old call setup conflicts with the new one. Run again and answer yes (or set REMOVE_LEGACY_RTC=1),
       or empty livekit_url in $(basename "$CONFIG") to leave calls as they are for now."
  fi
fi

# ------------------------------------------------------------------- install
log "Installing / upgrading Element Server Suite (first run can take 10+ minutes)"
helm_args=(upgrade --install --namespace "$NAMESPACE" ess oci://ghcr.io/element-hq/ess-helm/matrix-stack
           -f "$VALUES" --wait --timeout 20m)
[ -z "$CHART_VERSION" ] || helm_args+=(--version "$CHART_VERSION")
if [ -f "$EXTRA_VALUES" ]; then
  echo "Also applying $(basename "$EXTRA_VALUES")"
  helm_args+=(-f "$EXTRA_VALUES")
fi
helm "${helm_args[@]}"

# ------------------------------------------- direct route to LiveKit (3 servers)
EXT=rtc-external-livekit
if [ -n "$EXT_IP" ]; then
  log "Routing https://$RTC_HOST/ -> LiveKit server $EXT_IP:$EXT_PORT"
  for _ in $(seq 60); do
    kubectl get crd serverstransports.traefik.io >/dev/null 2>&1 && break
    sleep 5
  done
  if [ -n "$EXT_CERT" ]; then
    ca_file=$(mktemp)
    printf '%s' "$EXT_CERT" | base64 -d >"$ca_file" 2>/dev/null && openssl x509 -in "$ca_file" -noout 2>/dev/null ||
      die "external_livekit_cert in $(basename "$CONFIG") is not the certificate line from setup-livekit.sh
       (it must be the whole line, with nothing cut off)."
    kubectl -n "$NAMESPACE" delete secret "$EXT-ca" --ignore-not-found >/dev/null
    kubectl -n "$NAMESPACE" create secret generic "$EXT-ca" --from-file=ca.crt="$ca_file"
    rm -f "$ca_file"
    TRANSPORT_TLS="rootCAs:
    - secret: ${EXT}-ca"
  else
    warn "external_livekit_cert is empty: this server will not check which LiveKit server it talks to."
    kubectl -n "$NAMESPACE" delete secret "$EXT-ca" --ignore-not-found >/dev/null
    TRANSPORT_TLS="insecureSkipVerify: true"
  fi
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${EXT}
  namespace: ${NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/service.serversscheme: https
    traefik.ingress.kubernetes.io/service.serverstransport: ${NAMESPACE}-${EXT}@kubernetescrd
spec:
  ports:
    - port: ${EXT_PORT}
      targetPort: ${EXT_PORT}
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: ${EXT}
  namespace: ${NAMESPACE}
subsets:
  - addresses:
      - ip: ${EXT_IP}
    ports:
      - port: ${EXT_PORT}
---
# TLS to the LiveKit server uses its self-signed certificate under a fixed
# private name — no domain appears in the connection.
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: ${EXT}
  namespace: ${NAMESPACE}
spec:
  serverName: livekit-internal
  ${TRANSPORT_TLS}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${EXT}
  namespace: ${NAMESPACE}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: traefik
  rules:
    - host: ${RTC_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${EXT}
                port:
                  number: ${EXT_PORT}
  tls:
    - hosts:
        - ${RTC_HOST}
      secretName: ${EXT}-tls
EOF
else
  kubectl -n "$NAMESPACE" delete --ignore-not-found "ingress/$EXT" "service/$EXT" "endpoints/$EXT" "secret/$EXT-ca" >/dev/null
  kubectl -n "$NAMESPACE" delete --ignore-not-found "serverstransport.traefik.io/$EXT" >/dev/null 2>&1 || true
fi

# --------------------------------------------------------------- calls check
if [ -n "$LIVEKIT_URL" ]; then
  log "Checking the LiveKit address"
  body=$(curl -s --max-time 15 "https://${LIVEKIT_URL#wss://}/" || true)
  if [ "$body" = OK ]; then
    echo "ok   $LIVEKIT_URL answers with a trusted certificate — calls are wired up."
  else
    warn "$LIVEKIT_URL did not answer correctly from this server (got: '${body:-nothing}').
         Calls will fail until it does: check the LiveKit / relay server, its firewall and its certificate."
  fi
  if [ -n "$EXT_IP" ]; then
    body=$(curl -sk --max-time 15 "https://$EXT_IP:$EXT_PORT/" || true)
    [ "$body" = OK ] && echo "ok   LiveKit server $EXT_IP:$EXT_PORT is reachable from here." ||
      warn "LiveKit server $EXT_IP:$EXT_PORT is not reachable from here: its firewall must allow
         this server${PUBLIC_IP:+ ($PUBLIC_IP)} on TCP $EXT_PORT."
  fi
fi

# ------------------------------------------------------------------- summary
cat <<MSG

=====================================================================
 Element Server Suite is installed.

 Sign-in / accounts : https://${ACCOUNT_HOST}
 Admin console      : https://${ADMIN_HOST}
 Homeserver         : https://${MATRIX_HOST}   (server name: ${SERVER_NAME})
${WEB_HOST:+ Element Web        : https://${WEB_HOST}
}
 Create your first (admin) user:
   sudo k3s kubectl exec -n ${NAMESPACE} -it deploy/ess-matrix-authentication-service -- mas-cli manage register-user
MSG
[ "$REGISTRATION" != token ] || cat <<MSG
 Create an invite token so others can sign up:
   sudo k3s kubectl exec -n ${NAMESPACE} deploy/ess-matrix-authentication-service -- mas-cli manage issue-user-registration-token
MSG
echo
echo " ---- Calls ----------------------------------------------------------"
if [ -z "$LIVEKIT_URL" ]; then
  cat <<MSG
 Calls are NOT active yet:
   1. On the LiveKit server run:  sudo bash setup-livekit.sh
   2. Put the address, key and secret it prints into $(basename "$CONFIG"),
      then run:  ${RERUN}
MSG
else
  echo " Call clients connect to: ${LIVEKIT_URL}"
  [ -z "$EXT_IP" ] || echo " LiveKit server (3-server layout): ${EXT_IP}:${EXT_PORT}"
fi
echo
echo " Change settings: edit $(basename "$CONFIG"), then run:  ${RERUN}"
[ "$TEST" != 1 ] || cat <<MSG

 TEST MODE — the live install was not touched. Remove this test copy with:
   sudo helm uninstall ess -n ${NAMESPACE} --kubeconfig ${KUBECONFIG}
   sudo k3s kubectl delete namespace ${NAMESPACE}
   sudo rm -rf ${STATE_DIR} ${CONFIG}
MSG
echo "====================================================================="
