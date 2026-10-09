# Swock VPS Install

This directory contains the Swock account panel and a guided installer for a complete self-hosted Swock VPS. Each installation runs its own account database and tunnel server. Profiles created by that installation connect to the operator's VPS, not to the repository author's VPS.

The Android app imports a `swock://` profile URI. The panel creates an account, generates its client key, adds the public key to the tunnel server's live allowlist, and shows a profile URI for the account holder to import.

## Requirements

- A fresh Debian or Ubuntu VPS with a public IPv4 address and working `/dev/net/tun`
- Two DNS hostnames whose A records point directly to that VPS: one for the web panel and one for VPN profiles
- Root access for installation
- Inbound TCP access through both the VPS provider firewall and the operating-system firewall for ports `80`, `443`, and the direct VPN ports you select

Nginx uses SNI/TLS multiplexing on public ports `80` and `443`. It routes HTTPS for the panel hostname to the panel and WSS for the VPN hostname to the tunnel server. Plain HTTP on port `80` remains available for Let's Encrypt challenges and redirects. During setup, choose direct TCP, WebSocket, and TLS ports, then choose WSS on `80`, `443`, or both. Direct VPN listeners cannot use `22`, `80`, `443`, or internal proxy ports. TCP and WebSocket may share a direct port; the direct TLS port must differ.

## Install

Point both DNS records to the VPS, then install Git and the basic download tools and run the installer:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git
git clone https://github.com/alfredobrown890-collab/Swock.git
cd Swock
sudo bash devmanagement/deploy/install.sh
```

During installation, enter the panel domain, VPN/account domain, direct TCP/WebSocket/TLS ports, public WSS port(s), certificate email, and panel administrator credentials. Port entries are required; the installer does not offer or silently apply preset VPN listener ports. Direct port values must be in the range `1`-`65535`. WSS public ports are selected from `80` and `443`, with the `VPN_SERVER_HOST` SNI routed to the TLS tunnel listener by Nginx. Choose any non-empty, single-line panel password up to 4096 UTF-8 bytes. Password entry is hidden and confirmed, then base64-encoded in the root-only `/etc/swock-devmanagement.env`. Point both domains' A records directly to the VPS before installing; the Let's Encrypt certificate covers both hostnames. The VPN domain is embedded in every profile URI, while the panel domain is used for the admin website. The server private key and panel environment are stored outside the Git checkout in `/etc`.

The installer adds NodeSource and installs Node.js 20, which includes `node` and `npm`. It installs the panel dependencies with:

```bash
cd /opt/swock-devmanagement
npm ci --omit=dev
```

These npm steps run automatically as part of installation. The script also installs Go if needed, builds the tunnel server, configures Nginx and TLS certificates, enables IPv4 forwarding, adds the tunnel-subnet route, and installs the nftables masquerade rule.

The installer does not change the VPS provider firewall or an existing UFW/firewalld forwarding policy. If UFW is active, allow ports `80`, `443`, your direct VPN ports, and routed traffic between `swock0` and the VPS default-route interface. For example, replace `ens3` and the direct ports with the values you selected:

```bash
read -r -p 'TCP port: ' vpn_tcp
read -r -p 'WebSocket port: ' vpn_ws
read -r -p 'TLS port: ' vpn_tls
sudo ufw allow "80,443,$vpn_tcp,$vpn_ws,$vpn_tls/tcp"
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

The server can assign addresses to up to 253 VPN accounts (`10.8.0.2`-`10.8.0.254`). Each account is routed independently and supports one active connection; a second connection using the same account replaces its existing session. Disabled accounts retain their assigned address until deleted.

To migrate from SWK1, update users to a SWK2-capable app before updating the VPS. After updating the server, use **Reissue profile** for each existing VPN account and send the new URI privately to the user. The account name, password, expiry, and assigned address are preserved while the client key is rotated. Old SWK1 profiles are rejected by default.

## Protocol Overview

Swock uses its own packet-tunnel protocol. New profiles use `SWK2`; it is not WireGuard, OpenVPN, or Shadowsocks-compatible. Legacy `SWK1` is rejected by default because it reused AEAD nonces.

The Android app creates a `VpnService` interface and sends IP packets through the selected profile. The profile URI contains the VPN hostname, port, pinned server public key, client private key, expiry, and selected transport settings. TLS SNI and optional WebSocket host/path values are included when configured.

Connection setup and data flow:

1. The client connects over TCP, optionally negotiates verified TLS, and optionally performs a WebSocket upgrade. WebSocket and TLS are independent layers; enabling both produces WSS.
2. The client sends `SWK2` and its X25519 public key. The server authorizes that key and retrieves its assigned address from the panel-managed allowlist.
3. The server replies with `SWK2`, its 32-byte public key, the assigned IPv4 address, and a fresh random 32-byte session salt. The app verifies the server key and expected account address.
4. Both sides calculate an X25519 shared secret, bind the public keys and session salt into a transcript hash, then derive distinct client-to-server and server-to-client keys with direction-specific labels.
5. Before registering the connection, the client and server exchange encrypted key-confirmation proofs using nonce 0, demonstrating possession of the matching directional keys. Tunnel packet counters then begin at 1 in both directions.
6. Each IP packet is encrypted with ChaCha20-Poly1305 and sent as a 4-byte big-endian frame length followed by the ciphertext. Each direction has its own counter and key; the fresh salt changes the keys on reconnect.
7. The VPS injects received packets into `swock0` and routes return packets to the active client assigned the destination IPv4 address.

Legacy `SWK1` used one packet key and both directions started counters at zero, repeating AEAD nonces. Updated servers reject SWK1 unless the explicit insecure `--allow-legacy-swk1` migration flag is enabled; the installer does not enable it. SWK2 separates directional keys and salts every connection, but still lacks forward secrecy and automatic rekeying and has not been independently audited.

The TLS/WebSocket transport ports installed by this guide are:

| Transport | Port | Protection |
| --- | ---: | --- |
| TCP | Entered during setup | SWK2 packet protection |
| WebSocket | Entered during setup | WebSocket plus SWK2 packet protection |
| TLS | Entered during setup | Verified TLS plus SWK2 packet protection |
| WebSocket over TLS (recommended) | Public `80` and/or `443` | Nginx routes TLS by SNI to the VPN server; verified TLS, WebSocket, and SWK2 packet protection |

The HTTPS account panel and WSS share port `443` through SNI routing. Port `80` carries both plain HTTP for certificate validation/redirects and TLS for WSS; Nginx distinguishes TLS ClientHello traffic from HTTP and routes it accordingly. The installer configures IPv4 forwarding and NAT only; it does not configure IPv6 internet egress.

### Capacity And Upgrade

- The server can assign addresses to up to 253 accounts (`10.8.0.2`-`10.8.0.254`); disabled accounts retain their address until deleted. A second connection for the same account replaces that account's previous session.
- Disabling or expiring an account removes its client key from authorization for subsequent handshakes. An already established tunnel is not forcibly disconnected by that change and remains active until it disconnects or reconnects.
- The app account password is not sent in the `SWK2` handshake. The generated profile URI contains the client private key and is the tunnel credential.
- To migrate from SWK1, update clients to a SWK2-capable app before updating the VPS. Then run the updater, choose **Reissue profile** for every existing VPN account, and privately send each replacement URI to its user. Reissue preserves the account username, password, expiry, and assigned tunnel address while rotating the client key. Old SWK1 profiles are rejected after the server update.

## Update And Backups

Run updates or reinstall the panel and tunnel server from the same Git checkout. The updater asks you to enter the direct listener ports and WSS public port(s) again, updates server listeners and generated profile URIs together, and preserves account data, server keys, certificates, and administrator credentials:

```bash
cd swock
git pull --ff-only
sudo bash devmanagement/deploy/update.sh
```

Back up `/var/lib/swock-devmanagement/`, `/var/lib/swock/`, `/etc/swock-devmanagement.env`, and `/etc/swock-server.private` securely. The latter three contain credentials, authorized client keys, and cryptographic key material.

Useful service checks:

```bash
sudo systemctl status swock-devmanagement swock-server nginx
curl -fsS https://<panel-domain>/api/health
```

## Uninstall

From the repository checkout, remove the Swock panel and tunnel services while keeping their data and keys for backup:

```bash
sudo bash devmanagement/deploy/uninstall.sh
```

The script requires you to type `uninstall`. To permanently remove the VPN account database, client allowlist, panel environment, and server private key, use the explicit purge option:

```bash
sudo bash devmanagement/deploy/uninstall.sh --purge-data
```

Back up `/var/lib/swock/`, `/var/lib/swock-devmanagement/`, `/etc/swock-devmanagement.env`, and `/etc/swock-server.private` before purging. Shared system packages and Let's Encrypt certificates are retained. Existing Linux SSH users are not removed by this script. The uninstaller removes Swock's forwarding configuration file but leaves the live global forwarding setting unchanged in case another service uses it.

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

The panel is available at `http://localhost:8080`. For issued profiles to import successfully, `VPN_SERVER_HOST`, a 64-character hexadecimal `VPN_SERVER_PUBLIC_KEY`, `VPN_TCP_PORT`, `VPN_WS_PORT`, and `VPN_TLS_PORT` must match the local tunnel server. Set at least one public WSS port in `VPN_WSS_PORTS` (or the legacy single `VPN_WSS_PORT`). `VPN_ALLOWED_KEYS_FILE` must point to the allowlist file consumed by the matching Swock tunnel server. Do not use placeholder values for a real install.

## API

`POST /api/vpn/login` accepts JSON `{ "username": "...", "password": "..." }` and returns the account expiry, configured VPN host, and configured TCP, WebSocket, TLS, and WebSocket-over-TLS ports. Expired or disabled accounts return `401`. The Android onboarding flow uses the generated `swock://` profile URI rather than this endpoint.
