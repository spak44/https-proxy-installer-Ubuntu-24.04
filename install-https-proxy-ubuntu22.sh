#!/usr/bin/env bash
# v1.1 (2026-10-21). Ubuntu 22.04; isolated Squid + stunnel + Certbot. No Docker changes.
set -Eeuo pipefail
umask 077
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l
IP=${1:-}
BASE=/etc/browser-proxy
CB=/opt/browser-proxy-certbot/bin/certbot
STATE=/var/lib/browser-proxy
die() { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }
trap 'printf "\nERROR at line %s. Installation stopped; installed files are retained. Do not send passwords.\n" "$LINENO" >&2' ERR
[[ $EUID == 0 ]] || die 'Run as root: sudo bash install-https-proxy.sh'
[[ -t 0 ]] || die 'Run in an interactive SSH terminal, not via curl | bash.'
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 22.04 ]] || die 'This installer supports Ubuntu 22.04 only.'
command -v systemctl >/dev/null || die 'systemd is required.'
command -v python3 >/dev/null || die 'python3 is required.'
exec 9>/run/browser-proxy-install.lock
flock -n 9 || die 'Another installation is running.'
[[ ! -f $BASE/complete ]] || die 'Already installed. Credentials: /root/browser-proxy-access.txt'
if [[ -z $IP ]]; then
  read -r -p 'Public IPv4 of THIS server (from your VPS panel): ' IP
fi
python3 - "$IP" <<'PYIP' || die 'Enter a public IPv4 address, without a port or URL.'
import ipaddress,sys
try:
 address=ipaddress.IPv4Address(sys.argv[1])
 assert address.is_global and not address.is_multicast
except (ValueError,AssertionError):
 sys.exit(1)
PYIP
if [[ ! -f $BASE/installer-owned ]]; then
  [[ ! -e $BASE && ! -e /opt/browser-proxy-certbot && ! -e $STATE ]] || die 'Existing browser-proxy files need inspection.'
  for pkg in squid squid-openssl stunnel4; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      die "Existing $pkg installation found. Nothing changed; send this message for review."
    fi
  done
  for unit in browser-proxy-squid browser-proxy-tls browser-proxy-renew; do
    [[ ! -e /etc/systemd/system/$unit.service ]] || die "Existing unit: $unit"
  done
fi

# Include Docker-published ports even when docker-proxy is disabled.
DOCKER_PORTS=''
if command -v docker >/dev/null; then
  IDS=$(docker ps -q) || die 'Cannot inspect Docker.'
  if [[ -n $IDS ]]; then
    DOCKER_PORTS=$(docker inspect $IDS | python3 -c '
import json,sys
for c in json.load(sys.stdin):
 for k, entries in (c.get("NetworkSettings",{}).get("Ports") or {}).items():
  if k.endswith("/tcp"):
   for e in entries or []: print(e["HostPort"])
')
  fi
fi
free_port() {
  ! grep -qx "$1" <<< "$DOCKER_PORTS" || return 1
  [[ -z $(ss -H -ltn "sport = :$1") ]] || return 1
  python3 - "$1" <<'PY'
import socket,sys
s=socket.socket()
try: s.bind(('0.0.0.0',int(sys.argv[1])))
except OSError: sys.exit(1)
finally: s.close()
PY
}
free_port 80 || die 'TCP 80 is occupied. No services were stopped. Send this message for review.'
PORT=''
for p in 443 8443 9443; do
  if free_port "$p"; then PORT=$p; break; fi
done
[[ -n $PORT ]] || die 'TCP 443, 8443 and 9443 are occupied.'
INNER=''
for p in 33128 33129 33130; do
  if free_port "$p"; then INNER=$p; break; fi
done
[[ -n $INNER ]] || die 'No free internal proxy port.'
printf '\nHTTPS proxy: %s:%s; internal loopback port: %s\n' "$IP" "$PORT" "$INNER"
printf 'TCP 80 must remain reachable for certificate renewal.\n'
printf 'If your provider has a firewall, allow inbound TCP 80 and %s there.\n' "$PORT"
read -r -p 'Email for the certificate account: ' EMAIL
[[ $EMAIL =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Invalid email.'
printf 'Certificate issuance requires accepting Let\047s Encrypt terms: https://letsencrypt.org/repository/\n'
read -r -p 'Type YES to accept the terms and install: ' ACCEPT
[[ ${ACCEPT^^} == YES ]] || die 'Cancelled.'
install -d -m 755 "$BASE"
touch "$BASE/installer-owned"
install -d -m 700 "$STATE" "$STATE/staging" "$STATE/live"

printf '\n[1/6] Installing packages (no full system upgrade)...\n'
# Prevent package defaults from starting a second/public HTTP proxy.
systemctl mask squid.service stunnel4.service
apt-get update
apt-get install -y --no-install-recommends squid stunnel4 apache2-utils python3-venv ca-certificates openssl
python3 -m venv /opt/browser-proxy-certbot
/opt/browser-proxy-certbot/bin/python -m pip install --upgrade pip
/opt/browser-proxy-certbot/bin/python -m pip install 'certbot>=5.4,<6'
"$CB" --version
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp comment 'browser-proxy ACME renewal'
  ufw allow "$PORT/tcp" comment 'browser-proxy TLS'
fi

printf '\n[2/6] Testing certificate issuance (staging)...\n'
COMMON=(certonly --standalone --preferred-challenges http --http-01-address 0.0.0.0
  --preferred-profile shortlived --ip-address "$IP" --cert-name browser-proxy
  --non-interactive --agree-tos --email "$EMAIL")
"$CB" "${COMMON[@]}" --staging --config-dir "$STATE/staging/config" \
  --work-dir "$STATE/staging/work" --logs-dir "$STATE/staging/logs"
printf '\n[3/6] Issuing trusted certificate...\n'
"$CB" "${COMMON[@]}" --config-dir "$STATE/live/config" \
  --work-dir "$STATE/live/work" --logs-dir "$STATE/live/logs"
CERT="$STATE/live/config/live/browser-proxy"

printf '\n[4/6] Creating authenticated proxy...\n'
if [[ ! -f $BASE/credentials.json ]]; then
  python3 - "$BASE/credentials.json" <<'PY'
import json,secrets,sys
with open(sys.argv[1],'x') as f:
 json.dump({'username':'firefox','password':secrets.token_urlsafe(24)},f)
PY
fi
python3 - "$BASE/credentials.json" <<'PY' | htpasswd -i -B -c "$BASE/passwd" firefox
import json,sys
print(json.load(open(sys.argv[1]))['password'])
PY
chown root:proxy "$BASE/passwd"
chmod 640 "$BASE/passwd"
HELPER=/usr/lib/squid/basic_ncsa_auth
[[ -x $HELPER ]] || die 'Squid password helper not found.'
cat > "$BASE/squid.conf" <<EOF
http_port 127.0.0.1:$INNER
visible_hostname browser-proxy
auth_param basic program $HELPER $BASE/passwd
auth_param basic realm Private HTTPS proxy
auth_param basic credentialsttl 1 minute
acl logged_in proxy_auth REQUIRED
acl safe_ports port 80 443
acl tls_ports port 443
acl CONNECT method CONNECT
acl private_dst dst 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4
acl private_dst dst ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
acl own_server dst $IP/32
http_access deny !safe_ports
http_access deny CONNECT !tls_ports
http_access deny !logged_in
http_access deny private_dst
http_access deny own_server
http_access allow logged_in
http_access deny all
cache deny all
access_log none
cache_log /var/log/browser-proxy/cache.log
cache_store_log none
pid_filename none
forwarded_for delete
via on
pinger_enable off
shutdown_lifetime 2 seconds
EOF
chmod 644 "$BASE/squid.conf"
install -d -o proxy -g proxy -m 750 /var/log/browser-proxy
cat > "$BASE/stunnel.conf" <<EOF
foreground = yes
pid =
setuid = stunnel4
setgid = stunnel4
debug = notice
[https-proxy]
accept = 0.0.0.0:$PORT
connect = 127.0.0.1:$INNER
cert = $CERT/fullchain.pem
key = $CERT/privkey.pem
sslVersionMin = TLSv1.2
EOF
cat > /etc/systemd/system/browser-proxy-squid.service <<EOF
[Unit]
Description=Private browser proxy (loopback Squid)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=proxy
Group=proxy
ExecStart=/usr/sbin/squid -N -f $BASE/squid.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/browser-proxy-tls.service <<EOF
[Unit]
Description=TLS endpoint for private browser proxy
After=network-online.target browser-proxy-squid.service
Wants=network-online.target browser-proxy-squid.service
[Service]
Type=simple
ExecStart=/usr/bin/stunnel4 $BASE/stunnel.conf
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
cat > "$BASE/deploy-certificate" <<'EOF'
#!/bin/sh
set -eu
systemctl restart browser-proxy-tls.service
systemctl is-active --quiet browser-proxy-tls.service
EOF
chmod 700 "$BASE/deploy-certificate"
cat > /etc/systemd/system/browser-proxy-renew.service <<EOF
[Unit]
Description=Renew browser proxy IP certificate
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$CB renew --quiet --config-dir $STATE/live/config --work-dir $STATE/live/work --logs-dir $STATE/live/logs --deploy-hook $BASE/deploy-certificate
EOF
cat > /etc/systemd/system/browser-proxy-renew.timer <<'EOF'
[Unit]
Description=Check short-lived proxy certificate every six hours
[Timer]
OnCalendar=*-*-* 00,06,12,18:00:00
RandomizedDelaySec=15m
Persistent=true
[Install]
WantedBy=timers.target
EOF
runuser -u proxy -- /usr/sbin/squid -k parse -f "$BASE/squid.conf"
systemctl daemon-reload
systemctl enable --now browser-proxy-squid.service browser-proxy-tls.service browser-proxy-renew.timer

printf '\n[5/6] Checking TLS, password enforcement, private-address blocking and CONNECT...\n'
python3 - "$IP" "$PORT" "$BASE/credentials.json" <<'PY'
import base64,json,socket,ssl,sys,time
ip,port,path=sys.argv[1:]; port=int(port)
c=json.load(open(path)); token=base64.b64encode((c['username']+':'+c['password']).encode()).decode()
ctx=ssl.create_default_context()
def request(target,auth=None,method='GET',timeout=25):
 with socket.create_connection(('127.0.0.1',port),timeout=timeout) as raw:
  with ctx.wrap_socket(raw,server_hostname=ip) as s:
   h=f'{method} {target} HTTP/1.1\r\nHost: {target if method=="CONNECT" else "example.com"}\r\nConnection: close\r\n'
   if auth is not None: h+=f'Proxy-Authorization: Basic {auth}\r\n'
   s.sendall((h+'\r\n').encode())
   data=b''
   while b'\r\n' not in data:
    part=s.recv(4096)
    if not part: raise RuntimeError('Empty proxy response')
    data+=part
   return int(data.split(b' ',2)[1])
# systemd Type=simple does not imply Squid is already listening.
# stunnel can accept TLS before its backend is ready, producing an empty
# response, EOF or reset. Retry those startup failures and transient statuses.
last_error='No response'
for attempt in range(60):
 try:
  code=request('http://example.com/',timeout=2)
  if code==407:
   break
  last_error=f'Expected 407 during startup, got {code}'
 except (OSError,RuntimeError,ValueError) as exc:
  last_error=f'{type(exc).__name__}: {exc}'
 if attempt==59:
  raise RuntimeError('Proxy did not become ready: '+last_error+
   '. Check: journalctl -u browser-proxy-squid -u browser-proxy-tls -n 60 --no-pager')
 time.sleep(1)
assert code==407, f'Unauthenticated request: expected 407, got {code}'
assert request('http://example.com/',base64.b64encode(b'firefox:wrong-password').decode())==407, 'Wrong password accepted'
assert request('http://127.0.0.1/',token)==403, 'Loopback access was not blocked'
assert request('example.com:443',token,'CONNECT')==200, 'HTTPS CONNECT failed'
print('PASS: trusted TLS certificate, auth required, wrong password rejected, loopback blocked, HTTPS CONNECT works.')
PY
printf '\n[6/6] Checking automated renewal...\n'
"$CB" renew --dry-run --no-random-sleep-on-renew --config-dir "$STATE/live/config" --work-dir "$STATE/live/work" \
  --logs-dir "$STATE/live/logs" --deploy-hook "$BASE/deploy-certificate" --run-deploy-hooks
systemctl is-active --quiet browser-proxy-squid.service browser-proxy-tls.service browser-proxy-renew.timer
cat > /root/browser-proxy.pac <<EOF
function FindProxyForURL(url, host) {
  return "HTTPS $IP:$PORT";
}
EOF
chmod 644 /root/browser-proxy.pac
python3 - "$IP" "$PORT" "$BASE/credentials.json" <<'PY'
import json,sys
ip,port,path=sys.argv[1:]; c=json.load(open(path))
with open('/root/browser-proxy-access.txt','w') as f:
 f.write(f'HTTPS proxy: {ip}:{port}\nUsername: {c["username"]}\nPassword: {c["password"]}\nPAC: /root/browser-proxy.pac\n')
PY
touch "$BASE/complete"
printf '\nSUCCESS. HTTPS proxy: %s:%s\n' "$IP" "$PORT"
printf 'Credentials (PRIVATE): /root/browser-proxy-access.txt\n'
printf 'View with: cat /root/browser-proxy-access.txt\n'
printf 'Firefox PAC: /root/browser-proxy.pac (copy to your computer).\n'
printf 'Do not share the password file or its screenshot.\n'
printf 'Checks passed locally. External reachability must still be checked from Firefox.\n'
