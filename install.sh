#!/usr/bin/env bash
# hermes-stack — one-script install for Hermes + Prometheus + Mnemosyne + gonka-router,
# with the web dashboard and optional public TLS via Caddy.
#
# usage:
#   ./install.sh up             clone layers, build, start everything, apply Hermes config
#   ./install.sh config         (re)apply the critical Hermes config.yaml settings
#   ./install.sh login-nous     OAuth login to Nous Portal (needed for the dashboard)
#   ./install.sh register-dash  register the dashboard for $DOMAIN and wire the client id
#   ./install.sh login-grok     OAuth login to xAI (needed for image vision)
#   ./install.sh vision         route image vision to Grok (main model stays Gonka)
#   ./install.sh verify         health-check every layer + an end-to-end pong
#
# edit .env first (at least GONKA_API_KEY; DOMAIN if you want public access).
set -euo pipefail
cd "$(dirname "$0")"

PROM_REPO=${PROM_REPO:-https://github.com/alexkolumbo/prometheus.git}
MNEMO_REPO=${MNEMO_REPO:-https://github.com/alexkolumbo/mnemosyne.git}
ROUTER_REPO=${ROUTER_REPO:-https://github.com/alexkolumbo/gonka-router.git}

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
load_env() { [ -f .env ] && { set -a; . ./.env; set +a; }; return 0; }

clone_layers() {
  command -v git >/dev/null || die "git is not installed"
  [ -d prometheus/.git ]   || git clone --depth 1 "$PROM_REPO"   prometheus
  [ -d mnemosyne/.git ]    || git clone --depth 1 "$MNEMO_REPO"  mnemosyne
  [ -d gonka-router/.git ] || git clone --depth 1 "$ROUTER_REPO" gonka-router
  mkdir -p prometheus/log mnemosyne/gateway/log hermes-web
}

ensure_env() {
  [ -f .env ] || cp .env.example .env
  load_env
  [ -n "${GONKA_API_KEY:-}" ] || die "set GONKA_API_KEY in .env first"
  if ! grep -qE '^HERMES_API_KEY=.{8,}' .env; then
    local k; k=$(head -c24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    sed -i "s|^HERMES_API_KEY=.*|HERMES_API_KEY=$k|" .env
    echo "generated HERMES_API_KEY"
  fi
  load_env
}

wait_health() {
  local i st
  for i in $(seq 1 40); do
    st=$(docker inspect hermes --format '{{.State.Health.Status}}' 2>/dev/null || true)
    [ "$st" = healthy ] && { echo "hermes is healthy"; return 0; }
    sleep 3
  done
  echo "warning: hermes not healthy yet — check 'docker logs hermes'"
}

cmd_config() {
  say "applying critical Hermes config.yaml settings"
  load_env
  docker exec -e GK="${GONKA_API_KEY}" hermes python3 - <<'PY'
import os, yaml
p = "/opt/data/config.yaml"
c = yaml.safe_load(open(p)) or {}
gk = os.environ["GK"]
gw = "http://mnemosyne-gateway:8781/v1"
c.setdefault("model", {}).update(
    {"provider": "custom", "base_url": gw, "default": "moonshotai/Kimi-K2.6", "api_key": gk})
c.setdefault("terminal", {})["backend"] = "local"
full = ["browser", "clarify", "delegation", "file", "image_gen", "memory", "messaging",
        "session_search", "skills", "terminal", "todo", "vision", "web"]
c["platform_toolsets"] = {"cli": full, "telegram": full, "api_server": full}
c["custom_providers"] = [{"name": "GonkaAI", "base_url": gw, "api_key": gk,
                          "model": "Qwen/Qwen3-235B-A22B-Instruct-2507-FP8"}]
c.setdefault("api_server", {}).update({"enabled": True, "host": "0.0.0.0", "port": 8642})
yaml.safe_dump(c, open(p, "w"), sort_keys=False, allow_unicode=True)
print("config.yaml patched (model -> gateway, terminal local, toolsets, custom provider)")
PY
  docker restart hermes >/dev/null
  echo "hermes restarted"
}

cmd_up() {
  command -v docker >/dev/null || die "docker is not installed"
  clone_layers
  ensure_env
  say "build images"; docker compose build
  load_env
  local profile=()
  if [ -n "${DOMAIN:-}" ] && [ "${DOMAIN}" != "hermes.example.com" ]; then
    profile=(--profile public)
    echo "public TLS for ${DOMAIN} via Caddy (ports 80/443 must be open, A record set)"
  else
    echo "no DOMAIN set -> Caddy skipped; panel reachable via SSH tunnel to 127.0.0.1:9119"
  fi
  say "start stack"; docker compose "${profile[@]}" up -d
  wait_health
  cmd_config
  cmd_verify || true
  say "core install done"
  echo "to finish the dashboard + images, run:"
  echo "  ./install.sh login-nous        # then in browser"
  echo "  ./install.sh register-dash     # needs DOMAIN in .env"
  echo "  ./install.sh login-grok        # then in browser (paste the in-page code)"
  echo "  ./install.sh vision"
}

cmd_login_nous() { docker exec -it hermes hermes auth add nous       --type oauth --no-browser --manual-paste; }
cmd_login_grok() { docker exec -it hermes hermes auth add xai-oauth  --type oauth --no-browser --manual-paste; }

cmd_register_dash() {
  load_env
  { [ -n "${DOMAIN:-}" ] && [ "${DOMAIN}" != "hermes.example.com" ]; } || die "set DOMAIN in .env first"
  say "register dashboard for https://${DOMAIN}"
  local out cid
  out=$(docker exec hermes hermes dashboard register --name hermes-dashboard \
        --redirect-uri "https://${DOMAIN}/auth/callback" 2>&1) \
    || { echo "$out"; die "register failed — run './install.sh login-nous' first"; }
  echo "$out"
  cid=$(printf '%s\n' "$out" | grep -oE 'HERMES_DASHBOARD_OAUTH_CLIENT_ID=[^[:space:]]+' | head -1 | cut -d= -f2-)
  [ -n "$cid" ] || die "could not parse the client id from register output"
  sed -i "s|^HERMES_DASHBOARD_OAUTH_CLIENT_ID=.*|HERMES_DASHBOARD_OAUTH_CLIENT_ID=$cid|" .env
  docker compose up -d hermes
  echo "client id wired; once DNS for ${DOMAIN} points here, the panel is live at https://${DOMAIN}"
}

cmd_vision() {
  docker exec hermes hermes config set auxiliary.vision.provider xai-oauth
  docker exec hermes hermes config set auxiliary.vision.model grok-4
  docker restart hermes >/dev/null
  echo "image vision routed to Grok (grok-4); main text model stays Gonka"
}

cmd_verify() {
  say "layer health"
  docker exec hermes sh -c '
    for u in prometheus-proxy:8780 mnemosyne-gateway:8781 mnemosyne-store:8782 gonka-router:8783; do
      printf "  %-24s %s\n" "$u/healthz" "$(curl -s -m5 -o /dev/null -w "%{http_code}" http://$u/healthz)"
    done
    printf "  %-24s %s\n" "hermes:8642/health" "$(curl -s -m5 -o /dev/null -w "%{http_code}" http://localhost:8642/health)"
  '
  say "end-to-end pong (Hermes -> gateway -> proxy -> Gonka)"
  docker exec hermes sh -c '
    HK=$(printenv HERMES_API_KEY)
    curl -s -m120 -H "Authorization: Bearer $HK" -H "Content-Type: application/json" \
      -X POST http://localhost:8642/v1/chat/completions \
      -d "{\"model\":\"hermes-agent\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with one word: pong\"}],\"stream\":false}"
  '
  echo
}

case "${1:-help}" in
  up)            cmd_up ;;
  config)        cmd_config ;;
  login-nous)    cmd_login_nous ;;
  register-dash) cmd_register_dash ;;
  login-grok)    cmd_login_grok ;;
  vision)        cmd_vision ;;
  verify)        cmd_verify ;;
  *) sed -n '2,18p' "$0"
     echo
     echo "commands: up | config | login-nous | register-dash | login-grok | vision | verify" ;;
esac
