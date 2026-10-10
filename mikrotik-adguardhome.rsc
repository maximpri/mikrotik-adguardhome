# ============================================================================
# mikrotik-adguardhome loader: AdGuard Home / Pi-hole for MikroTik RouterOS
# ============================================================================
# Install and run (RouterOS terminal):
#   :local s [:parse ([/tool fetch url="https://raw.githubusercontent.com/maximpri/mikrotik-adguardhome/main/mikrotik-adguardhome.rsc" output=user as-value]->"data")]; $s
#
# The first run installs this loader as /system script "mikrotik-adguardhome". After
# that, run:  /system script run mikrotik-adguardhome
#
# Each run downloads the current deployment script from GitHub, pinned to one
# commit, verifies it is complete, and runs it with the settings below. To
# change settings, edit them in System > Scripts > mikrotik-adguardhome. Updates to the
# deployment script never overwrite them.
# ============================================================================
{

## ---------- Settings ----------
## "adguard", "pihole", or "" to keep the installed app (AdGuard Home first)
:local app ""
:local storage "/usb1"
## "" keeps the config on the same storage
:local configStorage ""
:local address "172.17.0.2/24"
:local gateway "172.17.0.1"
## Router DNS fallback while the container switches ("" disables)
:local fallbackDns "1.1.1.1"
## Pi-hole web password ("" keeps the current one)
:local piholePassword ""
:local adguardImage "adguard/adguardhome:latest"
:local piholeImage "pihole/pihole:latest"

## ---------- Source ----------
:local repo "maximpri/mikrotik-adguardhome"
:local ref "agent/safe-upgrade-pihole"
:local file "adguardhome_script.rsc"

## ---------- Loader ----------
:local name "mikrotik-adguardhome"
:local chunk 60000
## Built from two parts so that only a file's last line contains it.
:local marker ("#SCRIPT-" . "COMPLETE")

## Run from the one-line installer while the loader is already installed:
## run the installed copy instead, so its settings are used.
:global AghDelegated
:if ($AghDelegated != true && [:len [/system script find where name=$name]] > 0) do={
    :set AghDelegated true
    :do {
        /system script run $name
    } on-error={
        :set AghDelegated false
        :error "mikrotik-adguardhome stopped; see the messages above"
    }
} else={
    :set AghDelegated false

    ## Pin every download to one commit, so all pieces come from the same
    ## version and no stale cached copy is used.
    :local commit $ref
    :do {
        :local r ([/tool fetch output=user as-value url=("https://api.github.com/repos/" . $repo . \
            "/commits/" . $ref) http-header-field="User-Agent: RouterOS,Accept: application/vnd.github.sha"]->"data")
        :if ([:len $r] = 40) do={ :set commit $r }
    } on-error={
        :put ("mikrotik-adguardhome: could not resolve '" . $ref . "' to a commit; using the branch")
    }
    :local base ("https://raw.githubusercontent.com/" . $repo . "/" . $commit . "/")

    ## Install this loader on first use.
    :if ([:len [/system script find where name=$name]] = 0) do={
        :local self ([/tool fetch output=user as-value url=($base . "mikrotik-adguardhome.rsc")]->"data")
        :if ([:typeof [:find $self $marker]] != "num") do={ :error "loader download incomplete" }
        /system script add name=$name source=$self
        :put "mikrotik-adguardhome: installed /system script mikrotik-adguardhome (edit settings there)"
    }

    ## Download the deployment script in ranges; one fetch holds at most 63 KiB.
    :local code ""
    :local offset 0
    :local more true
    :while ($more = true) do={
        :local part ""
        :do {
            :set part ([/tool fetch output=user as-value url=($base . $file) \
                http-header-field=("Range: bytes=" . $offset . "-" . ($offset + $chunk - 1))]->"data")
        } on-error={
            ## A range past the end of the file is refused: the download is done.
            :if ($offset = 0) do={ :error ("mikrotik-adguardhome: cannot download " . $file) }
            :set more false
        }
        :if ($more = true) do={
            :if ([:len $part] > $chunk && $offset > 0) do={ :error "mikrotik-adguardhome: server ignored the range request" }
            :set code ($code . $part)
            :set offset ($offset + $chunk)
            :if ([:len $part] < $chunk || $offset > 2000000) do={ :set more false }
        }
    }
    :if ([:typeof [:find $code $marker]] != "num") do={
        :error "mikrotik-adguardhome: deployment script download incomplete; nothing was changed"
    }
    :put ("mikrotik-adguardhome: " . $file . " @ " . [:pick $commit 0 12] . " (" . [:len $code] . " bytes)")

    ## Hand the settings to the deployment script and run it.
    :local opts [:toarray ""]
    :set ($opts->"app") $app
    :set ($opts->"storage") $storage
    :set ($opts->"configStorage") $configStorage
    :set ($opts->"address") $address
    :set ($opts->"gateway") $gateway
    :set ($opts->"fallbackDns") $fallbackDns
    :set ($opts->"piholePassword") $piholePassword
    :set ($opts->"adguardImage") $adguardImage
    :set ($opts->"piholeImage") $piholeImage
    :set ($opts->"updater") $name
    :global AghOptions $opts
    :local main [:parse $code]
    $main
}

}
#SCRIPT-COMPLETE
