# AdGuard Home Container Script for MikroTik RouterOS

Automated deployment and upgrade script for running [AdGuard Home](https://adguard.com/en/adguard-home/overview.html) as a container on MikroTik routers.

## Features

- **First-time setup**: Automatically enables container feature, configures Docker registry, creates mount points, and provisions veth interface
- **Upgrade mode**: Safely stops and removes existing container before pulling the latest image
- **Status monitoring**: Real-time terminal output showing deployment progress
- **Error handling**: Graceful timeout handling with informative error messages
- **Version check**: Validates RouterOS version compatibility before execution

## Requirements

- MikroTik RouterOS **7.21 or higher**
- Router with container support (ARM, ARM64, or x86)
- USB storage or disk mounted (default: `/usb1`)
- Network connectivity to Docker Hub

## Quick Start

### Option 1: Import directly

```routeros
/tool fetch url="https://raw.githubusercontent.com/YOUR_USERNAME/mikrotik-adguardhome/main/adguardhome_script.rsc"
/import adguardhome_script.rsc
```

### Option 2: Create as a scheduled script

```routeros
/system script add name=adguardhome-deploy source=[/file get adguardhome_script.rsc contents]
/system script run adguardhome-deploy
```

## Configuration

Edit the variables at the top of the script to match your setup:

```routeros
:local cName "adguardhome"           # Container name
:local cImage "adguard/adguardhome:latest"  # Docker image
:local cInterface "agh"              # veth interface name
:local cRootDir "/usb1/agh"          # Container root directory
:local cTmpDir "/usb1/tmp"           # Temp directory for image pulls
:local cMountName "agh_conf"         # Mount name for config persistence
:local cMountSrc "/usb1/conf/agh"    # Host path for config
:local cMountDst "/opt/adguardhome/conf"  # Container path for config
```

## Post-Deployment Steps (First-time only)

After the first successful deployment:

1. **Configure IP address** on the veth interface:
   ```routeros
   /ip address add address=172.17.0.1/24 interface=agh
   ```

2. **Set up NAT** (if needed):
   ```routeros
   /ip firewall nat add chain=srcnat src-address=172.17.0.0/24 action=masquerade
   ```

3. **Access AdGuard Home** web UI at `http://172.17.0.2:3000` (or your container IP)

4. **Complete the setup wizard** in the web interface

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                    Script Execution Flow                     │
├─────────────────────────────────────────────────────────────┤
│  1. Check RouterOS version (≥7.21)                          │
│  2. Enable container feature (if disabled) → reboot         │
│  3. Configure Docker registry                                │
│  4. Create mount point (if missing)                         │
│  5. Create veth interface (if missing)                      │
│  6. Stop & remove existing container (if upgrading)         │
│  7. Pull latest image & create container                    │
│  8. Wait for extraction to complete                         │
│  9. Start container                                         │
└─────────────────────────────────────────────────────────────┘
```

## Upgrading AdGuard Home

Simply run the script again - it will automatically:
- Stop the running container
- Remove the old container
- Pull the latest image
- Start the new container

Your configuration is preserved in the mounted volume.

## Troubleshooting

### Container won't stop
The script waits up to 60 seconds for the container to stop. If it times out, try manually stopping it:
```routeros
/container stop [find name=adguardhome]
```

### Image extraction takes too long
The script waits up to 5 minutes for image extraction. On slower hardware or USB storage, this may take longer. You can increase `extractTimeout` in the script.

### Container feature not available
Ensure your RouterOS license and hardware support containers. CHR requires a paid license for container support.

## License

MIT License - Feel free to use and modify.

## Author

**Maxim Priezjev** - February 2026

## Contributing

Issues and pull requests are welcome!

