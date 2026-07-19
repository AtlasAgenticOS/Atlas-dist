# Atlas user guide

A short tour of what Atlas does and how to use it, once it's installed (see
[QUICKSTART.md](QUICKSTART.md) for setup). Atlas is **one brain for your household** - an AI
assistant plus the data, devices, and automations behind it, all on your own box.

## The clients (same account, one continuous conversation)
- **Web** - the full dashboard, chat, settings. Any browser at your Atlas URL.
- **Android** - native app: dashboard, voice assistant + wake word, notifications, location.
- **Desktop** - a tray app (Windows) with notifications, a wall display, and quick chat.
- **TV** - a leanback home + kiosk wall view on Android TV / Chromecast.

Whatever you talk to, it's the **same assistant and the same conversation** - memory and context
are shared across clients.

## The assistant
Talk to it in plain language (type or voice). It can answer questions and **take actions** across
your enabled plugins - e.g. "what's on my calendar," "turn off the living room lights," "remind
me to call mom at 6," "what should we watch," "how much did we spend on groceries." It asks before
doing anything irreversible or outward-facing.

- **Voice:** on Android, a wake word starts it hands-free; say "stop" to cancel.
- **Personality:** each user can name their assistant and set its persona ("call yourself Friday,"
  "be more playful") in Settings -> Your Assistant.
- **Cost-aware:** it uses the cheapest capable model by default; you add your own Anthropic key so
  usage is billed to you.

## Dashboards
- **Today** - forward-looking daily brief (weather, calendar, bills due, health, news).
- **Activity** - what happened in the last 24h (automations, agent runs, spend).
- **Kiosk / Wall** - a fullscreen always-on view for a TV or spare screen.

## Plugins = your features
Everything household-specific is an **opt-in plugin** in the **Plugin Store** - enable only what
you use, and nothing runs until it's enabled + configured. Common ones:
- **Home Assistant** - lights, locks, sensors, media, "turn on/off," scenes. Needs your HA LAN
  URL + a token.
- **Media** - "what should we watch," continue watching, play on a TV (via a media provider like
  Jellyfin).
- **Phone link** - send/receive SMS, message people.
- **Finance** - budgets, spending, bills.
- **Reminders / chores / homeschool / music / image generation** - each its own toggle.
- **Third-party plugins** - browse the marketplace and install more (Admin -> System Updates).

## Users, guests, and kids
- The first account is the **owner (superadmin)** - can manage users, plugins, and the system.
- Add **household members**, **kids** (with content + AI limits), and **guests** (a limited
  subset - games, media, calls) from the Admin pages. Everyone's personal data is scoped to them.

## Admin (owner only)
- **Plugin Store** - enable/configure/install features.
- **System Updates** - one-click core update (with backup + auto-rollback) and the plugin
  marketplace.
- **Users** - invite/manage members, guests, and kids.
- **Admin Console** - the owner can even change the system by talking to it (conversational admin).

## Getting help
- Setup + troubleshooting: [SELF-HOST.md](SELF-HOST.md) and [QUICKSTART.md](QUICKSTART.md).
- Feature-specific setup (HA remote, Level Sense, etc.): the [runbooks](runbooks/).
