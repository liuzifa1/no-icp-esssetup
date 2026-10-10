#!/usr/bin/env bash
# setup-livekit.sh — step 1 of 3: the LiveKit media server (voice / video calls).
#
# Run this FIRST, whichever layout you chose (see README.md). It creates the
# LiveKit API key + secret and prints them at the end; setup-main.sh asks for
# them later.
#
# The server has no domain. nginx serves LiveKit on port 7443 with two
# certificates:
#   - a self-signed one, for the relay and the main server (3-server layout).
#     They ask for the plain TLS name "livekit-internal", never a domain.
#   - a free Let's Encrypt certificate for the public IP address, for call
#     clients connecting directly to  wss://<public IP>:7443  (2-server layout).
#     It needs TCP 80 reachable from the internet. Where the provider blocks
#     80/443 it cannot be issued — the script says so and carries on, and you
#     use the 3-server layout.
#
# Safe to run again: answers are remembered in /etc/element-rtc/livekit.env.
#
#   usage:  sudo bash setup-livekit.sh
#
# Unattended run (no prompts):
#   sudo EMAIL=you@example.com RTC_HOST=mrtc.example.com bash setup-livekit.sh
# Env:  NODE_IP   EMAIL (optional)   RTC_HOST (optional)
#       LIVEKIT_KEY + LIVEKIT_SECRET (only to reuse an existing pair)
#       IP_CERT=0 (3-server layout: do not even try the Let's Encrypt certificate)
#       SKIP_STAGING=1 (skip the test certificate)
#       TLS_PORT=7443  SIGNAL_PORT=7880  RTC_TCP_PORT=7881
#       RTC_UDP_START=50000  RTC_UDP_END=51000  TURN_PORT=3478
#       RECONFIGURE=1 (ask everything again)   UPGRADE=1 (re-download LiveKit)
#       LIVEKIT_VERSION=1.13.9   MAX_PARTICIPANTS=10
#       GITHUB_MIRROR=https://your-mirror/   (prefix for github.com downloads)
#
# TEST=1   set up a second, separate instance next to a running one: its own
#          service (livekit-server-test), files (/etc/element-rtc-test) and
#          ports (you are asked for each). The running instance is not touched.
# DEBUG=1  print every command as it runs (the output will contain secrets).
set -Eeuo pipefail
trap 'echo "FAILED at line $LINENO (see the output above)" >&2' ERR
if [ "${DEBUG:-0}" = 1 ]; then PS4='+ line ${LINENO}: '; set -x; fi
TEST="${TEST:-0}"; SUFFIX=""; [ "$TEST" != 1 ] || SUFFIX="-test"

STATE_DIR="/etc/element-rtc$SUFFIX"
STATE="$STATE_DIR/livekit.env"
TLS_DIR=/etc/element-rtc/tls      # certificates belong to the server, so a test instance shares them
UNIT="livekit-server$SUFFIX"
BIN="/usr/local/bin/livekit-server$SUFFIX"
LK_CONF="/etc/livekit/livekit$SUFFIX.yaml"
NGINX_CONF="/etc/nginx/conf.d/element-rtc$SUFFIX.conf"
ACME_CONF=/etc/nginx/conf.d/acme.conf
RERUN="sudo ${SUFFIX:+TEST=1 }bash setup-livekit.sh"
INTERNAL_NAME=livekit-internal    # TLS name the relay asks for (see README.md)
ACME=/root/.acme.sh/acme.sh
LIVEKIT_KEY="${LIVEKIT_KEY:-}"; LIVEKIT_SECRET="${LIVEKIT_SECRET:-}"
RTC_HOST="${RTC_HOST:-}"; NODE_IP="${NODE_IP:-}"; EMAIL="${EMAIL:-}"
TLS_PORT="${TLS_PORT:-}"; SIGNAL_PORT="${SIGNAL_PORT:-}"; RTC_TCP_PORT="${RTC_TCP_PORT:-}"
RTC_UDP_START="${RTC_UDP_START:-}"; RTC_UDP_END="${RTC_UDP_END:-}"; TURN_PORT="${TURN_PORT:-}"
MAX_PARTICIPANTS="${MAX_PARTICIPANTS:-}"
IP_CERT="${IP_CERT:-1}"; SKIP_STAGING="${SKIP_STAGING:-0}"
RECONFIGURE="${RECONFIGURE:-0}"; UPGRADE="${UPGRADE:-0}"
LIVEKIT_VERSION="${LIVEKIT_VERSION:-latest}"; GITHUB_MIRROR="${GITHUB_MIRROR:-}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
interactive() { [ -t 0 ]; }
is_ipv4()   { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
is_domain() { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }

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

will_ask() { interactive && { [ -z "${!1-}" ] || [ "$RECONFIGURE" = 1 ]; }; }

port_setting() {   # port_setting VAR "question" normal-default test-default — asked in test mode only
  if [ "$TEST" = 1 ]; then ask "$1" "$2" "$4"; else [ -n "${!1}" ] || printf -v "$1" '%s' "$3"; fi
  [[ "${!1}" =~ ^[0-9]+$ ]] || die "$1 must be a port number"
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
case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) die "unsupported CPU architecture: $(uname -m)" ;;
esac
load_state
[ "$TEST" != 1 ] || cat <<MSG

*** TEST MODE: a separate instance "$UNIT" with its own ports and files
*** ($STATE_DIR, $LK_CONF). The running LiveKit is not touched.
MSG

# ------------------------------------------------------------------ questions
will_ask RTC_HOST && cat <<'MSG'

Optional: the calls host your main server will use — normally "mrtc." plus your
Matrix domain, e.g. mrtc.example.com. LiveKit then reports to it when people
leave a call. Press Enter to skip.
MSG
ask RTC_HOST "Calls host of the main server"
[ -z "$RTC_HOST" ] || is_domain "$RTC_HOST" || die "RTC_HOST must be a hostname like mrtc.example.com"

if [ "$IP_CERT" != 0 ]; then
  will_ask EMAIL && echo && echo "Optional: an email address for Let's Encrypt certificate notices. Press Enter to skip."
  ask EMAIL "Email"
  [ -z "$EMAIL" ] || [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "EMAIL is not a valid address"
fi

log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-upgrade nginx curl openssl ca-certificates tar gzip iproute2

if [ -z "$LIVEKIT_KEY" ] || [ -z "$LIVEKIT_SECRET" ]; then
  LIVEKIT_KEY="lk$(openssl rand -hex 6)"; LIVEKIT_SECRET="$(openssl rand -hex 32)"
  echo "Created a new LiveKit API key pair (shown at the end)."
fi
[[ "$LIVEKIT_KEY" =~ ^[A-Za-z0-9_-]+$ ]] || die "LIVEKIT_KEY has unexpected characters"
[[ "$LIVEKIT_SECRET" =~ ^[A-Za-z0-9_-]{32,}$ ]] || die "LIVEKIT_SECRET must be 32+ letters/digits"

DETECTED_IP=""
for u in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me; do
  ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)
  if is_ipv4 "$ip"; then DETECTED_IP="$ip"; break; fi
done
interactive && [ -z "$NODE_IP" ] &&
  echo && echo "LiveKit tells callers to send audio/video to this server's PUBLIC IP."
ask NODE_IP "Public IP of this server" "$DETECTED_IP"
is_ipv4 "$NODE_IP" || die "could not determine the public IP; run again with NODE_IP=x.x.x.x"

[ "$TEST" != 1 ] || ! interactive ||
  { echo; echo "Test instance ports — they must differ from the running instance (Enter accepts):"; }
port_setting TLS_PORT      "WSS / TLS port (clients or the relay)" 7443 17443
port_setting SIGNAL_PORT   "LiveKit signalling port (local only)"  7880 17880
port_setting RTC_TCP_PORT  "Media TCP port"                        7881 17881
port_setting RTC_UDP_START "Media UDP range, first port"           50000 52000
port_setting RTC_UDP_END   "Media UDP range, last port"            51000 52100
port_setting TURN_PORT     "TURN UDP port"                         3478 13478
[ "$TLS_PORT" != 80 ] || die "port 80 is needed for certificate checks; pick another TLS_PORT"
[ "$RTC_UDP_START" -lt "$RTC_UDP_END" ] || die "RTC_UDP_START must be lower than RTC_UDP_END"
MAX_PARTICIPANTS="${MAX_PARTICIPANTS:-10}"
[[ "$MAX_PARTICIPANTS" =~ ^[0-9]+$ ]] || die "MAX_PARTICIPANTS must be a number (0 = unlimited)"

install -d -m 700 /etc/element-rtc "$STATE_DIR" "$TLS_DIR"
( umask 077
  printf '%s=%s\n' LIVEKIT_KEY "$LIVEKIT_KEY" LIVEKIT_SECRET "$LIVEKIT_SECRET" \
    RTC_HOST "$RTC_HOST" NODE_IP "$NODE_IP" EMAIL "$EMAIL" TLS_PORT "$TLS_PORT" \
    SIGNAL_PORT "$SIGNAL_PORT" RTC_TCP_PORT "$RTC_TCP_PORT" RTC_UDP_START "$RTC_UDP_START" \
    RTC_UDP_END "$RTC_UDP_END" TURN_PORT "$TURN_PORT" MAX_PARTICIPANTS "$MAX_PARTICIPANTS" >"$STATE" )

# ------------------------------------------------------------ sanity checks
# Never take a port from something that is already running (e.g. the live instance).
if ! systemctl is-active -q "$UNIT"; then
  if [ "$TEST" != 1 ] && pgrep -x livekit-server >/dev/null; then
    die "a livekit-server is already running outside this script's service.
       To try this script next to it, run:  sudo TEST=1 bash setup-livekit.sh
       To replace it, stop and disable it first (systemctl disable --now <its unit>)."
  fi
  for check in "t:$SIGNAL_PORT" "t:$RTC_TCP_PORT" "u:$TURN_PORT" "u:$RTC_UDP_START"; do
    busy=$(ss -H -ln"${check%%:*}"p "sport = :${check#*:}" 2>/dev/null || true)
    [ -z "$busy" ] || die "port ${check#*:} is already in use:
$busy
Choose another one:  sudo RECONFIGURE=1 ${RERUN#sudo }  (or set the port variable, see the script header)"
  done
fi
busy=$(ss -H -lntp "sport = :$TLS_PORT" 2>/dev/null | grep -v nginx || true)
[ -z "$busy" ] || die "TCP port $TLS_PORT is already used by another program:
$busy
This script puts nginx on that port — stop the other program or choose another port."
if grep -lsE "listen[[:space:]]+${TLS_PORT}([[:space:]]|;)" /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/* 2>/dev/null |
   grep -qvxF "$NGINX_CONF"; then
  die "TCP port $TLS_PORT is already used by another nginx site on this server.
       Choose another one (TLS_PORT=...), or try next to it with:  sudo TEST=1 bash setup-livekit.sh"
fi

NEW_NGINX_FILES=()
nginx_apply() {   # load the new nginx config; a broken one is never left behind for the next reload
  if ! nginx -t; then
    [ "${#NEW_NGINX_FILES[@]}" -eq 0 ] || rm -f "${NEW_NGINX_FILES[@]}"
    NEW_NGINX_FILES=()
    echo "nginx rejected the new configuration (removed again; the running nginx is unchanged)." >&2
    return 1
  fi
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  NEW_NGINX_FILES=()
}

# --------------------------------------------------------------- certificate
gh() { printf '%s%s' "$GITHUB_MIRROR" "$1"; }
IP_CRT="$TLS_DIR/fullchain.pem"; IP_KEY="$TLS_DIR/privkey.pem"

ip_cert_valid() {
  [ -s "$IP_CRT" ] && [ -s "$IP_KEY" ] &&
    openssl x509 -checkend $((3*86400)) -noout -in "$IP_CRT" >/dev/null 2>&1 &&
    openssl x509 -checkip "$NODE_IP" -noout -in "$IP_CRT" 2>/dev/null | grep -q 'does match'
}

get_ip_cert() {   # Let's Encrypt certificate for the IP address; returns 1 (with a reason) if impossible
  local tmp help pf
  apt-get install -y -qq --no-upgrade cron git || return 1
  systemctl enable --now cron >/dev/null 2>&1 || true
  if command -v ufw >/dev/null && [[ "$(ufw status)" == *"Status: active"* ]]; then ufw allow 80/tcp; fi
  mkdir -p /var/www/acme
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
    nginx_apply || { echo "Port 80 on this server is already taken by another nginx site." >&2; return 1; }
  fi
  if [ ! -x "$ACME" ]; then
    tmp=$(mktemp -d)
    timeout 90 git clone -q --depth 1 "$(gh https://github.com/acmesh-official/acme.sh.git)" "$tmp/acme.sh" ||
      { rm -rf "$tmp/acme.sh"   # GitHub unreachable (common in mainland China): use the official Gitee mirror
        git clone -q --depth 1 https://gitee.com/neilpang/acme.sh.git "$tmp/acme.sh" || return 1; }
    (cd "$tmp/acme.sh" && ./acme.sh --install ${EMAIL:+-m "$EMAIL"}) || return 1
    rm -rf "$tmp"
  fi
  "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$ACME" --install-cronjob >/dev/null 2>&1 || true    # acme.sh's built-in daily auto-renewal
  # IP certificates only exist in Let's Encrypt's "shortlived" profile (valid ~6 days).
  help=$("$ACME" --help 2>&1 || true)
  if   grep -q -- '--certificate-profile' <<<"$help"; then pf=--certificate-profile
  elif grep -q -- '--cert-profile'        <<<"$help"; then pf=--cert-profile
  else echo "this acme.sh is too old for IP certificates; update it:  $ACME --upgrade" >&2; return 1; fi
  if [ "$SKIP_STAGING" != 1 ]; then
    echo "Test run against Let's Encrypt staging (does not count against rate limits)"
    "$ACME" --issue -d "$NODE_IP" --webroot /var/www/acme "$pf" shortlived --keylength ec-256 \
      --server letsencrypt_test --force || return 1
  fi
  "$ACME" --issue -d "$NODE_IP" --webroot /var/www/acme "$pf" shortlived --keylength ec-256 \
    --server letsencrypt --force || return 1
  # The paths and reload command are remembered by acme.sh and reused on every auto-renewal.
  "$ACME" --install-cert -d "$NODE_IP" --ecc --key-file "$IP_KEY" --fullchain-file "$IP_CRT" \
    --reloadcmd "systemctl reload nginx" || return 1
  chmod 600 "$IP_KEY"
}

[ "$TEST" = 1 ] || rm -f /etc/nginx/sites-enabled/default

# Self-signed, for the server-to-server hops (relay, main server).
SELF_CRT="$TLS_DIR/internal.crt"; SELF_KEY="$TLS_DIR/internal.key"
if [ ! -s "$SELF_CRT" ] || [ ! -s "$SELF_KEY" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=$INTERNAL_NAME" -addext "subjectAltName=DNS:$INTERNAL_NAME" \
    -keyout "$SELF_KEY" -out "$SELF_CRT" 2>/dev/null
  chmod 600 "$SELF_KEY"
fi

# Publicly trusted, for clients connecting by IP (2-server layout).
TRUSTED=0
if ip_cert_valid; then
  log "A valid certificate for $NODE_IP is already installed — keeping it"
  TRUSTED=1
elif [ "$IP_CERT" != 0 ]; then
  log "Getting a Let's Encrypt certificate for $NODE_IP"
  if get_ip_cert && ip_cert_valid; then
    TRUSTED=1
  else
    warn "could not get a Let's Encrypt certificate for $NODE_IP.
         3-server layout: nothing to do — the relay and the main server use the
           self-signed certificate.
         2-server layout: clients need it. Open TCP 80 from anywhere in this server's
           firewall / cloud security group and run this script again. If your provider
           blocks port 80, use the 3-server layout instead."
  fi
fi

# ------------------------------------------------------------------- LiveKit
if [ ! -x "$BIN" ] || [ "$UPGRADE" = 1 ]; then
  if [ "$LIVEKIT_VERSION" = latest ]; then
    LIVEKIT_VERSION=$(curl -fsSLI --max-time 30 -o /dev/null -w '%{url_effective}' \
      https://github.com/livekit/livekit/releases/latest | sed 's|.*/v||' || true)
    [[ "$LIVEKIT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
      die "could not look up the latest LiveKit version; run again with LIVEKIT_VERSION=1.13.9 (for example)"
  fi
  LIVEKIT_VERSION=${LIVEKIT_VERSION#v}
  log "Installing LiveKit $LIVEKIT_VERSION"
  tmp=$(mktemp -d)
  url="https://github.com/livekit/livekit/releases/download/v${LIVEKIT_VERSION}/livekit_${LIVEKIT_VERSION}_linux_${ARCH}.tar.gz"
  curl -fL --retry 3 --connect-timeout 20 -o "$tmp/livekit.tar.gz" "$(gh "$url")" ||
    die "download failed: $url
       If GitHub is slow or blocked here, run again with GITHUB_MIRROR=https://<a-github-proxy>/"
  tar xzf "$tmp/livekit.tar.gz" -C "$tmp" livekit-server
  install -m 755 "$tmp/livekit-server" "$BIN"
  rm -rf "$tmp"
fi

log "Configuring LiveKit"
id livekit >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin livekit
install -d -m 755 /etc/livekit
{
  cat <<EOF
# Generated by setup-livekit.sh — edits are overwritten on the next run.
port: ${SIGNAL_PORT}
bind_addresses:
  - "127.0.0.1"          # signalling is only reachable through nginx (:$TLS_PORT)

rtc:
  tcp_port: ${RTC_TCP_PORT}
  port_range_start: ${RTC_UDP_START}
  port_range_end: ${RTC_UDP_END}
  node_ip: ${NODE_IP}
  use_external_ip: false

keys:
  "${LIVEKIT_KEY}": "${LIVEKIT_SECRET}"

logging:
  level: $([ "${DEBUG:-0}" = 1 ] && echo debug || echo info)

room:
  auto_create: false     # rooms are created by the login service on the main server
  empty_timeout: 300
  departure_timeout: 20
  max_participants: ${MAX_PARTICIPANTS}
  enabled_codecs:
    - mime: video/vp8
    - mime: audio/opus

turn:
  enabled: true
  udp_port: ${TURN_PORT}
EOF
  [ -z "$RTC_HOST" ] || cat <<EOF

# Tell the login service when people leave, so call membership stays accurate.
webhook:
  api_key: "${LIVEKIT_KEY}"
  urls:
    - https://${RTC_HOST}/sfu_webhook
EOF
} >"$LK_CONF"
chown root:livekit "$LK_CONF"
chmod 640 "$LK_CONF"

cat >"/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=LiveKit media server${SUFFIX:+ (test instance)}
After=network-online.target
Wants=network-online.target

[Service]
User=livekit
Group=livekit
ExecStart=${BIN} --config ${LK_CONF}
Restart=always
RestartSec=3
LimitNOFILE=500000

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null
systemctl restart "$UNIT"

# --------------------------------------------------------------------- nginx
log "Configuring nginx (TLS on :$TLS_PORT)"
[ -f "$NGINX_CONF" ] || NEW_NGINX_FILES+=("$NGINX_CONF")
{
  cat <<EOF
# Generated by setup-livekit.sh — edits are overwritten on the next run.
EOF
  # $1 = listen options + server_name, $2 = certificate, $3 = key
  server_block() {
    cat <<EOF

server {
    listen ${TLS_PORT} ssl$1;
    ssl_certificate     $2;
    ssl_certificate_key $3;
    ssl_protocols TLSv1.2 TLSv1.3;

    # LiveKit signalling (WebSocket)
    location / {
        proxy_pass http://127.0.0.1:${SIGNAL_PORT};
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
  }
  if [ "$TRUSTED" = 1 ]; then
    echo; echo "# Call clients connect by IP address (no name) and get the Let's Encrypt IP certificate."
    server_block " default_server;
    server_name _" "$IP_CRT" "$IP_KEY"
    echo; echo "# The relay and the main server ask for \"$INTERNAL_NAME\" and get the self-signed certificate."
    server_block ";
    server_name $INTERNAL_NAME" "$SELF_CRT" "$SELF_KEY"
  else
    echo; echo "# Only the self-signed certificate is available: relay and main server only."
    server_block ";
    server_name $INTERNAL_NAME _" "$SELF_CRT" "$SELF_KEY"
  fi
} >"$NGINX_CONF"
nginx_apply || die "see the nginx message above — usually the port is already defined in another nginx file."

if command -v ufw >/dev/null && [[ "$(ufw status)" == *"Status: active"* ]]; then
  log "Opening ports in ufw"
  ufw allow "${TLS_PORT}/tcp"; ufw allow "${RTC_TCP_PORT}/tcp"
  ufw allow "${TURN_PORT}/udp"; ufw allow "${RTC_UDP_START}:${RTC_UDP_END}/udp"
fi

# -------------------------------------------------------------------- verify
log "Checking the services"
sleep 3
body=$(curl -sk --max-time 10 "https://127.0.0.1:${TLS_PORT}/" || true)
ok=1
if [ "$body" = OK ]; then
  echo "ok   LiveKit answers through nginx"
else
  ok=0
  warn "LiveKit did not answer correctly (got: '${body:-nothing}'). Look at:  journalctl -u $UNIT -e"
fi

# ------------------------------------------------------------------- summary
SELF_CERT_LINE=$(base64 <"$SELF_CRT" | tr -d '\n')   # public part only; not a secret
cat <<MSG

=====================================================================
 LiveKit server $([ "$ok" = 1 ] && echo "is up" || echo "was configured, but a check FAILED (see above)")${SUFFIX:+  [TEST instance]}
 Certificates: self-signed for relay + main server: yes
               Let's Encrypt for clients by IP:    $([ "$TRUSTED" = 1 ] && echo "yes (renews automatically)" || echo "NO — 3-server layout only")

 Firewall / cloud security group — allow INBOUND on this server:
   UDP ${RTC_UDP_START}-${RTC_UDP_END}   from anywhere   (audio / video)
   UDP ${TURN_PORT}          from anywhere   (TURN)
   TCP ${RTC_TCP_PORT}          from anywhere   (audio / video fallback)
   TCP ${TLS_PORT}          2 servers: from anywhere / 3 servers: from the relay and the main server
$([ "$TRUSTED" != 1 ] || echo "   TCP 80            from anywhere   (certificate renewal every few days — keep it open)")

 Write these down — the next scripts ask for them:

   LiveKit API key     : ${LIVEKIT_KEY}
   LiveKit API secret  : ${LIVEKIT_SECRET}
   LiveKit server IP   : ${NODE_IP}
   LiveKit server port : ${TLS_PORT}

 NEXT
   2-server layout:  on the MAIN server run   sudo ${SUFFIX:+TEST=1 }bash setup-main.sh
                     LiveKit address there:   wss://${NODE_IP}:${TLS_PORT}$([ "$TRUSTED" = 1 ] || echo "
                     (NOT possible yet: this layout needs the Let's Encrypt certificate)")
                     LiveKit server IP there: leave empty
   3-server layout:  on the RELAY server run  sudo ${SUFFIX:+TEST=1 }bash setup-relay.sh
                     then setup-main.sh on the main server
                     (LiveKit address = the relay, LiveKit server IP = ${NODE_IP}).
                     Both also ask for the LiveKit certificate below, so they
                     can be sure they are talking to this server.
                     Copy the whole line, it is long:

${SELF_CERT_LINE}

 Show this again:  ${RERUN}   (add RECONFIGURE=1 to be asked everything again)
 Logs:             journalctl -u ${UNIT} -f
MSG
[ "$TEST" != 1 ] || cat <<MSG

 TEST MODE — the running instance was not touched. Remove this test instance with:
   sudo systemctl disable --now ${UNIT}
   sudo rm -rf /etc/systemd/system/${UNIT}.service ${STATE_DIR} ${LK_CONF} ${NGINX_CONF} ${BIN}
   sudo systemctl daemon-reload && sudo systemctl reload nginx
MSG
echo "====================================================================="
