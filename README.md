# AdGuard Home or Pi-hole for MikroTik RouterOS

A RouterOS script that installs, upgrades, or switches between [AdGuard Home](https://adguard.com/en/adguard-home/overview.html) and [Pi-hole](https://pi-hole.net/) as a MikroTik container. Run it at any time: it checks every step and rolls back a failed upgrade. If the router itself resolves through the container, the script keeps the router's DNS working throughout.

## Quick start

Paste this into the RouterOS terminal:

```routeros
:local s [:parse ([/tool fetch url="https://raw.githubusercontent.com/maximpri/mikrotik-adguardhome/main/adguardhome_script.rsc" output=user as-value]->"data")]; $s
```

It installs AdGuard Home, or upgrades whichever app is already installed. For **Pi-hole**, run this first:

```routeros
:global DnsFilterApp "pihole"
```

After the first successful run, the script saves a short updater. Use it from then on:

```routeros
/system script run dns-filter
```

The line downloads the script into memory, without writing a file to flash. The whole script is a single block, so a truncated download fails to parse and nothing runs. If anything fails or is rolled back, the run ends with an error and shows the reason in its summary.

**Backup:** before changing anything, every run saves the router configuration with `/export file=dns-filter-backup`. If the backup can't be written, the run stops without changing anything. To restore settings from the backup, review `dns-filter-backup.rsc` and import what you need. Set `cBackupFile` to `""` to skip the backup.

Prefer to review the script first? Download it, edit the settings at the top, and import it:

```routeros
/tool fetch url="https://raw.githubusercontent.com/maximpri/mikrotik-adguardhome/main/adguardhome_script.rsc"
/import adguardhome_script.rsc
```

## What a run does

| Situation | Result |
|---|---|
| Nothing installed | Installs the chosen app: `INSTALLED` |
| Installed; the image and settings have not changed | Downloads and compares the image, then removes the copy. Nothing restarts: `UP TO DATE` |
| Installed; a new image is available or a setting such as `cPiholePassword` changed | Switches to the new container after checks: `UPGRADED` |
| The new version fails a check | Starts the previous version again: `ROLLED BACK` |
| The other app is chosen | Switches apps after checks; the old app's container is kept stopped: `SWITCHED TO ...` |

Every run ends with a summary of the result, container, address, router DNS state, healthcheck, and web UI address.

## How upgrades stay safe

1. **The current container keeps serving.** The new image is pulled into a second container, `<name>-next`, with its own root directory. A slow or failed download doesn't affect DNS.
2. **No restart without a change.** If the new image matches the running one, the copy is removed and nothing restarts. The script compares the AdGuard Home binary, or the Pi-hole FTL binary plus `/pihole.docker.tag`.
3. **The switch is verified.** The script stops the old container and starts the new one. It then checks that the new one is running, still running after `cStabilitySeconds`, and answering DNS (if the old one was).
4. **Rollback.** If any check fails, the script stops the new container, restores the config backup, and starts the old one again. Before an upgrade it backs up the main config file (`AdGuardHome.yaml` or `pihole.toml`, up to 60 KB), because the new version may migrate it to a format the old one can't read. The old container must then pass the same checks it passed before: running, stable, and answering DNS. If it can't, the run reports `CRITICAL` and keeps both containers for inspection.
5. **Cleanup.** After a verified switch, the old container is removed and the new one takes the usual name (`adguardhome` or `pihole`). Leftovers from an interrupted run are cleaned up on the next run.

An upgrade briefly needs room for two copies of the image on `cDefaultStorageMount`. A lock prevents two runs from overlapping, for example a scheduled run and a manual one.

## Router DNS during upgrades

If the router resolves through the container, the router would lose DNS while the container switches. The script detects this: `/ip dns` `servers` contains the container address, or `use-doh-server` points at it. In that case it:

1. Puts `cFallbackDns` (default `1.1.1.1`) first in the router's DNS servers and removes the container from the list. It also clears a DoH server that points at the container. Then it flushes the DNS cache.
2. Runs the deployment.
3. Waits until the serving container resolves `cDnsTestHost`.
4. Restores the original servers and DoH setting exactly, and flushes the cache again so no unfiltered answers stay cached.

If nothing answers DNS, the fallback stays so the router keeps working. While the fallback is active, the original settings are saved in a `/system script` named `dns-filter-restore`. It survives reboots, the next run restores the settings from it, and you can run it by hand once the container answers again:

```routeros
/system script run dns-filter-restore
```

If you change the router's DNS servers yourself in the meantime, the next run discards the saved settings instead of overwriting yours.

Clients that use the router as their DNS server are covered by the fallback. Clients that query the container address directly, or are redirected to it with NAT, have no DNS for the few seconds of a switch. Updates that change nothing don't interrupt them.

## Requirements

- RouterOS **7.22 or later**. Native healthchecks need 7.23 or later.
- The RouterOS `container` package, installed and enabled, and container device-mode. The script starts the device-mode change, which then needs a physical button press or cold reboot to confirm.
- An ARM, ARM64, x86, or CHR system. EN7562CT devices such as the hEX Refresh (E50UG) are not supported: they run only arm32v5 images, and neither AdGuard Home nor Pi-hole publishes one.
- Storage mounted at `/usb1`, or a customized path.
- Router DNS and internet access to Docker Hub and GitHub.

## Configuration

Settings are at the top of the script:

```routeros
:local cApp ""                  # "adguard", "pihole", or "" to keep the installed app
:local cAdguardImage "adguard/adguardhome:latest"
:local cPiholeImage "pihole/pihole:latest"
:local cPiholePassword ""       # "" keeps the current password
:local cDefaultStorageMount "/usb1"
:local cConfigStorageMount $cDefaultStorageMount
:local cInterface "agh"
:local cContainerAddress "172.17.0.2/24"
:local cContainerGateway "172.17.0.1"
:local cFallbackDns "1.1.1.1"
:local cPullTimeout 600
```

`:global DnsFilterApp "pihole"` (or `"adguard"`) overrides `cApp` for one run. When neither is set, the script keeps the installed app and installs AdGuard Home if nothing is installed.

| App | Container | Root | Config mount | Other |
|---|---|---|---|---|
| AdGuard Home | `adguardhome` | `/usb1/agh` | `/usb1/conf/agh` → `/opt/adguardhome/conf` | Work data `/usb1/work/agh` → `/opt/adguardhome/work` |
| Pi-hole | `pihole` | `/usb1/pihole` | `/usb1/conf/pihole` → `/etc/pihole` | Env: `FTLCONF_dns_listeningMode=ALL`; `TZ` from the router clock |

Both apps use the same veth (`agh`) and address, so switching apps keeps the DNS server address unchanged.

`cConfigStorageMount` can point at persistent storage, such as internal flash, when the rest is on a RAM disk.

`latest` is mutable. Set an image tag for repeatable deployments.

## Choosing or switching apps

- **Install Pi-hole:** run the Pi-hole one-liner. The web UI is at `http://172.17.0.2/admin`. Set `cPiholePassword`, or find the generated password with `/container log pihole`.
- **Install AdGuard Home:** run the default one-liner and finish the setup wizard at `http://172.17.0.2:3000`.
- **Switch apps:** run the one-liner for the other app. The new app is verified before it takes over. A failed check starts the old app again. The old app's container is kept stopped, with its data intact, until you remove it:

  ```routeros
  /container remove [find name=adguardhome]
  ```

  A freshly installed AdGuard Home answers DNS only after its setup wizard. If the current app is answering DNS, the script won't replace it with an unconfigured AdGuard Home; the current app keeps running. To switch anyway, accepting a DNS outage until the wizard is done, run `:global DnsFilterForce "yes"` before the one-liner. Switching back to an app whose container was kept stopped reuses its configuration and is verified like any upgrade.

## Scheduled updates (optional)

After the first run, schedule the saved updater:

```routeros
/system scheduler add name=dns-filter-update interval=1d start-time=04:00:00 on-event="/system script run dns-filter"
```

Scheduled runs keep the installed app. Results are written to the RouterOS log under `DNS filter:`.

## Complete the network setup

The script creates the `agh` veth with `172.17.0.2/24` and gateway `172.17.0.1`, and warns if the veth is not in a bridge. It does not change bridges or firewall rules. For a new, isolated container network, run once:

```routeros
/interface bridge add name=containers
/ip address add address=172.17.0.1/24 interface=containers
/interface bridge port add bridge=containers interface=agh
/ip firewall nat add chain=srcnat action=masquerade src-address=172.17.0.0/24
```

If you already have a container bridge, attach `agh` to it instead. Then point clients, DHCP, or the router (`/ip dns set servers=172.17.0.2`) at the container. Allow DNS only from networks that should use it.

## Health monitoring

On RouterOS 7.23 and later, each new container gets a native healthcheck:

- **AdGuard Home:** HTTP on port 3000, then port 80. Edit the command in the script if you use a custom web port.
- **Pi-hole:** a `dig` query for `pi.hole`, matching Pi-hole's own Docker healthcheck.

```routeros
/container print proplist=name,healthcheck-status
```

On 7.22, the script relies on its own running, stability, and DNS checks.

## Upgrading from script versions before 2.0

Existing AdGuard Home deployments are upgraded in place. The first run pulls into `adguardhome-next` at `/usb1/agh-next`, switches, removes the old container, and renames the new one to `adguardhome`. Later upgrades alternate between `/usb1/agh` and `/usb1/agh-next`.

Deployments from before 1.7.0 keep AdGuard Home's work data (statistics, query log, cached filter lists, login sessions) inside the container. The upgrade replaces the container, so the script stops and asks first. To move work data to `/usb1/work/agh`, and start statistics and the query log empty, run:

```routeros
:global DnsFilterForce "yes"
```

Then run the script again. Settings, users, rules, and filter lists in `AdGuardHome.yaml` are kept. If that run fails or rolls back, the new mount is removed again, so the old container keeps its data.

## Troubleshooting

```routeros
/container print detail
/container log adguardhome
/ip dns print
/log print where message~"DNS filter"
```

- **`syntax error` or a fetch error:** check router DNS and internet access with `:put [:resolve raw.githubusercontent.com]`. If certificate validation fails because of the CRL, add `check-certificate=yes-without-crl` to the fetch command.
- **`Router DNS: fallback active` in the summary:** the container is not answering yet. Run the script again once it answers, or run `/system script run dns-filter-restore`.
- **`Another run is in progress`:** a previous run was interrupted. Clear the lock with `:set DnsFilterLock ""`.
- **Slow image pulls:** increase `cPullTimeout`.
- **No container network:** verify the veth address, bridge membership, gateway, and masquerade rule.

## Development

`tools/lint_rsc.py` runs in CI. It checks that the script stays under 60 KB (the in-memory download limit is 63 KiB), that it is a single `{ }` block ending with the end-of-file marker, that delimiters balance, and that every variable is declared.

## Security notes

- Container support expands the router's attack surface. Keep RouterOS and the apps patched.
- Do not expose the web UIs or DNS service to untrusted networks.
- Images are pulled with certificate checks enabled. `latest` can change at any time; pin a tag if you need control over upgrades.
- The script changes router DNS servers only temporarily, only when they point at the container, and restores them once the container answers. It does not delete static DNS records.

See MikroTik's [Container documentation](https://manual.mikrotik.com/docs/containers/) and [device-mode documentation](https://manual.mikrotik.com/docs/system-information-and-utilities/device-mode/).

## License

[MIT](LICENSE)
