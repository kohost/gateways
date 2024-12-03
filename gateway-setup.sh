#!/bin/bash

# Exit on any error
set -e

echo "=== Starting Kohost Installation ==="

# Generate random password
echo "=== User Setup ==="
echo "Generating random password..."
PASSWORD=$(openssl rand -base64 16)
echo "Random password generated successfully"

# Change the hostname
echo "Changing hostname to kohost-gateway..."
hostnamectl set-hostname kohost-gateway
echo "kohost-gateway" > /etc/hostname
echo "Hostname changed to kohost-gateway"

# Create kohost user with sudo privileges
echo "Creating kohost user..."
useradd -m -s /bin/bash kohost
echo "kohost:$PASSWORD" | chpasswd
usermod -aG sudo kohost
echo "Kohost user created successfully"

# Configure sudo without password for kohost
echo "Configuring sudo access..."
echo "kohost ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/kohost
echo "Sudo access configured"

# Setup SSH key
mkdir -p /home/kohost/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFuZktdaBTxo/xOUdZgzv/YLPw8FQMUvGgDH2q9ODRIw" > /home/kohost/.ssh/authorized_keys
chmod 700 /home/kohost/.ssh
chmod 600 /home/kohost/.ssh/authorized_keys
chown -R kohost:kohost /home/kohost/.ssh

echo "Configuring needrestart..."
sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
echo "Needrestart configured"

# Switch to kohost user for remaining operations
echo "=== Package Installation ==="
sudo -u kohost bash << EOF
    
    DEBIAN_FRONTEND=noninteractive
    
    # Function to check if a command exists
    command_exists() {
        command -v "$@" > /dev/null 2>&1
    }
    
    # Install Docker if not present
    echo "Checking for Docker installation..."
    if ! command_exists docker; then
        echo "Docker not found, installing..."
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        echo "Docker repository added"
    else
        echo "Docker already installed"
    fi

    # Add cloudflared repository if not present
    echo "Checking for Cloudflared installation..."
    if ! command_exists cloudflared; then
        echo "Cloudflared not found, installing..."
        sudo mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared \$(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
        echo "Cloudflared repository added"
    else
        echo "Cloudflared already installed"
    fi

    # Update and install all packages at once
    echo "Updating package lists..."
    sudo apt-get update
    echo "Installing required packages..."
    sudo apt-get install -y ca-certificates curl gnupg docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin cloudflared
    echo "Upgrading system packages..."
    sudo apt-get upgrade -y
    echo "Package installation complete"

    # Add kohost to docker group
    echo "Adding kohost user to docker group..."
    sudo usermod -aG docker kohost
    echo "User added to docker group"

    # Enable docker service
    echo "Enabling Docker service..."
    sudo systemctl enable docker
    echo "Docker service enabled"
    
    echo "=== Installation Complete ==="

    # Initialize docker swarm
    sudo docker swarm init

    # Create overlay network
    sudo docker network create --driver overlay kohost_network
	sudo docker network create --driver overlay portainer_agent_network

    # Create portainer agent service
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

EOF
echo "Setup complete! The password for user 'kohost' is: $PASSWORD"