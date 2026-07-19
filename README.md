# Atlas — AgenticOS

**Your household's own private AI operating system.** One brain across web, Android, and desktop that
runs *your* home: a multi-provider AI assistant, home automation, reminders & calendar, finance,
homeschool, music, image generation, messaging, and more — self-hosted on your own hardware, with your
data and secrets never leaving your box.

> This is the **public distribution channel** for Atlas. The application source stays private; you install
> from public container images + this repo. Clone this, run one script, and you have your own instance.

---

## What you're getting

Atlas is a **single-household appliance**: one install = one family's private system. It is not a cloud
service you rent — you own and run it. Highlights:

- **One continuous AI assistant** across every device (web / Android / desktop), with shared memory and a
  persona you can name and shape. Multi-provider: Anthropic (default), OpenAI, Gemini, OpenRouter, or a
  local model — your keys, your choice.
- **Cloud-LLM-first, no GPU required.** Runs cost-aware on cloud models by default; an optional GPU profile
  adds on-box local AI, voice, and image generation.
- **Home automation** via Home Assistant (optional), including voice control, presence, and device actions.
- **Everyday life:** reminders, calendar, daily brief, grocery/meals, finance/budgeting, homeschool lesson
  plans + devotionals, location sharing & "find my family," a shared kiosk/wall display, and a music engine.
- **Image & 3D generation** ($0, on your own GPU) via ComfyUI/FLUX — text-to-image, wallpapers, image-to-3D.
- **Messaging:** text from the web/desktop through your phone (Phone Link) or a Google Messages bridge.
- **Plugin marketplace** — everything household-specific is an opt-in plugin you enable when you want it.
  You can even install third-party plugins, or point Atlas at community plugin registries.
- **Community (opt-in):** a cross-instance directory so people on *different* Atlas instances can find each
  other by @handle and connect — your household data always stays private.
- **Private by design:** every secret is generated fresh on install; nothing is shared with the publisher
  or any other household. You can run it LAN-only, or reach it privately via Tailscale / publicly via a
  Cloudflare Tunnel — your choice.

---

## Requirements

- A machine to run it on — a home PC or server, **Windows or Linux/macOS**. Always-on is best.
- **~10 GB free + a few CPU cores.** No GPU required.
- **Docker Desktop** (the installer can install it for you on Windows) with the WSL2 backend on Windows.
- Optional: an **Anthropic API key** (or OpenAI/Gemini) to power the assistant — add it anytime.
- Optional (for host features like Home Assistant / image-gen): a Windows host for the **Atlas Agent**.

---

## Quick install

```bash
git clone https://github.com/AtlasAgenticOS/Atlas-dist.git
cd Atlas-dist
```

- **Windows:** `pwsh ./install.ps1`   (add `-InstallDocker` to auto-install Docker Desktop)
- **Linux/macOS:** `./install.sh`      (add `--install-docker`)

The installer checks prerequisites, **generates every secret for you**, writes a fresh `.env`, pulls the
public images, brings up the stack behind a built-in HTTPS edge, and waits until it's healthy. It **refuses
to run if a `.env` already exists**, so it can never clobber an existing install.

Then open the printed URL (default `http://localhost/Atlas/`) — a first-run **`/Setup`** wizard creates your
owner account. That's it. Full walkthrough: **[docs/QUICKSTART.md](docs/QUICKSTART.md)**.

> **Back up your `.env`** after install (especially `VAULT_MASTER_SECRET`) — it encrypts all your stored
> credentials and cannot be recovered if lost.

---

## After install

- **Remote access (optional):** Tailscale (private, recommended) or a Cloudflare Tunnel (public URL). See
  [docs/SELF-HOST.md](docs/SELF-HOST.md).
- **Apps:** the **web** UI works immediately; install the **Android**/**desktop** apps and point them at
  your server's URL + key.
- **Host features (Windows):** install the **Atlas Agent** from this repo's
  [Releases](https://github.com/AtlasAgenticOS/Atlas-dist/releases) (the `agent-v*` release) and pair it to
  your instance via `/Atlas/AgentSetup` — needed for Home Assistant, image generation, and host actions.
- **Turn on what you use:** open the **Plugin Store** and enable the features you want. Nothing runs until
  enabled and configured.

---

## Updates

Atlas updates by pulling new **public images** — no source, no rebuild:

```bash
pwsh ./scripts/apply-update-images.ps1   # reads the feed, pulls the new tag, health-gates, auto-rolls-back
```

The `core-version.json` feed in this repo tells your instance when a new version is available; the update
backs up your DB, pulls the target image tag, restarts, and rolls back automatically if health doesn't come
green. The Atlas Agent auto-updates itself from the `agent-v*` releases here.

---

## Plugins & the community marketplace

- Enable/disable features in the **Plugin Store**. Household-specific integrations (Home Assistant, media,
  phone link, finance, image-gen, …) are all opt-in plugins.
- **Install third-party plugins** by URL, or **subscribe to community marketplaces** (Admin → System Updates
  → *Plugin marketplaces*). A registry is just a public `plugin-registry.json` — anyone can host one.
- Author your own: see the plugin guide, and package it with `scripts/package-plugin.ps1`.

---

## What's in this repo

| Path | What |
|---|---|
| `install.ps1` / `install.sh` | the self-host installer (generates secrets, pulls images, brings up the stack) |
| `docker-compose.yml` + `docker-compose.selfhost.yml` | the container stack + the self-host edge overlay |
| `.env.example` | the template the installer fills with fresh secrets |
| `deploy/selfhost/Caddyfile` | the built-in HTTPS reverse-proxy edge |
| `scripts/apply-update-images.ps1` | pull-based updater (image tags via the feed) |
| `scripts/setup-image-gen.ps1` | optional GPU image-gen installer (ComfyUI + FLUX) |
| `core-version.json` | the update feed your instance checks |
| `plugin-registry.json` + `plugins/` | the built-in plugin marketplace |
| `agent/atlas-agent-version.json` + [Releases](https://github.com/AtlasAgenticOS/Atlas-dist/releases) | the host Agent update feed + binaries |
| `docs/` | quickstart, self-host guide, and user guide |

Container images: **`ghcr.io/atlasagenticos/*`** (public). Application source is private.

---

## Docs & help

- **[docs/QUICKSTART.md](docs/QUICKSTART.md)** — from nothing to a working instance.
- **[docs/SELF-HOST.md](docs/SELF-HOST.md)** — deeper self-host reference (remote access, GPU, HA, ports).
- **[docs/USER-GUIDE.md](docs/USER-GUIDE.md)** — using Atlas day to day.
- Questions / issues: open an issue on this repo.

---

## Privacy & ownership

Your data lives in **your** database on **your** machine. Secrets are generated per-install and never shared.
The publisher cannot see your instance. Copying another instance's `.env` is never supported — each
household is cryptographically isolated. You are running your own private system.
