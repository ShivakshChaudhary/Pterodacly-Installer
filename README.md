# Pterodactyl Panel Auto-Installer

![Pterodactyl Logo](https://pterodactyl.io/logos/new/pterodactyl_logo.png)

A streamlined bash script to automatically install Pterodactyl Panel with minimal user input.

## Features

- 🚀 **One-command installation** - Only requires FQDN input
- ⚡ **Fast deployment** - Complete in under 5 minutes
- 🔒 **Secure defaults** - Auto-generated strong passwords
- 🔧 **Pre-configured** with optimal settings:
  - SSL ready (with self-signed certs)
  - Redis caching
  - Proper file permissions
  - Cron job setup
- 🛡️ **No unnecessary services**:
  - UFW firewall disabled
  - No Let's Encrypt prompts
- 📦 **Supports**:
  - Ubuntu 20.04/22.04
  - Debian 10/11
  - Rocky Linux 8/9
  - AlmaLinux 8/9

## Quick Start

```bash
bash <(curl -s https://raw.githubusercontent.com/ShivakshChaudhary/Pterodacly-Installer/refs/heads/main/pterodacly-installer.sh)
