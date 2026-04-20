# ============================================================================
# AdGuard Home Container Deployment Script for MikroTik RouterOS
# ============================================================================
# Version: 1.6.0
# Author:  Maxim Priezjev
# Date:    April 20, 2026
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
#   - Visual progress: Percentage-based progress with [OK]/[FAILED] markers
#   - Error handling: Graceful timeout handling with rollback on failure
#   - DNS management: Sets 1.1.1.1 during pull, restores after completion
#   - Auto cleanup: Removes stale reverse DNS entries for 172.17.0.1
#   - Double verification: Stability check after initial deployment
#
# Prerequisites:
#   - RouterOS 7.22 or higher with container support (CHR, ARM, ARM64, or TILE)
#   - USB storage mounted at /usb1 (or modify cDefaultStorageMount variable)
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
:local cDefaultStorageMount "/usb1"
:local cRootDir ($cDefaultStorageMount . "/agh")
:local cTmpDir ($cDefaultStorageMount . "/tmp")
:local cMountListName "agh_conf"
:local cMountSrc ($cDefaultStorageMount . "/conf/agh")
:local cMountDst "/opt/adguardhome/conf"
:local cEnvListName "AGH"
:local cRegistryUrl "https://registry-1.docker.io"
:local cRequiredMinorVersion "22"
:local cScriptVersion "1.6.1"

## Timeout configuration (adjust for slow USB/large images)
:local cPullTimeout 300
:local cStartDelay 10
:local cVerifyDelay 10

## DNS backup for restoration
:local dnsBackup ""

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
    :local storageFound [/file find where name=$cDefaultStorageMount]
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
    :put "      |   |-- Fix: Edit cDefaultStorageMount at line 45"
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
    ## Test with DNS resolution check - simpler and reliable
    :resolve "registry-1.docker.io"
    :set networkOk true
    :put "      |   |-- [OK] Docker Hub reachable"
} on-error={
    :put "      |   |-- [WARN] Network test failed - will try pull anyway"
}

:if ($storageOk = true) do={
    :put "      |-- [OK] Pre-flight checks passed"
} else={
    :put "      |-- [FAILED] Pre-flight checks failed"
    :if ($storageOk != true) do={
        :put "      |-- [ERROR] Storage required for container deployment"
        :put "      |-- DEBUG INFO:"
        :put ("      |   |-- storageOk=" . $storageOk)
        :put "      |   |-- Run: /disk print"
        :error "Storage not configured"
    }
}

## ========================================
## Milestone 3: Container Feature
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] Container Feature...")

:local containerEnabled false
:if ([:find [/system/device-mode print] "container: yes"] != nil) do={
    :set containerEnabled true
}

:if ($containerEnabled = true) do={
    :put "      |-- [OK] Already enabled"
} else={
    :put "      |-- Enabling container feature..."
    /system/device-mode/update container=yes
    :put "      |-- [WARN] Reboot required"
    :put "      |-- Run script again after reboot"
    :error "Reboot required"
}

## ========================================
## Milestone 4: Registry Configuration
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] Registry Configuration...")

:local currentRegistry [/container config get registry-url]
:if ($currentRegistry != $cRegistryUrl) do={
    /container config set registry-url=$cRegistryUrl tmpdir=$cTmpDir
    :put ("      |-- [OK] Configured " . $cRegistryUrl)
} else={
    :put "      |-- [OK] Already configured"
}

## ========================================
## Milestone 5: Mount Points
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] Mount Points...")

:local mountExists [:len [/container mounts find list=$cMountListName]]
:if ($mountExists = 0) do={
    /container mounts add list=$cMountListName src=$cMountSrc dst=$cMountDst
    :put ("      |-- [OK] Created mount '" . $cMountListName . "'")
} else={
    :put ("      |-- [OK] Mount '" . $cMountListName . "' exists")
}

## ========================================
## Milestone 6: Environment Variables
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] Environment Variables...")

:local envExists [:len [/container envs find list=$cEnvListName]]
:if ($envExists = 0) do={
    /container envs add list=$cEnvListName key=QUIC_GO_DISABLE_RECEIVE_BUFFER_WARNING value=true
    :put ("      |-- [OK] Created envlist '" . $cEnvListName . "'")
} else={
    :put ("      |-- [OK] Envlist '" . $cEnvListName . "' exists")
}

## ========================================
## Milestone 7: Veth Interface
## ========================================

:set milestoneNum ($milestoneNum + 1)
:put ("[" . $milestoneNum . "/" . $milestoneTotal . "] Network Interface...")

:local vethExists [:len [/interface veth find name=$cInterface]]
:if ($vethExists = 0) do={
    /interface veth add name=$cInterface
    :put ("      |-- [OK] Created veth '" . $cInterface . "'")
    :put "      |-- [WARN] Configure IP address manually"
} else={
    :put ("      |-- [OK] Veth '" . $cInterface . "' exists")
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

    ## Configure DNS for reliable container pull
    :put "      |-- Configuring DNS for pull..."
    :set dnsBackup [/ip dns get servers]
    /ip dns set servers=1.1.1.1,8.8.8.8
    :put "      |   |-- [OK] Temporary DNS: 1.1.1.1, 8.8.8.8"

    :put "      |-- Triggering repull..."

    ## Save original state for rollback
    :local originalRunning false
    :local cDataOrig [/container print as-value where name=$cName]
    :if ([:len $cDataOrig] > 0) do={
        :local firstItemOrig ($cDataOrig->0)
        :foreach k,v in=$firstItemOrig do={
            :if ($k = "running") do={ :set originalRunning $v }
        }
    }

    /container repull [find name=$cName]

    ## Wait for repull with percentage progress
    :local repullTimeout $cPullTimeout
    :local repullCounter 0
    :local isExtracting true
    :local progressPercent 0

    :do {
        :delay 10s
        :set repullCounter ($repullCounter + 10)

        :local cData [/container print as-value where name=$cName]
        :if ([:len $cData] > 0) do={
            :local firstItem ($cData->0)
            :foreach k,v in=$firstItem do={
                :if ($k = "extracting") do={ :set isExtracting $v }
                :if ($k = "running") do={ :set deployOk $v }
            }
        }

        ## Show percentage progress
        :set progressPercent ($repullCounter * 100 / $repullTimeout)
        :if ($progressPercent > 100) do={ :set progressPercent 100 }
        :put ("      |   |-- Progress: " . $progressPercent . "%")
    } while=($isExtracting = true && $repullCounter < $repullTimeout)

    :if ($deployOk = true) do={
        :put ("      |   |-- [OK] Repull completed in " . $repullCounter . "s")
    } else={
        ## Try to start if stopped
        :local isStopped false
        :local cData [/container print as-value where name=$cName]
        :if ([:len $cData] > 0) do={
            :local firstItem ($cData->0)
            :foreach k,v in=$firstItem do={
                :if ($k = "stopped") do={ :set isStopped $v }
            }
        }

        :if ($isStopped = true) do={
            :put "      |   |-- Starting container..."
            /container start [find name=$cName]
            :delay 10s

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
            :put "      |   |-- [FAILED] Repull timeout"
            :put "      |   |-- DEBUG INFO:"
            :put ("      |   |-- repullCounter=" . $repullCounter . "s")
            :put ("      |   |-- repullTimeout=" . $repullTimeout . "s")
            :put ("      |   |-- isExtracting=" . $isExtracting)
            :put "      |   |-- Run: /container print detail"

            ## ROLLBACK: Try to restore original state
            :put "      |   |-- Attempting rollback..."
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
                        :delay 10s
                        :put "      |   |-- [ROLLBACK] Container restored to previous state"
                    }
                }
            } on-error={
                :put "      |   |-- [ROLLBACK FAILED] Manual intervention required"
            }
            :set deploymentSuccess false
        }
    }
} else={
    :put "      |-- Mode: First-time deployment"
    :put ("      |-- Image: " . $cImage)

    ## Configure DNS for reliable container pull
    :put "      |-- Configuring DNS for pull..."
    :set dnsBackup [/ip dns get servers]
    /ip dns set servers=1.1.1.1,8.8.8.8
    :put "      |   |-- [OK] Temporary DNS: 1.1.1.1, 8.8.8.8"

    :put "      |-- Pulling image..."

    /container add remote-image=$cImage name=$cName \
        interface=$cInterface logging=yes mountlists=$cMountListName start-on-boot=yes \
        root-dir=$cRootDir workdir="/opt/adguardhome/work" \
        cmd="-c /opt/adguardhome/conf/AdGuardHome.yaml -h 0.0.0.0 -w /opt/adguardhome/work" \
        entrypoint=/opt/adguardhome/AdGuardHome \
        envlist=$cEnvListName

    ## Wait for extraction with percentage progress
    :local extractTimeout $cPullTimeout
    :local extractCounter 0
    :local isExtracting true
    :local isStopped false
    :local extractPercent 0

    :do {
        :delay 10s
        :set extractCounter ($extractCounter + 10)

        :local cData [/container print as-value where name=$cName]
        :if ([:len $cData] > 0) do={
            :local firstItem ($cData->0)
            :foreach k,v in=$firstItem do={
                :if ($k = "extracting") do={ :set isExtracting $v }
                :if ($k = "stopped") do={ :set isStopped $v }
            }
        }

        ## Show percentage progress
        :set extractPercent ($extractCounter * 100 / $extractTimeout)
        :if ($extractPercent > 100) do={ :set extractPercent 100 }
        :put ("      |   |-- Progress: " . $extractPercent . "%")
    } while=($isExtracting = true && $extractCounter < $extractTimeout)

    :put ("      |   |-- [OK] Extraction completed in " . $extractCounter . "s")

    :if ($isStopped = true) do={
        :put "      |-- Starting container..."
        /container start [find name=$cName]
        :delay 5s

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
        :put "      |-- [FAILED] Extraction timeout"
        :put "      |-- DEBUG INFO:"
        :put ("      |   |-- extractCounter=" . $extractCounter . "s")
        :put ("      |   |-- extractTimeout=" . $extractTimeout . "s")
        :put ("      |   |-- isExtracting=" . $isExtracting)
        :put "      |   |-- Run: /container print detail"

        ## ROLLBACK: Remove failed container (cleanup for first-time deploy)
        :put "      |   |-- Attempting cleanup..."
        :do {
            /container remove [find name=$cName]
            :put "      |   |-- [ROLLBACK] Failed container removed"
            :put "      |   |-- Re-run script to retry deployment"
        } on-error={
            :put "      |   |-- [ROLLBACK FAILED] Manual cleanup required"
            :put ("      |   |-- Run: /container remove " . $cName)
        }
        :set deploymentSuccess false
    }
}

## Verification sub-step
:put "      |-- Verification..."
:delay 5s

:local cData [/container print as-value where name=$cName]
:if ([:len $cData] > 0) do={
    :local firstItem ($cData->0)
    :local finalRunning false
    :local finalUptime ""

    :foreach k,v in=$firstItem do={
        :if ($k = "running") do={ :set finalRunning $v }
        :if ($k = "uptime") do={ :set finalUptime $v }
    }

    :if ($finalRunning = true && [:len $finalUptime] > 0) do={
        :put ("      |   |-- [OK] Running with uptime: " . $finalUptime)
        :set deployOk true
    } else={
        :if ($finalRunning = true) do={
            :put "      |   |-- [WARN] Running but no uptime"
            :put "      |   |-- DEBUG: Container may be starting, wait and check"
        } else={
            :put "      |   |-- [FAILED] Not running"
            :put "      |   |-- DEBUG INFO:"
            :put ("      |   |--   finalRunning=" . $finalRunning)
            :put ("      |   |--   finalUptime=" . $finalUptime)
            :put "      |   |-- Run: /container print detail"
            :put ("      |   |-- Run: /container start " . $cName)
            :set deploymentSuccess false
        }
    }
} else={
    :put "      |   |-- [FAILED] Container not found"
    :put "      |   |-- DEBUG INFO:"
    :put ("      |   |-- cName=" . $cName)
    :put "      |   |-- Run: /container print"
    :set deploymentSuccess false
}

:delay 5s

## Second verification pass (stability check)
:put "      |-- Stability check..."
:delay $cVerifyDelay

:local cData2 [/container print as-value where name=$cName]
:if ([:len $cData2] > 0) do={
    :local firstItem ($cData2->0)
    :local finalRunning2 false
    :local finalUptime2 ""

    :foreach k,v in=$firstItem do={
        :if ($k = "running") do={ :set finalRunning2 $v }
        :if ($k = "uptime") do={ :set finalUptime2 $v }
    }

    :if ($finalRunning2 = true && [:len $finalUptime2] > 0) do={
        :put ("      |   |-- [OK] Stable - uptime: " . $finalUptime2)
        :set deployOk true
    } else={
        :if ($finalRunning2 = true) do={
            :put "      |   |-- [WARN] Container starting - may need more time"
        } else={
            :put "      |   |-- [FAILED] Container crashed after start"
            :put "      |   |-- DEBUG: Check container logs"
            :set deploymentSuccess false
        }
    }
} else={
    :put "      |   |-- [FAILED] Container disappeared"
    :set deploymentSuccess false
}

:if ($deployOk = true) do={
    :put "      |-- [OK] Deployment completed"

    ## Remove stale reverse DNS entries for container IP
    :put "      |-- Cleaning DNS..."
    :do {
        /ip dns static remove [find where address=172.17.0.1]
        :put "      |   |-- [OK] Removed stale reverse DNS (172.17.0.1)"
    } on-error={
        :put "      |   |-- [OK] No stale reverse DNS found"
    }

    ## Restore DNS settings
    :put "      |-- Restoring DNS..."
    :if ([:len $dnsBackup] > 0 && $dnsBackup != "1.1.1.1,8.8.8.8") do={
        /ip dns set servers=$dnsBackup
        :put ("      |   |-- [OK] DNS restored to: " . $dnsBackup)
    } else={
        :put "      |   |-- [INFO] DNS already configured"
    }
} else={
    :put "      |-- [FAILED] Deployment failed"

    ## Restore DNS even on failure
    :put "      |-- Restoring DNS..."
    :if ([:len $dnsBackup] > 0) do={
        /ip dns set servers=$dnsBackup
        :put "      |   |-- [OK] DNS restored after failure"
    }
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