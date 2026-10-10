# ============================================================================
# AdGuard Home / Pi-hole Container Deployment Script for MikroTik RouterOS
# ============================================================================
# Version: 2.1.0
# Author:  Maxim Priezjev
# Date:    October 10, 2026
# Minimum RouterOS: 7.22
#
# Installs, upgrades, or switches between AdGuard Home and Pi-hole as a
# RouterOS container. Safe to run at any time:
#   - The new image is pulled into a second container while the current one
#     keeps serving DNS. If the image is unchanged, nothing is restarted.
#   - The switch is verified (running, stable, answering DNS). On failure the
#     previous container is started again (rollback).
#   - If the router itself resolves through the container, a fallback DNS
#     server is used during the switch and the original settings are restored
#     once the container answers again.
#
# Normally run by the mikrotik-adguardhome loader (mikrotik-adguardhome.rsc),
# which downloads this file from GitHub, verifies it, and passes its settings
# in the global AghOptions. See README.md. It also runs on its own via /import.
#
# Before changing anything, each run saves /export file=mikrotik-adguardhome-backup.
#
# The whole script is one { } block, so a truncated download fails to parse
# and nothing runs.
#
# Prerequisites:
#   - RouterOS 7.22 or later with the container package (ARM, ARM64, x86, CHR)
#   - Storage mounted at /usb1 (or change cDefaultStorageMount)
#   - Not supported: EN7562CT devices (hEX Refresh) run only arm32v5 images
# ============================================================================

{

## ========================================
## Settings
## ========================================

## "adguard", "pihole", or "" to keep the installed app (AdGuard Home when
## nothing is installed yet)
:local cApp ""
:local cAdguardImage "adguard/adguardhome:latest"
:local cPiholeImage "pihole/pihole:latest"
## Pi-hole web UI password. "" keeps the current one; a new install then gets
## a random password shown in /container log.
:local cPiholePassword ""

:local cDefaultStorageMount "/usb1"
## Keep config on persistent storage if cDefaultStorageMount is a RAM disk.
:local cConfigStorageMount $cDefaultStorageMount
:local cInterface "agh"
:local cContainerAddress "172.17.0.2/24"
:local cContainerGateway "172.17.0.1"
:local cRegistryUrl "https://registry-1.docker.io"
:local cRegistryHost "registry-1.docker.io"

## Configuration export saved before any change ("" disables)
:local cBackupFile "mikrotik-adguardhome-backup"
## Loader script whose comment records the deployed image digest
:local cUpdaterName "mikrotik-adguardhome"
:local cTmpDir ($cDefaultStorageMount . "/tmp")

## Fallback resolvers used while the router's DNS server is switching
## (comma-separated; "" disables) and the name used to test DNS.
:local cFallbackDns "1.1.1.1"
:local cDnsTestHost "cloudflare.com"

## Settings passed by the loader override the values above.
:global AghOptions
:local opts $AghOptions
:do { /system script environment remove [find where name="AghOptions"] } on-error={ }
:if ([:typeof $opts] = "array") do={
    :if ([:typeof ($opts->"app")] = "str") do={ :set cApp ($opts->"app") }
    :if ([:len ($opts->"storage")] > 0) do={
        :set cDefaultStorageMount ($opts->"storage")
        :set cConfigStorageMount ($opts->"storage")
        :set cTmpDir (($opts->"storage") . "/tmp")
    }
    :if ([:len ($opts->"configStorage")] > 0) do={ :set cConfigStorageMount ($opts->"configStorage") }
    :if ([:len ($opts->"address")] > 0) do={ :set cContainerAddress ($opts->"address") }
    :if ([:len ($opts->"gateway")] > 0) do={ :set cContainerGateway ($opts->"gateway") }
    :if ([:typeof ($opts->"fallbackDns")] = "str") do={ :set cFallbackDns ($opts->"fallbackDns") }
    :if ([:typeof ($opts->"piholePassword")] = "str") do={ :set cPiholePassword ($opts->"piholePassword") }
    :if ([:len ($opts->"adguardImage")] > 0) do={ :set cAdguardImage ($opts->"adguardImage") }
    :if ([:len ($opts->"piholeImage")] > 0) do={ :set cPiholeImage ($opts->"piholeImage") }
    :if ([:len ($opts->"updater")] > 0) do={ :set cUpdaterName ($opts->"updater") }
}

## RouterOS 7.23+ native healthcheck timing
:local cHealthcheckInterval "00:00:30"
:local cHealthcheckTimeout "00:00:10"
:local cHealthcheckStartPeriod "00:02:00"
:local cHealthcheckRetries 3

## Timeouts in seconds
:local cPullTimeout 600
:local cStartTimeout 30
:local cStopTimeout 30
:local cStabilitySeconds 10
:local cDnsReadyTimeout 90
:local cPollSeconds 5
:local cProgressSeconds 30

## ========================================
## Internal state
## ========================================

:local cScriptVersion "2.1.0"
:local stepNum 0
:local stepTotal 10
:local currentStep ""
:local deploymentSuccess true
:local failReason ""
:local resultText ""
:local warningCount 0
:local containerIp ""
:local healthcheckSupported false
:local healthcheckConfigured false
## Set when this run adds the work-data mount to an existing deployment; the
## mount is removed again if the run fails, so the old container is unchanged.
:local workMountAdded false
## Image recorded for the next run's up-to-date check
:local deployedImage ""
## Container that serves DNS right now; updated only after a verified switch.
:local servingName ""

## App profile (filled in step 3)
:local appId ""
:local appTitle ""
:local appBase ""
:local appImage ""
:local appRootDir ""
:local appMountList ""
:local appConfSrc ""
:local appConfDst ""
:local appWorkSrc ""
:local appWorkDst ""
:local appEnvList ""
:local appConfigFile ""
:local appHealthcheckCmd ""

## DNS fallback state. While the fallback is active, the original settings
## are kept in this /system script, which survives reboots, lets a later run
## recover an interrupted one, and restores DNS when run by hand.
:local cRestoreScript "mikrotik-adguardhome-restore"
:local dnsFallbackActive false
:local dnsOriginalServers ""
:local dnsOriginalDoh ""
:local dnsDohUsesContainer false
:local dnsStatus "unchanged"

## ========================================
## Helper functions
## ========================================
## Functions cannot see the caller's locals; all inputs are arguments.

## Returns missing, error, extracting, running, stopped, or other. RouterOS
## releases report state differently (7.24 has no running field), so state
## flags are queried first and memory use is the last resort. It is global
## so the other helpers can call it.
:global AghState do={
    :if ([:len [/container find where name=$containerName]] = 0) do={ :return "missing" }
    :local state ""
    :foreach f in={"extracting";"stopped";"running"} do={
        :if ([:len $state] = 0) do={
            :do {
                :local q [:parse (":return [:len [/container find where name=\"" . $containerName . \
                    "\" and " . $f . "]]")]
                :if ([$q] > 0) do={ :set state $f }
            } on-error={ }
        }
    }
    :local items [/container print as-value where name=$containerName]
    :local status ""
    :local memory 0
    :foreach k,v in=($items->0) do={
        :if ([:len $state] = 0 && ($k = "extracting" || $k = "stopped" || $k = "running") && $v = true) do={
            :set state $k
        }
        :if ($k = "status") do={ :set status [:tostr $v] }
        :if ($k = "memory-current") do={ :set memory [:tonum $v] }
    }
    :if ([:typeof [:find $status "error"]] = "num") do={ :return "error" }
    :if ([:len $state] = 0 && ($status = "extracting" || $status = "stopped" || $status = "running")) do={
        :set state $status
    }
    :if ([:len $state] = 0 && [:typeof $memory] = "num") do={
        :if ($memory > 0) do={ :set state "running" }
    }
    :if ([:len $state] = 0) do={ :return "other" }
    :return $state
}

## Returns a Docker Hub digest for the image tag, or "" if it cannot be read.
## It changes whenever the tag is pushed, so it is used to skip the download
## when nothing changed. Uses the public tag API: RouterOS fetch requests with
## custom headers (registry auth) fail on some releases.
:local remoteDigest do={
    :local img [:tostr $image]
    :local tag "latest"
    :local colon [:find $img ":"]
    :if ([:typeof $colon] = "num") do={
        :set tag [:pick $img ($colon + 1) [:len $img]]
        :set img [:pick $img 0 $colon]
    }
    :if ([:typeof [:find $img "/"]] != "num") do={ :set img ("library/" . $img) }
    :local digest ""
    :do {
        :local body ([/tool fetch output=user as-value url=("https://hub.docker.com/v2/repositories/" . \
            $img . "/tags/" . $tag)]->"data")
        :local d1 [:find $body "sha256:"]
        :if ([:typeof $d1] = "num") do={ :set digest [:pick $body $d1 ($d1 + 71)] }
    } on-error={ }
    :return $digest
}

## Waits until a new container finishes extracting. Returns the final state.
:local waitForExtraction do={
    :global AghState
    :local state "other"
    :local lastState ""
    :local elapsed 0
    :while ($state != "stopped" && $state != "running" && $state != "error" && \
        $state != "missing" && $elapsed < [:tonum $timeout]) do={
        :delay [:totime ($poll . "s")]
        :set elapsed ($elapsed + [:tonum $poll])
        :set state [$AghState containerName=$containerName]
        :if ($state != $lastState || ($elapsed % [:tonum $progress]) = 0) do={
            :put ("      |   |-- " . $elapsed . "s: " . $state)
            :set lastState $state
        }
    }
    :return $state
}

## Starts a container and waits until it is running. A container that was
## still stopping rejects the request, so it is re-sent while stopped.
:local startContainer do={
    :global AghState
    :do { /container start [find where name=$containerName] } on-error={ }
    :local state ""
    :local waited 0
    :while ($state != "running" && $waited < [:tonum $timeout]) do={
        :delay 2s
        :set waited ($waited + 2)
        :set state [$AghState containerName=$containerName]
        :if ($state = "stopped") do={
            :do { /container start [find where name=$containerName] } on-error={ }
        }
    }
    :return ($state = "running")
}

## Ranks how active a container is: 2 running, 1 starts on boot, 0 neither.
:local appScore do={
    :global AghState
    :if ([:len $containerName] = 0) do={ :return 0 }
    :if ([$AghState containerName=$containerName] = "running") do={ :return 2 }
    :local boot false
    :do { :set boot [/container get [find where name=$containerName] start-on-boot] } on-error={ }
    :if ($boot = true || $boot = "yes") do={ :return 1 }
    :return 0
}

## Stops a container and waits until it is stopped (or gone).
:local stopContainer do={
    :global AghState
    :do { /container stop [find where name=$containerName] } on-error={ }
    :local state ""
    :local waited 0
    :while ($state != "stopped" && $state != "missing" && $waited < [:tonum $timeout]) do={
        :delay 2s
        :set waited ($waited + 2)
        :set state [$AghState containerName=$containerName]
    }
    :return ($state = "stopped" || $state = "missing")
}

## Returns true once the server answers a DNS query (one try if timeout=0).
:local dnsAnswers do={
    :local ok false
    :local waited 0
    :local limit [:tonum $timeout]
    :while ($ok = false && $waited <= $limit) do={
        :do {
            :resolve $host server=$server
            :set ok true
        } on-error={
            :set waited ($waited + 3)
            :if ($waited <= $limit) do={ :delay 3s }
        }
    }
    :return $ok
}

## Prints container properties and the log command.
:local printContainerDetails do={
    :local items [/container print as-value where name=$containerName]
    :if ([:len $items] > 0) do={
        :foreach k,v in=($items->0) do={
            :put ("      |   |     " . $k . "=" . [:tostr $v])
        }
    }
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

## Converts a RouterOS path to a /file name (no leading slash).
:local filePath do={
    :local p [:tostr $path]
    :if ([:pick $p 0 1] = "/") do={ :set p [:pick $p 1 [:len $p]] }
    :while ([:len $p] > 0 && [:pick $p ([:len $p] - 1)] = "/") do={
        :set p [:pick $p 0 ([:len $p] - 1)]
    }
    :return $p
}

## Returns the /file name for a path: as given, with a leading slash, or any
## file whose name ends with the path below the disk. "" if none.
:local findFile do={
    :local p [:tostr $path]
    :if ([:pick $p 0 1] = "/") do={ :set p [:pick $p 1 [:len $p]] }
    :local ids [/file find where name=$p]
    :if ([:len $ids] = 0) do={ :set ids [/file find where name=("/" . $p)] }
    :if ([:len $ids] = 0) do={
        :local slash [:find $p "/"]
        :if ([:typeof $slash] = "num") do={
            :set ids [/file find where name~([:pick $p ($slash + 1) [:len $p]] . "\$")]
        }
    }
    :if ([:len $ids] = 0) do={ :return "" }
    :return [/file get ($ids->0) name]
}

## Copies a small text file (under 60 KB) and verifies the copy's size.
:local copySmallFile do={
    :local ids [/file find where name=$src]
    :if ([:len $ids] = 0) do={ :set ids [/file find where name=("/" . $src)] }
    :if ([:len $ids] = 0) do={ :return false }
    :local size [/file get ($ids->0) size]
    :if ($size > 60000) do={ :return false }
    :local data [/file get ($ids->0) contents]
    :if ([:len $data] != $size) do={ :return false }
    :local written false
    :do {
        :local oldIds [/file find where name=$dst]
        :if ([:len $oldIds] > 0) do={
            /file set ($oldIds->0) contents=$data
        } else={
            /file add name=$dst contents=$data
        }
        :set written true
    } on-error={ }
    :if ($written = false) do={ :return false }
    :delay 1s
    :local copyIds [/file find where name=$dst]
    :if ([:len $copyIds] = 0) do={ :return false }
    :return ([/file get ($copyIds->0) size] = $size)
}

## Returns the live container of an app (base or base-next), or "". With
## both present, the running one wins, then the one that starts on boot.
:local findLive do={
    :global AghState
    :local candidates [:toarray ""]
    :set candidates ($candidates, $base)
    :set candidates ($candidates, ($base . "-next"))
    :local names [:toarray ""]
    :foreach n in=$candidates do={
        :if ([:len [/container find where name=$n]] > 0) do={ :set names ($names, $n) }
    }
    :if ([:len $names] = 0) do={ :return "" }
    :local chosen ""
    :foreach n in=$names do={
        :if ([:len $chosen] = 0 && [$AghState containerName=$n] = "running") do={ :set chosen $n }
    }
    :foreach n in=$names do={
        :local boot false
        :do { :set boot [/container get [find where name=$n] start-on-boot] } on-error={ }
        :if ([:len $chosen] = 0 && ($boot = true || $boot = "yes")) do={ :set chosen $n }
    }
    :if ([:len $chosen] > 0) do={ :return $chosen }
    :return ($names->0)
}

## Applies the 7.23+ healthcheck without blocking deployment.
:local applyHealthcheck do={
    :local configured false
    :do {
        :local setHealthcheck [:parse $command]
        $setHealthcheck
        :set configured true
        :put "      |   |-- [OK] Native healthcheck configured"
    } on-error={
        :put "      |   |-- [WARNING] RouterOS rejected the healthcheck settings"
        :log warning "mikrotik-adguardhome: native healthcheck configuration failed"
    }
    :return $configured
}

## ========================================
## Header, lock, and version check
## ========================================

:put ""
:put "========================================"
:put ("  AdGuard Home / Pi-hole Deployment v" . $cScriptVersion)
:put "========================================"

## Prevent overlapping runs (for example a scheduler and a manual run).
:global AghLock
:local uptimeNow [/system resource get uptime]
:if ([:typeof $AghLock] = "time") do={
    ## A run takes at most about 15 minutes; an older lock is stale.
    :if (($uptimeNow - $AghLock) < 00:20:00) do={
        :put "  [FAILED] Another run started less than 20 minutes ago and is still active."
        :put "  If that run was interrupted, clear the lock with: :set AghLock \"\""
        :error "Another run is in progress"
    }
}
:set AghLock $uptimeNow

## :global AghApp overrides cApp for this run only.
:global AghApp
:if ([:typeof $AghApp] = "str" && [:len $AghApp] > 0) do={
    :set cApp $AghApp
}
:global AghForce
:local forceSwitch ($AghForce = "yes")
:do { /system script environment remove [find where name="AghApp" or name="AghForce"] } on-error={ }

:set stepNum ($stepNum + 1)
:put ""
:put ("[" . $stepNum . "/" . $stepTotal . "] RouterOS version...")

:local rosVersion [/system resource get version]
:local versionClean $rosVersion
:local spacePos [:find $rosVersion " "]
:if ([:typeof $spacePos] != "nil") do={ :set versionClean [:pick $rosVersion 0 $spacePos] }
:local firstDot [:find $versionClean "."]
:local majorNumber [:tonum [:pick $versionClean 0 $firstDot]]
## Keep only the leading digits so pre-releases such as 7.23rc1 parse as 23.
:local minorDigits ""
:local minorDone false
:for i from=($firstDot + 1) to=([:len $versionClean] - 1) do={
    :local ch [:pick $versionClean $i]
    :if ($minorDone = false && [:typeof [:find "0123456789" $ch]] = "num") do={
        :set minorDigits ($minorDigits . $ch)
    } else={
        :set minorDone true
    }
}
:if ([:len $minorDigits] = 0) do={ :set minorDigits "0" }
:local minorNumber [:tonum $minorDigits]

:put ("      |-- Detected: " . $rosVersion)
:if (!($majorNumber > 7 || ($majorNumber = 7 && $minorNumber >= 22))) do={
    :put "      |-- [FAILED] RouterOS 7.22 or later is required"
    :set AghLock ""
    :log error ("mikrotik-adguardhome: RouterOS " . $rosVersion . " is not supported")
    :error "Version check failed"
}
:if ($majorNumber > 7 || ($majorNumber = 7 && $minorNumber >= 23)) do={
    :set healthcheckSupported true
    :put "      |-- [OK] Supported; native healthchecks available"
} else={
    :put "      |-- [OK] Supported; native healthchecks need 7.23+"
}

## ========================================
## Steps 2-10
## ========================================
## Every failure sets failReason and raises an error, caught at the end of
## this block so the router DNS is always restored.

:do {

    ## ---------- Step 2: Backup ----------
    :set stepNum ($stepNum + 1)
    :set currentStep "Backup"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Configuration backup...")
    :if ([:len $cBackupFile] > 0) do={
        :local backupOk false
        :do {
            /export file=$cBackupFile
            :set backupOk true
        } on-error={ }
        :delay 2s
        :if ($backupOk = false || [:len [/file find where name=($cBackupFile . ".rsc")]] = 0) do={
            :put ("      |-- [FAILED] Could not write " . $cBackupFile . ".rsc; nothing was changed")
            :put "      |-- Check free space with /system resource print, or set cBackupFile \"\""
            :set failReason "Configuration backup failed"
            :error $failReason
        }
        :put ("      |-- [OK] Saved " . $cBackupFile . ".rsc (restore: /import " . $cBackupFile . ".rsc)")
    } else={
        :put "      |-- [SKIPPED] cBackupFile is empty"
    }

    ## Migrate scripts left by earlier versions of this project.
    :do {
        :if ([:len [/system script find where name="dns-filter-restore"]] > 0 && \
            [:len [/system script find where name=$cRestoreScript]] = 0) do={
            /system script set [find where name="dns-filter-restore"] name=$cRestoreScript
        }
        :foreach id in=[/system script find where name="dns-filter"] do={
            :if ([:typeof [:find [/system script get $id source] "maximpri/mikrotik-adguardhome"]] = "num") do={
                /system script remove $id
                :put "      |-- [CLEANUP] Removed the old 'dns-filter' updater script"
            }
        }
    } on-error={ }

    ## ---------- Step 3: Container support and app ----------
    :set stepNum ($stepNum + 1)
    :set currentStep "Container support"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Container support and app...")

    :if ([:len [/system package find where name="container" and disabled=no]] = 0) do={
        :put "      |-- [FAILED] The container package is not installed or is disabled"
        :set failReason "Container package unavailable"
        :error $failReason
    }
    :if ([/system/device-mode get container] != true) do={
        /system/device-mode/update container=yes
        :put "      |-- [ACTION REQUIRED] Press the reset/mode button or cold-reboot to"
        :put "      |   |   confirm container device-mode, then run this script again"
        :set failReason "Physical device-mode confirmation required"
        :error $failReason
    }
    :put "      |-- [OK] Container package and device-mode enabled"

    :local adguardLive [$findLive base="adguardhome"]
    :local piholeLive [$findLive base="pihole"]
    :if ($cApp = "adguardhome") do={ :set cApp "adguard" }
    :if ($cApp = "pi-hole") do={ :set cApp "pihole" }
    :local adguardScore [$appScore containerName=$adguardLive]
    :local piholeScore [$appScore containerName=$piholeLive]
    :if ([:len $cApp] = 0) do={
        ## Keep the installed app: the running one, else the one that starts
        ## on boot. A container kept stopped by an earlier switch never wins.
        :set cApp "adguard"
        :if ([:len $piholeLive] > 0 && ([:len $adguardLive] = 0 || $piholeScore > $adguardScore)) do={
            :set cApp "pihole"
        }
    }

    :local liveName ""
    :local otherLive ""
    :local liveScore 0
    :local otherScore 0
    :if ($cApp = "adguard") do={
        :set appId "adguard"
        :set appTitle "AdGuard Home"
        :set appBase "adguardhome"
        :set appImage $cAdguardImage
        :set appRootDir ($cDefaultStorageMount . "/agh")
        :set appMountList "agh_conf"
        :set appConfSrc ($cConfigStorageMount . "/conf/agh")
        :set appConfDst "/opt/adguardhome/conf"
        :set appWorkSrc ($cDefaultStorageMount . "/work/agh")
        :set appWorkDst "/opt/adguardhome/work"
        :set appEnvList "AGH"
        :set appConfigFile "AdGuardHome.yaml"
        :set appHealthcheckCmd "sh -c 'wget -q --spider http://127.0.0.1:3000 || wget -q --spider http://127.0.0.1:80'"
        :set liveName $adguardLive
        :set otherLive $piholeLive
        :set liveScore $adguardScore
        :set otherScore $piholeScore
    }
    :if ($cApp = "pihole") do={
        :set appId "pihole"
        :set appTitle "Pi-hole"
        :set appBase "pihole"
        :set appImage $cPiholeImage
        :set appRootDir ($cDefaultStorageMount . "/pihole")
        :set appMountList "pihole_conf"
        :set appConfSrc ($cConfigStorageMount . "/conf/pihole")
        :set appConfDst "/etc/pihole"
        :set appEnvList "PIHOLE"
        :set appConfigFile "pihole.toml"
        :set appHealthcheckCmd "sh -c 'dig +short +norecurse +retry=0 @127.0.0.1 pi.hole || exit 1'"
        :set liveName $piholeLive
        :set otherLive $adguardLive
        :set liveScore $piholeScore
        :set otherScore $adguardScore
    }
    :if ([:len $appId] = 0) do={
        :put ("      |-- [FAILED] Unknown app '" . $cApp . "'; use adguard or pihole")
        :set failReason "Unknown app"
        :error $failReason
    }

    ## The container being replaced: this app's live container, or the other
    ## app's when switching. If this app's container was kept stopped by an
    ## earlier switch while the other app serves, this is a switch back.
    :local oldName $liveName
    :local switchingApps false
    :local staleName ""
    :if ([:len $otherLive] > 0) do={
        :if ([:len $liveName] = 0) do={
            :set oldName $otherLive
            :set switchingApps true
        } else={
            :if ($otherScore > $liveScore) do={
                :set staleName $liveName
                :set oldName $otherLive
                :set switchingApps true
            }
        }
    }
    :set servingName $oldName
    :if ($switchingApps = true) do={
        :put ("      |-- App: " . $appTitle . " (switching from '" . $oldName . "')")
    } else={
        :if ([:len $liveName] > 0) do={
            :put ("      |-- App: " . $appTitle . " (installed as '" . $liveName . "')")
        } else={
            :put ("      |-- App: " . $appTitle . " (new install)")
        }
    }

    ## ---------- Step 4: Storage ----------
    :set stepNum ($stepNum + 1)
    :set currentStep "Storage"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Storage...")

    :local diskName [$filePath path=$cDefaultStorageMount]
    :local storageOk false
    :do {
        :if ([:len [/disk find where mount-point=$diskName]] > 0) do={ :set storageOk true }
    } on-error={ }
    :if ($storageOk = false && [:len [/file find where name=$diskName]] > 0) do={
        :set storageOk true
    }
    :if ($storageOk = false) do={
        :put ("      |-- [FAILED] " . $cDefaultStorageMount . " is not mounted. Available:")
        :foreach d in=[/disk find] do={
            :local mp [/disk get $d mount-point]
            :if ([:len $mp] > 0) do={ :put ("      |   |-- /" . $mp) }
        }
        :put "      |-- Fix: Edit cDefaultStorageMount near the top of this script"
        :set failReason ("Storage " . $cDefaultStorageMount . " not found")
        :error $failReason
    }
    :put ("      |-- [OK] " . $cDefaultStorageMount . " is mounted")
    :put ("      |-- Config: " . $appConfSrc)

    ## ---------- Step 5: Router DNS ----------
    :set stepNum ($stepNum + 1)
    :set currentStep "Router DNS"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Router DNS and Docker Hub access...")

    ## The container address comes from the veth when it exists, because the
    ## script keeps custom veth addressing.
    :set containerIp $cContainerAddress
    :local vethIdsForIp [/interface veth find name=$cInterface]
    :if ([:len $vethIdsForIp] > 0) do={
        :local vethAddress [:tostr [/interface veth get ($vethIdsForIp->0) address]]
        :if ([:len $vethAddress] > 0) do={ :set containerIp $vethAddress }
    }
    :foreach sep in={";";",";"/"} do={
        :local sepPos [:find $containerIp $sep]
        :if ([:typeof $sepPos] = "num") do={ :set containerIp [:pick $containerIp 0 $sepPos] }
    }

    :local serversUseContainer false
    :local currentServers [$splitList value=[/ip dns get servers]]
    :local fallbackList [$splitList value=$cFallbackDns]

    ## Settings saved by an earlier run (comment: servers|dohUsed|temp|doh)
    ## are used only while the temporary list it installed is still in place.
    :local currentJoined ""
    :foreach s in=$currentServers do={
        :if ([:len $currentJoined] > 0) do={ :set currentJoined ($currentJoined . ",") }
        :set currentJoined ($currentJoined . $s)
    }
    :local saved ""
    :local savedIds [/system script find where name=$cRestoreScript]
    :if ([:len $savedIds] > 0) do={
        :set saved [:tostr [/system script get ($savedIds->0) comment]]
        :local p1 [:find $saved "|"]
        :local p2
        :local p3
        :if ([:typeof $p1] = "num") do={ :set p2 [:find $saved "|" ($p1 + 1)] }
        :if ([:typeof $p2] = "num") do={ :set p3 [:find $saved "|" ($p2 + 1)] }
        :if ([:typeof $p3] != "num") do={
            :set saved ""
        } else={
            :if ([:pick $saved ($p2 + 1) $p3] != $currentJoined) do={ :set saved "" }
        }
        :if ([:len $saved] = 0) do={
            /system script remove $savedIds
            :put "      |-- [INFO] Discarded stale DNS recovery data"
        } else={
            :set dnsOriginalServers [:pick $saved 0 $p1]
            :set dnsDohUsesContainer ([:pick $saved ($p1 + 1) $p2] = "yes")
            :set dnsOriginalDoh [:pick $saved ($p3 + 1) [:len $saved]]
        }
    }
    :if ([:len $saved] > 0) do={
        :set serversUseContainer true
        :put ("      |-- [INFO] Recovering DNS settings from an interrupted run: " . $dnsOriginalServers)
    } else={
        :foreach s in=$currentServers do={
            :if ([:len $dnsOriginalServers] > 0) do={ :set dnsOriginalServers ($dnsOriginalServers . ",") }
            :set dnsOriginalServers ($dnsOriginalServers . $s)
            :if ($s = $containerIp) do={ :set serversUseContainer true }
        }
        :set dnsOriginalDoh [:tostr [/ip dns get use-doh-server]]
        :if ([:typeof [:find $dnsOriginalDoh ("//" . $containerIp . "/")]] = "num" || \
            [:typeof [:find $dnsOriginalDoh ("//" . $containerIp . ":")]] = "num") do={
            :set dnsDohUsesContainer true
        }
    }

    :if ($serversUseContainer = true || $dnsDohUsesContainer = true) do={
        :put ("      |-- Router DNS resolves through the container (" . $containerIp . ")")
        :if ([:len $fallbackList] = 0) do={
            :put "      |-- [WARNING] cFallbackDns is empty; router DNS stops during a switch"
            :set warningCount ($warningCount + 1)
        } else={
            ## Fallback first, then the other original servers (not the container).
            :local tempServers ""
            :foreach f in=$fallbackList do={
                :if ([:len $tempServers] > 0) do={ :set tempServers ($tempServers . ",") }
                :set tempServers ($tempServers . $f)
            }
            :foreach s in=[$splitList value=$dnsOriginalServers] do={
                :local skip ($s = $containerIp)
                :foreach f in=$fallbackList do={ :if ($f = $s) do={ :set skip true } }
                :if ($skip = false) do={ :set tempServers ($tempServers . "," . $s) }
            }
            :local dohUsedFlag "no"
            :local restoreSource ("/ip dns set servers=\"" . $dnsOriginalServers . "\"")
            :if ($dnsDohUsesContainer = true) do={
                :set dohUsedFlag "yes"
                :set restoreSource ($restoreSource . "; /ip dns set use-doh-server=\"" . $dnsOriginalDoh . "\"")
            }
            :set restoreSource ($restoreSource . "; /ip dns cache flush; /system script remove [find name=\"" . \
                $cRestoreScript . "\"]")
            :do { /system script remove [find where name=$cRestoreScript] } on-error={ }
            /system script add name=$cRestoreScript source=$restoreSource \
                comment=($dnsOriginalServers . "|" . $dohUsedFlag . "|" . $tempServers . "|" . $dnsOriginalDoh)

            /ip dns set servers=$tempServers
            :set dnsFallbackActive true
            :set dnsStatus ("fallback active (" . $tempServers . ")")
            :if ($dnsDohUsesContainer = true) do={ /ip dns set use-doh-server="" }
            /ip dns cache flush
            :put ("      |-- [OK] Temporary router DNS: " . $tempServers)
            :log warning ("mikrotik-adguardhome: router DNS temporarily " . $tempServers . \
                " (original: " . $dnsOriginalServers . ")")
        }
    } else={
        :put "      |-- [OK] Router DNS does not depend on the container"
    }

    :local networkOk false
    :do {
        :resolve $cRegistryHost
        :set networkOk true
    } on-error={ }
    :if ($networkOk = false) do={
        :put ("      |-- [FAILED] Cannot resolve " . $cRegistryHost . "; check /ip dns print")
        :set failReason "Docker Hub is not resolvable"
        :error $failReason
    }
    :put "      |-- [OK] Docker Hub resolves"

    ## ---------- Step 6: Registry ----------
    :set stepNum ($stepNum + 1)
    :set currentStep "Registry configuration"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Registry configuration...")

    :if ([/container config get registry-url] != $cRegistryUrl || \
        [/container config get tmpdir] != $cTmpDir) do={
        /container config set registry-url=$cRegistryUrl tmpdir=$cTmpDir
        :put ("      |-- [OK] Registry " . $cRegistryUrl . ", temp " . $cTmpDir)
    } else={
        :put "      |-- [OK] Already configured"
    }

    ## ---------- Step 7: Mounts ----------
    :set stepNum ($stepNum + 1)
    :set currentStep "Mount points"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Mount points...")

    :local confFound false
    :local confMatches false
    :local workFound false
    :local workMatches false
    :foreach mountId in=[/container mounts find where list=$appMountList] do={
        :local dst [/container mounts get $mountId dst]
        :local src [/container mounts get $mountId src]
        :if ($dst = $appConfDst) do={
            :set confFound true
            :if ($src = $appConfSrc) do={ :set confMatches true }
        }
        :if ([:len $appWorkDst] > 0 && $dst = $appWorkDst) do={
            :set workFound true
            :if ($src = $appWorkSrc) do={ :set workMatches true }
        }
    }
    :if ($confFound = false) do={
        /container mounts add list=$appMountList src=$appConfSrc dst=$appConfDst
        :put ("      |-- [OK] Created config mount " . $appConfSrc . " -> " . $appConfDst)
    } else={
        :if ($confMatches = false) do={
            :put ("      |-- [FAILED] Mount list " . $appMountList . " uses another config source")
            :put ("      |-- Expected: " . $appConfSrc . " -> " . $appConfDst)
            :set failReason "Config mount mismatch"
            :error $failReason
        }
        :put "      |-- [OK] Config mount verified"
    }
    :if ([:len $appWorkDst] > 0) do={
        :if ($workFound = false) do={
            ## Older deployments keep work data (statistics, query log, filter
            ## cache) inside the container. Moving it to storage starts it
            ## empty, so that needs consent; the config file is kept either way.
            :if ([:len $liveName] > 0 && $forceSwitch = false) do={
                :put ("      |-- [STOPPED] '" . $liveName . "' keeps its statistics and query log inside")
                :put "      |   |   the container. Moving them to storage starts them empty. Settings,"
                :put "      |   |   users, rules and filter lists are kept. Nothing was changed."
                :put "      |-- To proceed: :global AghForce \"yes\" and run again"
                :set failReason "Work-data move needs consent (AghForce)"
                :error $failReason
            }
            /container mounts add list=$appMountList src=$appWorkSrc dst=$appWorkDst
            :if ([:len $liveName] > 0) do={ :set workMountAdded true }
            :put ("      |-- [OK] Created work-data mount " . $appWorkSrc . " -> " . $appWorkDst)
        } else={
            :if ($workMatches = false) do={
                :put ("      |-- [FAILED] Work-data mount must be " . $appWorkSrc . " -> " . $appWorkDst)
                :set failReason "Work-data mount mismatch"
                :error $failReason
            }
            :put "      |-- [OK] Work-data mount verified"
        }
    }

    ## ---------- Step 8: Environment ----------
    :set stepNum ($stepNum + 1)
    :set currentStep "Environment variables"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Environment variables...")

    :local envChanged false
    :local envKeys [:toarray ""]
    :local envValues [:toarray ""]
    :if ($appId = "adguard") do={
        :set envKeys ($envKeys, "QUIC_GO_DISABLE_RECEIVE_BUFFER_WARNING")
        :set envValues ($envValues, "true")
    } else={
        ## Answer queries from every network, not just the container subnet.
        :set envKeys ($envKeys, "FTLCONF_dns_listeningMode")
        :set envValues ($envValues, "ALL")
        :local tz [:tostr [/system clock get time-zone-name]]
        :if ([:len $tz] > 0 && $tz != "manual") do={
            :set envKeys ($envKeys, "TZ")
            :set envValues ($envValues, $tz)
        }
        :if ([:len $cPiholePassword] > 0) do={
            :set envKeys ($envKeys, "FTLCONF_webserver_api_password")
            :set envValues ($envValues, $cPiholePassword)
        }
    }
    :for i from=0 to=([:len $envKeys] - 1) do={
        :local key ($envKeys->$i)
        :local value ($envValues->$i)
        :local ids [/container envs find where list=$appEnvList and key=$key]
        :if ([:len $ids] = 0) do={
            /container envs add list=$appEnvList key=$key value=$value
            :do { /container envs set [find where list=$appEnvList and key=$key] comment="pending" } on-error={ }
            :set envChanged true
            :put ("      |-- [OK] Added " . $key)
        } else={
            :if ([/container envs get ($ids->0) value] != $value) do={
                /container envs set ($ids->0) value=$value
                :do { /container envs set ($ids->0) comment="pending" } on-error={ }
                :set envChanged true
                :put ("      |-- [OK] Updated " . $key)
            }
        }
    }
    ## Changes from a run that failed before applying them are still pending.
    :do {
        :if ([:len [/container envs find where list=$appEnvList and comment="pending"]] > 0) do={
            :set envChanged true
        }
    } on-error={ }
    :if ($envChanged = true) do={
        :put "      |-- [INFO] Settings changed; the container will be replaced"
    }
    :put ("      |-- [OK] Envlist '" . $appEnvList . "' verified")

    ## ---------- Step 9: Veth ----------
    :set stepNum ($stepNum + 1)
    :set currentStep "Network interface"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Network interface...")

    :local vethIds [/interface veth find name=$cInterface]
    :if ([:len $vethIds] = 0) do={
        /interface veth add name=$cInterface address=$cContainerAddress gateway=$cContainerGateway
        :put ("      |-- [OK] Created veth '" . $cInterface . "' " . $cContainerAddress)
    } else={
        :local currentAddress [:tostr [/interface veth get ($vethIds->0) address]]
        :local currentGateway [:tostr [/interface veth get ($vethIds->0) gateway]]
        :if ([:len $currentAddress] = 0 && [:len $currentGateway] = 0) do={
            /interface veth set ($vethIds->0) address=$cContainerAddress gateway=$cContainerGateway
            :put ("      |-- [OK] Configured address on '" . $cInterface . "'")
        } else={
            :put ("      |-- [OK] Veth '" . $cInterface . "' " . $currentAddress . " via " . $currentGateway)
        }
    }
    :if ([:len [/interface bridge port find where interface=$cInterface]] = 0) do={
        :put ("      |-- [WARNING] '" . $cInterface . "' is not attached to a bridge (see README)")
        :set warningCount ($warningCount + 1)
    }

    ## ---------- Step 10: Deploy ----------
    :set stepNum ($stepNum + 1)
    :set currentStep "Container deployment"
    :put ("[" . $stepNum . "/" . $stepTotal . "] Container deployment...")
    :put ("      |-- Image: " . $appImage)

    :local newName $appBase
    :local newRoot $appRootDir
    :if ([:len $liveName] > 0) do={
        :if ($liveName = $appBase) do={ :set newName ($appBase . "-next") }
        :local oldRoot [:tostr [/container get [find where name=$liveName] root-dir]]
        :if ([:len $oldRoot] = 0) do={ :set oldRoot $appRootDir }
        :while ([:len $oldRoot] > 1 && [:pick $oldRoot ([:len $oldRoot] - 1)] = "/") do={
            :set oldRoot [:pick $oldRoot 0 ([:len $oldRoot] - 1)]
        }
        :if ([:len $oldRoot] > 5 && [:pick $oldRoot ([:len $oldRoot] - 5) [:len $oldRoot]] = "-next") do={
            :set newRoot [:pick $oldRoot 0 ([:len $oldRoot] - 5)]
        } else={
            :set newRoot ($oldRoot . "-next")
        }
    }

    ## Remove leftovers from an interrupted run: a non-live container with the
    ## new name, and an unused directory at the new root.
    :if ([:len [/container find where name=$newName]] > 0 && $newName != $oldName) do={
        $stopContainer containerName=$newName timeout=$cStopTimeout
        /container remove [find where name=$newName]
        :put ("      |-- [CLEANUP] Removed leftover container '" . $newName . "'")
    }
    :local newRootFile [$filePath path=$newRoot]
    ## The new root must not overlap any container root or mount source.
    :local usedPaths [:toarray ""]
    :foreach c in=[/container find] do={
        :set usedPaths ($usedPaths, [$filePath path=[/container get $c root-dir]])
    }
    :foreach m in=[/container mounts find] do={
        :set usedPaths ($usedPaths, [$filePath path=[/container mounts get $m src]])
    }
    :local rootInUse false
    :foreach p in=$usedPaths do={
        :if ([:len $p] > 0) do={
            :if ($p = $newRootFile || [:pick $p 0 ([:len $newRootFile] + 1)] = ($newRootFile . "/") || \
                [:pick $newRootFile 0 ([:len $p] + 1)] = ($p . "/")) do={
                :set rootInUse true
            }
        }
    }
    :if ($rootInUse = true) do={
        :put ("      |-- [FAILED] " . $newRoot . " overlaps a container root or mount")
        :set failReason "Root directory in use"
        :error $failReason
    }
    :if ([:len [/file find where name=$newRootFile]] > 0) do={
        :do {
            /file remove [find where name=$newRootFile]
            :put ("      |-- [CLEANUP] Removed unused " . $newRoot)
        } on-error={
            :put ("      |-- [WARNING] Could not remove unused " . $newRoot)
            :set warningCount ($warningCount + 1)
        }
    }

    ## Same app: skip the download when the registry digest matches the one
    ## recorded at the last successful run (in the updater's comment).
    :local remote ""
    :local upToDate false
    :if ([:len $liveName] > 0 && $switchingApps = false && $envChanged = false && \
        $workMountAdded = false && [:len $cUpdaterName] > 0) do={
        :set remote [$remoteDigest image=$appImage]
        :local updaterIds [/system script find where name=$cUpdaterName]
        :if ([:len $remote] > 0 && [:len $updaterIds] > 0) do={
            :set upToDate ([/system script get ($updaterIds->0) comment] = ($appId . " " . $remote))
        }
        ## A live container that is not running is replaced even if current.
        :if ($upToDate = true && [$AghState containerName=$liveName] != "running") do={
            :set upToDate false
        }
    } else={
        :set remote [$remoteDigest image=$appImage]
    }

    :if ($upToDate = true) do={
        :set deployedImage ($appId . " " . $remote)
        :put ("      |-- [OK] Already up to date; nothing downloaded, '" . $liveName . "' not restarted")
        :set resultText "UP TO DATE"
    } else={
        :local bootFlag "no"
        :if ([:len $oldName] = 0) do={ :set bootFlag "yes" }
        :if ([:len $oldName] > 0) do={
            :put ("      |-- Pulling into '" . $newName . "'; '" . $oldName . "' keeps serving DNS")
        } else={
            :put ("      |-- Pulling into '" . $newName . "'")
        }
        :do {
            :if ($appId = "adguard") do={
                /container add remote-image=$appImage check-certificate=yes name=$newName \
                    interface=$cInterface logging=yes mountlists=$appMountList start-on-boot=$bootFlag \
                    root-dir=$newRoot workdir="/opt/adguardhome/work" envlist=$appEnvList \
                    cmd="-c /opt/adguardhome/conf/AdGuardHome.yaml -h 0.0.0.0 -w /opt/adguardhome/work" \
                    entrypoint=/opt/adguardhome/AdGuardHome
            } else={
                /container add remote-image=$appImage check-certificate=yes name=$newName \
                    interface=$cInterface logging=yes mountlists=$appMountList start-on-boot=$bootFlag \
                    root-dir=$newRoot envlist=$appEnvList
            }
        } on-error={
            :put "      |   |-- [FAILED] RouterOS rejected the container (disk space? /container log)"
            :set failReason "Container creation rejected"
            :error $failReason
        }

        :local pullState [$waitForExtraction containerName=$newName timeout=$cPullTimeout \
            poll=$cPollSeconds progress=$cProgressSeconds]
        :if ($pullState != "stopped" && $pullState != "running") do={
            :put ("      |   |-- [FAILED] Image pull ended in state: " . $pullState)
            $printContainerDetails containerName=$newName
            :do { /container remove [find where name=$newName] } on-error={ }
            :if ([:len $oldName] > 0) do={
                :put ("      |   |-- '" . $oldName . "' was not touched and keeps running")
            }
            :set failReason ("Image pull failed (" . $pullState . "); increase cPullTimeout if slow")
            :error $failReason
        }
        :put "      |   |-- [OK] Image extracted"
        :if ($healthcheckSupported = true) do={
            :set healthcheckConfigured [$applyHealthcheck command=("/container set [find name=\"" . \
                $newName . "\"] healthcheck-cmd=\"" . $appHealthcheckCmd . "\" healthcheck-interval=" . \
                $cHealthcheckInterval . " healthcheck-timeout=" . $cHealthcheckTimeout . \
                " healthcheck-start-period=" . $cHealthcheckStartPeriod . " healthcheck-retries=" . \
                $cHealthcheckRetries)]
        }

        ## The new container must answer DNS if the old one did (Pi-hole
        ## always must). The probe is retried so a brief upstream hiccup does
        ## not lower the bar. A fresh Pi-hole may build its blocklists first.
        :local oldAnswered false
        :local requireDns false
        :local dnsWait $cDnsReadyTimeout
        :local configBackup ""
        :local confFile [$findFile path=([$filePath path=$appConfSrc] . "/" . $appConfigFile)]
        :local hasConfig ([:len $confFile] > 0)
        :if ([:len $oldName] > 0) do={
            :if ([$AghState containerName=$oldName] = "running") do={
                :set oldAnswered [$dnsAnswers host=$cDnsTestHost server=$containerIp timeout=15]
            }
            :set requireDns $oldAnswered
            :if ($appId = "pihole") do={ :set requireDns true }
            :if ($appId = "pihole" && $hasConfig = false) do={ :set dnsWait ($cDnsReadyTimeout * 3) }
            ## A fresh AdGuard Home answers DNS only after its setup wizard, so
            ## replacing a working resolver with it needs explicit consent.
            :if ($appId = "adguard" && $switchingApps = true && $hasConfig = false && \
                $oldAnswered = true) do={
                :if ($forceSwitch = false) do={
                    :put "      |-- [STOPPED] AdGuard Home has no config yet and would not answer DNS"
                    :put ("      |   |   until its setup wizard is done. '" . $oldName . "' keeps running.")
                    :put "      |-- To switch anyway: :global AghForce \"yes\" and run again"
                    :do { /container remove [find where name=$newName] } on-error={ }
                    :set failReason "Switch needs AdGuard Home setup (or AghForce)"
                    :error $failReason
                }
                :set requireDns false
                :put "      |-- [INFO] Forced: DNS is down until the AdGuard Home setup wizard is done"
            }
            :if ($switchingApps = false) do={
                ## Upgrades may migrate the config to a format the old version
                ## cannot read, so keep a copy for rollback.
                :local ok false
                :if ($hasConfig = true) do={
                    :do { :set ok [$copySmallFile src=$confFile dst=($confFile . ".rollback")] } on-error={ }
                }
                :if ($ok = true) do={
                    :set configBackup ($confFile . ".rollback")
                    :put ("      |-- [OK] Config backed up to " . $configBackup)
                } else={
                    :put "      |-- [INFO] Config backup unavailable; rollback reuses the current file"
                }
            }
            :put ("      |-- Switching '" . $oldName . "' -> '" . $newName . "'...")
            :if ([$stopContainer containerName=$oldName timeout=$cStopTimeout] = false) do={
                :put ("      |   |-- [FAILED] '" . $oldName . "' did not stop in time; switch cancelled")
                :if ([$startContainer containerName=$oldName timeout=$cStartTimeout] = true) do={
                    :put ("      |   |-- [OK] '" . $oldName . "' is running")
                } else={
                    :put ("      |   |-- [CRITICAL] '" . $oldName . "' is not running; check /container print")
                }
                :do { /container remove [find where name=$newName] } on-error={ }
                :set failReason "Old container did not stop"
                :error $failReason
            }
        }

        ## Start and verify the new container; any failure rolls back below.
        :local switchOk false
        :do {
            :if ([$startContainer containerName=$newName timeout=$cStartTimeout] = false) do={
                :set failReason "New container did not start"
                :error $failReason
            }
            :put ("      |   |-- [OK] Started; checking stability (" . $cStabilitySeconds . "s)...")
            :delay [:totime ($cStabilitySeconds . "s")]
            :if ([$AghState containerName=$newName] != "running") do={
                :set failReason "New container stopped after starting"
                :error $failReason
            }
            :if ($requireDns = true) do={
                :put "      |   |-- Waiting for DNS answers..."
                :if ([$dnsAnswers host=$cDnsTestHost server=$containerIp timeout=$dnsWait] = false) do={
                    :set failReason "New container does not answer DNS"
                    :error $failReason
                }
                :put ("      |   |-- [OK] Answers DNS at " . $containerIp)
            }
            :set switchOk true
        } on-error={ }

        :if ($switchOk = false) do={
            :put ("      |   |-- [FAILED] " . $failReason)
            $printContainerDetails containerName=$newName
            :if ([:len $oldName] = 0) do={ :error $failReason }

            ## Rollback: stop the new container and bring the old one back.
            :put ("      |-- Rolling back to '" . $oldName . "'...")
            :if ([$stopContainer containerName=$newName timeout=$cStopTimeout] = false) do={
                :put ("      |   |-- [WARNING] '" . $newName . "' did not confirm it stopped")
            }
            ## The new version may have migrated the config; restore it first.
            :if ([:len $configBackup] > 0) do={
                :local copied false
                :do { :set copied [$copySmallFile src=$configBackup dst=$confFile] } on-error={ }
                :if ($copied = true) do={
                    :put "      |   |-- [OK] Config restored from backup"
                } else={
                    :put "      |   |-- [WARNING] Could not restore the config backup"
                    :set warningCount ($warningCount + 1)
                }
            }
            :if ($workMountAdded = true) do={
                :do {
                    /container mounts remove [find where list=$appMountList and dst=$appWorkDst]
                    :set workMountAdded false
                } on-error={ }
            }
            ## The rollback passes only the checks the old container passed before.
            :local restored [$startContainer containerName=$oldName timeout=$cStartTimeout]
            :if ($restored = true) do={
                :delay [:totime ($cStabilitySeconds . "s")]
                :set restored ([$AghState containerName=$oldName] = "running")
            }
            :if ($restored = true && $oldAnswered = true) do={
                :set restored [$dnsAnswers host=$cDnsTestHost server=$containerIp timeout=$cDnsReadyTimeout]
            }
            :if ($restored = true) do={
                :do { /container remove [find where name=$newName] } on-error={ }
                :put ("      |   |-- [OK] Rolled back; '" . $oldName . "' is running again")
                :set resultText "ROLLED BACK"
                :set failReason ($failReason . "; previous version restored")
            } else={
                :put ("      |   |-- [CRITICAL] '" . $oldName . "' did not pass its checks either")
                :put ("      |   |-- Both containers were kept: '" . $oldName . "', '" . $newName . "'")
                :set failReason ($failReason . "; rollback failed")
            }
            :error $failReason
        }

        ## Success: make the new container permanent.
        :set servingName $newName
        :if ([:len $remote] > 0) do={ :set deployedImage ($appId . " " . $remote) }
        :do { /container set [find where name=$newName] start-on-boot=yes } on-error={ }
        :if ([:len $oldName] > 0) do={
            :if ($switchingApps = true) do={
                ## Keep the previous app's container stopped for manual fallback.
                :do { /container set [find where name=$oldName] start-on-boot=no } on-error={ }
                :put ("      |-- [OK] '" . $oldName . "' kept stopped; remove it with:")
                :put ("      |   |-- /container remove [find name=" . $oldName . "]")
                :if ([:len $staleName] > 0) do={
                    :do {
                        /container remove [find where name=$staleName]
                        :put ("      |-- [OK] Removed the earlier stopped '" . $staleName . "'")
                    } on-error={ }
                }
                :set resultText ("SWITCHED TO " . $appTitle)
            } else={
                :do {
                    /container remove [find where name=$oldName]
                    :put ("      |-- [OK] Removed previous container '" . $oldName . "'")
                } on-error={
                    :put ("      |-- [WARNING] Could not remove '" . $oldName . "'")
                    :set warningCount ($warningCount + 1)
                }
                :set resultText "UPGRADED"
            }
            :if ([:len $configBackup] > 0) do={
                :do { /file remove [find where name=$configBackup] } on-error={ }
            }
        } else={
            :set resultText "INSTALLED"
        }
        ## Only one app may serve the shared address: stop the other app's
        ## container and keep it from starting on boot.
        :if ([:len $otherLive] > 0 && $otherLive != $oldName && \
            [$appScore containerName=$otherLive] > 0) do={
            $stopContainer containerName=$otherLive timeout=$cStopTimeout
            :do { /container set [find where name=$otherLive] start-on-boot=no } on-error={ }
            :put ("      |-- [OK] '" . $otherLive . "' stopped and disabled on boot")
        }
        :do {
            /container envs set [find where list=$appEnvList and comment="pending"] comment=""
        } on-error={ }
        ## Keep the familiar name when it is free.
        :if ($newName != $appBase && [:len [/container find where name=$appBase]] = 0) do={
            :do {
                /container set [find where name=$newName] name=$appBase
                :set servingName $appBase
            } on-error={ }
        }
    }

} on-error={
    :set deploymentSuccess false
    :if ($workMountAdded = true) do={
        :do { /container mounts remove [find where list=$appMountList and dst=$appWorkDst] } on-error={ }
    }
    :if ([:len $failReason] = 0) do={
        :set failReason ("Unexpected RouterOS error during: " . $currentStep)
    }
}

## ========================================
## Restore router DNS
## ========================================
## Restores the original settings once the serving container answers;
## otherwise the fallback stays so the router keeps working DNS.

:if ($dnsFallbackActive = true) do={
    :put "[DNS] Restoring router DNS..."
    :local answers false
    :if ([:len $servingName] > 0 && [$AghState containerName=$servingName] = "running") do={
        :set answers [$dnsAnswers host=$cDnsTestHost server=$containerIp timeout=$cDnsReadyTimeout]
    }
    :local restoredOk false
    :if ($answers = true) do={
        :do {
            /ip dns set servers=$dnsOriginalServers
            :if ($dnsDohUsesContainer = true) do={ /ip dns set use-doh-server=$dnsOriginalDoh }
            /ip dns cache flush
            :do { /system script remove [find where name=$cRestoreScript] } on-error={ }
            :set restoredOk true
        } on-error={
            :put "      |-- [WARNING] RouterOS rejected the original DNS settings"
        }
    }
    :if ($restoredOk = true) do={
        :set dnsStatus ("restored (" . $dnsOriginalServers . ")")
        :put ("      |-- [OK] Restored " . $dnsOriginalServers . " and flushed the cache")
        :log info "mikrotik-adguardhome: router DNS restored"
    } else={
        :put ("      |-- [WARNING] Keeping the fallback; " . $containerIp . " is not answering DNS")
        :put ("      |-- Original servers: " . $dnsOriginalServers)
        :put "      |-- Run this script again once it answers, or restore manually with:"
        :put ("      |   |-- /system script run " . $cRestoreScript)
        :set warningCount ($warningCount + 1)
        :log warning ("mikrotik-adguardhome: fallback DNS kept; original servers: " . $dnsOriginalServers)
    }
}

:set AghLock ""

## ========================================
## Summary
## ========================================

:if ($deploymentSuccess = false && $resultText != "ROLLED BACK") do={ :set resultText "FAILED" }
:local finalState "none"
:if ([:len $servingName] > 0) do={ :set finalState [$AghState containerName=$servingName] }
:local healthcheckSummary "needs RouterOS 7.23+"
:if ($healthcheckSupported = true) do={
    :set healthcheckSummary "unchanged"
    :if ($healthcheckConfigured = true) do={ :set healthcheckSummary "configured" }
}
:if ([:len $containerIp] = 0) do={ :set containerIp $cContainerAddress }
:if ([:len $appTitle] = 0) do={ :set appTitle "AdGuard Home / Pi-hole" }

:put ""
:put "========================================"
:if ($warningCount > 0 && $deploymentSuccess = true) do={
    :put ("  " . $resultText . " (" . $warningCount . " warning(s))")
} else={
    :put ("  " . $resultText)
}
:put "========================================"
:if ($deploymentSuccess = false) do={ :put ("  Reason:      " . $failReason) }
:put ("  App:         " . $appTitle)
:put ("  Container:   " . $servingName . " (" . $finalState . ")")
:put ("  Address:     " . $containerIp)
:put ("  Router DNS:  " . $dnsStatus)
:put ("  Healthcheck: " . $healthcheckSummary)
:if ($deploymentSuccess = true) do={
    :if ($appId = "pihole") do={
        :put ("  Web UI:      http://" . $containerIp . "/admin")
        :if ($resultText != "UP TO DATE" && [:len $cPiholePassword] = 0) do={
            :put ("  Password:    first install: see /container log " . $servingName)
        }
    } else={
        :if ($resultText = "INSTALLED" || $resultText = "SWITCHED TO AdGuard Home") do={
            :put ("  Web UI:      http://" . $containerIp . ":3000 (setup wizard on first run)")
        } else={
            :put ("  Web UI:      http://" . $containerIp)
        }
    }
    ## Record the deployed image on the loader for the next up-to-date check.
    :local updaterIds [/system script find where name=$cUpdaterName]
    :if ([:len $updaterIds] > 0) do={
        :if ([:len $deployedImage] > 0) do={
            :do { /system script set ($updaterIds->0) comment=$deployedImage } on-error={ }
        }
        :put ("  Next time:   /system script run " . $cUpdaterName)
    }
    :log info ("mikrotik-adguardhome: " . $resultText . " " . $appTitle)
} else={
    :put "  Check:       /container print detail; /ip dns print"
    :if ([:len $cBackupFile] > 0) do={
        :put ("  Backup:      " . $cBackupFile . ".rsc")
    }
    :log error ("mikrotik-adguardhome: " . $resultText . ": " . $failReason)
}
:put "========================================"
:put ""

:do { /system script environment remove [find where name="AghState"] } on-error={ }
:if ($deploymentSuccess = false) do={
    :error ($resultText . ": " . $failReason)
}

}
#SCRIPT-COMPLETE
