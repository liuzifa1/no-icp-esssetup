#!/usr/bin/env bash
# setup-relay.sh — step 2 of 3 (optional): a WSS relay in front of LiveKit.
#
# Only for the 3-server layout (see README.md); run it after setup-livekit.sh.
#
# Use it when LiveKit should live where bandwidth is cheap while clients
# connect somewhere close to them, or when the LiveKit server's provider blocks
# ports 80/443 so it cannot get a trusted certificate. Call clients connect to
#   wss://<this server's IP>:<port>
# and nginx forwards the call signalling to the LiveKit server. Like the
# LiveKit server, the relay has no domain: it uses a free Let's Encrypt
# certificate issued for its public IP address (renewed automatically).
#
# Safe to run again: answers are remembered in /etc/element-rtc/relay.env.
#
#   usage:  sudo bash setup-relay.sh
#
# Unattended run (no prompts):
#   sudo EMAIL=you@example.com BACKEND_IP=1.2.3.4 bash setup-relay.sh
# Env:  EMAIL  BACKEND_IP  BACKEND_PORT=7443  LISTEN_PORT=7443  PUBLIC_IP
#       BACKEND_CERT (the "LiveKit certificate" line from setup-livekit.sh; optional)
#       SKIP_STAGING=1 (skip the test certificate)   RECONFIGURE=1 (ask everything again)
#       GITHUB_MIRROR=https://your-mirror/   (prefix for github.com downloads)
#
# TEST=1   add a second relay next to a running one: its own port (default
#          7444), config (relay-test.conf) and answers (/etc/element-rtc-test).
#          The running relay is not touched; the IP certificate is shared.
# DEBUG=1  print every command as it runs.
set -Eeuo pipefail
trap 'echo "FAILED at line $LINENO (see the output above)" >&2' ERR
if [ "${DEBUG:-0}" = 1 ]; then PS4='+ line ${LINENO}: '; set -x; fi
TEST="${TEST:-0}"; SUFFIX=""; [ "$TEST" != 1 ] || SUFFIX="-test"

STATE_DIR="/etc/element-rtc$SUFFIX"
RELAY_CONF="/etc/nginx/conf.d/relay$SUFFIX.conf"
ACME_CONF=/etc/nginx/conf.d/acme.conf
RERUN="sudo ${SUFFIX:+TEST=1 }bash setup-relay.sh"
STATE="$STATE_DIR/relay.env"
BACKEND_SNI=livekit-internal      # TLS name the LiveKit server answers to (see README.md)
ACME=/root/.acme.sh/acme.sh
CERT_DIR=/etc/nginx/certs
EMAIL="${EMAIL:-}"; PUBLIC_IP="${PUBLIC_IP:-}"
BACKEND_IP="${BACKEND_IP:-}"; BACKEND_PORT="${BACKEND_PORT:-}"; LISTEN_PORT="${LISTEN_PORT:-}"
BACKEND_CERT="${BACKEND_CERT:-}"
SKIP_STAGING="${SKIP_STAGING:-0}"; RECONFIGURE="${RECONFIGURE:-0}"; GITHUB_MIRROR="${GITHUB_MIRROR:-}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
interactive() { [ -t 0 ]; }
is_ipv4() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

ask() {   # ask VAR "question" [default] — skipped when VAR is already known
  local var=$1 question=$2 default=${3-} answer
  if [ -n "${!var-}" ]; then
    [ "$RECONFIGURE" = 1 ] && interactive || return 0
    default=${!var}
  fi
  if interactive; then
    read -r -p "$question${default:+ [$default]}: " answer
    printf -v "$var" '%s' "${answer:-$default}"
  else
    printf -v "$var" '%s' "$default"
  fi
}

load_state() {   # saved answers fill in whatever the environment did not set
  local line k v
  [ -f "$STATE" ] || return 0
  while IFS= read -r line; do
    k=${line%%=*}; v=${line#*=}
    [[ "$k" =~ ^[A-Z_]+$ ]] || continue
    [ -n "${!k-}" ] || printf -v "$k" '%s' "$v"
  done <"$STATE"
}

[ "$(id -u)" -eq 0 ] || die "run as root:  sudo bash $0"
[ "$(uname -s)" = Linux ] || die "this script must run on the Linux server itself"
command -v apt-get >/dev/null || die "Debian / Ubuntu only"
load_state
[ "$TEST" != 1 ] || cat <<MSG

*** TEST MODE: a second relay on its own port ($RELAY_CONF).
*** The running relay is not touched.
MSG

# ------------------------------------------------------------------ questions
interactive && [ -z "$BACKEND_IP" ] && cat <<'MSG'

This relay forwards call clients to your LiveKit server. Have ready: the
LiveKit server IP, port and certificate printed at the end of setup-livekit.sh.
MSG
ask EMAIL "Email for the Let's Encrypt account (certificate notices)"
[[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "a valid EMAIL is required"
ask BACKEND_IP "Public IP of your LiveKit server"
is_ipv4 "$BACKEND_IP" || die "BACKEND_IP must be the IPv4 address of the LiveKit server"
ask BACKEND_PORT "LiveKit server port" "$([ "$TEST" = 1 ] && echo 17443 || echo 7443)"
ask LISTEN_PORT "Port this relay listens on" "$([ "$TEST" = 1 ] && echo 7444 || echo 7443)"
[[ "$BACKEND_PORT" =~ ^[0-9]+$ && "$LISTEN_PORT" =~ ^[0-9]+$ ]] || die "ports must be numbers"
interactive && [ -z "$BACKEND_CERT" ] && cat <<'MSG'

Paste the "LiveKit certificate" line from setup-livekit.sh, so this relay only
ever forwards calls to your real LiveKit server. (Enter skips the check.)
MSG
ask BACKEND_CERT "LiveKit certificate"
BACKEND_CERT=$(printf '%s' "$BACKEND_CERT" | tr -d '[:space:]')
[ "$LISTEN_PORT" != 80 ] || die "port 80 is needed for certificate checks; pick another LISTEN_PORT"

# ------------------------------------------------------------------ packages
log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-upgrade nginx curl cron openssl ca-certificates git iproute2
systemctl enable --now nginx cron >/dev/null
[ "$TEST" = 1 ] || rm -f /etc/nginx/sites-enabled/default
busy=$(ss -H -lntp "sport = :$LISTEN_PORT" 2>/dev/null | grep -v nginx || true)
[ -z "$busy" ] || die "TCP port $LISTEN_PORT is already used by another program:
$busy
Choose another one:  sudo RECONFIGURE=1 ${RERUN#sudo }"
if [ "$TEST" = 1 ] && grep -lsE "listen[[:space:]]+${LISTEN_PORT}([[:space:]]|;)" /etc/nginx/conf.d/*.conf | grep -qvF "$RELAY_CONF"; then
  die "port $LISTEN_PORT is already used by the running relay. Choose another one:  sudo RECONFIGURE=1 ${RERUN#sudo }"
fi

NEW_NGINX_FILES=()
nginx_apply() {   # load the new nginx config; a broken one is never left behind for the next reload
  if ! nginx -t; then
    [ "${#NEW_NGINX_FILES[@]}" -eq 0 ] || rm -f "${NEW_NGINX_FILES[@]}"
    die "nginx rejected the new configuration (removed again; the running nginx is unchanged).
       The message above names the conflict — usually a port or default server already defined elsewhere."
  fi
  systemctl reload nginx
  NEW_NGINX_FILES=()
}
if command -v ufw >/dev/null && [[ "$(ufw status)" == *"Status: active"* ]]; then
  ufw allow 80/tcp
  ufw allow "${LISTEN_PORT}/tcp"
fi

# ----------------------------------------------------------------- public IP
if [ -z "$PUBLIC_IP" ]; then
  for u in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me; do
    ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)
    if is_ipv4 "$ip"; then PUBLIC_IP="$ip"; break; fi
  done
fi
is_ipv4 "$PUBLIC_IP" || die "cannot detect this server's public IP; run again with PUBLIC_IP=x.x.x.x"
echo "This relay's public IP: $PUBLIC_IP"

install -d -m 700 "$STATE_DIR"
( umask 077
  printf '%s=%s\n' EMAIL "$EMAIL" BACKEND_IP "$BACKEND_IP" BACKEND_PORT "$BACKEND_PORT" \
    LISTEN_PORT "$LISTEN_PORT" PUBLIC_IP "$PUBLIC_IP" BACKEND_CERT "$BACKEND_CERT" >"$STATE" )

BACKEND_CA="$STATE_DIR/livekit-ca.crt"
if [ -n "$BACKEND_CERT" ]; then
  # nginx workers must be able to read it; it is a public certificate.
  chmod 755 "$STATE_DIR"; chmod 600 "$STATE"
  printf '%s' "$BACKEND_CERT" | base64 -d >"$BACKEND_CA" 2>/dev/null &&
    openssl x509 -in "$BACKEND_CA" -noout 2>/dev/null ||
    die "that is not the LiveKit certificate line (copy the whole line, with nothing cut off).
       Run again:  sudo RECONFIGURE=1 ${RERUN#sudo }"
  chmod 644 "$BACKEND_CA"
  VERIFY_LINES="proxy_ssl_verify on;
        proxy_ssl_trusted_certificate ${BACKEND_CA};"
else
  warn "no LiveKit certificate given: the relay will not check which server it forwards to."
  VERIFY_LINES="proxy_ssl_verify off;"
fi

# --------------------------------------------- port 80: certificate checks only
log "Preparing port 80 for Let's Encrypt"
mkdir -p /var/www/acme "$CERT_DIR"
if [ ! -f "$ACME_CONF" ]; then
  NEW_NGINX_FILES+=("$ACME_CONF")
  cat >"$ACME_CONF" <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 404; }
}
EOF
fi
# A relay config without its certificate would stop nginx from loading.
[ -s "$CERT_DIR/fullchain.pem" ] || rm -f "$RELAY_CONF"
nginx_apply

# ------------------------------------------------------------------- acme.sh
gh() { printf '%s%s' "$GITHUB_MIRROR" "$1"; }
if [ ! -x "$ACME" ]; then
  log "Installing acme.sh (certificate client)"
  tmp=$(mktemp -d)
  timeout 90 git clone -q --depth 1 "$(gh https://github.com/acmesh-official/acme.sh.git)" "$tmp/acme.sh" ||
    { rm -rf "$tmp/acme.sh"   # GitHub unreachable (common in mainland China): use the official Gitee mirror
      git clone -q --depth 1 https://gitee.com/neilpang/acme.sh.git "$tmp/acme.sh"; }
  (cd "$tmp/acme.sh" && ./acme.sh --install -m "$EMAIL")
  rm -rf "$tmp"
fi
"$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
"$ACME" --install-cronjob >/dev/null 2>&1 || true    # acme.sh's built-in daily auto-renewal

# IP certificates only exist in Let's Encrypt's "shortlived" profile (valid ~6 days).
HELP=$("$ACME" --help 2>&1 || true)
if   grep -q -- '--certificate-profile' <<<"$HELP"; then PF=--certificate-profile
elif grep -q -- '--cert-profile'        <<<"$HELP"; then PF=--cert-profile
else die "this acme.sh is too old for IP certificates; update it:  $ACME --upgrade"; fi

issue_cert() {   # $1 = ACME server alias, rest = extra flags
  "$ACME" --issue -d "$PUBLIC_IP" --webroot /var/www/acme "$PF" shortlived \
    --keylength ec-256 --server "$1" "${@:2}"
}

if [ -s "$CERT_DIR/fullchain.pem" ] && [ -s "$CERT_DIR/privkey.pem" ] &&
   openssl x509 -checkend $((3*86400)) -noout -in "$CERT_DIR/fullchain.pem" >/dev/null 2>&1 &&
   openssl x509 -checkip "$PUBLIC_IP" -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null | grep -q 'does match'; then
  log "A valid certificate for $PUBLIC_IP is already installed — keeping it"
else
  cert_help="Let's Encrypt must be able to reach http://$PUBLIC_IP/ :
       open TCP 80 from anywhere in this server's firewall / cloud security group, then run again."
  if [ "$SKIP_STAGING" != 1 ]; then
    log "Test run against Let's Encrypt staging (does not count against rate limits)"
    issue_cert letsencrypt_test --force || die "the test certificate failed. $cert_help"
  fi
  log "Requesting the real certificate for $PUBLIC_IP"
  issue_cert letsencrypt --force || die "certificate request failed. $cert_help"
  # The paths and reload command are remembered by acme.sh and reused on every auto-renewal.
  "$ACME" --install-cert -d "$PUBLIC_IP" --ecc \
    --key-file "$CERT_DIR/privkey.pem" \
    --fullchain-file "$CERT_DIR/fullchain.pem" \
    --reloadcmd "systemctl reload nginx"
  chmod 600 "$CERT_DIR/privkey.pem"
fi

# ----------------------------------------------------------------- WSS relay
log "Configuring the relay on :${LISTEN_PORT}"
[ -f "$RELAY_CONF" ] || NEW_NGINX_FILES+=("$RELAY_CONF")
cat >"$RELAY_CONF" <<EOF
# Generated by setup-relay.sh — edits are overwritten on the next run.
# Browsers connect by IP address and get the Let's Encrypt IP certificate.
server {
    listen ${LISTEN_PORT} ssl;
    server_name _;
    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass https://${BACKEND_IP}:${BACKEND_PORT};

        # The LiveKit server uses a self-signed certificate under this name, so
        # no domain appears in the connection.
        proxy_ssl_server_name on;
        proxy_ssl_name ${BACKEND_SNI};
        proxy_ssl_protocols TLSv1.3;
        ${VERIFY_LINES}

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
nginx_apply

# -------------------------------------------------------------------- verify
log "Checking"
openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject -enddate -ext subjectAltName
sleep 2
body=$(curl -sk --max-time 10 -w ' (HTTP %{http_code})' "https://127.0.0.1:${LISTEN_PORT}/" || true)
backend_ok=0
if [[ "$body" == "OK (HTTP 200)" ]]; then
  backend_ok=1; echo "ok   relay -> LiveKit server works"
else
  warn "relay -> LiveKit server: got '${body:-no answer}'.
         Usually the LiveKit server's firewall does not allow TCP ${BACKEND_PORT} from ${PUBLIC_IP} yet.
         (HTTP 502 with the firewall open: the LiveKit certificate line does not belong to that server.)"
fi

# ------------------------------------------------------------------- summary
cat <<MSG

=====================================================================
 Relay configured: wss://${PUBLIC_IP}:${LISTEN_PORT}  ->  ${BACKEND_IP}:${BACKEND_PORT}${SUFFIX:+  [TEST relay]}
 $([ "$backend_ok" = 1 ] && echo "The LiveKit server is reachable." || echo "The LiveKit server is NOT reachable yet (see the warning above).")

 Firewall / cloud security group:
   this relay      : allow TCP 80 and TCP ${LISTEN_PORT} from anywhere
                     (80 must stay open: the certificate renews every few days)
   LiveKit server  : allow TCP ${BACKEND_PORT} from ${PUBLIC_IP}

$([ "$backend_ok" = 1 ] || echo "
 Fix the LiveKit server's firewall first, then run this script again to re-check.")
 NEXT: on the MAIN server run  sudo ${SUFFIX:+TEST=1 }bash setup-main.sh
 It asks for (3-server layout):

   LiveKit address     : wss://${PUBLIC_IP}:${LISTEN_PORT}
   LiveKit server IP   : ${BACKEND_IP}
   LiveKit server port : ${BACKEND_PORT}

 and for the LiveKit API key, secret and certificate printed by setup-livekit.sh.
MSG
cat <<MSG

 Change an answer later:  sudo RECONFIGURE=1 ${RERUN#sudo }
 Certificate renewal is automatic (acme.sh cron job).
MSG
[ "$TEST" != 1 ] || cat <<MSG

 TEST MODE — the running relay was not touched. Remove this test relay with:
   sudo rm -rf ${RELAY_CONF} ${STATE_DIR}
   sudo systemctl reload nginx
MSG
cat <<MSG
=====================================================================
MSG
