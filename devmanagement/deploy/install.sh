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
read -r -s -p 'Web panel login password (16-128 safe characters): ' admin_password
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
[[ $admin_email == *@*.* ]] || { echo 'Provide a valid contact email for the TLS certificate.' >&2; exit 2; }
[[ $admin_username =~ ^[a-zA-Z0-9._-]{3,32}$ ]] || { echo 'Admin username must be 3-32 letters, numbers, dots, underscores, or hyphens.' >&2; exit 2; }
[[ ${#admin_password} -ge 16 && ${#admin_password} -le 128 && $admin_password =~ ^[a-zA-Z0-9._@%+=:-]+$ ]] || {
  echo 'Password must be 16-128 characters using letters, numbers, or these symbols: . _ @ % + = : -' >&2
  exit 2
}
[[ $admin_password == "$password_confirmation" ]] || { echo 'Passwords do not match.' >&2; exit 2; }
unset password_confirmation

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[[ -f "$repo_root/server/go.mod" && -f "$repo_root/devmanagement/package-lock.json" ]] || {
  echo 'Run this script from a complete Swock checkout; server/ and devmanagement/ are both required.' >&2
  exit 1
}

env_file=/etc/swock-devmanagement.env
server_key=/etc/swock-server.private
nginx_site=/etc/nginx/sites-available/swock-devmanagement
if [[ -e $env_file || -e $server_key || -e $nginx_site ]]; then
  echo 'A Swock installation already exists. Use deploy/update.sh to update it; do not reinstall over its secrets or database.' >&2
  exit 1
fi
if [[ -e /var/lib/swock/allowed-client-keys || -e /etc/systemd/system/swock-server.service || -e /etc/systemd/system/swock-devmanagement.service ]]; then
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
apt-get install -y ca-certificates curl gnupg jq nginx certbot python3-certbot-nginx nftables iproute2 build-essential python3 openssl

install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
chmod 0644 /etc/apt/keyrings/nodesource.gpg
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main\n' "$(dpkg --print-architecture)" \
  > /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install -y nodejs

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
cd "$repo_root/server"
"$go_bin" build -trimpath -ldflags='-s -w' -o /usr/local/bin/swock-server ./cmd/swock-server
"$go_bin" build -trimpath -ldflags='-s -w' -o /usr/local/bin/swock-keygen ./cmd/swock-keygen
chmod 0755 /usr/local/bin/swock-server /usr/local/bin/swock-keygen

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
ADMIN_PASSWORD=$admin_password
DB_FILE=/var/lib/swock-devmanagement/devmanagement.sqlite
VPN_SERVER_NAME=Swock VPN
VPN_SERVER_HOST=$vpn_domain
VPN_SERVER_PUBLIC_KEY=$server_public_key
VPN_ALLOWED_KEYS_FILE=/var/lib/swock/allowed-client-keys
VPN_TCP_PORT=8505
VPN_WS_PORT=801
VPN_TLS_PORT=8443
VPN_WSS_PORT=9443
VPN_TLS_SNI=$vpn_domain
VPN_WS_PATH=/
VPN_WS_HOST=
ENV
chown root:root "$env_file"
chmod 0600 "$env_file"
unset session_secret server_public_key admin_password

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
server {
    listen 80;
    listen [::]:80;
    server_name $panel_domain;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX
ln -s "$nginx_site" /etc/nginx/sites-enabled/swock-devmanagement
nginx -t
systemctl enable --now nginx
certificate_domains=(-d "$panel_domain")
if [[ $vpn_domain != "$panel_domain" ]]; then
  certificate_domains+=(-d "$vpn_domain")
fi
certbot --nginx --non-interactive --agree-tos --email "$admin_email" "${certificate_domains[@]}" --redirect

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
ExecStartPre=/usr/local/sbin/swock-network-setup
ExecStart=/usr/local/bin/swock-server -private-key-file /etc/swock-server.private -allowed-client-key-file /var/lib/swock/allowed-client-keys -listen :8505,:801 -tls-listen :8443,:9443 -tls-cert /etc/letsencrypt/live/DOMAIN/fullchain.pem -tls-key /etc/letsencrypt/live/DOMAIN/privkey.pem -tun-name swock0
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
systemctl enable --now swock-server.service swock-devmanagement.service

echo 'Swock self-hosted installation is complete.'
echo "Panel URL: https://$panel_domain"
echo "Panel login username: $admin_username"
echo 'Use the password you entered during setup.'
echo "VPN/account domain: $vpn_domain"
echo 'Required inbound TCP ports: 80, 443, 801, 8505, 8443, 9443'
echo 'Also allow routed traffic from 10.8.0.0/24 through the VPS firewall/provider firewall.'