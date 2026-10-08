# Swock VPS Installer

Install a self-hosted Swock VPN server and account web panel on a Debian or Ubuntu VPS. Each installation manages its own users and connects them to that VPS.

The installer is interactive: it asks for separate web-panel and VPN domains, a certificate contact email, a panel username, and a panel password. Password entry is hidden and confirmed before setup.

## Why Swock

- **Per-account access and routing:** each VPN account receives its own X25519 client key and tunnel IP. The server allowlist authorizes that identity, and TUN return packets are routed to that account.
- **Verified TLS option:** TLS/WSS transports validate the certificate and hostname and protect traffic between the app and VPS from network observers.
- **Transport choice:** use TCP, WebSocket, TLS, or WebSocket over TLS (WSS) while keeping the same Swock packet protocol. WSS is the configured recommendation; available transports still depend on the VPS and network allowing their ports.
- **Self-hosted control:** the operator owns the VPS, panel, account database, and server keys; no centrally hosted Swock account service is required.
- **Device-level VPN integration:** the Android client uses `VpnService` and a TUN interface to send routed IP packets, rather than configuring only an application-level proxy.

Swock uses a custom protocol and is not wire-compatible with WireGuard, OpenVPN, or Shadowsocks. The protocol has not been independently audited as part of this project. The VPS can assign addresses to up to 253 accounts (`10.8.0.2`-`10.8.0.254`); each account can have one active connection, and a new connection for that account replaces its previous session. Account revocation blocks new handshakes but does not forcibly terminate an already-connected session.

## Security Model

The current implementation provides these controls:

- **Server identity pinning:** each profile carries the expected server X25519 public key. The app rejects a handshake if the server presents a different key; TLS transports additionally validate the certificate and SNI.
- **Per-account authorization:** each account has its own X25519 client keypair. The server checks the client's public key against the panel-managed allowlist before accepting a tunnel.
- **Account lifecycle controls:** disable and expiry remove keys from authorization for new handshakes. Expiry cleanup runs every 60 seconds.
- **Verified transport option:** TLS and WSS encrypt and authenticate the connection to the configured certificate hostname. TCP and plain WebSocket do not have this outer TLS protection.

**Important:** new profiles use `SWK2`, which derives different packet keys for the two traffic directions and mixes a fresh random salt into each connection. Legacy `SWK1` profiles reused AEAD nonces and are rejected by default. The custom protocol has not been independently audited. Static long-term X25519 keys mean SWK2 does not yet provide forward secrecy or automatic rekeying.

These controls do not hide connection metadata such as the VPS address, timing, or traffic volume. A profile URI contains the client's private key, so anyone who obtains the URI can use that account. Disable the account and distribute a replacement profile if its URI is exposed. The static-key handshake also lacks forward secrecy and automatic rekeying: compromise of a long-term key could expose recorded sessions made with that key.

## Protocol Comparison

| Property | Swock (current implementation) | WireGuard | OpenVPN |
| --- | --- | --- | --- |
| Protocol and maturity | Custom `SWK2`; not independently audited; rejects unsafe SWK1 by default | Purpose-built, widely deployed protocol with mature implementations | Mature, widely deployed TLS-based VPN protocol |
| Tunnel data protection | ChaCha20-Poly1305 with per-direction keys and per-session salt; no forward secrecy yet | Noise-based handshake and ChaCha20-Poly1305 transport | TLS control channel plus a configurable data-channel cipher; security depends on configuration |
| Peer identity | Per-account X25519 public key allowlist; server key pinned in profile | Static public-key peer identities | Commonly certificates, with optional username/password authentication |
| Forward secrecy and rekeying | No ephemeral handshake keys or session rekeying currently | Ephemeral handshake keys and automatic key rotation | Available through TLS cipher/session configuration; depends on configuration |
| Transports | TCP, WebSocket, TLS, WSS | UDP | UDP or TCP |
| Current server capacity | Up to 253 accounts; one connection per account | Designed to support multiple peers | Supports multiple clients |


## Requirements

- A fresh Debian or Ubuntu VPS with a public IPv4 address and `/dev/net/tun`
- An `amd64` or `arm64` VPS
- Two DNS A records pointing directly to the VPS: one for the panel and one for the VPN service
- Root access
- Inbound TCP access for ports `80`, `443`, `8505`, and `9443`

Create both DNS records and allow the listed ports in the VPS provider firewall before installing. Port `80` carries certificate validation and the WebSocket tunnel, `443` is shared by SNI between the HTTPS panel and the TLS tunnel (the two domains must differ), and `8505` (TCP) and `9443` (WSS) serve the remaining transports.

## Full Installation

Clone this repository on the VPS and run the installer:

```bash
git clone https://github.com/alfredobrown890-collab/Swock.git
cd Swock
sudo bash devmanagement/deploy/install.sh
```

Enter the panel domain, VPN domain, certificate email, and panel login credentials when prompted. Choose any non-empty, single-line panel password up to 4096 UTF-8 bytes; the installer hides and confirms it. VPN account passwords also have no minimum length and may be up to 4096 UTF-8 bytes. The optional Linux SSH accounts accept single-line passwords up to 255 UTF-8 bytes.

The installer installs Node.js, Go, Nginx, Certbot, and required system packages; builds the panel dependencies and Go tunnel server; installs the panel's restricted SSH account manager; obtains a Let's Encrypt certificate for both domains; generates the server key; configures the TUN device, IPv4 forwarding/NAT, and systemd services; and stores panel configuration securely in `/etc/swock-devmanagement.env`.

The VPN hostname is embedded in accounts' `swock://` profile URIs. Sign in to the web panel using the URL and credentials chosen during installation, create an account with an expiry, and send its profile URI privately to the user to import into the Swock app. The URI contains a private client key and must be treated as a credential.

The installer does not modify an existing Swock installation. It does not configure the provider firewall, an existing UFW/firewalld routing policy, or IPv6 egress. Follow the [full VPS guide](devmanagement/README.md) for firewall routing, updates, backups, protocol details, and current service limits.

## Upgrade Existing Installations

SWK2 requires a matching updated Android app and VPS server. Update users to a SWK2-capable app first, then update the VPS from its existing checkout:

```bash
git pull --ff-only
sudo bash devmanagement/deploy/update.sh
```

The updated server rejects legacy SWK1 by default. In the panel, choose **Reissue profile** for each active VPN account and privately send the replacement URI to that user. The account username, password, expiry, and assigned address remain unchanged; the client key rotates. Do not enable `--allow-legacy-swk1` during normal operation because legacy SWK1 repeats AEAD nonces.

## Update

From the same checkout on the VPS:

```bash
git pull --ff-only
sudo bash devmanagement/deploy/update.sh
```
