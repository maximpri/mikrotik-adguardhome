# AdGuard Home for MikroTik RouterOS

An idempotent RouterOS script that deploys and upgrades [AdGuard Home](https://adguard.com/en/adguard-home/overview.html) as a MikroTik container.

## What it does

- Validates RouterOS, the container package, external storage, DNS, and Docker Hub access.
- Configures the Docker Hub registry and extraction directory.
- Creates or validates persistent AdGuard Home configuration and work-data mounts.
- Creates a statically addressed veth interface.
- Performs first-time image pull, extraction, start, and stability checks.
- Uses RouterOS 7.22's automatic stop/repull/start behavior for upgrades.
- Preserves the router's DNS, static DNS records, firewall, and bridge configuration.

## Requirements

- RouterOS **7.22.x**. The script intentionally rejects other releases because its repull workflow is specific to 7.22 and has not been tested on later versions.
- The RouterOS `container` package, installed and enabled.
- An ARM, ARM64, x86, or CHR system supported by the container package.
- External storage mounted at `/usb1`, or a customized storage path.
- Working router DNS and internet access to Docker Hub.
- Physical access if container device-mode is not already enabled.

MikroTik recommends fast external storage for containers. Slow flash drives can require a larger `cPullTimeout`.

## Quick start

Fetch and import the script:

```routeros
/tool fetch url="https://raw.githubusercontent.com/maximpri/mikrotik-adguardhome/main/adguardhome_script.rsc"
/import adguardhome_script.rsc
```

Alternatively, store it as a reusable RouterOS script:

```routeros
/system script add name=adguardhome-deploy source=[/file get adguardhome_script.rsc contents]
/system script run adguardhome-deploy
```

If container device-mode is disabled, RouterOS requires physical confirmation. Follow the command's activation instructions, let the router restart, and run the deployment script again.

## Configuration

Edit the variables near the top of `adguardhome_script.rsc` before importing it:

```routeros
:local cName "adguardhome"
:local cImage "adguard/adguardhome:latest"
:local cInterface "agh"
:local cDefaultStorageMount "/usb1"
:local cContainerAddress "172.17.0.2/24"
:local cContainerGateway "172.17.0.1"
:local cPullTimeout 300
```

Derived defaults are:

| Purpose | Path |
|---|---|
| Container root | `/usb1/agh` |
| Extraction temp | `/usb1/tmp` |
| Persistent configuration | `/usb1/conf/agh` |
| Configuration in container | `/opt/adguardhome/conf` |
| Persistent work data | `/usb1/work/agh` |
| Work data in container | `/opt/adguardhome/work` |

`latest` is convenient for automatic upgrades but is mutable. Set `cImage` to a specific AdGuard Home tag if you need repeatable deployments.

## Complete the network setup

The script assigns `172.17.0.2/24` and gateway `172.17.0.1` to the `agh` veth. It deliberately does not change bridges or firewall rules because those are router-specific.

For a new, isolated container network, run these commands once:

```routeros
/interface bridge add name=containers
/ip address add address=172.17.0.1/24 interface=containers
/interface bridge port add bridge=containers interface=agh
/ip firewall nat add chain=srcnat action=masquerade src-address=172.17.0.0/24
```

If you already have a container bridge, attach `agh` to it and use addressing that matches that bridge instead. Do not create a second overlapping `172.17.0.0/24` network.

After the container starts:

1. Open `http://172.17.0.2:3000`.
2. Complete the AdGuard Home setup wizard.
3. Allow DNS traffic only from the networks that should use the resolver.
4. Point those clients, DHCP scopes, or the router DNS configuration at the AdGuard Home address.

## Upgrades

Run the script again. When the named container exists, it calls:

```routeros
/container repull [find name=adguardhome] remote-image=adguard/adguardhome:latest
```

RouterOS 7.22 automatically stops, repulls, and restarts the container. The script waits up to five minutes by default and then verifies that the container remains running.

The persistent configuration and work-data mounts are retained. If an existing mount destination points to a different source directory, the script stops instead of silently switching data.

Deployments made with script versions before 1.7.0 may have only the configuration mount. The script stops rather than add an empty work-data mount that would hide existing data. Back up `/opt/adguardhome/work`, add a mount from `/usb1/work/agh` to that destination, and restore the data before the next repull.

## Troubleshooting

Inspect container state and logs:

```routeros
/container print detail
/container log adguardhome
```

Check storage and DNS:

```routeros
/disk print
/file print
/ip dns print
:put [:resolve registry-1.docker.io]
```

If image extraction exceeds five minutes, increase `cPullTimeout`. If the container has no network access, verify the veth address, bridge membership, gateway address, and masquerade rule.

## Security notes

- Container support expands the router's attack surface. Keep RouterOS and AdGuard Home patched.
- Do not expose the setup UI or DNS service to untrusted networks.
- Review the image tag before upgrades; `latest` can change at any time.
- The script does not overwrite router DNS servers or delete static DNS records.

See MikroTik's [Container documentation](https://manual.mikrotik.com/docs/containers/) and [device-mode documentation](https://manual.mikrotik.com/docs/system-information-and-utilities/device-mode/) for platform details.

## License

[MIT](LICENSE)
