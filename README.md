# Swock VPS Installer

Install a self-hosted Swock VPN server and account web panel on a Debian or Ubuntu VPS. Each installation manages its own users and connects them to that VPS.

The installer is interactive: it asks for separate web-panel and VPN domains, a certificate contact email, a panel username, and a panel password. Password entry is hidden and confirmed before setup.

## Requirements

- A fresh Debian or Ubuntu VPS with a public IPv4 address and `/dev/net/tun`
- An `amd64` or `arm64` VPS
- Two DNS A records pointing directly to the VPS: one for the panel and one for the VPN service
- Root access
- Inbound TCP access for ports `80`, `443`, `801`, `8505`, `8443`, and `9443`

Create both DNS records and allow the listed ports in the VPS provider firewall before installing. Port `80` is used for certificate validation, `443` serves the HTTPS panel, and the remaining ports serve VPN transports.

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

## Update

From the same checkout on the VPS:

```bash
git pull --ff-only
sudo bash devmanagement/deploy/update.sh
```
