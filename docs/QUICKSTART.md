# Atlas quickstart - stand up your own household instance

The happy path from nothing to a working Atlas on your own hardware. Your data and secrets
never leave your box. For the deeper reference see [SELF-HOST.md](SELF-HOST.md); for what's
still rough see [INSTALL-READINESS.md](INSTALL-READINESS.md).

## 0. What you need
- A machine to run it on (a home PC/server; Windows or Linux/macOS). Always-on is best.
- ~10 GB free + a few CPU cores. **No GPU required** (Atlas runs cloud-LLM-first without one).
- The installer will offer to install **Docker** for you if it's missing.
- Optional: an **Anthropic API key** (powers the assistant; add anytime).

## 1. Get the code + run the installer
```bash
git clone https://github.com/AtlasAgenticOS/Atlas-dist.git
cd Atlas-dist
```
- **Windows:** `pwsh ./install.ps1`   (add `-InstallDocker` to auto-install Docker)
- **Linux/macOS:** `./install.sh`      (add `--install-docker`)

The installer checks prerequisites, installs Docker if you approve, **generates every secret
for you**, writes a fresh `.env`, brings up the stack (base + the Caddy edge), and waits until
the API is healthy. It **refuses to run if a `.env` already exists**, so it can't clobber an
existing install.

> First run builds images - it can take several minutes.

## 2. Create your owner account (`/Setup`)
Open the URL the installer prints (default `http://localhost/Atlas/`). On a brand-new install
it lands on **`/Setup`**: pick a username + password (this becomes the **owner / superadmin**),
optionally paste an Anthropic key, and you're in. (If users already exist, `/Setup` bounces to
`/Login` - it only runs once.)

## 3. Reach it from outside your home (optional)
Pick one - both are optional profiles, neither needs a port-forward:
- **Tailscale (recommended, private):** reachable only by your devices.
  ```bash
  # .env:  TS_AUTHKEY=tskey-...   (login.tailscale.com/admin/settings/keys)
  docker compose -f docker-compose.yml -f docker-compose.selfhost.yml --profile tailscale up -d
  ```
- **Cloudflare Tunnel (public URL):** anyone with the link can reach it (needed for a public
  store, shared links, or people who won't install a VPN). See
  [deploy/selfhost/README.md](../deploy/selfhost/README.md).

For a real public domain with auto-HTTPS, set `ATLAS_DOMAIN=atlas.example.com` in `.env` and
re-run the installer. LAN-only (no remote access) is a fine default to start.

## 4. Connect the apps
- **Web** works immediately at your Atlas URL.
- **Android / Desktop:** install the app, then in **Settings** enter your server's **Base URL**
  (e.g. `https://atlas.<tailnet>.ts.net/Atlas/api`) + API key. (If you build the apps yourself for
  your household, set `AtlasDefaults.BaseUrl` once per client so they default to your server -
  see [INSTALL-READINESS.md](INSTALL-READINESS.md#p1---the-turnkey-experience).)

## 5. (Windows host) Install the Atlas Agent - for host-integration features
Home Assistant, **image generation** (ComfyUI on your GPU), and host shell/automation run through the
**Atlas Agent**, a small Windows service on the Atlas host. The container platform works fine without
it - install it only if you want those features.
1. Download **`atlas-agent-setup.msi`** from the latest `agent-v*` release at
   `github.com/AtlasAgenticOS/Atlas-dist/releases` and run it (or the standalone `atlas-agent.exe`).
2. In Atlas open **`/Atlas/AgentSetup`**, copy the pairing token, and give it to the agent - that points
   it at **your** instance. It then auto-updates itself from the org.
3. For GPU image-gen, also install ComfyUI + models once: `pwsh ./scripts/setup-image-gen.ps1`.

## 6. Turn on what you use
Everything household-specific is an **opt-in plugin**. Open the **Plugin Store** and enable what
you want - Home Assistant, media, phone link, finance, image-gen, etc. Nothing runs until enabled
and configured. Some plugins have their own setup (e.g. Home Assistant needs a LAN URL + token -
[runbook](runbooks/homeassistant-remote-tunnel.md); Level Sense capture needs local DNS -
[runbook](runbooks/levelsense-capture-setup.md)).

## Updating
From **Admin -> System Updates** (one-click, with backup + health-gate + auto-rollback), or by
hand: `git pull` then re-run the compose up. Your `.env` and data are untouched.

## If something's wrong
- API not healthy? `docker compose -f docker-compose.yml -f docker-compose.selfhost.yml logs atlas-api`
- Edge not responding? Check the `caddy` container is up and `ATLAS_DOMAIN` matches how you're
  reaching it.
- Full troubleshooting + honest "still manual" list: [SELF-HOST.md](SELF-HOST.md).
