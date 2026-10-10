# ============================================================================
# mikrotik-adguardhome loader: AdGuard Home / Pi-hole for MikroTik RouterOS
# ============================================================================
# Install and run (RouterOS terminal):
#   :local s [:parse ([/tool fetch url="https://raw.githubusercontent.com/maximpri/mikrotik-adguardhome/main/mikrotik-adguardhome.rsc" output=user as-value]->"data")]; $s
# Afterwards:
#   /system script run mikrotik-adguardhome
#
# Each run, the loader:
#   1. Rewrites /system script mikrotik-adguardhome as a short stub that runs
#      the latest loader, so an old or broken copy never matters.
#   2. Reads settings from /system script mikrotik-adguardhome-settings,
#      creating it on first use (and carrying over settings from earlier
#      versions of the loader).
#   3. Downloads adguardhome_script.rsc pinned to one commit, in ranges,
#      verifies it is complete, and runs it with those settings.
# ============================================================================
{

:local repo "maximpri/mikrotik-adguardhome"
:local ref "agent/safe-upgrade-pihole"
:local file "adguardhome_script.rsc"
:local name "mikrotik-adguardhome"
:local settingsName ($name . "-settings")
:local chunk 60000
## Built from two parts so that only a file's last line contains it.
:local marker ("#SCRIPT-" . "COMPLETE")

## Default settings; the settings script overrides them.
:local keys {"app";"storage";"configStorage";"address";"gateway";"fallbackDns";"piholePassword";"adguardImage";"piholeImage"}
:local settings [:toarray ""]
:set ($settings->"app") ""
:set ($settings->"storage") "/usb1"
:set ($settings->"configStorage") ""
:set ($settings->"address") "172.17.0.2/24"
:set ($settings->"gateway") "172.17.0.1"
:set ($settings->"fallbackDns") "1.1.1.1"
:set ($settings->"piholePassword") ""
:set ($settings->"adguardImage") "adguard/adguardhome:latest"
:set ($settings->"piholeImage") "pihole/pihole:latest"

## Escapes a value for a double-quoted RouterOS string.
:local quote do={
    :local out ""
    :local text [:tostr $value]
    :if ([:len $text] = 0) do={ :return "" }
    :for i from=0 to=([:len $text] - 1) do={
        :local ch [:pick $text $i]
        :if ($ch = "\"" || $ch = "\\" || $ch = "\$") do={ :set out ($out . "\\") }
        :set out ($out . $ch)
    }
    :return $out
}

## Returns the quoted value of ':local <key> "..."' in a script, or nothing.
:local readLocal do={
    :local pattern (":local " . $key . " \"")
    :local start [:find $source $pattern]
    :if ([:typeof $start] != "num") do={ :return [:nothing] }
    :local rest [:pick $source ($start + [:len $pattern]) [:len $source]]
    :local end [:find $rest "\""]
    :if ([:typeof $end] != "num") do={ :return [:nothing] }
    :if ($end = 0) do={ :return "" }
    :return [:pick $rest 0 $end]
}

:put ""
:put "mikrotik-adguardhome loader"

## Clear state left by earlier loader versions.
:do {
    /system script environment remove [find where name~"^(DnsFilter|AGHDnsRestore|AghDelegated|AghSettings)"]
} on-error={ }

## 1. Stub: always run the latest loader. Keep the comment, which records
##    the deployed image for the up-to-date check.
:local stub (":local s [:parse ([/tool fetch url=\"https://raw.githubusercontent.com/" . $repo . "/" . \
    $ref . "/" . $name . ".rsc\" output=user as-value]->\"data\")]; \$s")
:local scriptIds [/system script find where name=$name]
:local oldSource ""
:if ([:len $scriptIds] > 0) do={
    :set oldSource [:tostr [/system script get ($scriptIds->0) source]]
    :if ($oldSource != $stub) do={
        /system script set ($scriptIds->0) source=$stub
        :put "  [OK] Updated /system script mikrotik-adguardhome"
    }
    ## A hand-made script may lack the permissions later runs need.
    :do {
        /system script set ($scriptIds->0) policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon
    } on-error={
        :put "  [WARNING] Could not set full permissions on /system script mikrotik-adguardhome"
    }
} else={
    /system script add name=$name source=$stub
    :put "  [OK] Installed /system script mikrotik-adguardhome"
}

## 2. Settings: create the settings script on first use, carrying over values
##    from an earlier loader that kept them in its own source.
:local settingsIds [/system script find where name=$settingsName]
:if ([:len $settingsIds] = 0) do={
    :local source ("# mikrotik-adguardhome settings. Change the values in quotes, then run:\r\n" . \
        "#   /system script run mikrotik-adguardhome\r\n" . \
        "# app: adguard, pihole, or empty to keep the installed app.\r\n" . \
        ":global AghSettings [:toarray \"\"]\r\n")
    :foreach k in=$keys do={
        :local value ($settings->$k)
        :local carried [$readLocal source=$oldSource key=$k]
        :if ([:typeof $carried] = "str") do={ :set value $carried }
        :set source ($source . ":set (\$AghSettings->\"" . $k . "\") \"" . [$quote value=$value] . "\"\r\n")
    }
    /system script add name=$settingsName source=$source
    :put "  [OK] Created /system script mikrotik-adguardhome-settings"
    :set settingsIds [/system script find where name=$settingsName]
}
:global AghSettings
:do {
    :local apply [:parse [/system script get ($settingsIds->0) source]]
    $apply
} on-error={
    :error "mikrotik-adguardhome: the settings script has an error; fix it in System > Scripts"
}
:if ([:typeof $AghSettings] = "array") do={
    :foreach k in=$keys do={
        :if ([:typeof ($AghSettings->$k)] = "str") do={ :set ($settings->$k) ($AghSettings->$k) }
    }
}
:do { /system script environment remove [find where name="AghSettings"] } on-error={ }

## 3. Pin the download to one commit, so all ranges come from the same
##    version and no stale cached copy is used.
:local commit $ref
:do {
    :local r ([/tool fetch output=user as-value url=("https://api.github.com/repos/" . $repo . \
        "/commits/" . $ref) http-header-field="User-Agent: RouterOS,Accept: application/vnd.github.sha"]->"data")
    :if ([:len $r] = 40) do={ :set commit $r }
} on-error={
    :put ("  [INFO] Could not resolve '" . $ref . "' to a commit; using the branch")
}
:local url ("https://raw.githubusercontent.com/" . $repo . "/" . $commit . "/" . $file)

## A single fetch holds at most 63 KiB, so download in ranges.
:local code ""
:local offset 0
:local more true
:while ($more = true) do={
    :local part ""
    :local got false
    :do {
        :set part ([/tool fetch output=user as-value url=$url \
            http-header-field=("Range: bytes=" . $offset . "-" . ($offset + $chunk - 1))]->"data")
        :set got true
    } on-error={ }
    :if ($got = false) do={
        ## A range past the end of the file is refused: the download is done.
        :if ($offset = 0) do={ :error ("mikrotik-adguardhome: cannot download " . $file) }
        :set more false
    } else={
        :if ([:len $part] > $chunk) do={
            ## The server sent the whole file instead of a range.
            :set code $part
            :set more false
        } else={
            :set code ($code . $part)
            :set offset ($offset + $chunk)
            :if ([:len $part] < $chunk || $offset > 2000000) do={ :set more false }
        }
    }
}
:if ([:typeof [:find $code $marker]] != "num") do={
    :error "mikrotik-adguardhome: download incomplete; nothing was changed"
}
:put ("  [OK] " . $file . " @ " . [:pick $commit 0 12] . " (" . [:len $code] . " bytes)")

## Run the deployment script with the settings.
:set ($settings->"updater") $name
:global AghOptions $settings
:local main [:parse $code]
$main

}
#SCRIPT-COMPLETE
