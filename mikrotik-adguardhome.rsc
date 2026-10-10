# ============================================================================
# mikrotik-adguardhome loader: AdGuard Home / Pi-hole for MikroTik RouterOS
# ============================================================================
# Version: 2.2.0
# Install and run (RouterOS terminal):
#   :local s [:parse ([/tool fetch url="https://raw.githubusercontent.com/maximpri/mikrotik-adguardhome/latest/mikrotik-adguardhome.rsc" output=user as-value]->"data")]; $s
# Afterwards:
#   /system script run mikrotik-adguardhome
#
# Each run, the loader:
#   1. Reads settings from /system script mikrotik-adguardhome-settings,
#      creating it on first use (and carrying over settings from earlier
#      versions of the loader).
#   2. Rewrites /system script mikrotik-adguardhome as a short stub that runs
#      the latest loader, so an old or broken copy never matters. The stub
#      switches to the fallback DNS if the router cannot resolve names.
#   3. Downloads adguardhome_script.rsc, pinned to one commit when GitHub
#      can resolve it, to a temporary file and imports it with those
#      settings. The script is one { } block, so a truncated download fails
#      to parse and nothing runs.
# ============================================================================
{

:local repo "maximpri/mikrotik-adguardhome"
## Git tag (or branch) to run. "latest" is moved to each published version.
:local ref "latest"
:local file "adguardhome_script.rsc"
:local name "mikrotik-adguardhome"
:local settingsName ($name . "-settings")
:local tmpFile ($name . "-download.rsc")

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
:put "mikrotik-adguardhome loader v2.2.0"

## Clear state left by earlier loader versions.
:do {
    /system script environment remove [find where name~"^(DnsFilter|AGHDnsRestore|AghDelegated|AghSettings)"]
} on-error={ }

## 1. Capture any existing copy of the loader script; an earlier version kept
##    the settings in its own source.
:local scriptIds [/system script find where name=$name]
:local oldSource ""
:if ([:len $scriptIds] > 0) do={
    :set oldSource [:tostr [/system script get ($scriptIds->0) source]]
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

## 3. Stub: runs the latest loader. If the router cannot resolve names (its
##    DNS server is the container and the container is down, as on a RAM
##    disk after a reboot), it switches to the fallback DNS first and saves
##    the original settings where the deployment script restores them.
##    The comment, which records the deployed image, is kept.
:local fb ""
:local item ""
:local raw [:tostr ($settings->"fallbackDns")]
:for i from=0 to=[:len $raw] do={
    :local ch ""
    :if ($i < [:len $raw]) do={ :set ch [:pick $raw $i] }
    :if ($i = [:len $raw] || $ch = "," || $ch = ";") do={
        :if ([:len $item] > 0) do={
            :if ([:len $fb] > 0) do={ :set fb ($fb . ",") }
            :set fb ($fb . $item)
        }
        :set item ""
    } else={
        :if ($ch != " ") do={ :set item ($item . $ch) }
    }
}
:local loaderUrl ("https://raw.githubusercontent.com/" . $repo . "/" . $ref . "/" . $name . ".rsc")
:local stub ( \
    "# mikrotik-adguardhome: runs the latest loader. The loader rewrites this\r\n" . \
    "# script on every run; change settings in mikrotik-adguardhome-settings.\r\n" . \
    ":if ([:len \"" . $fb . "\"] > 0) do={\r\n" . \
    "    :do { :resolve raw.githubusercontent.com } on-error={\r\n" . \
    "        ## The router cannot resolve, for example because its DNS server is\r\n" . \
    "        ## the container and the container is down. Save the DNS settings\r\n" . \
    "        ## for the deployment script to restore, then use the fallback.\r\n" . \
    "        :local r \"mikrotik-adguardhome-restore\"\r\n" . \
    "        :if ([:len [/system script find where name=\$r]] = 0) do={\r\n" . \
    "            :local o \"\"\r\n" . \
    "            :foreach x in=[/ip dns get servers] do={\r\n" . \
    "                :if ([:len \$o] > 0) do={ :set o (\$o . \",\") }\r\n" . \
    "                :set o (\$o . [:tostr \$x])\r\n" . \
    "            }\r\n" . \
    "            :local d [:tostr [/ip dns get use-doh-server]]\r\n" . \
    "            :local u \"no\"\r\n" . \
    "            :local c (\"/ip dns set servers=\\\"\" . \$o . \"\\\"\")\r\n" . \
    "            :if ([:len \$d] > 0) do={\r\n" . \
    "                :set u \"yes\"\r\n" . \
    "                :set c (\$c . \"; /ip dns set use-doh-server=\\\"\" . \$d . \"\\\"\")\r\n" . \
    "            }\r\n" . \
    "            /system script add name=\$r comment=(\$o . \"|\" . \$u . \"|" . $fb . "|\" . \$d) source=(\$c . \\\r\n" . \
    "                \"; /ip dns cache flush; /system script remove [find name=\\\"\" . \$r . \"\\\"]\")\r\n" . \
    "        }\r\n" . \
    "        /ip dns set servers=\"" . $fb . "\" use-doh-server=\"\"\r\n" . \
    "        /ip dns cache flush\r\n" . \
    "        :put \"mikrotik-adguardhome: router DNS is not answering; using " . $fb . " to download\"\r\n" . \
    "    }\r\n" . \
    "}\r\n" . \
    ":local s [:parse ([/tool fetch url=\"" . $loaderUrl . "\" output=user as-value]->\"data\")]; \$s\r\n")
:if ([:len $scriptIds] > 0) do={
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

## 4. Pin the download to one commit, so no stale cached copy is used. Plain
##    request: RouterOS fetch may reject custom headers or partial responses.
:local commit $ref
:do {
    :local r ([/tool fetch output=user as-value url=("https://api.github.com/repos/" . $repo . \
        "/commits/" . $ref)]->"data")
    ## The value follows "sha": with or without a space.
    :local p [:find $r "\"sha\""]
    :if ([:typeof $p] = "num") do={
        :local rest [:pick $r ($p + 5) ($p + 60)]
        :local q [:find $rest "\""]
        :if ([:typeof $q] = "num") do={
            :local c [:pick $rest ($q + 1) ($q + 41)]
            :if ([:len $c] = 40) do={ :set commit $c }
        }
    }
} on-error={ }
:if ($commit = $ref) do={
    :put ("  [INFO] Using '" . $ref . "' (GitHub did not report its commit)")
}
:local url ("https://raw.githubusercontent.com/" . $repo . "/" . $commit . "/" . $file)

## Download to a file (a single in-memory fetch holds at most 63 KiB).
:do { /file remove [find where name=$tmpFile] } on-error={ }
:local fetched false
:do {
    :local r [/tool fetch url=$url dst-path=$tmpFile as-value]
    :if (($r->"status") = "finished") do={ :set fetched true }
} on-error={ }
:delay 1s
:local fileIds [/file find where name=$tmpFile]
:if ($fetched = false || [:len $fileIds] = 0) do={
    :do { /file remove [find where name=$tmpFile] } on-error={ }
    :error ("mikrotik-adguardhome: cannot download " . $url)
}
:put ("  [OK] " . $file . " @ " . [:pick $commit 0 12] . " (" . [/file get ($fileIds->0) size] . " bytes)")

## Run the deployment script with the settings, then remove the download.
:set ($settings->"updater") $name
:global AghOptions $settings
:local failed false
:do {
    /import file-name=$tmpFile verbose=no
} on-error={
    :set failed true
}
:do { /file remove [find where name=$tmpFile] } on-error={ }
:if ($failed = true) do={
    :error "mikrotik-adguardhome: stopped; see the summary above"
}

}
#SCRIPT-COMPLETE
