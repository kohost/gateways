#!/bin/bash

# Exit on any error
set -e

# --- Colors --- #
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
RED="\033[0;31m"
BOLD="\033[1m"
NC="\033[0m" # No Color

echo -e "${BOLD}=== Starting Kohost Installation ===${NC}"

# Generate random password
echo -e "\n${BOLD}--- User Setup ---${NC}"
echo -e "[*] Generating random password..."
PASSWORD=$(openssl rand -base64 16)
echo -e "${GREEN}[+] Random password generated successfully${NC}"

# Change the hostname
echo -e "[*] Changing hostname to kohost-gateway..."
hostnamectl set-hostname kohost-gateway
echo "kohost-gateway" > /etc/hostname
echo -e "${GREEN}[+] Hostname changed to kohost-gateway${NC}"

# Create kohost user with sudo privileges if it doesn't exist
if ! id kohost &>/dev/null; then
    echo -e "[*] Creating kohost user..."
    useradd -m -s /bin/bash kohost
    echo "kohost:$PASSWORD" | chpasswd
    usermod -aG sudo kohost
    echo -e "${GREEN}[+] Kohost user created successfully${NC}"
else
    echo -e "${YELLOW}[-] User kohost already exists, skipping creation.${NC}"
fi

# Configure sudo without password for kohost
echo -e "[*] Configuring sudo access for kohost..."
echo "kohost ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/kohost
echo -e "${GREEN}[+] Sudo access configured${NC}"

# Setup SSH key
echo -e "[*] Setting up SSH key for kohost..."
mkdir -p /home/kohost/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFuZktdaBTxo/xOUdZgzv/YLPw8FQMUvGgDH2q9ODRIw" > /home/kohost/.ssh/authorized_keys
chmod 700 /home/kohost/.ssh
chmod 600 /home/kohost/.ssh/authorized_keys
chown -R kohost:kohost /home/kohost/.ssh
echo -e "${GREEN}[+] SSH key configured${NC}"

echo -e "[*] Configuring needrestart..."
sed -i "/^#\$nrconf{restart} = 'i';/c\\\$nrconf{restart} = 'a';" /etc/needrestart/needrestart.conf
echo -e "${GREEN}[+] Needrestart configured${NC}"

# Configure Docker daemon logging
echo -e "[*] Configuring Docker daemon logging..."
mkdir -p /etc/docker
tee /etc/docker/daemon.json > /dev/null <<'EEOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "5"
    }
}
EEOF
echo -e "${GREEN}[+] Docker logging configured${NC}"

# Determine Primary IP Address
echo -e "[*] Determining primary IP address..."
PRIMARY_IP=$(ip -4 addr show $(ip route show default | awk '{print $5}') | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")

if [ -z "$PRIMARY_IP" ]; then
    echo -e "${RED}Error: Could not determine primary IP address. Exiting.${NC}"
    exit 1
fi
echo -e "${GREEN}[+] Primary IP address determined: ${PRIMARY_IP}${NC}"
export PRIMARY_IP # Export for subshell

# Switch to kohost user for remaining operations
echo -e "\n${BOLD}--- Package Installation (as kohost user) ---${NC}"
sudo -u kohost bash << EOF
    
    # Define colors within the subshell too
    GREEN="\033[0;32m"
    YELLOW="\033[0;33m"
    BLUE="\033[0;34m"
    RED="\033[0;31m"
    BOLD="\033[1m"
    NC="\033[0m"

    DEBIAN_FRONTEND=noninteractive
    
    # Function to check if a command exists
    command_exists() {
        command -v "$@" > /dev/null 2>&1
    }
    
    # Install Docker if not present
    echo -e "[*] Checking for Docker installation..."
    if ! command_exists docker; then
        echo -e "[*] Docker not found, configuring repository..."
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        echo -e "${GREEN}[+] Docker repository added${NC}"
    else
        echo -e "${YELLOW}[-] Docker already installed, skipping repository setup.${NC}"
    fi

    # Add cloudflared repository if not present
    echo -e "[*] Checking for Cloudflared installation..."
    if ! command_exists cloudflared; then
        echo -e "[*] Cloudflared not found, configuring repository..."
        sudo mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared \$(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
        echo -e "${GREEN}[+] Cloudflared repository added${NC}"
    else
        echo -e "${YELLOW}[-] Cloudflared already installed, skipping repository setup.${NC}"
    fi

    # Update and install all packages at once
    echo -e "[*] Updating package lists (apt-get update)..."
    sudo apt-get update
    echo -e "${GREEN}[+] Package lists updated.${NC}"
    echo -e "[*] Installing required packages (apt-get install)..."
    sudo apt-get install -y ca-certificates curl gnupg docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin cloudflared build-essential make gcc perl kmod net-tools
    echo -e "${GREEN}[+] Required packages installed.${NC}"
    echo -e "[*] Upgrading system packages (apt-get upgrade)..."
    sudo apt-get upgrade -y
    echo -e "${GREEN}[+] System packages upgraded.${NC}"
    echo -e "${GREEN}[+] Package installation and upgrade complete.${NC}"

    # Add kohost to docker group
    echo -e "[*] Adding kohost user to docker group..."
    sudo usermod -aG docker kohost
    echo -e "${GREEN}[+] User added to docker group${NC}"

    # Enable docker service
    echo -e "[*] Enabling Docker service..."
    sudo systemctl enable docker
    echo -e "${GREEN}[+] Docker service enabled${NC}"
    
    echo -e "\n${BOLD}--- Docker Swarm and Network Setup ---${NC}"

    # Initialize docker swarm if not already initialized
    if ! sudo docker info | grep -q "Swarm: active"; then
        echo -e "[*] Initializing Docker Swarm (advertising on ${PRIMARY_IP})..."
        sudo docker swarm init --advertise-addr "$PRIMARY_IP"
        echo -e "${GREEN}[+] Docker Swarm initialized.${NC}"
    else
        echo -e "${YELLOW}[-] Docker Swarm already active.${NC}"
    fi

    # Create overlay network if not present
    if ! sudo docker network inspect kohost_network > /dev/null 2>&1; then
        echo -e "[*] Creating overlay network: kohost_network..."
        sudo docker network create --driver overlay kohost_network
        echo -e "${GREEN}[+] Network kohost_network created.${NC}"
    else
        echo -e "${YELLOW}[-] Network kohost_network already exists.${NC}"
    fi

    if ! sudo docker network inspect portainer_agent_network > /dev/null 2>&1; then
        echo -e "[*] Creating overlay network: portainer_agent_network..."
        sudo docker network create --driver overlay portainer_agent_network
        echo -e "${GREEN}[+] Network portainer_agent_network created.${NC}"
    else
        echo -e "${YELLOW}[-] Network portainer_agent_network already exists.${NC}"
    fi

    # Create portainer agent service if not present
    if ! sudo docker service inspect portainer_agent > /dev/null 2>&1; then
        echo -e "[*] Creating Portainer Agent service..."
        sudo docker service create \
            --name portainer_agent \
            --network portainer_agent_network \
            -p 9001:9001/tcp \
            --mode global \
            --constraint 'node.platform.os == linux' \
            --mount type=bind,src=//var/run/docker.sock,dst=/var/run/docker.sock \
            --mount type=bind,src=//var/lib/docker/volumes,dst=/var/lib/docker/volumes \
            --mount type=bind,src=//,dst=/host \
            portainer/agent:2.21.4
        echo -e "${GREEN}[+] Portainer Agent service created.${NC}"
    else
        echo -e "${YELLOW}[-] Portainer Agent service already exists.${NC}"
    fi

EOF

echo -e "\n${BOLD}=== Kohost Setup Complete ===${NC}"
echo -e "${GREEN}The password for user 'kohost' is: ${BOLD}${PASSWORD}${NC}"
echo -e "${YELLOW}Rebooting is recommended to apply all changes (e.g., group memberships).${NC}"