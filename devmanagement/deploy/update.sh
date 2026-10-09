#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run the updater with sudo.' >&2; exit 1; }

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[[ -f "$repo_root/server/go.mod" && -f "$repo_root/devmanagement/package-lock.json" ]] || {
  echo 'Run this script from a complete Swock checkout.' >&2
  exit 1
}
[[ -f /etc/swock-devmanagement.env && -f /etc/swock-server.private ]] || {
  echo 'No installed Swock server found; use install.sh for a fresh installation.' >&2
  exit 1
}
env_file=/etc/swock-devmanagement.env
server_unit=/etc/systemd/system/swock-server.service
[[ -f $server_unit ]] || { echo 'The installed swock-server systemd unit was not found.' >&2; exit 1; }
grep -q -- '-listen ' "$server_unit" && grep -q -- '-tls-listen ' "$server_unit" || {
  echo 'The installed tunnel service has no recognized listener arguments; refusing to change its configuration.' >&2
  exit 1
}
nginx_site=/etc/nginx/sites-available/swock-devmanagement
certificate_name=$(sed -nE 's#^[[:space:]]*ssl_certificate[[:space:]]+/etc/letsencrypt/live/([^/]+)/fullchain\\.pem;.*#\\1#p' "$nginx_site" | head -n 1)
[[ -n $certificate_name && -r "/etc/letsencrypt/live/$certificate_name/fullchain.pem" && -r "/etc/letsencrypt/live/$certificate_name/privkey.pem" ]] || {
  echo 'Could not identify the active TLS certificate for the VPN listener.' >&2
  exit 1
}

ask_port() {
  local name=$1 label=$2 value
  read -r -p "$label (1-65535): " value
  [[ $value =~ ^[0-9]{1,5}$ ]] && (( 10#$value >= 1 && 10#$value <= 65535 )) || {
    echo "$label must be a whole number from 1 to 65535." >&2
    exit 2
  }
  value=$((10#$value))
  printf -v "$name" '%s' "$value"
}

ask_port vpn_tcp_port 'VPN TCP port'
ask_port vpn_ws_port 'VPN WebSocket port'
ask_port vpn_tls_port 'VPN TLS port'
read -r -p 'VPN WebSocket + TLS public port(s) through Nginx (80, 443, or 80,443): ' vpn_wss_ports_input
for port in "$vpn_tcp_port" "$vpn_ws_port" "$vpn_tls_port"; do
  case $port in
    22|80|443|3000|18081|18443|19443)
      echo "Port $port is reserved for SSH, Nginx multiplexing, or an internal service; choose another VPN listener port." >&2
      exit 2
      ;;
  esac
done
IFS=',' read -r -a vpn_wss_ports <<< "$vpn_wss_ports_input"
if ((${#vpn_wss_ports[@]} == 0)); then
  echo 'Choose at least one supported WebSocket+TLS public port: 80 and/or 443.' >&2
  exit 2
fi
for index in "${!vpn_wss_ports[@]}"; do
  vpn_wss_ports[$index]=${vpn_wss_ports[$index]//[[:space:]]/}
  case ${vpn_wss_ports[$index]} in
    80|443) ;;
    *) echo "WebSocket+TLS public ports are multiplexed through Nginx; choose 80 and/or 443 (got '${vpn_wss_ports[$index]}')." >&2; exit 2 ;;
  esac
done
vpn_wss_ports_csv=$(IFS=,; printf '%s' "${vpn_wss_ports[*]}")
if [[ $vpn_wss_ports_csv == 80,443 ]]; then
  vpn_wss_ports=(443 80)
  vpn_wss_ports_csv=443,80
fi
if [[ $vpn_tcp_port == "$vpn_tls_port" || $vpn_ws_port == "$vpn_tls_port" ]]; then
  echo 'Plain TCP/WebSocket ports may share a value, but the direct TLS listener must use a different port.' >&2
  exit 2
fi
[[ -f /etc/nginx/streams-enabled/swock.conf ]] || {
  echo 'Nginx TLS multiplexing is not installed; use deploy/install.sh to migrate this VPS.' >&2
  exit 1
}

export PATH="/usr/local/bin:/usr/local/go/bin:/usr/bin:/bin"
go_bin=$(command -v go || true)
[[ -n $go_bin ]] || { echo 'Go 1.22 or newer is required to update the tunnel server.' >&2; exit 1; }
go_minor=$($go_bin version | sed -n 's/.* go1\.\([0-9][0-9]*\).*/\1/p')
[[ ${go_minor:-0} -ge 22 ]] || { echo 'Go 1.22 or newer is required to update the tunnel server.' >&2; exit 1; }

install -d -o root -g root -m 0755 /opt/swock-devmanagement
tar --exclude=node_modules --exclude=data --exclude=.env -C "$repo_root/devmanagement" -cf - . \
  | tar -C /opt/swock-devmanagement -xf -
cd /opt/swock-devmanagement
npm ci --omit=dev
chown -R root:root /opt/swock-devmanagement
chmod -R go-w /opt/swock-devmanagement

build_directory=$(mktemp -d)
trap 'rm -rf "$build_directory"' EXIT
cd "$repo_root/server"
"$go_bin" build -trimpath -ldflags='-s -w' -o "$build_directory/swock-server" ./cmd/swock-server
"$go_bin" build -trimpath -ldflags='-s -w' -o "$build_directory/swock-keygen" ./cmd/swock-keygen
install -m 0755 "$build_directory/swock-server" /usr/local/bin/swock-server
install -m 0755 "$build_directory/swock-keygen" /usr/local/bin/swock-keygen
install -d -m 0755 /usr/local/sbin

# Require ports explicitly and keep profile URIs in step with the server.
set_env_value() {
  local key=$1 value=$2 temporary
  temporary=$(mktemp)
  if grep -q "^${key}=" "$env_file"; then
    sed "s|^${key}=.*|${key}=${value}|" "$env_file" > "$temporary"
  else
    cat "$env_file" > "$temporary"
    printf '%s=%s\n' "$key" "$value" >> "$temporary"
  fi
  cat "$temporary" > "$env_file"
  rm -f "$temporary"
}
set_env_value VPN_TCP_PORT "$vpn_tcp_port"
set_env_value VPN_WS_PORT "$vpn_ws_port"
set_env_value VPN_TLS_PORT "$vpn_tls_port"
set_env_value VPN_WSS_PORTS "$vpn_wss_ports_csv"
set_env_value VPN_WSS_PORT "${vpn_wss_ports[0]}"
set_env_value PORT 3000
set_env_value PANEL_BIND_PORT 3000
chmod 0600 "$env_file"

sed -i -E \
  -e "s|-listen [^ ]+|-listen :${vpn_tcp_port},:${vpn_ws_port}|" \
  -e "s|-tls-listen [^ ]+|-tls-listen :${vpn_tls_port},127.0.0.1:19443|" \
  -e "s|-tls-cert [^ ]+|-tls-cert /etc/letsencrypt/live/${certificate_name}/fullchain.pem|" \
  -e "s|-tls-key [^ ]+|-tls-key /etc/letsencrypt/live/${certificate_name}/privkey.pem|" \
  "$server_unit"
grep -q -- "-listen :${vpn_tcp_port},:${vpn_ws_port}" "$server_unit" || {
  echo 'Could not update VPN listener ports in the systemd unit.' >&2
  exit 1
}
grep -q -- "-tls-listen :${vpn_tls_port},127.0.0.1:19443" "$server_unit" || {
  echo 'Could not update VPN TLS listener ports in the systemd unit.' >&2
  exit 1
}
if ! grep -Fq 'ExecStartPre=/usr/sbin/ip route replace 10.8.0.0/24 dev swock0' "$server_unit"; then
  sed -i '/ExecStartPre=\/usr\/sbin\/ip link set dev swock0 up/a ExecStartPre=/usr/sbin/ip route replace 10.8.0.0/24 dev swock0' "$server_unit"
fi

# Remove the optional panel-managed SSH account feature. Existing Linux SSH
# accounts are left untouched.
systemctl disable --now swock-ssh-manager.service 2>/dev/null || true
rm -f /etc/systemd/system/swock-ssh-manager.service \
  /usr/local/lib/swock-ssh-manager.js /usr/local/sbin/swock-ssh-account

systemctl daemon-reload
nginx -t
systemctl reload nginx
systemctl restart swock-devmanagement.service
systemctl restart swock-server.service
echo 'Swock panel and tunnel server updated. Existing VPN accounts, signing keys, TLS certificates, and panel credentials were preserved.'
echo 'Existing Linux SSH accounts were left untouched.'
echo "Configured inbound VPN TCP ports: 80, 443, $vpn_tcp_port, $vpn_ws_port, $vpn_tls_port"
echo "WebSocket+TLS profiles are available on public port(s): $vpn_wss_ports_csv"
echo 'Allow these ports in the VPS provider firewall and host firewall.'
