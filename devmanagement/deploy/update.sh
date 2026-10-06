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

systemctl restart swock-server.service swock-devmanagement.service
echo 'Swock panel and tunnel server updated. Existing accounts, signing keys, and environment settings were preserved.'