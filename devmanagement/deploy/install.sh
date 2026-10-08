#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run this installer with sudo.' >&2; exit 1; }
[[ $# -eq 0 ]] || { echo 'Run without arguments; the installer will prompt for setup values.' >&2; exit 2; }

valid_domain() {
  local domain=$1 label
  local -a labels
  [[ $domain =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && ! $domain =~ ^[0-9.]+$ ]] || return 1
  (( ${#domain} <= 253 )) || return 1
  IFS='.' read -r -a labels <<< "$domain"
  ((${#labels[@]} >= 2)) || return 1
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

read -r -p 'Web panel domain (for example, panel.example.com): ' panel_domain
read -r -p 'VPN/account domain (for example, vpn.example.com): ' vpn_domain
read -r -p 'Contact email for the TLS certificate: ' admin_email
read -r -p 'Web panel login username: ' admin_username
read -r -s -p 'Choose a web panel password (any non-empty single-line password, up to 4096 UTF-8 bytes): ' admin_password
printf '\n'
read -r -s -p 'Confirm web panel login password: ' password_confirmation
printf '\n'

panel_domain=${panel_domain,,}
vpn_domain=${vpn_domain,,}
if ! valid_domain "$panel_domain"; then
  echo 'Panel domain must be a valid fully-qualified DNS hostname, not a URL or IP address.' >&2
  exit 2
fi
if ! valid_domain "$vpn_domain"; then
  echo 'VPN/account domain must be a valid fully-qualified DNS hostname, not a URL or IP address.' >&2
  exit 2
fi
if [[ $panel_domain == "$vpn_domain" ]]; then
  echo 'Panel and VPN/account domains must differ: port 443 is shared by SNI between the panel and the TLS tunnel.' >&2
  exit 2
fi
[[ $admin_email == *@*.* ]] || { echo 'Provide a valid contact email for the TLS certificate.' >&2; exit 2; }
[[ $admin_username =~ ^[a-zA-Z0-9._-]{3,32}$ ]] || { echo 'Admin username must be 3-32 letters, numbers, dots, underscores, or hyphens.' >&2; exit 2; }
admin_password_bytes=$(printf '%s' "$admin_password" | wc -c)
if [[ -z $admin_password || $admin_password_bytes -gt 4096 ]]; then
  echo 'Password must not be empty and must be no more than 4096 UTF-8 bytes.' >&2
  exit 2
fi
[[ $admin_password == "$password_confirmation" ]] || { echo 'Passwords do not match.' >&2; exit 2; }
unset password_confirmation
admin_password_b64=$(printf '%s' "$admin_password" | base64 | tr -d '\n')

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[[ -f "$repo_root/server/go.mod" && -f "$repo_root/devmanagement/package-lock.json" ]] || {
  echo 'Run this script from a complete Swock checkout; server/ and devmanagement/ are both required.' >&2
  exit 1
}
[[ -f "$repo_root/server/deploy/swock-ssh-manager.js" && -f "$repo_root/server/deploy/swock-ssh-account" && -f "$repo_root/server/deploy/swock-ssh-manager.service" ]] || {
  echo 'The checkout is missing the SSH account manager deployment files.' >&2
  exit 1
}

env_file=/etc/swock-devmanagement.env
server_key=/etc/swock-server.private
nginx_site=/etc/nginx/sites-available/swock-devmanagement
if [[ -e $env_file || -e $server_key || -e $nginx_site ]]; then
  echo 'A Swock installation already exists. Use deploy/update.sh to update it; do not reinstall over its secrets or database.' >&2
  exit 1
fi
if [[ -e /var/lib/swock/allowed-client-keys || -e /etc/systemd/system/swock-server.service || -e /etc/systemd/system/swock-devmanagement.service || -e /etc/systemd/system/swock-ssh-manager.service ]]; then
  echo 'Existing Swock data or service files were found. Refusing to overwrite them.' >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]] || ! . /etc/os-release || [[ ${ID:-} != debian && ${ID:-} != ubuntu ]]; then
  echo 'This installer supports Debian and Ubuntu.' >&2
  exit 1
fi
command -v apt-get >/dev/null || { echo 'apt-get is required.' >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg jq nginx certbot python3-certbot-nginx libnginx-mod-stream nftables iproute2 build-essential python3 openssl

install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
chmod 0644 /etc/apt/keyrings/nodesource.gpg
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main\n' "$(dpkg --print-architecture)" \
  > /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install -y nodejs
# Distro nodejs packages (e.g. Ubuntu 26.04) ship without npm; install it separately.
command -v npm >/dev/null || apt-get install -y npm

node_major=$(node -p 'Number(process.versions.node.split(".")[0])')
(( node_major >= 18 )) || { echo 'Node.js 18 or newer is required.' >&2; exit 1; }

go_bin=$(command -v go || true)
go_minor=0
if [[ -n $go_bin ]]; then
  go_version=$($go_bin version | sed -n 's/.* go1\.\([0-9][0-9]*\).*/\1/p')
  go_minor=${go_version:-0}
fi
if (( go_minor < 22 )); then
  case "$(dpkg --print-architecture)" in
    amd64) go_arch=amd64 ;;
    arm64) go_arch=arm64 ;;
    *) echo 'Go server builds are supported on amd64 and arm64 VPS hosts.' >&2; exit 1 ;;
  esac
  read -r go_archive go_sha256 < <(
    curl -fsSL 'https://go.dev/dl/?mode=json' \
      | jq -r --arg arch "$go_arch" '[.[] | select(.stable == true) | .files[] | select(.os == "linux" and .arch == $arch and .kind == "archive")][0] | [.filename, .sha256] | @tsv'
  )
  [[ -n $go_archive && $go_sha256 =~ ^[a-f0-9]{64}$ ]] || { echo 'Could not find the official Go archive for this VPS architecture.' >&2; exit 1; }
  go_version=${go_archive#go}
  go_version=${go_version%%.linux-*}
  go_dir="/opt/swock/toolchains/go${go_version}"
  archive_path="/tmp/${go_archive}.$$"
  install -d -m 0755 "$go_dir"
  curl -fsSL "https://go.dev/dl/${go_archive}" -o "$archive_path"
  printf '%s  %s\n' "$go_sha256" "$archive_path" | sha256sum --check --status || {
    rm -f "$archive_path"
    echo 'The downloaded Go archive failed its SHA-256 check.' >&2
    exit 1
  }
  tar -xzf "$archive_path" -C "$go_dir" --strip-components=1
  rm -f "$archive_path"
  ln -sfn "$go_dir/bin/go" /usr/local/bin/go
  go_bin="$go_dir/bin/go"
fi

egress_interface=$(ip -o -4 route show default | awk 'NR == 1 { print $5 }')
[[ $egress_interface =~ ^[a-zA-Z0-9_.:-]+$ ]] || { echo 'Could not determine the VPS IPv4 default-route interface.' >&2; exit 1; }

groupadd --system swock 2>/dev/null || true
if ! id swock-panel >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/swock-devmanagement --shell /usr/sbin/nologin --gid swock swock-panel
else
  usermod --gid swock swock-panel
fi

install -d -o root -g root -m 0755 /opt/swock-devmanagement
tar --exclude=node_modules --exclude=data --exclude=.env -C "$repo_root/devmanagement" -cf - . \
  | tar -C /opt/swock-devmanagement -xf -
cd /opt/swock-devmanagement
npm ci --omit=dev
chown -R root:root /opt/swock-devmanagement
chmod -R go-w /opt/swock-devmanagement

install -d -m 0755 /usr/local/bin
install -d -m 0755 /usr/local/lib /usr/local/sbin
cd "$repo_root/server"
"$go_bin" build -trimpath -ldflags='-s -w' -o /usr/local/bin/swock-server ./cmd/swock-server
"$go_bin" build -trimpath -ldflags='-s -w' -o /usr/local/bin/swock-keygen ./cmd/swock-keygen
chmod 0755 /usr/local/bin/swock-server /usr/local/bin/swock-keygen
install -m 0644 deploy/swock-ssh-manager.js /usr/local/lib/swock-ssh-manager.js
install -m 0755 deploy/swock-ssh-account /usr/local/sbin/swock-ssh-account
install -m 0644 deploy/swock-ssh-manager.service /etc/systemd/system/swock-ssh-manager.service

install -d -o swock-panel -g swock -m 0750 /var/lib/swock-devmanagement
install -d -o root -g swock -m 2770 /var/lib/swock
install -o root -g swock -m 0640 /dev/null /var/lib/swock/allowed-client-keys
keypair=$(/usr/local/bin/swock-keygen)
private_key=$(printf '%s\n' "$keypair" | sed -n 's/^private=//p')
server_public_key=$(printf '%s\n' "$keypair" | sed -n 's/^public=//p')
[[ $private_key =~ ^[a-f0-9]{64}$ && $server_public_key =~ ^[a-f0-9]{64}$ ]] || { echo 'Server key generation failed.' >&2; exit 1; }
printf '%s\n' "$private_key" > "$server_key"
chmod 0600 "$server_key"
unset keypair private_key

session_secret=$(openssl rand -hex 48)
cat > "$env_file" <<ENV
PORT=8080
NODE_ENV=production
SESSION_SECRET=$session_secret
ADMIN_USERNAME=$admin_username
ADMIN_PASSWORD_B64=$admin_password_b64
DB_FILE=/var/lib/swock-devmanagement/devmanagement.sqlite
VPN_SERVER_NAME=Swock VPN
VPN_SERVER_HOST=$vpn_domain
VPN_SERVER_PUBLIC_KEY=$server_public_key
VPN_ALLOWED_KEYS_FILE=/var/lib/swock/allowed-client-keys
VPN_TCP_PORT=8505
VPN_WS_PORT=80
VPN_TLS_PORT=443
VPN_WSS_PORT=9443
VPN_TLS_SNI=$vpn_domain
VPN_WS_PATH=/
VPN_WS_HOST=
ENV
chown root:root "$env_file"
chmod 0600 "$env_file"
unset session_secret server_public_key admin_password admin_password_b64

cat > /usr/local/sbin/swock-network-setup <<NETWORK
#!/usr/bin/env bash
set -euo pipefail
egress_interface='$egress_interface'
nft delete table ip swock 2>/dev/null || true
nft add table ip swock
nft add chain ip swock postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
nft add rule ip swock postrouting ip saddr 10.8.0.0/24 oifname "\$egress_interface" masquerade
NETWORK
chmod 0755 /usr/local/sbin/swock-network-setup
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-swock.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null

cat > "$nginx_site" <<NGINX
# Port 80: WebSocket tunnel traffic goes to the Swock server; other requests (and ACME) are handled here.
server {
    listen 80;
    listen [::]:80;
    server_name $panel_domain $vpn_domain;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        if (\$http_upgrade != websocket) {
            return 301 https://\$host\$request_uri;
        }
        proxy_pass http://127.0.0.1:801;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_buffering off;
    }
}
NGINX
ln -s "$nginx_site" /etc/nginx/sites-enabled/swock-devmanagement
nginx -t
systemctl enable --now nginx
systemctl reload nginx
certificate_domains=(-d "$panel_domain" -d "$vpn_domain")
install -d -m 0755 /var/www/html
certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos --email "$admin_email" "${certificate_domains[@]}"

# HTTPS panel moves to loopback; the public port 443 is shared by SNI (stream) between panel and TLS tunnel.
cat >> "$nginx_site" <<NGINX

server {
    listen 127.0.0.1:8444 ssl;
    server_name $panel_domain;
    ssl_certificate /etc/letsencrypt/live/$panel_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$panel_domain/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGINX
cat > /etc/nginx/modules-enabled/99-swock-stream.conf <<STREAM
stream {
    map \$ssl_preread_server_name \$swock_tls_backend {
        $vpn_domain 127.0.0.1:8443;
        default 127.0.0.1:8444;
    }
    server {
        listen 443;
        listen [::]:443;
        ssl_preread on;
        proxy_pass \$swock_tls_backend;
    }
}
STREAM
nginx -t
systemctl reload nginx

cat > /etc/systemd/system/swock-devmanagement.service <<'UNIT'
[Unit]
Description=Swock account management panel
After=network.target

[Service]
Type=simple
User=swock-panel
Group=swock
WorkingDirectory=/opt/swock-devmanagement
EnvironmentFile=/etc/swock-devmanagement.env
ExecStart=/usr/bin/node /opt/swock-devmanagement/server.js
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/swock-devmanagement /var/lib/swock

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/swock-server.service <<'UNIT'
[Unit]
Description=Swock encrypted VPN tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c '/usr/sbin/ip tuntap add dev swock0 mode tun 2>/dev/null || true'
ExecStartPre=/usr/sbin/ip addr replace 10.8.0.1/24 dev swock0
ExecStartPre=/usr/sbin/ip link set dev swock0 up
ExecStartPre=/usr/sbin/ip route replace 10.8.0.0/24 dev swock0
ExecStartPre=/usr/local/sbin/swock-network-setup
ExecStart=/usr/local/bin/swock-server -private-key-file /etc/swock-server.private -allowed-client-key-file /var/lib/swock/allowed-client-keys -listen :8505,127.0.0.1:801 -tls-listen 127.0.0.1:8443,:9443 -tls-cert /etc/letsencrypt/live/DOMAIN/fullchain.pem -tls-key /etc/letsencrypt/live/DOMAIN/privkey.pem -tun-name swock0
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/dev/net/tun /var/lib/swock

[Install]
WantedBy=multi-user.target
UNIT
sed -i "s/DOMAIN/$panel_domain/g" /etc/systemd/system/swock-server.service

install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/50-swock-server <<'HOOK'
#!/usr/bin/env bash
systemctl try-restart swock-server.service
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/50-swock-server

systemctl daemon-reload
systemctl enable --now swock-ssh-manager.service swock-server.service swock-devmanagement.service

echo 'Swock self-hosted installation is complete.'
echo "Panel URL: https://$panel_domain"
echo "Panel login username: $admin_username"
echo 'Use the password you entered during setup.'
echo "VPN/account domain: $vpn_domain"
echo 'Required inbound TCP ports: 80 (WebSocket), 443 (TLS and panel), 8505 (TCP), 9443 (WSS)'
echo 'Also allow routed traffic from 10.8.0.0/24 through the VPS firewall/provider firewall.'