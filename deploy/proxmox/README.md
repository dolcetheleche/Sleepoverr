# Sleepoverr on Proxmox VE

Two scripts that create a small LXC container on your Proxmox VE host, install Sleepoverr in it, and keep it updated. They follow the style of the Proxmox community helper scripts, but have no dependency on them.

| Script | Runs on | Does |
|---|---|---|
| `sleepoverr.sh` | the Proxmox VE host (root shell) | creates the container, pushes `sleepoverr-ctl`, starts the install; later snapshots and updates |
| `sleepoverr-ctl.sh` | inside the container (installed as `/usr/local/bin/sleepoverr-ctl`) | installs Docker and Sleepoverr; `update`, `backup`, `restore`, `status`, `logs`, ... |

`sleepoverr-ctl` also works on any Debian or Ubuntu machine or VM where you are root.

## Status: what has and has not been tested

- Tested (`deploy/proxmox/tests/run.sh`, 130 checks, also run in CI): the logic of both scripts against fake `pct`, `pveam`, `pvesh`, `pvesm` and `docker` commands that record what they are asked to do. That covers the exact `pct create` options, validation, snapshots and pruning, `.env` creation and permissions, backup retention, the update sequence, self-update, and failure paths.
- Not tested: a real Proxmox host, real Docker, a real image build or pull. The scripts have not yet run end to end. Expect to find small problems on the first real run and report them.

## Install the test environment (guest 1000, 2 cores, 4 GB RAM)

This builds Sleepoverr from source and starts it together with a mock RomM server (see `dev/README.md`). It needs no RomM and no credentials. In the Proxmox host shell, as root:

```sh
curl -fsSL https://raw.githubusercontent.com/dolcetheleche/Sleepoverr/master/deploy/proxmox/sleepoverr.sh \
  | bash -s -- install --test-env
```

Until these changes are merged into `master`, use the branch they are on for both the script and the code it installs:

```sh
curl -fsSL https://raw.githubusercontent.com/dolcetheleche/Sleepoverr/feat/pve-installer/deploy/proxmox/sleepoverr.sh \
  | SLEEPOVERR_REF=feat/pve-installer bash -s -- install --test-env
```

It asks a few questions (press Enter for the defaults) and creates:

- container ID 1000, hostname `sleepoverr-test`, unprivileged, with `nesting=1,keyctl=1` (needed for Docker), starting at boot, tag `sleepoverr;test`
- 2 cores, 4096 MB RAM, 512 MB swap, a 20 GB disk (change with `CT_DISK`)
- the newest Debian 13 or 12 template it can find, downloaded if missing

If ID 1000 is already used by another guest, the script stops before changing anything.

When it finishes it prints the container's address. Sleepoverr is on port 8000, the mock RomM API on 8081. Inside the container, `sleepoverr-ctl status` prints the URLs, the mock client token and the first-run setup code.

## Install a production container

```sh
curl -fsSL https://raw.githubusercontent.com/dolcetheleche/Sleepoverr/master/deploy/proxmox/sleepoverr.sh \
  | bash -s -- install
```

Defaults: next free ID, 2 cores, 2048 MB RAM, 20 GB disk, DHCP. It optionally asks for your IGDB (Twitch) credentials and, for later use by the RomM sync, your RomM URL and a read-only Client API Token. Everything can also be edited afterwards in `/opt/sleepoverr/.env` (then `sleepoverr-ctl restart`).

The script first tries to pull `ghcr.io/dolcetheleche/sleepoverr:latest`. Images are only published when a `v*` tag is pushed, and a new ghcr package is private until you make it public (GitHub -> your profile -> Packages -> sleepoverr -> Package settings -> Change visibility). If the pull fails, it builds from source in the container instead, which takes several minutes. Force one or the other with `SLEEPOVERR_MODE=image` or `SLEEPOVERR_MODE=source`.

## Update

From the Proxmox host (the script finds the container tagged `sleepoverr`, or pass its ID):

```sh
curl -fsSL .../sleepoverr.sh | bash -s -- update 100
```

For a production container this first takes a Proxmox snapshot named `sleepoverr-pre-update-<date>` (the newest three are kept), then runs `sleepoverr-ctl update` inside it. That in turn:

1. replaces `sleepoverr-ctl` itself if a newer one is on GitHub
2. backs up the data (stops the app for a few seconds, archives the database, uploads and `.env`)
3. refreshes `docker-compose.yml`, pulls the new image (or fetches and rebuilds the source)
4. restarts and waits for the health check

If the new version does not become healthy it exits with an error and tells you how to roll back. You can also run `sleepoverr-ctl update` directly in the container (`pct enter 100`). On the host, add `--no-snapshot` to skip the snapshot; inside the container, `sleepoverr-ctl update --no-backup` skips the data backup.

For the test container, an update pulls the latest source and rebuilds; the test data is kept. `sleepoverr-ctl reset` deletes the test data and starts over.

## Backup, restore and rollback

- `sleepoverr-ctl backup` writes `/var/backups/sleepoverr/sleepoverr-<date>.tar.gz` (mode 600; the newest 5 are kept). The archive contains the database, uploads and `.env`, so treat it as a secret.
- `sleepoverr-ctl restore <file>` replaces the database and uploads with the backup (it asks first; `-y` skips the question). The `.env` in the archive is not applied; to recover it: `tar -xzOf <file> env`.
- Whole-container rollback: `pct rollback <id> sleepoverr-pre-update-<date>` (needs a storage type that supports snapshots; the script warns and carries on if yours does not).
- Copy backups off the container too, for example with a Proxmox Backup job for the container.

## Options

Answers can be given as environment variables instead of prompts (useful with `-y`, which never asks). Examples:

```sh
CT_ID=1000 CT_CORES=2 CT_RAM=4096 CT_DISK=20 CT_STORAGE=local-lvm CT_BRIDGE=vmbr0 \
CT_IP=192.168.1.50/24 CT_GW=192.168.1.1 IGDB_CLIENT_ID=... IGDB_CLIENT_SECRET=... \
  bash sleepoverr.sh install -y
```

| Variable | Default | Meaning |
|---|---|---|
| `CT_ID`, `CT_HOSTNAME` | next free ID / `sleepoverr` (test: `1000` / `sleepoverr-test`) | container ID and name |
| `CT_CORES`, `CT_RAM`, `CT_SWAP`, `CT_DISK` | 2, 2048 (test: 4096), 512, 20 | cores, MB RAM, MB swap, GB disk |
| `CT_STORAGE`, `CT_TEMPLATE_STORAGE` | first of `local-lvm`, `local-zfs`, `local` / `local` | where the disk and the template live |
| `CT_BRIDGE`, `CT_IP`, `CT_GW`, `CT_VLAN` | `vmbr0`, `dhcp`, -, - | network |
| `IGDB_CLIENT_ID`, `IGDB_CLIENT_SECRET` | empty | optional; can be added later in `.env` |
| `ROMM_URL`, `ROMM_API_TOKEN` | empty | optional, production only; read once the RomM sync exists |
| `SLEEPOVERR_REPO`, `SLEEPOVERR_REF` | `dolcetheleche/Sleepoverr`, `master` | which GitHub repo and branch or tag to install from; pin a release with `SLEEPOVERR_REF=v0.1.0` |
| `SLEEPOVERR_MODE`, `SLEEPOVERR_TAG` | `auto`, `latest` | `image` or `source`; image tag to pull |

Flags: `-y/--yes` accept defaults, `--dry-run` print the changes without making them, `--test-env` the test profile, `--no-snapshot` on update.

## Security notes

- `sleepoverr.sh` runs as root on your Proxmox host, and the install pipes code from GitHub, so what is on the branch you point it at runs on your hypervisor. Read the script first (download it, open it, then run it), pin `SLEEPOVERR_REF` to a tag you reviewed, and protect `master` with a pull-request rule.
- Secrets you enter are written to a file with mode 600, pushed into the container, read once and deleted; they never appear on a command line. `.env` is mode 600 and a fresh `JWT_SECRET_KEY` is generated for every install.
- The container is unprivileged. Docker inside it needs `nesting=1,keyctl=1`. If Docker will not start, check the host's kernel and AppArmor setup.

## Remove

```sh
pct stop 1000 && pct destroy 1000
```

This deletes the container and its data. Take a backup first if you want to keep anything.
