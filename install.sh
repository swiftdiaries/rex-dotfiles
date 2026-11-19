#!/bin/bash
# Install the Mac side by symlinking into place, so `git pull` updates it.
#   ./install.sh [HOST]        HOST = ssh alias of the dev VM; asked for when left out
#   ./install.sh --vm [HOST]   also set up the VM over ssh
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
VM=0
[ "${1:-}" = "--vm" ] && { VM=1; shift; }
HOST="${1:-}"
if [ -z "$HOST" ]; then
  current="$("$REPO/mac/bin/rex-vm-host")"
  if [ -t 0 ]; then
    hosts="$(awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) printf "%s ", $i }' ~/.ssh/config 2>/dev/null)"
    [ -n "$hosts" ] && echo "ssh hosts: $hosts"
    read -r -p "VM ssh host [$current]: " HOST
  fi
  HOST="${HOST:-$current}"
fi
[[ "$HOST" =~ ^[A-Za-z0-9._@-]+$ ]] || { echo "not an ssh host alias: $HOST" >&2; exit 1; }

link() { mkdir -p "$(dirname "$2")"; ln -sfn "$1" "$2"; echo "  $2 -> $1"; }

echo "Mac:"
link "$REPO/mac/config/init.lua" "$HOME/.config/rex/init.lua"
link "$REPO/mac/config/keys.lua" "$HOME/.config/rex/keys.lua"
link "$REPO/mac/config/connect.lua" "$HOME/.config/rex/connect.lua"
for f in "$REPO"/mac/bin/*; do link "$f" "$HOME/.local/bin/$(basename "$f")"; done

# Machine-specific values stay out of the repo.
# Written beside init.lua in the repo (git-ignored) and linked into
# ~/.config/rex, so `require` finds it however Rex resolves the symlink.
printf 'return { label = "%s", ssh = "%s" }\n' "$HOST" "$HOST" > "$REPO/mac/config/host.lua"
link "$REPO/mac/config/host.lua" "$HOME/.config/rex/host.lua"

PLIST="$HOME/Library/LaunchAgents/com.rex.autoforward.plist"
mkdir -p "$(dirname "$PLIST")"
sed -e "s#@HOME@#$HOME#g" "$REPO/mac/launchd/com.rex.autoforward.plist.tmpl" > "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
echo "  loaded launchd agent com.rex.autoforward"

command -v rex >/dev/null && rex config check && rex config reload || true

if [ "$VM" = 1 ]; then
  echo "VM ($HOST):"
  ssh "$HOST" 'mkdir -p ~/.config/rex /tmp/rex-dotfiles'
  scp -q "$REPO/vm/setup.sh" "$REPO/mac/config/keys.lua" "$REPO/vm/config/worktree.lua" "$HOST:/tmp/rex-dotfiles/"
  ssh "$HOST" 'bash /tmp/rex-dotfiles/setup.sh && cp /tmp/rex-dotfiles/keys.lua /tmp/rex-dotfiles/worktree.lua ~/.config/rex/ && (~/.local/bin/rex config reload 2>/dev/null || rex config reload)'
fi
