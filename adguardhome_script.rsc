# ============================================================================
# AdGuard Home Container Deployment Script for MikroTik RouterOS
# ============================================================================
# Version: 1.7.0
# Author:  Maxim Priezjev
# Date:    July 14, 2026
# Tested on: RouterOS 7.22.1
#
# IMPORTANT: This script is tested only on RouterOS 7.22.x
#            Do not use on 7.23 or later without testing first
#
# Description:
#   This script automates the deployment and upgrade of AdGuard Home as a
#   container on MikroTik routers. It handles both first-time installation
#   and subsequent upgrades to the latest version.
#
# Features:
#   - First-time setup: Automatically enables container feature, configures
#     Docker registry, creates mount points, and provisions veth interface
#   - Upgrade mode: Uses RouterOS 7.22+ automatic repull feature for seamless
#     container updates (no manual stop/remove required)
#   - Visual progress: Timed status updates with [OK]/[FAILED] markers
#   - Error handling: Graceful timeout handling with cleanup on failure
#   - Safe networking: Preserves the router's DNS and static DNS configuration
#   - Idempotent setup: Validates existing mounts, envs, and veth settings
#   - Double verification: Stability check after initial deployment
#
# Prerequisites:
#   - RouterOS 7.22.x with container support (ARM, ARM64, x86, or CHR)
#   - USB storage mounted at /usb1 (or modify cDefaultStorageMount variable)
#   - Network connectivity to Docker Hub
#
# Post-deployment steps (first-time only):
#   1. Attach the veth interface to a container bridge
#   2. Assign 172.17.0.1/24 to that bridge and configure NAT/firewall rules
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
:local cDefaultStorageMount "/usb1"
:local cRootDir ($cDefaultStorageMount . "/agh")
:local cTmpDir ($cDefaultStorageMount . "/tmp")
:local cMountListName "agh_conf"
:local cMountSrc ($cDefaultStorageMount . "/conf/agh")
:local cMountDst "/opt/adguardhome/conf"
:local cWorkMountSrc ($cDefaultStorageMount . "/work/agh")
:local cWorkMountDst "/opt/adguardhome/work"
:local cEnvListName "AGH"
:local cRegistryUrl "https://registry-1.docker.io"
:local cRegistryHost "registry-1.docker.io"
:local cContainerAddress "172.17.0.2/24"
:local cContainerGateway "172.17.0.1"
:local cRequiredMinorVersion "22"
:local cScriptVersion "1.7.0"

## Timeout configuration (adjust for slow USB/large images)
:local cPullTimeout 300
:local cPollInterval 5s
:local cPollSeconds 5
:local cStartDelay 5s
:local cVerifyDelay 10

## Progress tracking
:local milestoneNum 0
:local milestoneTotal 8
:local deploymentSuccess true

## ========================================
## Display Header
## ========================================

:put ""
:put "========================================"
:put ("  AdGuard Home Deployment v" . $cScriptVersion)
:put "========================================"
:put ""

## ========================================
## Milestone 1: RouterOS Version Check
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] RouterOS Version Check...")

:local rosVersion [/system resource get version]
:local versionClean $rosVersion
:local spacePos [:find $rosVersion " "]
:if ([:typeof $spacePos] != "nil") do={
    :set versionClean [:pick $rosVersion 0 $spacePos]
}

:local firstDot [:find $versionClean "."]
:local majorVersion [:pick $versionClean 0 $firstDot]

:local afterFirstDot [:pick $versionClean ($firstDot + 1) [:len $versionClean]]
:local secondDot [:find $afterFirstDot "."]
:local minorVersion $afterFirstDot
:if ([:typeof $secondDot] != "nil") do={
    :set minorVersion [:pick $afterFirstDot 0 $secondDot]
}

:local versionOk false
## Only allow RouterOS 7.22.x (block 7.23 and later)
:if ([:tonum $majorVersion] = 7 && [:tonum $minorVersion] = [:tonum $cRequiredMinorVersion]) do={
    :set versionOk true
}

:if ($versionOk = true) do={
    :put ("      |-- Detected: " . $rosVersion)
    :put ("      |-- Required: 7.22.x (this script tested on 7.22 only)")
    :put "      |-- [OK] Version verified"
} else={
    :put ("      |-- Detected: " . $rosVersion)
    :put "      |-- Required: 7.22.x only"
    :put "      |-- [FAILED] Version mismatch"
    :put "      |-- DEBUG INFO:"
    :put ("      |   |-- majorVersion=" . $majorVersion)
    :put ("      |   |-- minorVersion=" . $minorVersion)
    :put ("      |   |-- Required: 7." . $cRequiredMinorVersion . ".*")
    :if ([:tonum $minorVersion] > [:tonum $cRequiredMinorVersion]) do={
        :put "      |   |-- Note: Later versions may have API changes"
    }
    :put "      |   |-- Fix: Use script version for your RouterOS release"
    :set deploymentSuccess false
    :log error ("RouterOS version not supported: " . $rosVersion . " (requires 7.22.x)")
    :error "Version check failed"
}

## ========================================
## Milestone 2: Pre-flight Checks
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] Pre-flight Checks...")

## Container package verification
:put "      |-- Container package..."
:local packageOk false
:local packageIds [/system package find where name="container"]
:local enabledPackageIds [/system package find where name="container" and disabled=no]
:if ([:len $enabledPackageIds] > 0) do={
    :set packageOk true
    :put "      |   |-- [OK] Installed and enabled"
} else={
    :if ([:len $packageIds] > 0) do={
        :put "      |   |-- [FAILED] Package is disabled"
    } else={
        :put "      |   |-- [FAILED] Package is not installed"
    }
}

## Storage mount verification
:put "      |-- Storage mount..."
:local storageOk false

## Strip leading slash for disk check (mount-point shows "usb1" not "/usb1")
:local diskName $cDefaultStorageMount
:if ([:pick $diskName 0 1] = "/") do={
    :set diskName [:pick $diskName 1 [:len $diskName]]
}

:do {
    ## Check /disk menu for mounted storage
    :local diskList [/disk find where mount-point=$diskName]
    :if ([:len $diskList] > 0) do={
        :set storageOk true
        :put ("      |   |-- [OK] " . $cDefaultStorageMount . " verified (disk: " . $diskName . ")")
    }
} on-error={ }

## Also check /file as fallback
:if ($storageOk = false) do={
    :local storageFound [/file find where name=$diskName]
    :if ([:len $storageFound] > 0) do={
        :set storageOk true
        :put ("      |   |-- [OK] " . $cDefaultStorageMount . " verified")
    }
}

:if ($storageOk = false) do={
    :put ("      |   |-- [FAILED] " . $cDefaultStorageMount . " not found")
    :put "      |   |-- DEBUG INFO:"
    :put ("      |   |-- cDefaultStorageMount=" . $cDefaultStorageMount)
    :put ("      |   |-- diskName (stripped)=" . $diskName)
    :put "      |   |-- Available mounts:"
    :foreach d in=[/disk find] do={
        :local mp [/disk get $d mount-point]
        :if ([:len $mp] > 0) do={
            :put ("      |   |--   /" . $mp)
        }
    }
    :put "      |   |-- Fix: Edit cDefaultStorageMount near the top of this script"
    :set deploymentSuccess false
}

## Directory creation
:put "      |-- Required directories..."
## Note: Disk directories are auto-created by RouterOS when containers use them
## Skip manual creation for disk paths to avoid spurious warnings
:put "      |   |-- [OK] Directories will be auto-created by container"
:put ("      |   |-- Paths: " . $cRootDir . ", " . $cMountSrc . ", " . $cTmpDir)

## Network connectivity
:put "      |-- Network connectivity..."
:local networkOk false
:do {
    :resolve $cRegistryHost
    :set networkOk true
    :put "      |   |-- [OK] Docker Hub reachable"
} on-error={
    :put "      |   |-- [FAILED] Cannot resolve Docker Hub"
}

:if ($packageOk = true && $storageOk = true && $networkOk = true) do={
    :put "      |-- [OK] Pre-flight checks passed"
} else={
    :put "      |-- [FAILED] Pre-flight checks failed"
    :if ($packageOk != true) do={
        :put "      |-- [ERROR] Install and enable the container package"
        :error "Container package unavailable"
    }
    :if ($storageOk != true) do={
        :put "      |-- [ERROR] Storage required for container deployment"
        :put "      |-- DEBUG INFO:"
        :put ("      |   |-- storageOk=" . $storageOk)
        :put "      |   |-- Run: /disk print"
        :error "Storage not configured"
    }
    :if ($networkOk != true) do={
        :put "      |-- [ERROR] Configure working DNS/network access before deployment"
        :put "      |   |-- Run: /ip dns print"
        :error "Docker Hub unavailable"
    }
}

## ========================================
## Milestone 3: Container Feature
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] Container Feature...")

:local containerEnabled [/system/device-mode get container]

:if ($containerEnabled = true) do={
    :put "      |-- [OK] Already enabled"
} else={
    :put "      |-- Enabling container feature..."
    /system/device-mode/update container=yes
    :put "      |-- [ACTION REQUIRED] Confirm within the activation window"
    :put "      |-- Briefly press the reset/mode button, or perform a cold power cycle"
    :put "      |-- Run this script again after RouterOS restarts"
    :error "Physical device-mode confirmation required"
}

## ========================================
## Milestone 4: Registry Configuration
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] Registry Configuration...")

:local currentRegistry [/container config get registry-url]
:local currentTmpDir [/container config get tmpdir]
:if ($currentRegistry != $cRegistryUrl || $currentTmpDir != $cTmpDir) do={
    /container config set registry-url=$cRegistryUrl tmpdir=$cTmpDir
    :put ("      |-- [OK] Registry: " . $cRegistryUrl)
    :put ("      |-- [OK] Temp directory: " . $cTmpDir)
} else={
    :put "      |-- [OK] Already configured"
}

## ========================================
## Milestone 5: Mount Points
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] Mount Points...")

:local mountFound false
:local mountMatches false
:foreach mountId in=[/container mounts find where list=$cMountListName] do={
    :local existingDst [/container mounts get $mountId dst]
    :if ($existingDst = $cMountDst) do={
        :set mountFound true
        :local existingSrc [/container mounts get $mountId src]
        :if ($existingSrc = $cMountSrc) do={
            :set mountMatches true
        }
    }
}

:if ($mountFound = false) do={
    /container mounts add list=$cMountListName src=$cMountSrc dst=$cMountDst
    :put ("      |-- [OK] Created mount '" . $cMountListName . "'")
} else={
    :if ($mountMatches = true) do={
        :put ("      |-- [OK] Mount '" . $cMountListName . "' verified")
    } else={
        :put ("      |-- [FAILED] Mount destination uses a different source")
        :put ("      |-- Expected: " . $cMountSrc . " -> " . $cMountDst)
        :put "      |-- Refusing to switch configuration storage automatically"
        :error "Mount configuration mismatch"
    }
}

## AdGuard Home exposes a second volume for runtime data. Add it automatically
## on new deployments, but do not mask an existing container's work directory.
:local workMountFound false
:local workMountMatches false
:foreach mountId in=[/container mounts find where list=$cMountListName] do={
    :local existingDst [/container mounts get $mountId dst]
    :if ($existingDst = $cWorkMountDst) do={
        :set workMountFound true
        :local existingSrc [/container mounts get $mountId src]
        :if ($existingSrc = $cWorkMountSrc) do={
            :set workMountMatches true
        }
    }
}

:if ($workMountFound = false) do={
    :if ([:len [/container find name=$cName]] = 0) do={
        /container mounts add list=$cMountListName src=$cWorkMountSrc dst=$cWorkMountDst
        :put "      |-- [OK] Created persistent work-data mount"
    } else={
        :put "      |-- [FAILED] Existing container has no separate work-data mount"
        :put "      |-- Back up and migrate /opt/adguardhome/work manually"
        :put "      |-- Refusing to repull until runtime data is protected"
        :error "Work-data mount migration required"
    }
} else={
    :if ($workMountMatches = true) do={
        :put "      |-- [OK] Work-data mount verified"
    } else={
        :put "      |-- [FAILED] Work-data destination uses a different source"
        :put ("      |-- Expected: " . $cWorkMountSrc . " -> " . $cWorkMountDst)
        :error "Work-data mount configuration mismatch"
    }
}

## ========================================
## Milestone 6: Environment Variables
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] Environment Variables...")

:local envId [/container envs find where list=$cEnvListName and key="QUIC_GO_DISABLE_RECEIVE_BUFFER_WARNING"]
:if ([:len $envId] = 0) do={
    /container envs add list=$cEnvListName key=QUIC_GO_DISABLE_RECEIVE_BUFFER_WARNING value=true
    :put ("      |-- [OK] Added QUIC warning override")
} else={
    :local envValue [/container envs get $envId value]
    :if ($envValue != "true") do={
        /container envs set $envId value=true
        :put "      |-- [OK] Corrected QUIC warning override"
    } else={
        :put ("      |-- [OK] Envlist '" . $cEnvListName . "' verified")
    }
}

## ========================================
## Milestone 7: Veth Interface
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] Network Interface...")

:local vethExists [:len [/interface veth find name=$cInterface]]
:if ($vethExists = 0) do={
    /interface veth add name=$cInterface address=$cContainerAddress gateway=$cContainerGateway
    :put ("      |-- [OK] Created veth '" . $cInterface . "'")
    :put ("      |-- [OK] Container address: " . $cContainerAddress)
    :put ("      |-- [OK] Container gateway: " . $cContainerGateway)
    :put "      |-- [ACTION REQUIRED] Attach veth to a bridge and configure NAT"
} else={
    :local vethId [/interface veth find name=$cInterface]
    :local currentAddress [/interface veth get $vethId address]
    :local currentGateway [/interface veth get $vethId gateway]

    :if ([:len $currentAddress] = 0 && [:len $currentGateway] = 0) do={
        /interface veth set $vethId address=$cContainerAddress gateway=$cContainerGateway
        :put ("      |-- [OK] Completed address configuration on '" . $cInterface . "'")
    } else={
        :put ("      |-- [OK] Veth '" . $cInterface . "' exists")
        :if ($currentAddress != $cContainerAddress || $currentGateway != $cContainerGateway) do={
            :put "      |-- [INFO] Preserving custom veth network settings"
            :put ("      |   |-- Address: " . $currentAddress)
            :put ("      |   |-- Gateway: " . $currentGateway)
        }
    }
}

## ========================================
## Milestone 8: Container Deployment
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] Container Deployment...")

:local containerExists false
:if ([:len [/container find name=$cName]] > 0) do={
    :set containerExists true
}
:local deployOk false

:if ($containerExists = true) do={
    :put "      |-- Mode: Upgrade (repull)"
    :put ("      |-- Image: " . $cImage)

    :put "      |-- Triggering repull..."

    :local repullStarted false
    :do {
        /container repull [find name=$cName] remote-image=$cImage
        :set repullStarted true
    } on-error={
        :put "      |   |-- [FAILED] RouterOS rejected the repull request"
        :put "      |   |-- Check free disk space and /container/log"
        :set deploymentSuccess false
    }

    :if ($repullStarted = false) do={
        :error "Container repull failed"
    }

    ## Wait until automatic stop/repull/start reaches a terminal state
    :local repullTimeout $cPullTimeout
    :local repullCounter 0
    :local isExtracting true
    :local isStopped false
    :local repullDone false

    :do {
        :delay $cPollInterval
        :set repullCounter ($repullCounter + $cPollSeconds)
        :set isExtracting false
        :set isStopped false
        :set deployOk false

        :local cData [/container print as-value where name=$cName]
        :if ([:len $cData] > 0) do={
            :local firstItem ($cData->0)
            :foreach k,v in=$firstItem do={
                :if ($k = "extracting") do={ :set isExtracting $v }
                :if ($k = "running") do={ :set deployOk $v }
                :if ($k = "stopped") do={ :set isStopped $v }
            }
        }

        :if ($deployOk = true || $isStopped = true) do={
            :set repullDone true
        }
        :put ("      |   |-- Waiting: " . $repullCounter . "s / " . $repullTimeout . "s")
    } while=($repullDone = false && $repullCounter < $repullTimeout)

    :if ($deployOk = true) do={
        :put ("      |   |-- [OK] Repull completed in " . $repullCounter . "s")
    } else={
        ## Try to start if stopped
        :if ($isStopped = true) do={
            :put "      |   |-- Starting container..."
            /container start [find name=$cName]
            :delay $cStartDelay

            :local cData [/container print as-value where name=$cName]
            :if ([:len $cData] > 0) do={
                :local firstItem ($cData->0)
                :foreach k,v in=$firstItem do={
                    :if ($k = "running") do={ :set deployOk $v }
                }
            }

            :if ($deployOk = true) do={
                :put "      |   |-- [OK] Started successfully"
            } else={
                :put "      |   |-- [FAILED] Could not start"
                :put "      |   |-- DEBUG INFO:"
                :local cData [/container print as-value where name=$cName]
                :if ([:len $cData] > 0) do={
                    :local firstItem ($cData->0)
                    :foreach k,v in=$firstItem do={
                        :put ("      |   |--   " . $k . "=" . $v)
                    }
                }
                :put "      |   |-- Run: /container print detail"
                :put ("      |   |-- Run: /container log " . $cName)
                :set deploymentSuccess false
            }
        } else={
            :put "      |   |-- [FAILED] Repull failed or timed out"
            :put "      |   |-- DEBUG INFO:"
            :put ("      |   |-- repullCounter=" . $repullCounter . "s")
            :put ("      |   |-- repullTimeout=" . $repullTimeout . "s")
            :put ("      |   |-- isExtracting=" . $isExtracting)
            :put "      |   |-- Run: /container print detail"

            ## Ask RouterOS to start the current container state if possible
            :put "      |   |-- Attempting recovery..."
            :do {
                :delay 5s
                :local cData [/container print as-value where name=$cName]
                :if ([:len $cData] > 0) do={
                    :local firstItem ($cData->0)
                    :local rollbackStopped false
                    :foreach k,v in=$firstItem do={
                        :if ($k = "stopped") do={ :set rollbackStopped $v }
                    }
                    :if ($rollbackStopped = true) do={
                        /container start [find name=$cName]
                        :delay $cStartDelay
                        :put "      |   |-- [RECOVERY] Container started"
                    }
                }
            } on-error={
                :put "      |   |-- [RECOVERY FAILED] Manual intervention required"
            }
            :set deploymentSuccess false
        }
    }
} else={
    :put "      |-- Mode: First-time deployment"
    :put ("      |-- Image: " . $cImage)

    :put "      |-- Pulling image..."

    :local addStarted false
    :do {
        /container add remote-image=$cImage check-certificate=yes name=$cName \
            interface=$cInterface logging=yes mountlists=$cMountListName start-on-boot=yes \
            root-dir=$cRootDir workdir="/opt/adguardhome/work" \
            cmd="-c /opt/adguardhome/conf/AdGuardHome.yaml -h 0.0.0.0 -w /opt/adguardhome/work" \
            entrypoint=/opt/adguardhome/AdGuardHome \
            envlist=$cEnvListName
        :set addStarted true
    } on-error={
        :put "      |   |-- [FAILED] RouterOS rejected the container request"
        :put "      |   |-- Check free disk space and /container/log"
        :set deploymentSuccess false
    }

    :if ($addStarted = false) do={
        :error "Container creation failed"
    }

    ## Wait for extraction to reach the stopped state
    :local extractTimeout $cPullTimeout
    :local extractCounter 0
    :local isExtracting true
    :local isStopped false

    :do {
        :delay $cPollInterval
        :set extractCounter ($extractCounter + $cPollSeconds)
        :set isExtracting false
        :set isStopped false

        :local cData [/container print as-value where name=$cName]
        :if ([:len $cData] > 0) do={
            :local firstItem ($cData->0)
            :foreach k,v in=$firstItem do={
                :if ($k = "extracting") do={ :set isExtracting $v }
                :if ($k = "stopped") do={ :set isStopped $v }
            }
        }

        :put ("      |   |-- Waiting: " . $extractCounter . "s / " . $extractTimeout . "s")
    } while=($isStopped = false && $extractCounter < $extractTimeout)

    :if ($isStopped = true) do={
        :put ("      |   |-- [OK] Extraction completed in " . $extractCounter . "s")
    }

    :if ($isStopped = true) do={
        :put "      |-- Starting container..."
        /container start [find name=$cName]
        :delay $cStartDelay

        :local cData [/container print as-value where name=$cName]
        :if ([:len $cData] > 0) do={
            :local firstItem ($cData->0)
            :foreach k,v in=$firstItem do={
                :if ($k = "running") do={ :set deployOk $v }
            }
        }

        :if ($deployOk = true) do={
            :put "      |   |-- [OK] Started successfully"
        } else={
            :put "      |   |-- [FAILED] Could not start"
            :put "      |   |-- DEBUG INFO:"
            :local cData [/container print as-value where name=$cName]
            :if ([:len $cData] > 0) do={
                :local firstItem ($cData->0)
                :foreach k,v in=$firstItem do={
                    :put ("      |   |--   " . $k . "=" . $v)
                }
            }
            :put "      |   |-- Run: /container print detail"
            :put ("      |   |-- Run: /container log " . $cName)
            :set deploymentSuccess false
        }
    } else={
        :put "      |-- [FAILED] Extraction failed or timed out"
        :put "      |-- DEBUG INFO:"
        :put ("      |   |-- extractCounter=" . $extractCounter . "s")
        :put ("      |   |-- extractTimeout=" . $extractTimeout . "s")
        :put ("      |   |-- isExtracting=" . $isExtracting)
        :put "      |   |-- Run: /container print detail"

        ## Remove the failed first-time container so the next run can retry
        :put "      |   |-- Attempting cleanup..."
        :do {
            /container remove [find name=$cName]
            :put "      |   |-- [CLEANUP] Failed container removed"
            :put "      |   |-- Re-run script to retry deployment"
        } on-error={
            :put "      |   |-- [CLEANUP FAILED] Manual cleanup required"
            :put ("      |   |-- Run: /container remove " . $cName)
        }
        :set deploymentSuccess false
    }
}

## Verification sub-step
:put "      |-- Verification..."
:delay $cStartDelay

:local cData [/container print as-value where name=$cName]
:local finalRunning false
:if ([:len $cData] > 0) do={
    :local firstItem ($cData->0)
    :foreach k,v in=$firstItem do={
        :if ($k = "running") do={ :set finalRunning $v }
    }

    :if ($finalRunning = true) do={
        :put "      |   |-- [OK] Container is running"
        :set deployOk true
    } else={
        :put "      |   |-- [FAILED] Container is not running"
        :put "      |   |-- Run: /container print detail"
        :put ("      |   |-- Run: /container log " . $cName)
        :set deployOk false
        :set deploymentSuccess false
    }
} else={
    :put "      |   |-- [FAILED] Container not found"
    :put "      |   |-- Run: /container print"
    :set deployOk false
    :set deploymentSuccess false
}

## Second verification pass (stability check)
:put "      |-- Stability check..."
:delay $cVerifyDelay

:local cData2 [/container print as-value where name=$cName]
:local finalRunning2 false
:if ([:len $cData2] > 0) do={
    :local firstItem ($cData2->0)
    :foreach k,v in=$firstItem do={
        :if ($k = "running") do={ :set finalRunning2 $v }
    }

    :if ($finalRunning2 = true) do={
        :put "      |   |-- [OK] Container remained running"
        :set deployOk true
    } else={
        :put "      |   |-- [FAILED] Container stopped after start"
        :put ("      |   |-- Run: /container log " . $cName)
        :set deployOk false
        :set deploymentSuccess false
    }
} else={
    :put "      |   |-- [FAILED] Container disappeared"
    :set deployOk false
    :set deploymentSuccess false
}

:if ($deployOk = true && $deploymentSuccess = true) do={
    :put "      |-- [OK] Deployment completed"
} else={
    :put "      |-- [FAILED] Deployment failed"
}

## ========================================
## Final Summary
## ========================================

:put ""
:put "========================================"

:if ($deploymentSuccess = true) do={
    :put "  DEPLOYMENT SUCCESSFUL"
    :log info "AdGuard Home deployment completed successfully"
} else={
    :put "  DEPLOYMENT FAILED"
    :put "  DEBUG SUMMARY:"
    :put ("  |-- cName=" . $cName)
    :put ("  |-- cImage=" . $cImage)
    :put ("  |-- cDefaultStorageMount=" . $cDefaultStorageMount)
    :put ("  |-- cRootDir=" . $cRootDir)
    :put ("  |-- cMountSrc=" . $cMountSrc)
    :put ("  |-- cInterface=" . $cInterface)
    :put "  |-- Troubleshooting commands:"
    :put "  |--   /container print detail"
    :put "  |--   /container log adguardhome"
    :put "  |--   /disk print"
    :put "  |--   /file print"
    :log error "AdGuard Home deployment failed"
}

:put "========================================"
:put ""
