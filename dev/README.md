# Sleepoverr test environment

A self-contained, throwaway stack for testing Sleepoverr against **RomM-shaped data
without touching your real RomM library**. Everything runs under the compose project
name `sleepoverr-test`, so its containers, network and volumes never collide with a
production `sleepoverr` or RomM stack.

> **What was and wasn't tested by the author.** This environment was written in a
> sandbox **without a Docker daemon**.
>
> - **Tested:** the mock RomM API (65 pytest tests, plus manual `curl` against a running
>   uvicorn), `make_placeholder_roms.py`, `test-env.sh init` / `urls` / `test-mock`
>   and its error paths (`sh -n`, `shellcheck`), and `docker compose ... config` (the
>   compose file parses and interpolates; this needs no daemon).
> - **Not tested:** building the images, `docker compose up`, the containers'
>   healthchecks, the `real-romm` profile against a real RomM image, the Proxmox VE
>   steps, and pointing at a real RomM. Treat those sections as instructions that should
>   work but have not been run. Please report anything that doesn't.

## What's in here

| Path | What it is |
| --- | --- |
| `mock-romm/` | Small FastAPI app imitating the read-only part of the RomM REST API the future sync will use (`/api/heartbeat`, `/api/token`, `/api/platforms`, `/api/roms`, `/api/roms/{id}`). Own Dockerfile, requirements and tests. |
| `mock-romm/fixtures/` | 6 platforms (NES, SNES, Mega Drive/Genesis, GBA, PlayStation, N64) and 40 ROMs. `igdb_id` is `null` everywhere, 8 ROMs are unidentified (`name: null`), and the play data (`rom_user`) covers the whole range of states. |
| `mock-romm/resolve_igdb_ids.py` | Optional: fills real IGDB ids into `fixtures/roms.resolved.json` using your IGDB keys. |
| `seed/make_placeholder_roms.py` | Writes a fake library of 40 tiny text files (contents: `placeholder`) into `data/library/roms/<fs_slug>/` for the real-RomM profile. |
| `docker-compose.test.yml` | The stack (see below). |
| `.env.test.example` | All settings, documented. `test-env.sh init` copies it to `.env.test` (gitignored) and fills in secrets. |
| `test-env.sh` | Helper script (POSIX sh). |

## Two modes

**Mock mode** (default, `test-env.sh up`). Starts `sleepoverr` (built from the repo's
`Dockerfile`) and `mock-romm`. It's light and fast, fully offline, and the data is
deterministic. Use this mode to build and test the RomM sync module.

**Real-RomM mode** (`test-env.sh up-real`). Also starts a real, throwaway `romm` plus
its MariaDB `romm-db`, scanning the placeholder library. Use it to check that the sync
works against the genuine API. It mirrors RomM's reference compose
(`examples/docker-compose.example.yml` at RomM tag **4.9.2**, the one shown on
docs.romm.app/4.9.2 Quick Start). The deliberate differences are listed in comments in
the compose file. The RomM image runs its own Redis internally, so there is no separate
cache service.

| Service | URL (default ports) | Profile |
| --- | --- | --- |
| Sleepoverr | `http://<host>:8000/` (health: `/healthz`) | default |
| Mock RomM | `http://<host>:8081/api/heartbeat`, docs at `/api/docs` | default |
| Real RomM | `http://<host>:8082/` | `real-romm` |

Inside the compose network, Sleepoverr sees `ROMM_URL=http://mock-romm:8080` and
`ROMM_API_TOKEN=<MOCK_ROMM_CLIENT_TOKEN>`. **The app does not read these yet.** They are
there for the RomM sync module that comes in a later phase.

## Prerequisites

- Docker Engine 24+ with the Compose v2 plugin (`docker compose`). Legacy
  `docker-compose` v1 also works with the helper. The MariaDB healthcheck's
  `start_interval` needs Engine 25+; on older engines, delete that line.
- `python3` (only for `init`, which builds the placeholder library, and for the optional
  scripts) and `openssl` (falls back to python3).
- Free host ports 8000, 8081 and 8082 (change them in `dev/.env.test`).
- About 1 GB of RAM for mock mode, plus about 1.5 GB more for real-RomM mode.

## Quick start: local (macOS / Linux / Windows-WSL)

```sh
git clone <your-sleepoverr-repo> sleepoverr && cd sleepoverr
dev/test-env.sh init          # writes dev/.env.test (random secrets) + dev/data/library
dev/test-env.sh up            # builds and starts sleepoverr + mock-romm
dev/test-env.sh urls          # prints URLs, mock credentials, client token, SETUP_CODE
```

Open `http://localhost:8000`. The first-run "create admin" form asks for the
`SETUP_CODE` that `urls` prints.

Try the mock:

```sh
TOKEN=$(sed -n 's/^MOCK_ROMM_CLIENT_TOKEN=//p' dev/.env.test)
curl -s localhost:8081/api/heartbeat
curl -s -H "Authorization: Bearer $TOKEN" 'localhost:8081/api/roms?limit=5&offset=5'
curl -s -H "Authorization: Bearer $TOKEN" 'localhost:8081/api/roms?updated_after=2026-10-01T00:00:00Z'
```

Other commands are `up-real`, `status`, `logs [service]`, `restart [service]`, `down`,
`reset [-y]` (deletes volumes and `dev/data`) and `test-mock`.

**Windows:** run everything inside a WSL2 distro (Ubuntu/Debian) with Docker Desktop's
WSL integration enabled. Clone the repo into the WSL filesystem (`~/...`), not
`/mnt/c/...`, so line endings and file permissions stay correct.

## Quick start: Proxmox VE (Debian 12 LXC)

1. **Create the container.** In the PVE UI choose *Create CT* with the `debian-12-standard`
   template, or use the shell:

   ```sh
   pct create 210 local:vztmpl/debian-12-standard_12.*_amd64.tar.zst \
     --hostname sleepoverr-test --unprivileged 1 --features nesting=1,keyctl=1 \
     --cores 2 --memory 4096 --swap 1024 --rootfs local-lvm:20 \
     --net0 name=eth0,bridge=vmbr0,ip=dhcp
   pct start 210 && pct enter 210
   ```

   An unprivileged container works, but **`nesting=1,keyctl=1` are required** for Docker.
   On an existing CT, set them under *Options → Features*. Mock mode needs at least
   2 vCPU, 4 GB RAM and 20 GB disk. For real-RomM mode, give it 4 GB RAM or more. A
   Debian 12 VM works the same way if you prefer full isolation.

2. **Install Docker Engine** from Docker's apt repository (as root inside the CT):

   ```sh
   apt-get update && apt-get install -y ca-certificates curl git python3 openssl
   install -m 0755 -d /etc/apt/keyrings
   curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
     https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
     > /etc/apt/sources.list.d/docker.list
   apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   docker run --rm hello-world
   ```

3. **Clone and start:**

   ```sh
   git clone <your-sleepoverr-repo> /opt/sleepoverr && cd /opt/sleepoverr
   dev/test-env.sh init && dev/test-env.sh up
   dev/test-env.sh urls   # shows the CT's LAN IP
   ```

4. **Reach it from the LAN** at `http://<CT-IP>:8000` (and `:8081` for the mock). Ports
   are published on all interfaces. If the PVE firewall is enabled for the CT, allow
   8000/8081/8082 from your LAN. Give the CT a DHCP reservation or a static IP so the
   address stays the same.

5. **Optional reverse proxy.** If you already run one (Nginx Proxy Manager, Caddy,
   Traefik), point a hostname such as `sleepoverr-test.lan` at `http://<CT-IP>:8000`. For
   Nginx, see `docs/deployment/nginx.example.conf` (raise the body-size limit for ROM
   uploads). Keep the test stack off the public internet: its secrets are throwaway and
   the mock has no rate limiting.

## Mock RomM details

- **Auth.** The mock accepts any of:
  - `Authorization: Bearer rmm_<64 hex>` equal to `MOCK_ROMM_CLIENT_TOKEN` (RomM's
    "Client API Token" format, the method Sleepoverr will use);
  - a JWT from `POST /api/token`, either `grant_type=password` (form-encoded `username`,
    `password`, `scope`) or `grant_type=refresh_token`;
  - HTTP Basic with `MOCK_ROMM_USER` / `MOCK_ROMM_PASSWORD`.

  Anything else gets `401 {"detail": ...}`. If `MOCK_ROMM_CLIENT_TOKEN` is empty, the
  mock generates one and prints it to its log.
- **`GET /api/roms`** supports `limit` (1-10000, default 50), `offset`, `order_by`
  (`name`, `updated_at`, `created_at`, `fs_size_bytes`), `order_dir`, `search_term`,
  repeatable `platform_ids`, `updated_after`, `matched`, `last_played` and repeatable
  `statuses`. Like RomM, `statuses` also accepts `now_playing`, `backlogged` and `hidden`,
  multiple values are OR-ed, and hidden ROMs are left out unless `statuses=hidden` is
  given. The envelope is
  `{items,total,limit,offset,char_index,rom_id_index,filter_values}`.
- **Play data lives only in `rom_user`** (`last_played`, `status`, `rating`,
  `completion`, `backlogged`, `now_playing`, ...), never at the top level of a ROM. For a
  ROM the user never touched, RomM returns a placeholder `rom_user` with `id`, `user_id`
  and `rom_id` all `-1`, and the mock does the same. **A sync must handle that.**
- **`updated_after` filters on the ROM's `updated_at`,** as RomM does (`Rom.updated_at >
  updated_after`). A change to play data (`rom_user.updated_at` / `last_played`) does
  *not* bump it, so an incremental sync that relies only on `updated_after` can miss play
  updates. The fixtures reproduce this on purpose.
- **Response compatibility.** The shapes follow RomM's response schemas. Both `siblings`
  (older OpenAPI) and `sibling_roms` (current RomM) are emitted, and `user__username` /
  `pinned_media` are included in `rom_user`. Fields the mock has no data for are
  `null`, `[]` or `false`.
- **Editing fixtures.** Edit the JSON files in `mock-romm/fixtures/` (compact form; the
  server expands it to full RomM schemas), then run `dev/test-env.sh restart mock-romm`.
  The fixtures directory is bind-mounted, so no rebuild is needed.
- **Run the tests** with `dev/test-env.sh test-mock`, or from the repo root:
  `pip install -r dev/mock-romm/requirements-dev.txt && python -m pytest dev/mock-romm -q`.
  The mock has its own pytest config, so the backend's coverage options don't apply.

### Optional: real IGDB ids in the fixtures

The committed fixtures don't guess IGDB game ids. To fill them in, you need a Twitch
developer application ([api-docs.igdb.com](https://api-docs.igdb.com/#account-creation)):

```sh
export IGDB_CLIENT_ID=... IGDB_CLIENT_SECRET=...
python3 dev/mock-romm/resolve_igdb_ids.py --dry-run   # review the matches first
python3 dev/mock-romm/resolve_igdb_ids.py             # writes fixtures/roms.resolved.json (gitignored)
dev/test-env.sh restart mock-romm
```

The mock prefers `roms.resolved.json` whenever that file exists. Delete it to go back.
Unidentified ROMs are skipped unless you pass `--include-unidentified`. This script was
only tested against mocked HTTP, because the author's sandbox had no IGDB access, so
check the dry-run output.

## Real-RomM mode

```sh
dev/test-env.sh up-real
```

Open `http://<host>:8082`. On first start, RomM shows its **setup wizard**: create an
admin user there (it is local to this throwaway instance). Then trigger a library scan.
Without metadata provider keys, the 40 placeholder files show up as *unidentified*,
which is expected. To get matches, add `IGDB_CLIENT_ID` / `IGDB_CLIENT_SECRET` (or the
other providers' keys) to `dev/.env.test` and run `up-real` again.

To point Sleepoverr's (future) sync at this instance, create a client token in it (see
below) and set `ROMM_URL=http://romm:8080` and `ROMM_API_TOKEN=rmm_...` in
`dev/.env.test`.

The library is mounted read-only, and all RomM state lives in `sleepoverr-test_romm-*`
volumes. `dev/test-env.sh reset` removes all of it.

## Pointing at your real RomM

When the sync module exists, you may want to try it against your actual library. **Use
a dedicated, read-only token.** Nothing in this test stack should be able to change
your real RomM.

1. In your RomM, open **Client API Tokens**. The UI labels it "Client API Tokens"; it is
   under the settings/administration area, and the exact menu location can differ
   between RomM versions. Client tokens need a RomM version that has this feature.
2. Create a token named e.g. `sleepoverr-test` with **only read scopes**: `roms.read`,
   `platforms.read`, `me.read`. Copy the `rmm_...` value (it is shown once).
3. In `dev/.env.test`, set:

   ```sh
   ROMM_URL=https://romm.your.lan      # as reachable from inside the sleepoverr container
   ROMM_API_TOKEN=rmm_...
   ```

4. Run `dev/test-env.sh up` again. Revoke the token in RomM when you're done.

> **Warning:** never give the test environment a token with write scopes (`*.write`) or your
> admin password. Note that `.env.test` is plain text (mode 600, gitignored).

## Troubleshooting

- **`port is already allocated`.** Another service uses 8000/8081/8082. Change
  `SLEEPOVERR_PORT`, `MOCK_ROMM_PORT` or `ROMM_PORT_TEST` in `dev/.env.test` and run
  `up` again.
- **`required variable ... is missing a value`.** `dev/.env.test` is missing a
  secret. Run `dev/test-env.sh init` (or `init -f` to regenerate everything; this
  invalidates existing test DB passwords, so run `reset` too).
- **`.env.test not found`.** Run `dev/test-env.sh init` first.
- **Docker fails in the LXC** (`permission denied`, `operation not permitted`, overlay
  errors). Enable `nesting=1,keyctl=1` on the CT (*Options → Features*) and restart it.
  If problems persist, use a VM.
- **Containers restart or get killed (OOM).** Real-RomM mode needs 4 GB+ RAM in the
  CT/VM. Check `dmesg` on the PVE host and raise the memory.
- **`romm` stays unhealthy or can't reach the DB.** On first start, MariaDB needs up to a
  minute to initialise. Check `dev/test-env.sh logs romm-db`. If you changed
  `ROMM_DB_PASSWORD` after the DB volume was created, the old password still applies:
  run `dev/test-env.sh reset`.
- **The RomM login doesn't work.** A fresh RomM has no users; complete the setup
  wizard at `http://<host>:8082` first. The mock's user/password (`urls`) only applies to
  the mock.
- **Sleepoverr's "create admin" asks for a code.** Use `SETUP_CODE` from
  `dev/test-env.sh urls`.
- **`sleepoverr` is waiting for `mock-romm`.** Sleepoverr starts once the mock's
  healthcheck passes. Check `dev/test-env.sh logs mock-romm`.
- **Mock data looks stale after editing fixtures.** Run `dev/test-env.sh restart
  mock-romm`. Also check whether a `roms.resolved.json` exists, because it takes
  precedence.
