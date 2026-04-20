# AdGuard Home Container Script for MikroTik RouterOS

Automated deployment and upgrade script for running [AdGuard Home](https://adguard.com/en/adguard-home/overview.html) as a container on MikroTik routers.

## Features

- **First-time setup**: Automatically enables container feature, configures Docker registry, creates mount points, and provisions veth interface
- **Upgrade mode**: Uses RouterOS 7.22+ `/container repull` command for seamless updates (no manual stop/remove required)
- **Visual progress**: Clear milestone markers `[OK]`/`[FAILED]` with tree structure showing step completion
- **Status monitoring**: Real-time terminal output showing deployment progress
- **Error handling**: Graceful timeout handling with informative error messages
- **Version check**: Validates RouterOS version compatibility before execution

## Requirements

- MikroTik RouterOS **7.22 or higher** (required for `/container repull` feature)
- Router with container support (ARM, ARM64, x86, or TILE)
- USB storage or disk mounted (default: `/usb1`)
- Network connectivity to Docker Hub

## Quick Start

### Option 1: Import directly

```routeros
/tool fetch url="https://raw.githubusercontent.com/maximpri/mikrotik-adguardhome/main/adguardhome_script.rsc"
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
│  1. Check RouterOS version (≥7.22)                          │
│  2. Pre-flight checks:                                      │
│     - Verify storage mount exists                           │
│     - Create required directories                           │
│     - Test network connectivity to Docker Hub               │
│  3. Enable container feature (if disabled) → reboot         │
│  4. Configure Docker registry                                │
│  5. Create mount point (if missing)                         │
│  6. Create veth interface (if missing)                      │
│  7. If container exists:                                     │
│     - Use /container repull (RouterOS 7.22+ feature)        │
│     - Automatic stop/repull/start handled by RouterOS       │
│     - Monitor for errors during extraction                  │
│  8. If first-time:                                           │
│     - Pull latest image & create container                   │
│     - Wait for extraction (with error detection)            │
│     - Start container                                       │
│  9. Post-deployment verification:                           │
│     - Check uptime for stable run                           │
│     - Retrieve container logs                               │
│     - Report SUCCESS VERIFIED or FAILED                     │
└─────────────────────────────────────────────────────────────┘
```

## RouterOS 7.22+ Features

This script leverages the new RouterOS 7.22 container improvements:
- **Automatic repull**: `/container repull` handles stop/repull/start automatically
- **zstd extraction**: Faster image extraction with zstd compression support
- **Improved error handling**: Better error messages when container fails to start

## Robust Deployment Verification

The script includes comprehensive checks to ensure deployment success:

### Pre-flight Checks
- **Storage verification**: Validates USB/disk mount exists before deployment
- **Directory creation**: Creates required directories (`/usb1/agh`, `/usb1/conf/agh`, `/usb1/tmp`)
- **Network connectivity**: Blocks if Docker Hub unreachable (blocking check)

### Deployment Monitoring
- **Error detection**: Monitors container status for "error" or "failed" states during extraction
- **Progress tracking**: Real-time status updates every 5 seconds

### Post-deployment Verification
- **Uptime check**: Verifies container has stable uptime (not just "running" flag)
- **Log inspection**: Retrieves container logs to surface any startup errors
- **Final state report**: Shows "SUCCESS VERIFIED" or "FAILED" with details

### Visual Progress Output

The script displays clear milestone markers during execution:

```
========================================
  AdGuard Home Deployment v1.3.0
========================================

[1/8] RouterOS Version Check...
      |-- Detected: 7.22.1
      |-- Required: >= 7.22
      |-- [OK] Version verified

[2/8] Pre-flight Checks...
      |-- Storage mount...
      |   |-- [OK] /usb1 verified
      |-- Network connectivity...
      |   |-- [OK] Docker Hub reachable
      |-- [OK] Pre-flight checks passed

...

[8/8] Container Deployment...
      |-- Mode: First-time deployment
      |-- Image: adguard/adguardhome:latest
      |-- [OK] Deployment completed

========================================
  DEPLOYMENT SUCCESSFUL
========================================
```

## Upgrading AdGuard Home

Simply run the script again - it will automatically:
- Stop the running container
- Remove the old container
- Pull the latest image
- Start the new container

Your configuration is preserved in the mounted volume.

## Troubleshooting

### Container won't start after repull
RouterOS 7.22+ automatically handles the repull process. If the container fails to start after a repull:
```routeros
/container start [find name=adguardhome]
```

### Repull takes too long
The script waits up to 5 minutes for repull completion. On slower hardware or USB storage, this may take longer. You can check the container status:
```routeros
/container print detail
```

### Container feature not available
Ensure your RouterOS license and hardware support containers. CHR requires a paid license for container support.

## License

MIT License - Feel free to use and modify.

## Author

**Maxim Priezjev** - April 2026

## Contributing

Issues and pull requests are welcome!

