# AdGuard Home or Pi-hole for MikroTik RouterOS

A RouterOS script that installs, upgrades, or switches between [AdGuard Home](https://adguard.com/en/adguard-home/overview.html) and [Pi-hole](https://pi-hole.net/) as a MikroTik container. Run it at any time: it checks every step and rolls back a failed upgrade. If the router itself resolves through the container, the script keeps the router's DNS working throughout.

## Quick start

Paste this into the RouterOS terminal:

```routeros
:local s [:parse ([/tool fetch url="https://raw.githubusercontent.com/maximpri/mikrotik-adguardhome/latest/mikrotik-adguardhome.rsc" output=user as-value]->"data")]; $s
```

It sets up two RouterOS scripts, `mikrotik-adguardhome` and `mikrotik-adguardhome-settings`, then installs AdGuard Home, or upgrades whichever app is already installed. From then on, the whole command is:

```routeros
/system script run mikrotik-adguardhome
```

For **Pi-hole**, put `:global AghApp "pihole"; ` in front of the line, or set `app` in the settings script later:

```routeros
:global AghApp "pihole"; :local s [:parse ([/tool fetch url="https://raw.githubusercontent.com/maximpri/mikrotik-adguardhome/latest/mikrotik-adguardhome.rsc" output=user as-value]->"data")]; $s
```

When pasting, check that the line starts with `:` and ends with `$s`. Some terminals insert stray characters such as `v` or `c` from the paste shortcut; RouterOS then reports `syntax error`, or does nothing.

See [Installing the bootstrap script](#installing-the-bootstrap-script) for other ways to install it, and for how to check, reset, or remove it.

**The loader.** `mikrotik-adguardhome.rsc` is the bootstrap script. It runs on every update, so it handles whatever earlier versions left on the router:

1. It rewrites `/system script mikrotik-adguardhome` as a two-line stub that downloads and runs the latest loader. An old, broken, or hand-made copy is replaced. The stub's comment, which records the deployed image, is kept.
2. It reads your settings from `/system script mikrotik-adguardhome-settings`. On first use it creates that script, carrying over values from an earlier loader that kept settings in its own source.
3. It downloads the version tagged `latest`. When GitHub reports which commit the tag points to, it pins the download to that commit. Otherwise it prints `Using 'latest'` and downloads through GitHub's cache, which can serve the previous version for up to about 5 minutes after a new one is published.
4. It downloads `adguardhome_script.rsc` to a temporary file, which has no size limit, imports it with your settings, and deletes the file. The deployment script is a single block, so a truncated download fails to parse and nothing runs.

If anything fails or is rolled back, the run ends with an error and shows the reason in its summary.

**Backup:** before changing anything, every run saves the router configuration with `/export file=mikrotik-adguardhome-backup`. Each run overwrites the previous backup. If the backup can't be written, the run stops without changing anything. To restore settings from the backup, review `mikrotik-adguardhome-backup.rsc` and import what you need.

Prefer to review the script first, or change less common settings such as timeouts? Download the deployment script, edit the settings at the top, and import it. The loader always downloads the published script, so these edits apply only to runs you import by hand:

```routeros
/tool fetch url="https://raw.githubusercontent.com/maximpri/mikrotik-adguardhome/latest/adguardhome_script.rsc"
/import adguardhome_script.rsc
```

## Installing the bootstrap script

The bootstrap (loader) script is the only part that lives on the router permanently. Installing it creates two RouterOS scripts:

| Script | Contents | Updated by runs |
|---|---|---|
| `mikrotik-adguardhome` | A two-line stub that downloads and runs the latest loader. Its comment records the deployed image. | Rewritten on every run |
| `mikrotik-adguardhome-settings` | Your settings (see [Configuration](#configuration)) | Never |

Installing it also runs a deployment right away, so the first run installs or upgrades the app. Use any one of these methods.

**Terminal (recommended).** Paste the line from [Quick start](#quick-start).

**Winbox or WebFig, without pasting into the terminal.** Open **System → Scripts**, add a script named `mikrotik-adguardhome`, and put this in **Source**:

```routeros
:local s [:parse ([/tool fetch url="https://raw.githubusercontent.com/maximpri/mikrotik-adguardhome/latest/mikrotik-adguardhome.rsc" output=user as-value]->"data")]; $s
```

Then click **Run Script**. This line is already the stub. The first run gives the script full permissions and creates the settings script.

**File import.** Download the loader and import it:

```routeros
/tool fetch url="https://raw.githubusercontent.com/maximpri/mikrotik-adguardhome/latest/mikrotik-adguardhome.rsc"
/import mikrotik-adguardhome.rsc
/file remove mikrotik-adguardhome.rsc
```

**Check the installation:**

```routeros
/system script print detail where name~"^mikrotik-adguardhome"
```

**Reinstall.** Run any install method again. It rewrites the stub and keeps your settings. To start over with default settings, remove the settings script first:

```routeros
/system script remove [find name=mikrotik-adguardhome-settings]
```

**Uninstall the scripts.** This leaves the containers, their data, and router DNS untouched:

```routeros
/system scheduler remove [find name=mikrotik-adguardhome-update]
/system script remove [find where name~"^mikrotik-adguardhome"]
```

Check `/ip dns print` first. If a run left the router on the fallback DNS, `mikrotik-adguardhome-restore` holds your original settings: run it before removing it. To also remove the app, stop and remove its container with `/container stop` and `/container remove`. The mounts, envs, veth, and the data under the storage path stay until you remove them.

## What a run does

| Situation | Result |
|---|---|
| Nothing installed | Installs the chosen app: `INSTALLED` |
| Installed; the image and settings have not changed | Checks Docker Hub only. Nothing is downloaded or restarted: `UP TO DATE` |
| Installed; a new image is available or a setting such as `piholePassword` changed | Switches to the new container after checks: `UPGRADED` |
| The new version fails a check | Starts the previous version again: `ROLLED BACK` |
| The other app is chosen | Switches apps after checks; the old app's container is kept stopped: `SWITCHED TO ...` |
| A check stops the run before any change (storage, DNS, consent) | Explains what to do; nothing is changed: `FAILED` |

Every run ends with a summary of the result, container, address, router DNS state, healthcheck, and web UI address.

**Self-healing.** Each run repairs what an interrupted or failed run, or an earlier version, left behind:

- a leftover `<name>-next` container, or an unused root directory;
- router DNS settings saved in `mikrotik-adguardhome-restore` while a fallback was active;
- a work-data mount that was added but never used;
- a run lock older than 20 minutes;
- scripts and global variables from earlier versions (such as `dns-filter` and `dns-filter-restore`).

The script judges container state from RouterOS state flags, and from memory use on releases such as 7.24 that report no running field.

## How upgrades stay safe

1. **The current container keeps serving.** The new image is pulled into a second container, `<name>-next`, with its own root directory. A slow or failed download doesn't affect DNS.
2. **No download without a change.** Before pulling, the script asks Docker Hub's public tag API which digest the image tag points to. If it matches the digest recorded at the last successful run (in the comment of the `mikrotik-adguardhome` loader script), and no setting changed, nothing is downloaded or restarted. The first run after installing this version always switches once, because nothing is recorded yet. If the digest can't be read, the script pulls and switches as usual.
3. **The switch is verified.** The script stops the old container and starts the new one. It then checks that the new one is running, still running after `cStabilitySeconds`, and answering DNS (if the old one was).
4. **Rollback.** If any check fails, the script stops the new container, restores the config backup, and starts the old one again. Before an upgrade it backs up the main config file (`AdGuardHome.yaml` or `pihole.toml`, up to 60 KB), because the new version may migrate it to a format the old one can't read. The old container must then pass the same checks it passed before: running, stable, and answering DNS. If it can't, the run reports `CRITICAL` and keeps both containers for inspection.
5. **Cleanup.** After a verified switch, the old container is removed and the new one takes the usual name (`adguardhome` or `pihole`). Leftovers from an interrupted run are cleaned up on the next run.

An upgrade briefly needs room for two copies of the image on the `storage` path. A lock prevents two runs from overlapping, for example a scheduled run and a manual one.

## Router DNS during upgrades

If the router resolves through the container, the router would lose DNS while the container switches. The script detects this: `/ip dns` `servers` contains the container address, or `use-doh-server` points at it. In that case it:

1. Puts the `fallbackDns` setting (default `1.1.1.1`) first in the router's DNS servers and removes the container from the list. It also clears a DoH server that points at the container. Then it flushes the DNS cache.
2. Runs the deployment.
3. Waits until the serving container resolves a test name (`cDnsTestHost`).
4. Restores the original servers and DoH setting exactly, and flushes the cache again so no unfiltered answers stay cached.

If nothing answers DNS, the fallback stays so the router keeps working. While the fallback is active, the original settings are saved in a `/system script` named `mikrotik-adguardhome-restore`. It survives reboots, the next run restores the settings from it, and you can run it by hand once the container answers again:

```routeros
/system script run mikrotik-adguardhome-restore
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

Edit the values in **System → Scripts → mikrotik-adguardhome-settings** (or `/system script edit mikrotik-adguardhome-settings source`). Updates never overwrite this script:

```routeros
:global AghSettings [:toarray ""]
:set ($AghSettings->"app") ""                  # adguard, pihole, or empty to keep the installed app
:set ($AghSettings->"storage") "/usb1"
:set ($AghSettings->"configStorage") ""        # empty keeps the config on the same storage
:set ($AghSettings->"address") "172.17.0.2/24"
:set ($AghSettings->"gateway") "172.17.0.1"
:set ($AghSettings->"fallbackDns") "1.1.1.1"   # empty disables the router DNS fallback
:set ($AghSettings->"piholePassword") ""       # empty keeps the current password
:set ($AghSettings->"adguardImage") "adguard/adguardhome:latest"
:set ($AghSettings->"piholeImage") "pihole/pihole:latest"
```

If the settings script has an error, the run stops before changing anything and says so. Delete the script to get a fresh one with defaults on the next run.

`:global AghApp "pihole"` (or `"adguard"`) overrides `app` for one run. When neither is set, the script keeps the running app (or, if none is running, the one that starts on boot) and installs AdGuard Home if nothing is installed. Less common settings, such as timeouts and the healthcheck command, are at the top of `adguardhome_script.rsc`; see [Quick start](#quick-start) for how to run a modified copy.

| App | Container | Root | Config mount | Other |
|---|---|---|---|---|
| AdGuard Home | `adguardhome` | `/usb1/agh` | `/usb1/conf/agh` → `/opt/adguardhome/conf` | Work data `/usb1/work/agh` → `/opt/adguardhome/work` |
| Pi-hole | `pihole` | `/usb1/pihole` | `/usb1/conf/pihole` → `/etc/pihole` | Env: `FTLCONF_dns_listeningMode=ALL`; `TZ` from the router clock |

Both apps use the same veth (`agh`) and address, so switching apps keeps the DNS server address unchanged.

`configStorage` can point at persistent storage, such as internal flash, when the rest is on a RAM disk.

The image tag `latest` changes with every upstream release. Set a fixed image tag, such as `adguard/adguardhome:v0.107.79`, for repeatable deployments.

## Choosing or switching apps

- **Install Pi-hole:** set `app` to `"pihole"` in the settings script, or run `:global AghApp "pihole"` before running the loader. The web UI is at `http://<address>/admin`. Set `piholePassword` first, or find the generated password with `/container log pihole`. Pi-hole starts with its own default blocklist; AdGuard Home settings and rules are not carried over.
- **Install AdGuard Home:** run the loader and finish the setup wizard at `http://<address>:3000`.
- **Switch apps:** choose the other app and run the loader. The new app is verified before it takes over. A failed check starts the old app again. The old app's container is kept stopped, with its data intact, until you remove it:

  ```routeros
  /container remove [find name=adguardhome]
  ```

  A freshly installed AdGuard Home answers DNS only after its setup wizard. If the current app is answering DNS, the script won't replace it with an unconfigured AdGuard Home; the current app keeps running. To switch anyway, accepting a DNS outage until the wizard is done, run `:global AghForce "yes"` before the loader. Switching back to an app whose container was kept stopped reuses its configuration and is verified like any upgrade.

## Scheduled updates (optional)

```routeros
/system scheduler add name=mikrotik-adguardhome-update interval=1d start-time=04:00:00 on-event="/system script run mikrotik-adguardhome"
```

Scheduled runs keep the installed app. Results are written to the RouterOS log under `mikrotik-adguardhome:`.

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

- **AdGuard Home:** HTTP on port 3000, then port 80. If AdGuard Home's web UI uses another port, the healthcheck reports unhealthy. That status is informational: the script doesn't enable `stop-on-unhealthy`, and its own checks use DNS.
- **Pi-hole:** a `dig` query for `pi.hole`, matching Pi-hole's own Docker healthcheck.

```routeros
/container print proplist=name,healthcheck-status
```

On 7.22, the script relies on its own running, stability, and DNS checks.

## Upgrading from earlier versions

Run the install line from [Quick start](#quick-start) once. It replaces the old updater scripts with the loader. Existing AdGuard Home deployments are upgraded in place. The first run pulls into `adguardhome-next` at `/usb1/agh-next`, switches, removes the old container, and renames the new one to `adguardhome`. Later upgrades alternate between `/usb1/agh` and `/usb1/agh-next`.

Deployments from before 1.7.0 keep AdGuard Home's work data (statistics, query log, cached filter lists, login sessions) inside the container. The upgrade replaces the container, so the script stops and asks first. To move work data to `/usb1/work/agh`, and start statistics and the query log empty, run:

```routeros
:global AghForce "yes"
```

Then run the script again. Settings, users, rules, and filter lists in `AdGuardHome.yaml` are kept. If that run fails or rolls back, the new mount is removed again, so the old container keeps its data.

## Troubleshooting

```routeros
/container print detail
/container log adguardhome
/ip dns print
/log print where message~"mikrotik-adguardhome"
```

- **`syntax error`, or the line does nothing:** check that the pasted line starts with `:` and ends with `$s`, with no stray characters.
- **A fetch error:** check router DNS and internet access with `:put [:resolve raw.githubusercontent.com]`. If certificate validation fails because of the CRL, add `check-certificate=yes-without-crl` to the fetch command.
- **`[INFO] Using 'latest'`:** normal on RouterOS, which GitHub's API doesn't answer. A version published in the last few minutes may not be served yet.
- **`Router DNS: fallback active` in the summary:** the container is not answering yet. Run the script again once it answers, or run `/system script run mikrotik-adguardhome-restore`.
- **`Another run is in progress`:** another run started within the last 20 minutes. If it was interrupted, wait or clear the lock with `:set AghLock ""`.
- **Slow image pulls:** a pull that exceeds 10 minutes fails without touching the running container. Use faster storage, or run a modified copy with a larger `cPullTimeout` (see [Quick start](#quick-start)).
- **No container network:** verify the veth address, bridge membership, gateway, and masquerade rule.

## Development

`tools/lint_rsc.py` runs in CI on both scripts. It checks that each is a single `{ }` block ending with the end-of-file marker, that delimiters balance, that every variable is declared, and that the loader stays small enough for a single in-memory fetch.

### Publishing a version

Routers run whatever the `latest` tag points to, so a push to `main` reaches no router until it is published. To publish, run the **Publish latest** workflow (Actions → Publish latest → Run workflow) with the commit or branch to release. It lints both scripts, then moves the `latest` tag. From a checkout, the equivalent is:

```sh
git tag -f latest <commit>
git push -f origin latest
```

## Security notes

- Container support expands the router's attack surface. Keep RouterOS and the apps patched.
- Do not expose the web UIs or DNS service to untrusted networks.
- Images are pulled with certificate checks enabled. The image tag `latest` changes with upstream releases; pin an image tag if you need control over app upgrades. Script updates reach routers only when a maintainer moves the git tag `latest`.
- The script changes router DNS servers only temporarily, only when they point at the container, and restores them once the container answers. It does not delete static DNS records.

See MikroTik's [Container documentation](https://manual.mikrotik.com/docs/containers/) and [device-mode documentation](https://manual.mikrotik.com/docs/system-information-and-utilities/device-mode/).

## License

[MIT](LICENSE)
