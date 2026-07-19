# Self-hosting Atlas

How to stand up your own Atlas instance on your own hardware. Atlas is a
single-home appliance: one container stack + one database per household, on one
box. Your data and secrets never leave that box.

> Status (2026-07): the **base stack installer works** (`install.ps1` brings up
> the containers with freshly generated secrets). Several convenience pieces are
> still in progress and are called out inline as **WIP** - where something is WIP,
> the manual steps to do it yourself are given.

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| Windows 10/11 | The reference host. (Linux works too but is untested for the installer.) |
| Docker Desktop + WSL2 | `winget install Docker.DockerDesktop`. Start it before installing. |
| ~20 GB free disk | SQL Server + images + your media metadata/vault. |
| PowerShell 7+ | `pwsh`. The installer targets it. |
| (Optional) NVIDIA GPU | Only if you want on-box local AI/voice. Atlas runs cloud-LLM-first without one. |

Atlas does **not** need a GPU. Without one it uses cloud models (Haiku-first, cost
aware) and skips on-device voice/LLM. That is the default and is fine.

## 2. Install the base stack

```powershell
git clone https://github.com/AtlasAgenticOS/Atlas-dist.git
cd Atlas-dist
pwsh ./install.ps1
```

`install.ps1`:

1. Checks Docker / Compose / engine / WSL / GPU.
2. **Refuses to run if a `.env` already exists** - so it can never clobber a
   configured box.
3. Generates every secret with a CSPRNG (`MSSQL_SA_PASSWORD`, `JWT_SECRET`,
   `API_KEY`, `VAULT_MASTER_SECRET`, `GMESSAGES_INGEST_SECRET`,
   `ATLAS_MUSIC_STREAM_TOKEN_SECRET`, `TURN_SECRET`) into a fresh `.env`.
4. Creates the data root (`ATLAS_DATA_ROOT`, default `C:\Atlas`) and its subfolders.
5. `docker compose up -d --build` and waits for `/Atlas/api/ping`.

Optional parameters:

```powershell
pwsh ./install.ps1 -DataRoot 'D:\AtlasData' -BaseUrl 'http://localhost:8080/Atlas'
```

`-DataRoot` is written to `ATLAS_DATA_ROOT` in the generated `.env`; every compose
volume mount reads it (`${ATLAS_DATA_ROOT:-C:\Atlas}`), so a custom location just
works with no compose edits.

> **Back up `.env` immediately**, especially `VAULT_MASTER_SECRET` - it encrypts
> every user's stored credentials (email, Home Assistant, etc.). Lose it and those
> become unrecoverable. **Never copy another instance's `.env`** - a household's
> secrets are unique to it.

## 3. First-run configuration

### Create the owner account
Open `http://localhost:8080/Atlas`. The first account you register becomes the
owner/admin.

> **WIP - guided `/Setup` wizard.** A single guided first-run page (create owner ->
> set base URL -> enter Anthropic key -> optionally enable plugins) is planned. Until
> it ships, do these steps manually via the normal register + Settings pages. The
> owner-gets-superadmin bootstrap and the seed cleanup are also part of this track.

### Add your Anthropic API key
Anthropic keys are **per-user** (each person bills their own), set in **Settings**,
not in `.env`. The owner should add theirs first so the assistant works.

### Enable the plugins you want
Everything household-specific is an opt-in plugin (Home Assistant, media library,
phone link, finance, image-gen, Twitch, ...). Open the **Plugin Store** and enable
what you use. Nothing runs until enabled + configured.

### Core updates & the plugin marketplace (Admin -> System Updates)
Superadmins get an **/Admin/Updates** page (Track G, the "WordPress" surface):
- **Core version + update check** against a public release feed - "up to date" or
  "vX available".
- **Third-party plugin marketplace** - browse a registry and one-click **Install**,
  or install a plugin package `.zip` from a URL. Third-party plugins run in your
  instance with your data (single-household model - the risk is your own), so you
  acknowledge that before installing.
- **Uninstall** + a **"Restart to activate"** button (installs load at boot).

Third-party plugins live in `${ATLAS_DATA_ROOT}/plugins/{id}/`. If a bad plugin
ever wedges startup, set `ATLAS_SAFE_MODE=true` and restart to boot without them,
then remove the folder. To write your own plugin, see [PLUGINS.md](PLUGINS.md).

## 4. Remote access (reach Atlas away from home)

Local `http://localhost:8080/Atlas` works on the box itself. To reach it from your
phone or elsewhere, pick one:

| Option | How | Notes |
|---|---|---|
| **Tailscale** (recommended) | Install Tailscale on the host, sign in. Use its MagicDNS name as your base URL. | No router/DNS/port-forward. Private to your tailnet. |
| **Cloudflare Tunnel** | `cloudflared` tunnel to a hostname you own. | Public hostname; more setup. |
| LAN only | Use the host's LAN IP. | Home network only. |

After choosing, set your public URL as `APP_BASE_URL` in `.env` and restart, so
email links and client bootstrap use it.

> **WIP - guided remote-access setup.** The wizard will offer to set Tailscale or
> Cloudflare up for you and auto-fill `APP_BASE_URL`. For now do it by hand.

## 5. Home Assistant (optional, for home automation)

If you want the smart-home features, Atlas talks to a Home Assistant instance.

> **Important:** on Windows, **Home Assistant must NOT run in Docker** - Docker's
> NAT breaks LAN device discovery. Run **HA OS in a Hyper-V VM** (or on separate
> hardware / a Pi). Then, in the Atlas **Home** plugin, enter your HA base URL +
> a long-lived access token.

> **WIP - guided HA provisioning.** A helper that stands up the HA Hyper-V VM for
> you is planned (Track B5). For now, install HA yourself and point Atlas at it.

**Atlas controls HA over the LAN** - it never needs a public URL or a tunnel. The only
thing HA needs from you is the `ha:base_url` (LAN IP) + a long-lived token in the Home
plugin. If you *also* want to open HA's own dashboard from outside your home, set up a
Cloudflare Tunnel at `ha.<your-domain>` - optional, and covered in
`docs/runbooks/homeassistant-remote-tunnel.md` (use a tunnel, never a port-forward).

## 6. Level Sense sensor capture (optional, needs LAN DNS)

If you run Level Sense Sentry freezer/temperature sensors and want Atlas to capture
their readings locally, the LAN's DNS must point `cloud.level-sense.com` at the Atlas
host (the devices phone home to a hardcoded cloud URL; you intercept it with DNS).

> **Important:** run a local DNS (Technitium) **native** on Windows - not in Docker
> (LAN UDP/53 through Docker's WSL NAT is unreliable, same as HA).

```powershell
pwsh ./scripts/setup-levelsense-capture.ps1            # add -InstallTechnitium if needed
```

Then point your **router's DHCP DNS** at the Atlas host so LAN devices use it. Full
walkthrough (incl. the Pi-hole/AdGuard alternative): `docs/runbooks/levelsense-capture-setup.md`.

## 7. Other optional stacks

Each is an opt-in plugin with its own setup:

- **Discord music bot** - needs a Discord app + token (`.env`: `DISCORD_*`).
- **SMS bridge (gmessages)** - QR-pair your phone.
- **Atlas Meet / calling (TURN)** - `coturn` for NAT traversal (`.env`: `TURN_*`). **Requires
  forwarding these UDP ports to the host** (TURN media is real UDP, can't go through a tunnel):
  **UDP 3478** (STUN/TURN control) and **UDP 49160-49200** (media relay range). Skip if you never
  use Meet/calls. The web edge itself only needs 80/443 (via DMZ or a forward).
- **Image generation** - ComfyUI/FLUX on a GPU host.

None run unless enabled + configured. See `.env.example` for every variable, grouped
required / recommended / optional.

## 8. Updating

```powershell
cd Atlas
git pull
docker compose up -d --build
```

Your `.env` and `ATLAS_DATA_ROOT` are untouched by updates.

## 9. What is still manual (honest list)

- The `/Setup` wizard (section 3) - do first-run config via Settings for now.
- Guided remote-access + Home Assistant provisioning (sections 4-5).
- GPU-tier auto-detection profiles in compose (local AI containers are on by
  default; a no-GPU profile switch is planned).
- Dependency auto-install (Docker/WSL2, HA VM, tunnel) - detect-and-guide today.

These are tracked; the base stack itself installs and runs from `install.ps1`.
