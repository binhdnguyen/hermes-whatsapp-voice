#!/usr/bin/env bash
# Undo deploy/mac-mini/apply.sh, newest step first. Each part is safe to run on its own:
#
#   deploy/mac-mini/rollback.sh service    # stop and remove the launchd agent
#   deploy/mac-mini/rollback.sh plugin     # disable the plugin in cao (keeps its data)
#   deploy/mac-mini/rollback.sh purge      # also delete the WhatsApp session and sidecar
#   deploy/mac-mini/rollback.sh gateway    # turn the default API server off again
#   deploy/mac-mini/rollback.sh all        # service + plugin + gateway
set -euo pipefail

PROFILE=cao
HERMES=${HERMES:-$HOME/.local/bin/hermes}
PLUGIN=hermes-whatsapp-voice
DATA=$HOME/.hermes/profiles/$PROFILE/plugin-data/$PLUGIN
LABEL=com.hermes.whatsapp-voice
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist

service() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "launchd agent removed"
}

plugin() {
  "$HERMES" -p "$PROFILE" plugins disable "$PLUGIN" || true
  "$HERMES" -p default gateway restart
}

purge() {
  service
  "$HERMES" -p "$PROFILE" plugins remove "$PLUGIN" || true
  rm -rf "$DATA"
  echo "Removed $DATA. Also unlink the device on the BOT phone: WhatsApp > Linked devices."
}

gateway() {
  # Turns the listener off rather than restoring the .bak copies, so edits other agents made to
  # config.yaml/.env since the apply are kept. The backups stay next to the originals.
  "$HERMES" -p default config set platforms.api_server.enabled false
  "$HERMES" -p default gateway restart
  echo "Default API server disabled. Backups: $(ls "$HOME"/.hermes/*.bak-hwv-* 2>/dev/null | tr '\n' ' ')"
}

case "${1:-}" in
  service) service ;;
  plugin) plugin ;;
  purge) purge ;;
  gateway) gateway ;;
  all) service; plugin; gateway ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
