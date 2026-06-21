# team mode

Run an isolated Hermes per person, sharing one stateless proxy/router/Caddy.
Each person gets their own agent (own `/opt/data` — sessions, files, memory), their
own Telegram bot, and their own web subdomain. Nothing of theirs is shared, so
contexts never cross. The proxy and router are input-transparent and hold no
per-person state, so sharing them leaks nothing — and the streaming + degeneration
guard + continuation in the proxy benefit everyone for free.

```
Telegram: a bot per person ─┐
                            ├─ hermes-alice (vol) ── web-alice ─┐
                            ├─ hermes-bob   (vol) ── web-bob   ─┤─ Caddy ─ hermes-<id>.DOMAIN
                            └─ hermes-…    (own /opt/data)      ┘
   every hermes-* ── base_url ─▶ ONE prometheus-proxy (guard + continuation) ─▶ Gonka
   ONE gonka-router.  Gonka key: per-person or one shared (from ../.env).
```

## Why a Hermes each (not one bot for everyone)

The unit of isolation in Hermes is the instance — its `/opt/data` holds the
sessions, the workspace/files, and the memory. Putting several people on one bot
only separates the chat threads; their files, memory and dashboard would be shared.
And one bot token can only be polled by one Hermes (two pollers fight with a 409),
so multiple isolated people on Telegram means multiple bots. Hence: one Hermes +
one bot + one subdomain per person.

## Setup

1. Prereqs: a server with Docker + git, a domain whose `hermes-<id>.DOMAIN` records
   you can point at it, a Nous Portal account per person (the dashboard login), and
   one Telegram bot per person from @BotFather. Size the box for ~0.5–1 GB per
   Hermes plus the shared layers (5 people ≈ 5–8 GB).

2. From the repo root:
   ```bash
   cp .env.example .env          # set DOMAIN and the shared GONKA_API_KEY
   cp team/team.users.example team/team.users   # add your people + bot tokens
   ./team/team.sh up             # generate + build + start everything
   ./team/team.sh config         # apply the Hermes settings to every instance
   ```

3. Per person, set up the web panel (web access) — needs their Nous login:
   ```bash
   ./team/team.sh dash alice
   ```
   Then add a DNS record `hermes-alice.DOMAIN -> server IP` (grey cloud / DNS-only).
   Telegram works as soon as `config` has run (each bot polls its own token).

## Keys

`gonka_key` in `team.users` is optional per person. One shared `GONKA_API_KEY`
(from `../.env`) is fine for a handful of people; give a heavy user — or a larger
team — their own key so rate limits and billing are separated.

## What's generated (gitignored, holds secrets — never commit)

`docker-compose.team.yml`, `Caddyfile.team`, `team/team.secrets.env` (per-person
API keys, bot tokens, OAuth client ids), `team/nginx-<id>.conf`. Re-run
`./team/team.sh up` after editing `team.users` to regenerate.

## The memory layer (Mnemosyne)

The shared chat path here is `Hermes -> prometheus-proxy -> Gonka`. Mnemosyne is
left out on purpose: its store keys context by a hash of the system prompt + first
message, so a *shared* store could collide across people. Each Hermes still has its
own native memory in `/opt/data`. If you want the Mnemosyne layer too, run a
gateway per person with a distinct namespace (`MNEMOSYNE_NS=<id>`) in front of a
shared store, and point `model.base_url` at that per-person gateway instead.
