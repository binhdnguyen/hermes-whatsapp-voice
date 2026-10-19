#!/usr/bin/env bash
# Mac Mini deployment of this fork into the Hermes `cao` profile. Run one step at a time:
#
#   deploy/mac-mini/apply.sh preflight          # read-only checks, safe any time
#   deploy/mac-mini/apply.sh gateway            # API server on the default profile + gateway restart
#   HWV_OWNER_NUMBER=+84... deploy/mac-mini/apply.sh plugin
#   deploy/mac-mini/apply.sh pair               # interactive: scan the QR from the BOT phone
#   deploy/mac-mini/apply.sh service            # launchd agent that keeps the sidecar running
#   deploy/mac-mini/apply.sh test               # rings the owner once
#   deploy/mac-mini/apply.sh status
#
# Undo with deploy/mac-mini/rollback.sh. Nothing here prints or commits secrets.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
PROFILE=cao
HERMES=${HERMES:-$HOME/.local/bin/hermes}
H=$HOME/.hermes
P=$H/profiles/$PROFILE
PLUGIN=hermes-whatsapp-voice
FORK=binhdnguyen/hermes-whatsapp-voice
DATA=$P/plugin-data/$PLUGIN
BIN_SRC=$REPO_DIR/sidecar/target/release/hermes-wa-voice
LABEL=com.hermes.whatsapp-voice
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
API=http://127.0.0.1:8642
TS=$(date +%Y%m%d-%H%M%S)

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Value of KEY in an .env file, without echoing it anywhere.
env_value() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- | sed -E "s/^[\"']//; s/[\"']\$//"; }
has_env() { [ -n "$(env_value "$1" "$2")" ]; }

cao_api_ok() {
  local key code
  key=$(env_value "$P/.env" API_SERVER_KEY)
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $key" "$API/p/$PROFILE/v1/capabilities" || true)
  [ "$code" = 200 ]
}

gateway_pid() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$H/gateway.pid" 2>/dev/null || true; }

restart_gateway() {
  local before after
  before=$(gateway_pid)
  say "Restarting the multiplexed gateway (all bots drop for a few seconds; PID before: ${before:-none})"
  "$HERMES" -p default gateway restart
  for _ in $(seq 1 60); do
    after=$(gateway_pid)
    [ -n "$after" ] && [ "$after" != "$before" ] && break
    sleep 1
  done
  echo "PID after: ${after:-none}"
}

preflight() {
  say "Hermes"
  local v; v=$("$HERMES" --version 2>/dev/null); echo "${v%%$'\n'*}"
  say "Sidecar binary (built from this fork)"
  [ -x "$BIN_SRC" ] || die "missing $BIN_SRC; run: (cd sidecar && cargo build --release --locked)"
  shasum -a 256 "$BIN_SRC"
  say "Fork commit"
  local sha; sha=$(git -C "$REPO_DIR" rev-parse HEAD)
  echo "HEAD $sha ($(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD))"
  git -C "$REPO_DIR" fetch -q origin
  git -C "$REPO_DIR" branch -r --contains "$sha" | grep -q origin/ || die "HEAD is not pushed to origin"
  [ -z "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)" ] || die "uncommitted changes in $REPO_DIR"
  say "Secrets present in $PROFILE (names only)"
  for k in GEMINI_API_KEY GOOGLE_API_KEY API_SERVER_KEY; do
    has_env "$P/.env" "$k" && echo "  $k: set" || echo "  $k: MISSING"
  done
  has_env "$P/.env" GOOGLE_API_KEY || has_env "$P/.env" GEMINI_API_KEY || die "no Gemini key in $PROFILE"
  has_env "$P/.env" API_SERVER_KEY || die "no API_SERVER_KEY in $PROFILE"
  say "Default profile API server"
  echo "  platforms.api_server.enabled = $("$HERMES" -p default config get platforms.api_server.enabled 2>/dev/null || echo unset)"
  has_env "$H/.env" API_SERVER_KEY && echo "  default API_SERVER_KEY: set" || echo "  default API_SERVER_KEY: not set (gateway step adds one)"
  cao_api_ok && echo "  $API/p/$PROFILE/v1 answers 200" || echo "  $API/p/$PROFILE/v1 not reachable yet (expected before the gateway step)"
  say "Plugin and service"
  "$HERMES" -p "$PROFILE" plugins list 2>/dev/null | grep -i whatsapp-voice || echo "  plugin not installed"
  [ -f "$PLIST" ] && echo "  $PLIST exists" || echo "  no launchd agent yet"
  echo; echo "Preflight OK."
}

gateway() {
  preflight >/dev/null
  say "Backing up default config and .env"
  cp -p "$H/config.yaml" "$H/config.yaml.bak-hwv-$TS"
  cp -p "$H/.env" "$H/.env.bak-hwv-$TS"
  echo "  $H/config.yaml.bak-hwv-$TS"
  echo "  $H/.env.bak-hwv-$TS"
  say "Enabling the API server on the default profile (127.0.0.1:8642, loopback only)"
  "$HERMES" -p default config set platforms.api_server.enabled true
  "$HERMES" -p default config set platforms.api_server.extra.host 127.0.0.1
  "$HERMES" -p default config set platforms.api_server.extra.port 8642
  if has_env "$H/.env" API_SERVER_KEY; then
    echo "  default API_SERVER_KEY already set; keeping it"
  else
    (umask 077; printf '\nAPI_SERVER_KEY=%s\n' "$(openssl rand -hex 32)" >> "$H/.env")
    echo "  added a new random API_SERVER_KEY to $H/.env"
  fi
  restart_gateway
  say "Waiting for $API/p/$PROFILE/v1"
  for _ in $(seq 1 60); do cao_api_ok && { echo "  200 OK"; return; }; sleep 2; done
  die "cao API not answering; check $H/logs/gateway.error.log, or run rollback.sh gateway"
}

plugin() {
  local owner="${HWV_OWNER_NUMBER:-}"
  [[ "$owner" =~ ^\+[1-9][0-9]{7,14}$ ]] || die "set HWV_OWNER_NUMBER=+84xxxxxxxxx (your own WhatsApp number)"
  cao_api_ok || die "cao API not reachable; run the gateway step first"
  preflight >/dev/null
  local sha; sha=$(git -C "$REPO_DIR" rev-parse HEAD)
  say "Installing $FORK at $sha into profile $PROFILE"
  "$HERMES" -p "$PROFILE" plugins install "$FORK" --ref "$sha" --enable
  say "Installing the locally built sidecar (no download from GitHub releases)"
  mkdir -p "$DATA/bin"; chmod 700 "$DATA"
  install -m 755 "$BIN_SRC" "$DATA/bin/hermes-wa-voice"
  shasum -a 256 "$DATA/bin/hermes-wa-voice"
  say "Plugin settings"
  local s=plugins.entries.$PLUGIN.settings
  "$HERMES" -p "$PROFILE" config set "$s.owner_number" "$owner"
  "$HERMES" -p "$PROFILE" config set "$s.languages" "vi-VN,en-US"
  "$HERMES" -p "$PROFILE" config set "$s.hermes_api_url" "$API/p/$PROFILE"
  restart_gateway
  echo; echo "Next: deploy/mac-mini/apply.sh pair   (have the BOT phone ready)"
}

pair() {
  say "Pairing: on the BOT phone open WhatsApp > Linked devices > Link a device, then scan"
  exec "$HERMES" -p "$PROFILE" whatsapp-voice pair "$@"
}

service() {
  [ -x "$DATA/bin/hermes-wa-voice" ] || die "run the plugin step first"
  [ -f "$DATA/whatsapp.db" ] || die "not paired yet; run the pair step first"
  say "Writing $PLIST"
  sed -e "s#@HERMES@#$HERMES#g" -e "s#@PROFILE@#$PROFILE#g" -e "s#@LOG@#$DATA/sidecar.log#g" -e "s#@HOME@#$HOME#g" \
    "$REPO_DIR/deploy/mac-mini/$LABEL.plist" > "$PLIST"
  plutil -lint "$PLIST"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  sleep 5
  status
}

status() {
  launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E '^\s+(state|pid) =' || echo "launchd agent not loaded"
  "$HERMES" -p "$PROFILE" whatsapp-voice status || true
}

test_call() {
  "$HERMES" -p "$PROFILE" whatsapp-voice call "Đây là cuộc gọi thử từ Mac Mini. This is a test call from the Mac Mini."
}

case "${1:-}" in
  preflight) preflight ;;
  gateway) gateway ;;
  plugin) plugin ;;
  pair) shift; pair "$@" ;;
  service) service ;;
  test) test_call ;;
  status) status ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
