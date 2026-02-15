# ============================================================================
# AdGuard Home Container Deployment Script for MikroTik RouterOS
# ============================================================================
# Version: 1.0.1
# Author:  Maxim Priezjev
# Date:    February 15, 2026
# Tested on: RouterOS 7.21.3
# 
# Description:
#   This script automates the deployment and upgrade of AdGuard Home as a
#   container on MikroTik routers. It handles both first-time installation
#   and subsequent upgrades to the latest version.
#
# Features:
#   - First-time setup: Automatically enables container feature, configures
#     Docker registry, creates mount points, and provisions veth interface
#   - Upgrade mode: Safely stops and removes existing container before
#     pulling the latest image
#   - Status monitoring: Real-time terminal output showing deployment progress
#   - Error handling: Graceful timeout handling with informative error messages
#
# Prerequisites:
#   - RouterOS 7.x with container support (CHR, ARM, ARM64, or TILE)
#   - USB storage mounted at /usb1 (or modify cRootDir variable)
#   - Network connectivity to Docker Hub
#
# Post-deployment steps (first-time only):
#   1. Configure IP address on the veth interface
#   2. Set up firewall/NAT rules as needed
#   3. Access AdGuard Home web UI (default: http://<container-ip>:3000)
#   4. Complete initial AdGuard Home setup wizard
#
# Usage:
#   /import adguardhome_script.rsc
#   or
#   /system script add name=adguardhome-deploy source=[/file get adguardhome_script.rsc contents]
#   /system script run adguardhome-deploy
#
# ============================================================================

## Variables
:local cName "adguardhome"
:local cImage "adguard/adguardhome:latest"
:local cInterface "agh"
:local cRootDir "/disk1/agh"
:local cTmpDir "/disk1/tmp"
:local cMountListName "agh_conf"
:local cMountSrc "/disk1/conf/agh"
:local cMountDst "/opt/adguardhome/conf"
:local cEnvListName "AGH"
:local cRegistryUrl "https://registry-1.docker.io"
:local cMinVersion "7.21"

## ========================================
## RouterOS Version Check
## ========================================

:put "Checking RouterOS version..."
:local rosVersion [/system resource get version]
## Extract version number (remove any suffix like "rc1" or "beta")
:local versionClean $rosVersion
:local spacePos [:find $rosVersion " "]
:if ([:typeof $spacePos] != "nil") do={
    :set versionClean [:pick $rosVersion 0 $spacePos]
}

## Parse major version (before first dot)
:local firstDot [:find $versionClean "."]
:local majorVersion [:pick $versionClean 0 $firstDot]

## Parse minor version (between first and second dot)
:local afterFirstDot [:pick $versionClean ($firstDot + 1) [:len $versionClean]]
:local secondDot [:find $afterFirstDot "."]
:local minorVersion $afterFirstDot
:if ([:typeof $secondDot] != "nil") do={
    :set minorVersion [:pick $afterFirstDot 0 $secondDot]
}

:put ("Detected RouterOS version: " . $rosVersion . " (major: " . $majorVersion . ", minor: " . $minorVersion . ")")

## Check minimum version requirement (7.21)
:local versionOk false
:if ([:tonum $majorVersion] > 7) do={
    :set versionOk true
} else={
    :if ([:tonum $majorVersion] = 7 && [:tonum $minorVersion] >= 21) do={
        :set versionOk true
    }
}

:if ($versionOk != true) do={
    :put ("ERROR: This script requires RouterOS " . $cMinVersion . " or higher")
    :put ("Your version: " . $rosVersion)
    :log error ("AdGuard Home script requires RouterOS " . $cMinVersion . "+, found " . $rosVersion)
    :error "RouterOS version too old"
} else={
    :put "RouterOS version OK"
}

## ========================================
## First-time setup checks
## ========================================

## Check if container feature is enabled
:put "Checking if container feature is enabled..."
:local containerEnabled false

## Try to get container status directly using find
:local containerStatus [/system device-mode get container]
:put "DEBUG: container status from get: $containerStatus"

:if ($containerStatus = "yes" || $containerStatus = true || $containerStatus = "true") do={
    :set containerEnabled true
    :put "DEBUG: Container is ENABLED"
} else={
    :put "DEBUG: Container is DISABLED (value: $containerStatus)"
}

:if ($containerEnabled != true) do={
    :put "Container feature is DISABLED. Enabling..."
    :put "NOTE: Router will need to be rebooted after this change!"
    /system/device-mode/update container=yes
    :put "Container feature enabled. Please REBOOT the router and run this script again."
    :error "Reboot required"
} else={
    :put "Container feature is enabled"
}

## Check and configure container registry
:put "Checking container configuration..."
:local currentRegistry [/container config get registry-url]
:if ($currentRegistry != $cRegistryUrl) do={
    :put ("Setting registry-url to " . $cRegistryUrl)
    /container config set registry-url=$cRegistryUrl tmpdir=$cTmpDir
} else={
    :put "Registry already configured"
}

## Check and create mount if it doesn't exist
:put "Checking mount configuration..."
:if ([:len [/container mounts find list=$cMountListName]] = 0) do={
    :put ("Creating mount: " . $cMountListName)
    /container mounts add list=$cMountListName src=$cMountSrc dst=$cMountDst
} else={
    :put ("Mount " . $cMountListName . " already exists")
}

## Check and create envlist if it doesn't exist
:put "Checking env list configuration..."
:if ([:len [/container envs find list=$cEnvListName]] = 0) do={
    :put ("Creating mount: " . $cMountListName)
    /container envs add list=$cEnvListName key=QUIC_GO_DISABLE_RECEIVE_BUFFER_WARNING  value=true
} else={
    :put ("Env list " . $cEnvListName . " already exists")
}

## Check and create veth interface if it doesn't exist
:put "Checking veth interface..."
:if ([:len [/interface veth find name=$cInterface]] = 0) do={
    :put ("Creating veth interface: " . $cInterface)
    /interface veth add name=$cInterface
    :put "NOTE: You may need to configure IP address and firewall rules for the interface"
} else={
    :put ("Interface " . $cInterface . " already exists")
}

## ========================================
## Container deployment
## ========================================

## Stop container if it exists
:if ([:len [/container find name=$cName]] > 0) do={
    :log info "Stopping container $cName..."
    :put "Stopping container $cName..."
    /container stop [find name=$cName]
    
    ## Wait for container to stop
    :local timeout 60
    :local counter 0
    :local isStopped false
    
    :do {
        :local cData [/container print as-value where name=$cName]
        
        :if ([:len $cData] > 0) do={
            :local firstItem ($cData->0)
            :foreach k,v in=$firstItem do={
                :if ($k = "stopped") do={
                    :set isStopped $v
                }
            }
        } else={
            :set isStopped true
        }
        
        :if ($isStopped != true) do={
            :put "Waiting for stop... ($counter s)"
            :delay 1s
            :set counter ($counter + 1)
        }
    } while=($isStopped != true && $counter < $timeout)
    
    :put "Loop exited. Stopped: $isStopped"
    
    ## Only attempt removal if it successfully stopped
    :if ($isStopped = true) do={
        :log info "Removing old container $cName..."
        :put "Removing old container $cName..."
        /container remove [find name=$cName]
        ## Wait for cleanup
        :delay 5s
    } else={
        :log error "Failed to stop container $cName within $timeout seconds."
        :put "ERROR: Failed to stop container within timeout."
        :error "Stop timeout"
    }
} else={
    :put ("Container " . $cName . " not found, skipping removal...")
}

## Re-add the latest container
:log info "Pulling and adding $cImage..."
:put "Pulling and adding $cImage..."
/container add remote-image=$cImage name=$cName \
    interface=$cInterface logging=yes mountlists=$cMountListName start-on-boot=yes \
    root-dir=$cRootDir workdir="/opt/adguardhome/work" \
    cmd="-c /opt/adguardhome/conf/AdGuardHome.yaml -h 0.0.0.0 -w /opt/adguardhome/work" \
    entrypoint=/opt/adguardhome/AdGuardHome \
    envlist=$cEnvListName

## Wait for pull and extraction
:log info "Waiting for container to be ready (pulling/extracting)..."
:put "Waiting for container to be ready (pulling/extracting)..."
:local extractTimeout 300
:local extractCounter 0
:local isExtracting true
:local isStopped false

:do {
    :delay 5s
    :set extractCounter ($extractCounter + 5)
    
    :local cData [/container print as-value where name=$cName]
    :if ([:len $cData] > 0) do={
        :local firstItem ($cData->0)
        :foreach k,v in=$firstItem do={
            :if ($k = "extracting") do={ :set isExtracting $v }
            :if ($k = "stopped") do={ :set isStopped $v }
        }
    }
    
    :put "Extracting: $isExtracting, Stopped: $isStopped ($extractCounter s)"
} while=(($isExtracting = true || $isStopped != true) && $extractCounter < $extractTimeout)

## Final check and start
:if ($isStopped = true) do={
    /container start [find name=$cName]
    :log info ("Container " . $cName . " started successfully")
    :put ("SUCCESS: " . $cName . " container started")
} else={
    :log error ("Container " . $cName . " failed to be ready within timeout")
    :put ("ERROR: " . $cName . " upgrade failed. Extracting: $isExtracting, Stopped: $isStopped")
}
