#!/usr/bin/env bash
set -euo pipefail

echo "Updating packages..."
sudo apt-get update

echo "Installing dependencies..."
sudo apt-get install -y unzip curl gnupg software-properties-common

echo "Installing Terraform..."
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | \
  sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
sudo apt-get update && sudo apt-get install -y terraform

echo "Installing AWS CLI v2..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
sudo ./aws/install --update
echo "Cleaning up AWS CLI installation files..."
rm -rf aws awscliv2.zip

echo "Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash

echo
echo "========================================="
echo "Installation completed successfully!"
echo "========================================="
echo
echo "AWS CLI Version:"
aws --version
echo
echo "Helm Version:"
helm version
echo
echo "Terraform Version:"
terraform version
