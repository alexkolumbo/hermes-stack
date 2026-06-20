# hermes-stack

A one-script deployment for running the Hermes agent against Gonka with two
things bolted on that make it actually usable: a proxy that defeats Gonka's
output-length cap, and a server-side context/memory layer. It also wires up the
Hermes web dashboard behind TLS and optional Grok vision for images.

It pulls together four pieces:

- **Hermes** — the agent itself (Nous Research). Exposes an OpenAI-compatible API
  on `:8642` and a web dashboard on `:9119`. It holds the model choice and keys.
- **Prometheus** — a transparent continuation proxy. Gonka cuts every response at
  a few thousand tokens; Prometheus detects the cut and stitches the answer back
  together, so a coding agent can write a whole file in one go. It also asks the
  provider for a large output up front, so when the cap is raised answers stop
  being split. ([repo](https://github.com/alexkolumbo/prometheus))
- **Mnemosyne** — a context/memory layer. A gateway shrinks the window and keeps a
  running summary; a store keeps long-term memory with vector recall (fastembed +
  qdrant). ([repo](https://github.com/alexkolumbo/mnemosyne))
- **gonka-router** — a registry-aware router over the Gonka network. Runs alongside
  as a demo; not in the request path. ([repo](https://github.com/alexkolumbo/gonka-router))

How a request flows:

```
Hermes  ->  mnemosyne-gateway:8781  ->  prometheus-proxy:8780  ->  proxy.gonka.gg
                   |                            (continuation)         (Gonka)
                   +-> mnemosyne-store:8782 -> mnemosyne-qdrant:6333

dashboard:  Caddy(:443, TLS)  ->  hermes-web (nginx)  ->  hermes:9119
images:     Hermes  ->  Grok (xAI)  directly, via auxiliary.vision
```

The model config lives in Hermes on purpose — Prometheus and Mnemosyne are
deliberately dumb pass-throughs, so they work with any model without being told
about it.

## Requirements

- A Linux server (tested on Ubuntu 24.04/26.04), x86_64, 8–16 GB RAM recommended
  (qdrant + the embedder), Docker with the compose plugin, and git.
- A Gonka API key (Bearer for `proxy.gonka.gg`).
- For the public dashboard: a domain with an A record on the server, and a Nous
  Portal account (the dashboard login).
- For image recognition: an xAI/Grok account.

You enter your own keys and complete the OAuth logins yourself — the script never
handles your credentials.

## Quick start

```bash
git clone https://github.com/alexkolumbo/hermes-stack.git
cd hermes-stack
cp .env.example .env
# edit .env: set GONKA_API_KEY, and DOMAIN if you want public access
./install.sh up
```

`up` clones the three layer repos, builds them, starts the whole stack, and
applies the Hermes settings that matter (model pointed at the local gateway,
`terminal.backend: local`, full toolsets on the API-server profile, the GonkaAI
custom provider). When it finishes it prints an end-to-end `pong` from a request
that went all the way to Gonka and back.

If you set a real `DOMAIN`, Caddy comes up too and serves it on 80/443 with an
automatic Let's Encrypt certificate. Without a domain, Caddy is skipped and the
panel is reachable over an SSH tunnel:

```bash
ssh -L 9119:127.0.0.1:9119 root@<server>
# then open http://localhost:9119
```

## Finishing the dashboard and images

These steps need you to log in through a browser, so they're separate commands:

```bash
./install.sh login-nous       # log in to Nous Portal (open the printed link)
./install.sh register-dash    # registers the dashboard for your DOMAIN, wires the OAuth client
./install.sh login-grok       # log in to xAI — paste the code xAI shows on the page
./install.sh vision           # route image vision to Grok (grok-4)
```

After `register-dash`, once your domain's DNS points at the server, the dashboard
is live at `https://<domain>` behind a Nous Portal login.

`vision` keeps Gonka as the main text model and only sends images to Grok. Don't
switch the main model to Grok in the dashboard — that routes around the gateway
and you lose the continuation and memory layers.

## Re-running things

- Changed `.env`: `docker compose up -d hermes` (a plain restart won't reread it).
- Changed `config.yaml`: `docker restart hermes` is enough (it lives in a volume).
- Updated a layer: `docker compose up -d --build <service>`.
- Re-apply the Hermes settings any time: `./install.sh config`.
- Check everything: `./install.sh verify`.

## Notes from running this for real

- The dashboard has to run inside the Hermes container (the `HERMES_DASHBOARD_*`
  env). A second container on the same `/opt/data` volume starts a second gateway
  and they deadlock on the data locks.
- Keep `.env` as LF / UTF-8 with no BOM, and don't put a comment on the same line
  as a value — docker tolerates it but anything parsing the file by hand won't.
- `hermes login` was removed in recent images; use `hermes auth add <provider>
  --type oauth`. For xAI, paste the code shown on the consent page, not the
  `127.0.0.1/callback` URL.
- A freshly created DNS record gets negatively cached for a while (around 30 min
  on Cloudflare), and a server usually can't reach its own public IP (hairpin).
  Verify from outside or against the authoritative nameserver, not from the box.

## License

MIT. See LICENSE. The layer repos are MIT as well.
