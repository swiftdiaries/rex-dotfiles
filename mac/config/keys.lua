-- ~/.config/rex/keys.lua  (copy to the VM's ~/.config/rex/ too, see README)
-- Clipboard + forwarding keys. Client actions (pane.*, client.*) run on the
-- Mac app, so they reach the Mac clipboard whichever host the pane is on.

-- Copy / paste that also works inside TUIs that grab cmd+c (Claude Code, vim).
rex.bind("cmd+shift+c", "pane.copy")
rex.bind("cmd+shift+v", "pane.paste")

-- Keyboard scrollback copy (tmux-style): ctrl+b [  then v/y like vi.
-- pane.copy_mode.* is on the Bleeding Edge channel; drop this line if
-- `rex keymap` reports it as unknown.
rex.bind("ctrl+b>[", "pane.copy_mode.enter")

-- Manual forward picker for anything the auto-forwarder skips.
rex.bind("cmd+shift+p", "client.host.forward_port")
