# Swock VPS Install

This directory contains the Swock account panel and a guided installer for a complete self-hosted Swock VPS. Each installation runs its own account database and tunnel server. Profiles created by that installation connect to the operator's VPS, not to the repository author's VPS.

The Android app imports a `swock://` profile URI. The panel creates an account, generates its client key, adds the public key to the tunnel server's live allowlist, and shows a profile URI for the account holder to import.

## Requirements

- A fresh Debian or Ubuntu VPS with a public IPv4 address and working `/dev/net/tun`
- Two DNS hostnames whose A records point directly to that VPS: one for the web panel and one for VPN profiles
- Root access for installation
- Inbound TCP access through both the VPS provider firewall and the operating-system firewall for ports `80`, `443`, `801`, `8505`, `8443`, and `9443`

Port `80` is used by Nginx and Let's Encrypt. Port `443` serves the HTTPS admin panel. VPN transports listen on `801` (WebSocket), `8505` (TCP), `8443` (TLS), and `9443` (WebSocket over TLS).

## Install

After the repository is published, clone it on the VPS and run the installer from the checkout. Replace the GitHub URL with your repository URL:

```bash
git clone https://github.com/alfredobrown890-collab/Swock.git
cd Swock
sudo bash devmanagement/deploy/install.sh
```

During installation, enter the web panel domain, a separate VPN/account domain, a TLS certificate contact email, and the panel login username/password. Choose any non-empty, single-line panel password up to 4096 UTF-8 bytes. Password entry is hidden, confirmed, base64-encoded before being written to the root-only `/etc/swock-devmanagement.env`, and is never printed by the installer. VPN account passwords have no minimum length and are limited to 4096 UTF-8 bytes. Optional Linux SSH account passwords can be any non-empty single-line value up to 255 UTF-8 bytes, as required by the system password hash format. Point both domains' A records directly to the VPS before installing; the Let's Encrypt certificate covers both hostnames. The VPN domain is embedded in every profile URI, while the panel domain is used for the admin website. The server private key and panel environment are stored outside the Git checkout in `/etc`.

The installer enables IPv4 forwarding and adds a dedicated nftables masquerade rule scoped to the tunnel subnet. It does not change the VPS provider firewall or an existing UFW/firewalld forwarding policy. If UFW is active, allow the listed inbound ports and allow routed traffic between `swock0` and the VPS default-route interface. For example, replace `ens3` with the interface shown by `ip -o -4 route show default`:

```bash
sudo ufw allow 80,443,801,8505,8443,9443/tcp
sudo ufw route allow in on swock0 out on ens3 from 10.8.0.0/24
sudo ufw route allow in on ens3 out on swock0 to 10.8.0.0/24
```

Also open these ports and routed traffic in the VPS provider's firewall/security group. Some VPS providers must enable TUN devices or IPv4 forwarding for the instance.

## Create App Accounts

1. Sign in to the web panel domain you entered during installation.
2. Create an account and set its expiry.
3. Copy the generated Swock profile URI and send it privately to that account holder.
4. Import the URI in the Swock app.

The URI contains the account's private client key. Treat it as a password: anyone who receives it can use the account until it expires or is disabled. The separate username/password shown by the panel is not what the app imports. Disabling an account removes its key from authorization for new handshakes; expiry cleanup runs every 60 seconds. An already-connected tunnel is not forcibly closed.

## Protocol Overview

Swock uses its own packet-tunnel protocol, identified by the `SWK1` handshake. It is not WireGuard, OpenVPN, or Shadowsocks-compatible; a Swock client must connect to a Swock tunnel server.

The Android app creates a `VpnService` interface and sends IP packets through the selected profile. The profile URI contains the VPN hostname, port, pinned server public key, client private key, expiry, and selected transport settings. TLS SNI and optional WebSocket host/path values are included when configured.

Connection setup and data flow:

1. The client connects over TCP, optionally negotiates verified TLS, and optionally performs a WebSocket upgrade. WebSocket and TLS are independent layers; enabling both produces WSS.
2. The client sends the `SWK1` marker and its X25519 public key. The server checks that key against the authorized-client-key file maintained by the panel.
3. The server replies with `SWK1` and its 32-byte public key. The app compares this key with the server key pinned in the imported profile.
4. Both sides calculate an X25519 shared secret and derive the session key as SHA-256 of the shared secret followed by the client and server public keys.
5. Each IP packet is encrypted with ChaCha20-Poly1305 and sent as a 4-byte big-endian frame length followed by the ciphertext. Each direction uses its own increasing packet counter as the AEAD nonce.
6. The VPS injects received packets into the `swock0` TUN interface and forwards return packets through the same encrypted connection.

The TLS/WebSocket transport ports installed by this guide are:

| Transport | Port | Protection |
| --- | ---: | --- |
| TCP | `8505` | Swock packet encryption |
| WebSocket | `801` | WebSocket plus Swock packet encryption |
| TLS | `8443` | Verified TLS plus Swock packet encryption |
| WebSocket over TLS (recommended) | `9443` | Verified TLS, WebSocket, and Swock packet encryption |

The HTTPS account panel uses port `443`; it is separate from the tunnel listeners. Port `80` is used for HTTP certificate validation and redirect handling. The installer configures IPv4 forwarding and NAT only; it does not configure IPv6 internet egress.

### Current Limits

- The tunnel server supports one active client connection at a time. A new client connection replaces the existing one, so this deployment is not suitable for concurrent users yet.
- Disabling or expiring an account removes its client key from authorization for subsequent handshakes. An already established tunnel is not forcibly disconnected by that change and remains active until it disconnects or reconnects.
- The app account password is not sent in the `SWK1` handshake. The generated profile URI contains the client private key and is the credential used by the tunnel protocol.

## Update And Backups

Run updates from the same Git checkout. The updater replaces application code and binaries but preserves the database, server key, TLS certificate, and environment settings:

```bash
cd swock
git pull --ff-only
sudo bash devmanagement/deploy/update.sh
```

Back up `/var/lib/swock-devmanagement/`, `/var/lib/swock/`, `/etc/swock-devmanagement.env`, and `/etc/swock-server.private` securely. The latter three contain credentials, authorized client keys, and cryptographic key material.

Useful service checks:

```bash
sudo systemctl status swock-devmanagement swock-server swock-ssh-manager nginx
curl -fsS https://<panel-domain>/api/health
```

## Local Development

`.env.example` is only a starting point for running the panel manually during development. VPS users do not copy or edit it: `deploy/install.sh` prompts for each installation's panel/VPN domains and admin credentials, then writes the production environment file. The installer's tunnel listener ports and generated panel settings are kept matched.

```bash
cd devmanagement
cp .env.example .env
# Set unique SESSION_SECRET and ADMIN_PASSWORD values for local use only.
# Set VPN_SERVER_HOST and VPN_SERVER_PUBLIC_KEY to match a running Swock server.
npm ci
npm start
```

The panel is available at `http://localhost:8080`. The example transport ports are TCP `8505`, WebSocket `801`, TLS `8443`, and WSS `9443`; they must match the listener flags of the local tunnel server. For issued profiles to import successfully, `VPN_SERVER_HOST` and a 64-character hexadecimal `VPN_SERVER_PUBLIC_KEY` are required. `VPN_ALLOWED_KEYS_FILE` must point to the allowlist file consumed by the matching Swock tunnel server. Do not use placeholder values for a real install.

## API

`POST /api/vpn/login` accepts JSON `{ "username": "...", "password": "..." }` and returns the account expiry, configured VPN host, and configured TCP, WebSocket, TLS, and WebSocket-over-TLS ports. Expired or disabled accounts return `401`. The Android onboarding flow uses the generated `swock://` profile URI rather than this endpoint.
