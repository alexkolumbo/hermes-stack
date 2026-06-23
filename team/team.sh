#!/usr/bin/env bash
# team mode: one isolated Hermes (+ bot + web subdomain) per person, sharing one
# prometheus-proxy + gonka-router + Caddy. Edit team/team.users first, and set
# DOMAIN (and the shared GONKA_API_KEY fallback) in ../.env.
#
#   ./team/team.sh up         generate + build + start the whole team stack
#   ./team/team.sh config     apply the Hermes settings to every instance
#   ./team/team.sh dash <id>  set up the web dashboard for one person
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] && { set -a; . ./.env; set +a; }
VPY=/opt/hermes/.venv/bin/python   # the app venv has pyyaml; the system python3 does NOT

cmd_up() {
  command -v docker >/dev/null || { echo "docker required"; exit 1; }
  [ -d prometheus/.git ]   || git clone --depth 1 https://github.com/alexkolumbo/prometheus.git   prometheus
  [ -d gonka-router/.git ] || git clone --depth 1 https://github.com/alexkolumbo/gonka-router.git gonka-router
  mkdir -p prometheus/log
  python3 team/gen-team.py
  docker compose -f docker-compose.team.yml --env-file team/team.secrets.env up -d --build
  echo; echo "started. wait ~30s for the images to boot, then: ./team/team.sh config"
}

cmd_config() {
  for c in $(docker ps --format '{{.Names}}' | grep -E '^hermes-' | sort); do
    gk=$(docker exec "$c" printenv GONKA_API_KEY 2>/dev/null | tr -d '\r\n')
    docker exec -i -e GK="$gk" "$c" "$VPY" - <<'PY'
import os, yaml
p = "/opt/data/config.yaml"
c = yaml.safe_load(open(p)) or {}
gk = os.environ["GK"]; url = "http://prometheus-proxy:8780/v1"
c.setdefault("model", {}).update({"provider": "custom", "base_url": url,
                                  "default": "moonshotai/Kimi-K2.6", "api_key": gk})
c.setdefault("terminal", {})["backend"] = "local"
full = ["browser", "clarify", "delegation", "file", "image_gen", "memory", "messaging",
        "session_search", "skills", "terminal", "todo", "vision", "web"]
c["platform_toolsets"] = {"cli": full, "telegram": full, "api_server": full}
c["custom_providers"] = [{"name": "GonkaAI", "base_url": url, "api_key": gk,
                          "model": "Qwen/Qwen3-235B-A22B-Instruct-2507-FP8"}]
c.setdefault("api_server", {}).update({"enabled": True, "host": "0.0.0.0", "port": 8642})
yaml.safe_dump(c, open(p, "w"), sort_keys=False, allow_unicode=True)
print("patched config")
PY
    docker restart "$c" >/dev/null
    echo "configured $c"
  done
}

cmd_dash() {
  local id="${1:-}"
  [ -n "$id" ] || { echo "usage: ./team/team.sh dash <id>"; exit 1; }
  [ -n "${DOMAIN:-}" ] || { echo "set DOMAIN in ../.env first"; exit 1; }
  echo "1) Nous Portal login for hermes-$id (open the printed link):"
  docker exec -it "hermes-$id" hermes auth add nous --type oauth --no-browser --manual-paste
  echo "2) register the dashboard for https://hermes-$id.$DOMAIN:"
  local out cid U
  out=$(docker exec "hermes-$id" hermes dashboard register --name "hermes-$id" \
        --redirect-uri "https://hermes-$id.$DOMAIN/auth/callback" 2>&1) || { echo "$out"; exit 1; }
  echo "$out"
  cid=$(printf '%s\n' "$out" | grep -oE 'HERMES_DASHBOARD_OAUTH_CLIENT_ID=[^[:space:]]+' | head -1 | cut -d= -f2-)
  U=$(printf '%s' "$id" | tr 'a-z' 'A-Z')
  [ -n "$cid" ] || { echo "could not parse client id"; exit 1; }
  sed -i "s|^HERMES_DASHBOARD_OAUTH_CLIENT_ID_$U=.*|HERMES_DASHBOARD_OAUTH_CLIENT_ID_$U=$cid|" team/team.secrets.env
  docker compose -f docker-compose.team.yml --env-file team/team.secrets.env up -d "hermes-$id"
  echo "wired. add DNS hermes-$id.$DOMAIN -> server IP (grey cloud); panel: https://hermes-$id.$DOMAIN"
}

case "${1:-help}" in
  up)     cmd_up ;;
  config) cmd_config ;;
  dash)   shift; cmd_dash "$@" ;;
  *) sed -n '2,9p' "$0" ;;
esac
