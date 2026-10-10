# ============================================================================
# AdGuard Home Container Deployment Script for MikroTik RouterOS
# ============================================================================
# Version: 1.9.0
# Author:  Maxim Priezjev
# Date:    October 9, 2026
# Minimum RouterOS: 7.22
#
# IMPORTANT: RouterOS 7.23+ supports native container healthchecks. RouterOS
#            7.22 remains supported with the script's running/stability checks.
#
# Description:
#   This script automates the deployment and upgrade of AdGuard Home as a
#   container on MikroTik routers. It handles both first-time installation
#   and subsequent upgrades to the latest version.
#
# Features:
#   - First-time setup: Configures the Docker registry, mount points, and
#     veth interface, then pulls, extracts, and starts the container
#   - Upgrade mode: Uses RouterOS 7.22+ automatic repull for in-place updates
#   - Update-safe DNS: If the router itself resolves through AdGuard Home, a
#     fallback resolver is used while the container is down, and the original
#     DNS settings are restored once AdGuard Home answers again
#   - Error handling: Every failure path restores DNS and prints a summary
#   - Idempotent setup: Validates existing mounts, envs, and veth settings
#   - Health monitoring: Configures native healthchecks on RouterOS 7.23+
#
# Prerequisites:
#   - RouterOS 7.22 or later with container support (ARM, ARM64, x86, or CHR)
#   - USB storage mounted at /usb1 (or modify cDefaultStorageMount variable)
#   - Network connectivity to Docker Hub
#   - Not supported: EN7562CT devices (hEX Refresh) run only arm32v5
#     images, which AdGuard Home does not publish
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

## ========================================
## Settings
## ========================================

:local cName "adguardhome"
:local cImage "adguard/adguardhome:latest"
:local cInterface "agh"
:local cDefaultStorageMount "/usb1"
## Storage for the AdGuardHome.yaml config mount. Keep it on persistent
## storage, such as internal flash, if cDefaultStorageMount is a RAM disk.
:local cConfigStorageMount $cDefaultStorageMount
:local cRootDir ($cDefaultStorageMount . "/agh")
:local cTmpDir ($cDefaultStorageMount . "/tmp")
:local cMountListName "agh_conf"
:local cMountSrc ($cConfigStorageMount . "/conf/agh")
:local cMountDst "/opt/adguardhome/conf"
:local cWorkMountSrc ($cDefaultStorageMount . "/work/agh")
:local cWorkMountDst "/opt/adguardhome/work"
:local cEnvListName "AGH"
:local cRegistryUrl "https://registry-1.docker.io"
:local cRegistryHost "registry-1.docker.io"
:local cContainerAddress "172.17.0.2/24"
:local cContainerGateway "172.17.0.1"

## Update-safe DNS. When the router's DNS servers (or DoH server) point at the
## AdGuard Home container, these resolvers are used while it is down. Use a
## comma-separated list, or "" to disable the fallback.
:local cFallbackDns "1.1.1.1"
## Name resolved through AdGuard Home before the original DNS is restored.
:local cDnsTestHost "cloudflare.com"

## RouterOS 7.23+ native healthcheck configuration. The default command covers
## both the first-run setup UI (port 3000) and the normal web UI (port 80).
## Change this command if AdGuard Home uses a custom web port. The command is
## embedded in a double-quoted RouterOS string, so avoid unescaped " and $.
:local cHealthcheckCmd "sh -c 'wget -q --spider http://127.0.0.1:3000 || wget -q --spider http://127.0.0.1:80'"
:local cHealthcheckInterval "00:00:30"
:local cHealthcheckTimeout "00:00:10"
:local cHealthcheckStartPeriod "00:02:00"
:local cHealthcheckRetries 3

## Timeouts in seconds (increase for slow USB storage or slow links)
:local cPullTimeout 300
:local cStartTimeout 30
:local cStabilitySeconds 10
:local cDnsReadyTimeout 60
:local cPollSeconds 5
:local cProgressSeconds 30
## If repull has not visibly stopped the container after this many seconds,
## the script stops waiting and reports a warning.
:local cRepullGraceSeconds 60

## ========================================
## Internal state (do not edit)
## ========================================

:local cScriptVersion "1.9.0"
:local cMinimumMinorVersion 22
:local cHealthcheckMinorVersion 23
:local stepNum 0
:local stepTotal 9
:local currentStep ""
:local deploymentSuccess true
:local failReason ""
:local warningCount 0
:local containerExists false
:local containerIp ""
:local healthcheckSupported false
:local healthcheckConfigured false

## DNS fallback state. Globals let a later run restore DNS settings if this
## run is interrupted while the fallback is active.
:global AGHDnsRestorePending
:global AGHDnsRestoreServers
:global AGHDnsRestoreDoh
:global AGHDnsRestoreDohUsed
:local dnsFallbackActive false
:local dnsOriginalServers ""
:local dnsOriginalDoh ""
:local dnsDohUsesContainer false
:local dnsKeepFallback false
:local dnsStatus "unchanged"
:local pollDelay [:totime ($cPollSeconds . "s")]

## ========================================
## Helper functions
## ========================================
## RouterOS functions cannot see the caller's locals, so every input is passed
## as a named argument.

## Returns missing, error, extracting, running, stopped, or other.
:local getContainerState do={
    :local items [/container print as-value where name=$containerName]
    :if ([:len $items] = 0) do={
        :return "missing"
    }
    :local isRunning false
    :local isStopped false
    :local isExtracting false
    :local status ""
    :foreach k,v in=($items->0) do={
        :if ($k = "running") do={ :set isRunning $v }
        :if ($k = "stopped") do={ :set isStopped $v }
        :if ($k = "extracting") do={ :set isExtracting $v }
        :if ($k = "status") do={ :set status [:tostr $v] }
    }
    :if ([:typeof [:find $status "error"]] = "num") do={ :return "error" }
    :if ($isExtracting = true || $status = "extracting") do={ :return "extracting" }
    :if ($isRunning = true || $status = "running") do={ :return "running" }
    :if ($isStopped = true || $status = "stopped") do={ :return "stopped" }
    :return "other"
}

## Starts the container and waits until it reports running.
:local startContainer do={
    :local started false
    ## A rejected request can mean RouterOS is already starting it, so the
    ## state is polled either way.
    :do {
        /container start [find name=$containerName]
    } on-error={
        :put "      |   |-- [INFO] RouterOS rejected the start request; checking state"
    }
    :local waited 0
    :local limit [:tonum $timeout]
    :while ($started = false && $waited < $limit) do={
        :delay 2s
        :set waited ($waited + 2)
        :local items [/container print as-value where name=$containerName]
        :if ([:len $items] > 0) do={
            :foreach k,v in=($items->0) do={
                :if ($k = "running" && $v = true) do={ :set started true }
                :if ($k = "status" && [:tostr $v] = "running") do={ :set started true }
            }
        }
    }
    :return $started
}

## Prints container properties and troubleshooting commands.
:local printContainerDetails do={
    :local items [/container print as-value where name=$containerName]
    :if ([:len $items] > 0) do={
        :put "      |   |-- Container properties:"
        :foreach k,v in=($items->0) do={
            :put ("      |   |     " . $k . "=" . [:tostr $v])
        }
    }
    :put "      |   |-- Run: /container print detail"
    :put ("      |   |-- Run: /container log " . $containerName)
}

## Splits a comma- or semicolon-separated list into an array of strings.
:local splitList do={
    :local out [:toarray ""]
    :local raw [:tostr $value]
    :local item ""
    :local rawLen [:len $raw]
    :for i from=0 to=$rawLen do={
        :local ch ""
        :if ($i < $rawLen) do={ :set ch [:pick $raw $i] }
        :if ($i = $rawLen || $ch = "," || $ch = ";") do={
            :if ([:len $item] > 0) do={ :set out ($out, $item) }
            :set item ""
        } else={
            :if ($ch != " ") do={ :set item ($item . $ch) }
        }
    }
    :return $out
}

## Applies the 7.23+ healthcheck without blocking deployment.
:local applyHealthcheck do={
    :local configured false
    :put "      |-- Configuring native healthcheck..."
    :do {
        :local setHealthcheck [:parse $command]
        $setHealthcheck
        :set configured true
        :put "      |   |-- [OK] Healthcheck configured"
    } on-error={
        :put "      |   |-- [WARNING] RouterOS rejected the healthcheck settings"
        :put "      |   |-- Continuing with running/stability checks only"
        :log warning "AdGuard Home: native healthcheck configuration failed"
    }
    :return $configured
}

## ========================================
## Header
## ========================================

:put ""
:put "========================================"
:put ("  AdGuard Home Deployment v" . $cScriptVersion)
:put "========================================"
:put ""

## ========================================
## Step 1: RouterOS Version Check
## ========================================
## Runs before anything is changed, so it can stop the script directly.

:set stepNum ($stepNum + 1)
:put ("[" . $stepNum . "/" . $stepTotal . "] RouterOS version...")

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

## Keep only the leading digits so pre-releases such as 7.23rc1 parse as 23.
:local minorDigits ""
:local minorDigitsDone false
:if ([:len $minorVersion] > 0) do={
    :for i from=0 to=([:len $minorVersion] - 1) do={
        :local ch [:pick $minorVersion $i]
        :if ($minorDigitsDone = false && [:typeof [:find "0123456789" $ch]] = "num") do={
            :set minorDigits ($minorDigits . $ch)
        } else={
            :set minorDigitsDone true
        }
    }
}
:if ([:len $minorDigits] = 0) do={
    :set minorDigits "0"
}

:local majorNumber [:tonum $majorVersion]
:local minorNumber [:tonum $minorDigits]

:put ("      |-- Detected: " . $rosVersion)
:if (!($majorNumber > 7 || ($majorNumber = 7 && $minorNumber >= $cMinimumMinorVersion))) do={
    :put ("      |-- [FAILED] RouterOS 7." . $cMinimumMinorVersion . " or later is required")
    :put "      |-- Fix: Upgrade RouterOS and the container package"
    :log error ("AdGuard Home: RouterOS " . $rosVersion . " is not supported (requires 7.22 or later)")
    :error "Version check failed"
}

:if ($majorNumber > 7 || ($majorNumber = 7 && $minorNumber >= $cHealthcheckMinorVersion)) do={
    :set healthcheckSupported true
    :put "      |-- [OK] Supported; native container healthchecks available"
} else={
    :put "      |-- [OK] Supported; native healthchecks need 7.23+ (using stability checks)"
}

## Keep 7.23-only properties inside a runtime-parsed command. This prevents
## RouterOS 7.22 from rejecting the script while parsing an unreachable branch.
:local healthcheckSetCommand ""
:if ($healthcheckSupported = true) do={
    :set healthcheckSetCommand ("/container set [find name=\"" . $cName . "\"]" . \
        " healthcheck-cmd=\"" . $cHealthcheckCmd . "\"" . \
        " healthcheck-interval=\"" . $cHealthcheckInterval . "\"" . \
        " healthcheck-timeout=\"" . $cHealthcheckTimeout . "\"" . \
        " healthcheck-start-period=\"" . $cHealthcheckStartPeriod . "\"" . \
        " healthcheck-retries=" . $cHealthcheckRetries)
}

:if ([:len [/container find name=$cName]] > 0) do={
    :set containerExists true
    :log info ("AdGuard Home: upgrade started (script v" . $cScriptVersion . ")")
} else={
    :log info ("AdGuard Home: first-time deployment started (script v" . $cScriptVersion . ")")
}

## ========================================
## Steps 2-9
## ========================================
## Every failure below sets failReason and raises an error, which is caught at
## the end of this block so the DNS fallback can always be restored.

:do {

    ## ----------------------------------------
    ## Step 2: Container package and device-mode
    ## ----------------------------------------

    :set stepNum ($stepNum + 1)
    :set currentStep "Container support"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Container support...")

    :if ([:len [/system package find where name="container" and disabled=no]] = 0) do={
        :if ([:len [/system package find where name="container"]] > 0) do={
            :put "      |-- [FAILED] The container package is disabled"
            :put "      |-- Fix: /system package enable container, then reboot"
        } else={
            :put "      |-- [FAILED] The container package is not installed"
            :put "      |-- Fix: Install the container package for your RouterOS version"
        }
        :set failReason "Container package unavailable"
        :error $failReason
    }
    :put "      |-- [OK] Container package installed and enabled"

    :if ([/system/device-mode get container] != true) do={
        :put "      |-- Enabling container device-mode..."
        /system/device-mode/update container=yes
        :put "      |-- [ACTION REQUIRED] Confirm within the activation window"
        :put "      |-- Briefly press the reset/mode button, or perform a cold power cycle"
        :put "      |-- Run this script again after RouterOS restarts"
        :set failReason "Physical device-mode confirmation required"
        :error $failReason
    }
    :put "      |-- [OK] Container device-mode enabled"

    ## ----------------------------------------
    ## Step 3: Storage
    ## ----------------------------------------

    :set stepNum ($stepNum + 1)
    :set currentStep "Storage"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Storage...")

    ## /disk shows mount points without the leading slash ("usb1", not "/usb1").
    :local diskName $cDefaultStorageMount
    :if ([:pick $diskName 0 1] = "/") do={
        :set diskName [:pick $diskName 1 [:len $diskName]]
    }

    :local storageOk false
    :do {
        :if ([:len [/disk find where mount-point=$diskName]] > 0) do={
            :set storageOk true
        }
    } on-error={ }
    :if ($storageOk = false && [:len [/file find where name=$diskName]] > 0) do={
        :set storageOk true
    }

    :if ($storageOk = false) do={
        :put ("      |-- [FAILED] " . $cDefaultStorageMount . " is not mounted")
        :put "      |-- Available mounts:"
        :foreach d in=[/disk find] do={
            :local mp [/disk get $d mount-point]
            :if ([:len $mp] > 0) do={
                :put ("      |   |-- /" . $mp)
            }
        }
        :put "      |-- Fix: Edit cDefaultStorageMount near the top of this script"
        :set failReason ("Storage " . $cDefaultStorageMount . " not found")
        :error $failReason
    }
    :put ("      |-- [OK] " . $cDefaultStorageMount . " is mounted")
    :put ("      |-- Container root: " . $cRootDir)
    :put ("      |-- Config:         " . $cMountSrc)
    :put ("      |-- Work data:      " . $cWorkMountSrc)

    ## ----------------------------------------
    ## Step 4: Router DNS and Docker Hub access
    ## ----------------------------------------

    :set stepNum ($stepNum + 1)
    :set currentStep "Router DNS"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Router DNS and Docker Hub access...")

    ## The container's address comes from the existing veth when there is one,
    ## because the script preserves custom veth addressing.
    :set containerIp $cContainerAddress
    :local vethIdsForIp [/interface veth find name=$cInterface]
    :if ([:len $vethIdsForIp] > 0) do={
        :local vethAddress [:tostr [/interface veth get ($vethIdsForIp->0) address]]
        :if ([:len $vethAddress] > 0) do={
            :set containerIp $vethAddress
        }
    }
    :foreach sep in={";";",";"/"} do={
        :local sepPos [:find $containerIp $sep]
        :if ([:typeof $sepPos] = "num") do={
            :set containerIp [:pick $containerIp 0 $sepPos]
        }
    }

    ## Read the current DNS settings, or the originals saved by an
    ## interrupted run that left the fallback active.
    :local serversUseContainer false
    :local currentServers [$splitList value=[/ip dns get servers]]
    :local fallbackList [$splitList value=$cFallbackDns]

    ## Saved settings are used only while the fallback is still in place. If
    ## DNS was changed since then, the saved values are stale and discarded.
    :if ($AGHDnsRestorePending = "yes") do={
        :if ([:len $currentServers] = 0 || [:len $fallbackList] = 0 || \
            ($currentServers->0) != ($fallbackList->0)) do={
            :set AGHDnsRestorePending "no"
            :put "      |-- [INFO] Discarded stale DNS recovery data"
        }
    }

    :if ($AGHDnsRestorePending = "yes") do={
        :set dnsOriginalServers [:tostr $AGHDnsRestoreServers]
        :set dnsOriginalDoh [:tostr $AGHDnsRestoreDoh]
        :set dnsDohUsesContainer ($AGHDnsRestoreDohUsed = "yes")
        :set serversUseContainer true
        :put "      |-- [INFO] Recovering DNS settings saved by an interrupted run"
        :put ("      |   |-- Original servers: " . $dnsOriginalServers)
    } else={
        :foreach s in=$currentServers do={
            :if ([:len $dnsOriginalServers] > 0) do={
                :set dnsOriginalServers ($dnsOriginalServers . ",")
            }
            :set dnsOriginalServers ($dnsOriginalServers . $s)
            :if ($s = $containerIp) do={
                :set serversUseContainer true
            }
        }
        :set dnsOriginalDoh [:tostr [/ip dns get use-doh-server]]
        :if ([:len $dnsOriginalDoh] > 0) do={
            :if ([:typeof [:find $dnsOriginalDoh ("//" . $containerIp . "/")]] = "num" || \
                [:typeof [:find $dnsOriginalDoh ("//" . $containerIp . ":")]] = "num") do={
                :set dnsDohUsesContainer true
            }
        }
    }

    :if ($serversUseContainer = true || $dnsDohUsesContainer = true) do={
        :put ("      |-- Router DNS resolves through AdGuard Home (" . $containerIp . ")")
        :if ([:len $cFallbackDns] = 0) do={
            :put "      |-- [WARNING] cFallbackDns is empty; the router has no DNS while"
            :put "      |   |   the container is stopped, so the image pull may fail"
            :set warningCount ($warningCount + 1)
        } else={
            ## Fallback resolvers first, then the original servers except the
            ## container itself, so lookups do not wait on a stopped resolver.
            :local tempServers ""
            :foreach f in=$fallbackList do={
                :if ([:len $tempServers] > 0) do={ :set tempServers ($tempServers . ",") }
                :set tempServers ($tempServers . $f)
            }
            :foreach s in=[$splitList value=$dnsOriginalServers] do={
                :local skip ($s = $containerIp)
                :foreach f in=$fallbackList do={
                    :if ($f = $s) do={ :set skip true }
                }
                :if ($skip = false) do={
                    :set tempServers ($tempServers . "," . $s)
                }
            }

            :set AGHDnsRestoreServers $dnsOriginalServers
            :set AGHDnsRestoreDoh $dnsOriginalDoh
            :if ($dnsDohUsesContainer = true) do={
                :set AGHDnsRestoreDohUsed "yes"
            } else={
                :set AGHDnsRestoreDohUsed "no"
            }
            :set AGHDnsRestorePending "yes"

            /ip dns set servers=$tempServers
            :set dnsFallbackActive true
            :set dnsStatus ("fallback active (" . $tempServers . ")")
            :if ($dnsDohUsesContainer = true) do={
                /ip dns set use-doh-server=""
            }
            /ip dns cache flush
            :put ("      |-- [OK] Temporary router DNS: " . $tempServers)
            :log warning ("AdGuard Home: router DNS temporarily set to " . $tempServers . \
                " during deployment (original: " . $dnsOriginalServers . ")")
        }
    } else={
        :put "      |-- [OK] Router DNS does not depend on AdGuard Home"
    }

    :local networkOk false
    :do {
        :resolve $cRegistryHost
        :set networkOk true
    } on-error={ }
    :if ($networkOk = false) do={
        :put ("      |-- [FAILED] Cannot resolve " . $cRegistryHost)
        :put "      |-- Run: /ip dns print"
        :put ("      |-- Run: :put [:resolve " . $cRegistryHost . "]")
        :set failReason "Docker Hub is not resolvable"
        :error $failReason
    }
    :put "      |-- [OK] Docker Hub resolves"

    ## ----------------------------------------
    ## Step 5: Registry configuration
    ## ----------------------------------------

    :set stepNum ($stepNum + 1)
    :set currentStep "Registry configuration"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Registry configuration...")

    :if ([/container config get registry-url] != $cRegistryUrl || \
        [/container config get tmpdir] != $cTmpDir) do={
        /container config set registry-url=$cRegistryUrl tmpdir=$cTmpDir
        :put ("      |-- [OK] Registry: " . $cRegistryUrl)
        :put ("      |-- [OK] Temp directory: " . $cTmpDir)
    } else={
        :put "      |-- [OK] Already configured"
    }

    ## ----------------------------------------
    ## Step 6: Mount points
    ## ----------------------------------------

    :set stepNum ($stepNum + 1)
    :set currentStep "Mount points"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Mount points...")

    :local mountFound false
    :local mountMatches false
    :local workMountFound false
    :local workMountMatches false
    :foreach mountId in=[/container mounts find where list=$cMountListName] do={
        :local existingDst [/container mounts get $mountId dst]
        :local existingSrc [/container mounts get $mountId src]
        :if ($existingDst = $cMountDst) do={
            :set mountFound true
            :if ($existingSrc = $cMountSrc) do={ :set mountMatches true }
        }
        :if ($existingDst = $cWorkMountDst) do={
            :set workMountFound true
            :if ($existingSrc = $cWorkMountSrc) do={ :set workMountMatches true }
        }
    }

    :if ($mountFound = false) do={
        /container mounts add list=$cMountListName src=$cMountSrc dst=$cMountDst
        :put ("      |-- [OK] Created config mount " . $cMountSrc . " -> " . $cMountDst)
    } else={
        :if ($mountMatches = false) do={
            :put "      |-- [FAILED] The config mount uses a different source directory"
            :put ("      |-- Expected: " . $cMountSrc . " -> " . $cMountDst)
            :put "      |-- Refusing to switch configuration storage automatically"
            :put ("      |-- Run: /container mounts print where list=" . $cMountListName)
            :set failReason "Config mount mismatch"
            :error $failReason
        }
        :put "      |-- [OK] Config mount verified"
    }

    ## Add the work-data mount on new deployments only, so an existing
    ## container's work directory is never hidden behind an empty mount.
    :if ($workMountFound = false) do={
        :if ($containerExists = false) do={
            /container mounts add list=$cMountListName src=$cWorkMountSrc dst=$cWorkMountDst
            :put ("      |-- [OK] Created work-data mount " . $cWorkMountSrc . " -> " . $cWorkMountDst)
        } else={
            :put "      |-- [FAILED] The existing container has no work-data mount"
            :put ("      |-- Back up " . $cWorkMountDst . " and add a mount from " . $cWorkMountSrc)
            :put "      |-- Refusing to repull until runtime data is protected"
            :set failReason "Work-data mount migration required"
            :error $failReason
        }
    } else={
        :if ($workMountMatches = false) do={
            :put "      |-- [FAILED] The work-data mount uses a different source directory"
            :put ("      |-- Expected: " . $cWorkMountSrc . " -> " . $cWorkMountDst)
            :set failReason "Work-data mount mismatch"
            :error $failReason
        }
        :put "      |-- [OK] Work-data mount verified"
    }

    ## ----------------------------------------
    ## Step 7: Environment variables
    ## ----------------------------------------

    :set stepNum ($stepNum + 1)
    :set currentStep "Environment variables"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Environment variables...")

    :local envId [/container envs find where list=$cEnvListName and key="QUIC_GO_DISABLE_RECEIVE_BUFFER_WARNING"]
    :if ([:len $envId] = 0) do={
        /container envs add list=$cEnvListName key=QUIC_GO_DISABLE_RECEIVE_BUFFER_WARNING value=true
        :put "      |-- [OK] Added QUIC warning override"
    } else={
        :if ([/container envs get ($envId->0) value] != "true") do={
            /container envs set ($envId->0) value=true
            :put "      |-- [OK] Corrected QUIC warning override"
        } else={
            :put ("      |-- [OK] Envlist '" . $cEnvListName . "' verified")
        }
    }

    ## ----------------------------------------
    ## Step 8: Veth interface
    ## ----------------------------------------

    :set stepNum ($stepNum + 1)
    :set currentStep "Network interface"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Network interface...")

    :local vethIds [/interface veth find name=$cInterface]
    :if ([:len $vethIds] = 0) do={
        /interface veth add name=$cInterface address=$cContainerAddress gateway=$cContainerGateway
        :put ("      |-- [OK] Created veth '" . $cInterface . "' (" . $cContainerAddress . \
            " via " . $cContainerGateway . ")")
    } else={
        :local vethId ($vethIds->0)
        :local currentAddress [:tostr [/interface veth get $vethId address]]
        :local currentGateway [:tostr [/interface veth get $vethId gateway]]
        :if ([:len $currentAddress] = 0 && [:len $currentGateway] = 0) do={
            /interface veth set $vethId address=$cContainerAddress gateway=$cContainerGateway
            :put ("      |-- [OK] Completed address configuration on '" . $cInterface . "'")
        } else={
            :put ("      |-- [OK] Veth '" . $cInterface . "' exists")
            :if ($currentAddress != $cContainerAddress || $currentGateway != $cContainerGateway) do={
                :put ("      |-- [INFO] Keeping custom settings: " . $currentAddress . \
                    " via " . $currentGateway)
            }
        }
    }

    :if ([:len [/interface bridge port find where interface=$cInterface]] = 0) do={
        :put ("      |-- [WARNING] '" . $cInterface . "' is not attached to a bridge")
        :put "      |   |-- The container has no network until it is (see README)"
        :set warningCount ($warningCount + 1)
    }

    ## ----------------------------------------
    ## Step 9: Container deployment
    ## ----------------------------------------

    :set stepNum ($stepNum + 1)
    :set currentStep "Container deployment"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Container deployment...")
    :put ("      |-- Image: " . $cImage)

    :if ($containerExists = true) do={
        :put "      |-- Mode: Upgrade (repull)"

        :if ($healthcheckSupported = true) do={
            :set healthcheckConfigured [$applyHealthcheck command=$healthcheckSetCommand]
        }

        :local initialState [$getContainerState containerName=$cName]
        :put ("      |-- Current state: " . $initialState)
        :if ($initialState = "extracting") do={
            :put "      |-- [FAILED] The container is already extracting an image"
            :put "      |-- Wait for it to finish, then run this script again"
            :set failReason "Container busy"
            :error $failReason
        }

        :put "      |-- Triggering repull..."
        :do {
            /container repull [find name=$cName] remote-image=$cImage
        } on-error={
            :put "      |   |-- [FAILED] RouterOS rejected the repull request"
            :put "      |   |-- Check free disk space and /container log"
            :set failReason "Container repull rejected"
            :error $failReason
        }

        ## Wait for repull to stop, pull, extract, and restart the container.
        ## A brief "stopped" between stopping and pulling is not the end: a
        ## stopped container counts as finished only after extraction was seen,
        ## or after it stays stopped past the grace period. A running container
        ## counts only after it was seen going down.
        :local elapsed 0
        :local state $initialState
        :local lastState $initialState
        :local sawDown ($initialState != "running")
        :local sawExtracting false
        :local stoppedSince -1
        :local repullDone false
        :local repullAborted false
        :while ($repullDone = false && $repullAborted = false && $elapsed < $cPullTimeout) do={
            :delay $pollDelay
            :set elapsed ($elapsed + $cPollSeconds)
            :set state [$getContainerState containerName=$cName]
            :if ($state != "running") do={ :set sawDown true }
            :if ($state = "extracting") do={ :set sawExtracting true }
            :if ($state = "stopped") do={
                :if ($stoppedSince < 0) do={ :set stoppedSince $elapsed }
            } else={
                :set stoppedSince -1
            }
            :if ($state = "running" && $sawDown = true) do={ :set repullDone true }
            :if ($state = "stopped" && ($sawExtracting = true || \
                ($elapsed - $stoppedSince) >= $cRepullGraceSeconds)) do={
                :set repullDone true
            }
            :if ($state = "error" || $state = "missing") do={ :set repullAborted true }
            :if ($state = "running" && $sawDown = false && $elapsed >= $cRepullGraceSeconds) do={
                :set repullAborted true
            }
            :if ($state != $lastState || ($elapsed % $cProgressSeconds) = 0) do={
                :put ("      |   |-- " . $elapsed . "s: " . $state)
                :set lastState $state
            }
        }

        :if ($repullAborted = true && $state = "running") do={
            ## Repull never stopped the container. It may still start later, so
            ## the DNS fallback must stay in place; this is reported, not fatal.
            :put ("      |   |-- [WARNING] The container kept running for " . $elapsed . \
                "s; repull did not visibly start")
            :put "      |   |-- Check /container print detail; run the script again if needed"
            :set warningCount ($warningCount + 1)
            :set dnsKeepFallback true
            :set repullDone true
        }

        :if ($repullDone = false) do={
            :if ($repullAborted = true) do={
                :put ("      |   |-- [FAILED] Repull ended in state: " . $state)
            } else={
                :put ("      |   |-- [FAILED] Repull did not finish within " . $cPullTimeout . "s")
            }
            $printContainerDetails containerName=$cName
            :if ([$getContainerState containerName=$cName] = "stopped") do={
                :put "      |   |-- Attempting to start the existing container..."
                :if ([$startContainer containerName=$cName timeout=$cStartTimeout] = true) do={
                    :put "      |   |-- [RECOVERY] Container started"
                }
            }
            :put "      |   |-- Increase cPullTimeout for slow storage or links"
            :set failReason ("Repull failed (" . $state . ")")
            :error $failReason
        }

        :if ($state = "stopped") do={
            :put ("      |   |-- Image updated in " . $elapsed . "s; starting container...")
            :if ([$startContainer containerName=$cName timeout=$cStartTimeout] = false) do={
                :put "      |   |-- [FAILED] The container did not start"
                $printContainerDetails containerName=$cName
                :set failReason "Container did not start after repull"
                :error $failReason
            }
        }
        :if ($dnsKeepFallback = false) do={
            :put ("      |   |-- [OK] Repull finished in " . $elapsed . "s")
        }
    } else={
        :put "      |-- Mode: First-time deployment"
        :put "      |-- Pulling image..."
        :do {
            /container add remote-image=$cImage check-certificate=yes name=$cName \
                interface=$cInterface logging=yes mountlists=$cMountListName start-on-boot=yes \
                root-dir=$cRootDir workdir="/opt/adguardhome/work" \
                cmd="-c /opt/adguardhome/conf/AdGuardHome.yaml -h 0.0.0.0 -w /opt/adguardhome/work" \
                entrypoint=/opt/adguardhome/AdGuardHome \
                envlist=$cEnvListName
        } on-error={
            :put "      |   |-- [FAILED] RouterOS rejected the container request"
            :put "      |   |-- Check free disk space and /container log"
            :set failReason "Container creation rejected"
            :error $failReason
        }

        ## A new container reaches the stopped state once extraction finishes.
        :local elapsed 0
        :local state "other"
        :local lastState ""
        :while ($state != "stopped" && $state != "running" && $state != "error" && \
            $state != "missing" && $elapsed < $cPullTimeout) do={
            :delay $pollDelay
            :set elapsed ($elapsed + $cPollSeconds)
            :set state [$getContainerState containerName=$cName]
            :if ($state != $lastState || ($elapsed % $cProgressSeconds) = 0) do={
                :put ("      |   |-- " . $elapsed . "s: " . $state)
                :set lastState $state
            }
        }

        :if ($state != "stopped" && $state != "running") do={
            :if ($state = "error" || $state = "missing") do={
                :put ("      |   |-- [FAILED] Image pull ended in state: " . $state)
            } else={
                :put ("      |   |-- [FAILED] Extraction did not finish within " . $cPullTimeout . "s")
            }
            $printContainerDetails containerName=$cName
            ## Remove the partial container so the next run starts cleanly.
            :do {
                /container remove [find name=$cName]
                :put "      |   |-- [CLEANUP] Removed the incomplete container"
            } on-error={
                :put ("      |   |-- [CLEANUP FAILED] Run: /container remove " . $cName)
            }
            :put "      |   |-- Increase cPullTimeout for slow storage or links"
            :set failReason ("Image pull failed (" . $state . ")")
            :error $failReason
        }
        :put ("      |   |-- [OK] Image extracted in " . $elapsed . "s")

        :if ($healthcheckSupported = true) do={
            :set healthcheckConfigured [$applyHealthcheck command=$healthcheckSetCommand]
        }

        :if ($state != "running") do={
            :put "      |-- Starting container..."
            :if ([$startContainer containerName=$cName timeout=$cStartTimeout] = false) do={
                :put "      |   |-- [FAILED] The container did not start"
                $printContainerDetails containerName=$cName
                :set failReason "Container did not start"
                :error $failReason
            }
            :put "      |   |-- [OK] Container started"
        }
    }

    ## Stability check: AdGuard Home exits quickly on bad config or mounts.
    :put ("      |-- Stability check (" . $cStabilitySeconds . "s)...")
    :delay [:totime ($cStabilitySeconds . "s")]
    :if ([$getContainerState containerName=$cName] != "running") do={
        :put "      |   |-- [FAILED] The container stopped after starting"
        $printContainerDetails containerName=$cName
        :set failReason "Container is not stable"
        :error $failReason
    }
    :put "      |   |-- [OK] Container is running"

} on-error={
    :set deploymentSuccess false
    :if ([:len $failReason] = 0) do={
        :set failReason ("Unexpected RouterOS error during: " . $currentStep)
    }
}

## ========================================
## Restore router DNS
## ========================================
## Runs on success and failure. The original settings are restored only once
## AdGuard Home answers queries; otherwise the fallback stays so the router
## keeps working DNS.

:if ($dnsFallbackActive = true) do={
    :put "[DNS] Restoring router DNS..."
    :local adguardAnswers false
    :local waited 0
    :if ($dnsKeepFallback = false && [$getContainerState containerName=$cName] = "running") do={
        :while ($adguardAnswers = false && $waited <= $cDnsReadyTimeout) do={
            :do {
                :resolve $cDnsTestHost server=$containerIp
                :set adguardAnswers true
            } on-error={
                :delay $pollDelay
                :set waited ($waited + $cPollSeconds)
            }
        }
    }

    :if ($adguardAnswers = true) do={
        /ip dns set servers=$dnsOriginalServers
        :if ($dnsDohUsesContainer = true) do={
            /ip dns set use-doh-server=$dnsOriginalDoh
        }
        /ip dns cache flush
        :set AGHDnsRestorePending "no"
        :set dnsStatus ("restored (" . $dnsOriginalServers . ")")
        :put ("      |-- [OK] AdGuard Home answers DNS at " . $containerIp)
        :put ("      |-- [OK] Router DNS restored: " . $dnsOriginalServers)
        :put "      |-- [OK] DNS cache flushed"
        :log info "AdGuard Home: router DNS restored"
    } else={
        :if ($dnsKeepFallback = true) do={
            :put "      |-- [WARNING] The upgrade did not complete a restart"
        } else={
            :put ("      |-- [WARNING] AdGuard Home is not answering DNS at " . $containerIp)
        }
        :put "      |-- Keeping the fallback DNS so the router stays online"
        :put "      |-- After AdGuard Home answers again, run this script again, or:"
        :put ("      |   |-- /ip dns set servers=\"" . $dnsOriginalServers . "\"")
        :if ($dnsDohUsesContainer = true) do={
            :put ("      |   |-- /ip dns set use-doh-server=\"" . $dnsOriginalDoh . "\"")
        }
        :put "      |   |-- /ip dns cache flush"
        :put "      |   |-- /system script environment remove [find name~\"^AGHDnsRestore\"]"
        :set warningCount ($warningCount + 1)
        :log warning ("AdGuard Home: fallback DNS kept; original servers: " . $dnsOriginalServers)
    }
}

## ========================================
## Summary
## ========================================

:local finalState [$getContainerState containerName=$cName]
:local healthcheckSummary "unavailable (needs RouterOS 7.23+)"
:if ($healthcheckSupported = true) do={
    :if ($healthcheckConfigured = true) do={
        :set healthcheckSummary ("configured (start period " . $cHealthcheckStartPeriod . ")")
    } else={
        :set healthcheckSummary "not configured"
    }
}
:if ([:len $containerIp] = 0) do={
    :set containerIp $cContainerAddress
}

:put ""
:put "========================================"
:if ($deploymentSuccess = true) do={
    :if ($warningCount = 0) do={
        :put "  DEPLOYMENT SUCCESSFUL"
    } else={
        :put ("  DEPLOYMENT SUCCESSFUL WITH " . $warningCount . " WARNING(S)")
    }
} else={
    :put "  DEPLOYMENT FAILED"
}
:put "========================================"
:if ($deploymentSuccess = false) do={
    :put ("  Reason:      " . $failReason)
}
:if ($containerExists = true) do={
    :put "  Mode:        Upgrade"
} else={
    :put "  Mode:        First-time deployment"
}
:put ("  Container:   " . $cName . " (" . $finalState . ")")
:put ("  Image:       " . $cImage)
:put ("  Address:     " . $containerIp)
:put ("  Router DNS:  " . $dnsStatus)
:put ("  Healthcheck: " . $healthcheckSummary)

:if ($deploymentSuccess = true) do={
    :if ($containerExists = false) do={
        :put ""
        :put "  Next steps:"
        :put ("  1. Attach '" . $cInterface . "' to a bridge with " . $cContainerGateway . " (see README)")
        :put ("  2. Open http://" . $containerIp . ":3000 and complete the setup wizard")
        :put "  3. Point clients or DHCP at AdGuard Home"
    } else={
        :put ("  Web UI:      http://" . $containerIp)
    }
    :if ($healthcheckConfigured = true) do={
        :put "  Status:      /container print proplist=name,healthcheck-status"
    }
    :log info ("AdGuard Home: deployment completed (" . $finalState . ")")
} else={
    :put ""
    :put "  Troubleshooting:"
    :put "    /container print detail"
    :put ("    /container log " . $cName)
    :put "    /disk print"
    :put "    /ip dns print"
    :log error ("AdGuard Home: deployment failed: " . $failReason)
}
:put "========================================"
:put ""

:if ($deploymentSuccess = false) do={
    :error ("AdGuard Home deployment failed: " . $failReason)
}
