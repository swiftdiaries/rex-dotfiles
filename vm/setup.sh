#!/usr/bin/env bash
# Run once on the Linux dev VM. Idempotent.
set -euo pipefail

# Keep the Rex server (and every session) alive when SSH logs out.
loginctl enable-linger "$USER"

# Rex must be on PATH for non-interactive ssh, or in ~/.local/bin.
command -v rex >/dev/null || [[ -x ~/.local/bin/rex ]] || {
  echo "install rex into ~/.local/bin first"; exit 1; }
REX="$(command -v rex || echo ~/.local/bin/rex)"

# xterm-rex terminfo so programs know the terminal supports OSC 52 etc.
"$REX" terminfo setup --entry-only

# Shared key bindings (same file as the Mac) and the worktree action.
# Edit root/copy/run in ~/.config/rex/init.lua; reruns keep your edits.
mkdir -p ~/.config/rex
INIT=~/.config/rex/init.lua
touch "$INIT"
grep -q 'require("keys")' "$INIT" || echo 'require("keys")' >> "$INIT"
grep -q 'require("worktree")' "$INIT" || cat >> "$INIT" <<'EOF'
require("worktree"){
  root = "~/projects",          -- repos are <root>/<repo>, worktrees <root>/<repo>.worktrees/<branch>
  base = "main",                 -- new branches start at origin/<base>
  run  = "",                   -- command typed into the top pane, e.g. "make dev"
  copy = {},                    -- creds beyond .env*, relative to the main checkout
}
rex.bind("alt+cmd+w", "worktree_open")
EOF

# OSC 52 copy helper: `git diff | clip`, `clip < file`. Goes straight to the
# Mac clipboard through Rex, no X/Wayland needed on the VM.
mkdir -p ~/.local/bin
cat > ~/.local/bin/clip <<'EOF'
#!/usr/bin/env bash
data="$(cat "$@" | base64 | tr -d '\n')"
if [[ -n "${TMUX:-}" ]]; then
  printf '\ePtmux;\e\e]52;c;%s\a\e\\' "$data" > /dev/tty
else
  printf '\e]52;c;%s\a' "$data" > /dev/tty
fi
EOF
chmod +x ~/.local/bin/clip
ln -sf ~/.local/bin/clip ~/.local/bin/pbcopy

# tmux: pass OSC 52 through to Rex.
if command -v tmux >/dev/null; then
  touch ~/.tmux.conf
  grep -q 'set-clipboard on' ~/.tmux.conf || cat >> ~/.tmux.conf <<'EOF'
set -g set-clipboard on
set -g allow-passthrough on
set -as terminal-features ',xterm-rex:clipboard'
EOF
fi

# Neovim 0.10+: yank to the Mac clipboard with "+y.
NVIM_CFG=~/.config/nvim/plugin/osc52.lua
mkdir -p "$(dirname "$NVIM_CFG")"
[[ -f "$NVIM_CFG" ]] || cat > "$NVIM_CFG" <<'EOF'
vim.g.clipboard = 'osc52'
EOF

echo "done. Copy keys.lua and worktree.lua to ~/.config/rex/ here, then: rex config reload"
