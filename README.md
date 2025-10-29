# Ubuntu Server Setup Script

Automated setup script for Ubuntu servers that:

- Creates sudo user 'kohost'
- Installs Docker and Cloudflared
- Configures Docker Swarm and Portainer agent
- Sets up SSH key access

## Usage

```bash
curl -s https://raw.githubusercontent.com/kohost/gateways/refs/heads/master/gateway-setup.sh | sudo bash
```

## Prerequisites

- Ubuntu server (tested on 20.04, 22.04, 24.04)
- Root/sudo access
- Internet connectivity
- Cloudflare tunnel token

## Security

- Random password generated for kohost user
- Password-less sudo access configured
- SSH key authentication enabled
- Docker configured with secure defaults

## Components Installed

- Docker CE with Swarm mode
- Cloudflared tunnel client
- Portainer agent
- Docker overlay network (kohost_network)
