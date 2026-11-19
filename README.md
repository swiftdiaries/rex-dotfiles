# rex-dotfiles

[Rex](https://www.superlogical.com/rex/) setup for a Mac client driving a
remote Linux dev VM, typically running Claude Code there. It adds:

- **Connection:** an `ssh://` host. Rex drives your system ssh and autostarts the VM's server, so there's no manual socket forward.
- **Copy VM → Mac:** OSC 52 everywhere. Copy on selection, `cmd+shift+c`, copy mode, a `clip` command, tmux, and Neovim `"+y` all reach the Mac clipboard.
- **Paste Mac → VM:** `cmd+v`, for text and images. Rex handles images itself.
- **Ports:** automatic forwarding, VS Code-style. A port listening on the VM shows up at `localhost:<port>` on the Mac and closes when the process stops.

## Layout

```
install.sh                   symlinks the Mac side, templates per-machine values
mac/config/init.lua          host declaration, reads host.lua (git-ignored)
mac/config/connect.lua       "VM: Connect" and "VM: Choose Host…" palette actions
mac/config/keys.lua          key bindings (used on both ends)
mac/bin/rex-autoforward      polls the VM's listeners, runs `rex forward new -L`
mac/bin/rex-vm-host          prints the VM's ssh alias saved in ~/.config/rex/host.lua
mac/launchd/*.plist.tmpl     launchd agent for the auto-forwarder
vm/config/worktree.lua       "Project: Worktree…" action, runs on the VM
vm/config/tasks.lua          task DAG: validates .rex/tasks.json, plans a group, builds pane commands
vm/bin/rex-task              runs one task in its pane: waits for dependencies, records the outcome
examples/tasks.json          sample .rex/tasks.json
test/                        luajit tests for tasks.lua and the worktree action
vm/setup.sh                  linger, terminfo, clip helper, tmux/nvim OSC 52, VM init.lua
```

## Install

Add a Host alias for the VM to `~/.ssh/config`. Connection sharing keeps the
forwarder's polling cheap:

```
Host devvm
  HostName <vm address>
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
  ServerAliveInterval 30
```

Then run:

```sh
./install.sh --vm devvm     # Mac + VM
./install.sh devvm          # Mac only
./install.sh                # Mac only; lists your ssh hosts and asks which is the VM
```

In Rex, set **Settings › Terminal › Selection › Copy on selection** to on.
If you use 1Password or another agent, set it in **Settings › Remote Hosts › SSH**.

## Use

| Need | How |
| --- | --- |
| Change which VM | **VM: Choose Host…** in the palette picks from Rex's ssh hosts and `~/.ssh/config`, or takes a typed alias. It saves the choice, reloads Rex, and restarts the forwarder. Before Rex has custom UI, rerun `./install.sh` or run `rex do vm_choose_host ssh=<alias>` |
| Connect to the VM | `alt+cmd+s`, or **VM: Connect to devvm** in the palette. It starts the VM's Rex server over ssh and creates its `dev` session if missing. Then pick the host in the sidebar |
| Start work on a branch | `alt+cmd+w`, or **Project: Worktree…** in the palette, while viewing the VM. Pick a repo, then an existing worktree or type a new branch. It branches off `origin/<base>` (default `main`), copies the main checkout's git-ignored `.env*` files, and opens a tab with one pane per task of a [task group](#tasks) above a shell. Running it again for the same branch focuses that tab. Settings live in the VM's `~/.config/rex/init.lua` |
| Same, before Rex has custom UI | `rex do worktree_open repo=myrepo branch=feature/x group=up` on the VM. The pickers need `rex.ui` (API revision 17; `rex version` shows yours) |
| Copy from the VM | Select text, or use `cmd+shift+c`, `ctrl+b [` (copy mode), `cmd \| clip`, or nvim `"+y` |
| Forward a port | Automatic for ports ≥1024 bound to localhost or 0.0.0.0. Run `rex forward ls` to list forwards; the log is `/tmp/rex-autoforward.log` |
| One-off forward | `cmd+shift+p`, or `rex -S devvm forward open <pane-label>` |

## Tasks

A repo's `.rex/tasks.json` describes what to run in a worktree as a DAG, in the
spirit of [Zed tasks](https://zed.dev/docs/tasks). See `examples/tasks.json`.

| Field | Meaning |
| --- | --- |
| `label` | Name, and the key for `depends_on`. Letters, digits, `.`, `_`, `-` |
| `command`, `args` | Shell text, plus extra args that are quoted for you |
| `env`, `cwd` | Exported and entered in the pane. Values are shell text, so `$VAR` and `$((…))` expand |
| `depends_on` | Labels that must finish first. Independent tasks run in parallel |
| `service` | A long-running task (server, database). It satisfies dependents when ready, not when it exits |
| `ready` | For a service: `{"port": 5432}` waits for the port, `{"delay": 5}` waits 5 seconds. Without it, ready at start |
| `groups` | `[{"label": "up", "tasks": ["app"]}]`. The worktree action runs the chosen group plus everything it depends on; with several groups it asks which |

Every task gets its own pane and starts at once; `rex-task` makes it wait for
its dependencies. If a dependency fails, the task and everything after it is
skipped. A pane stays open at a shell when its task ends, so you can read the
output and rerun it. Task state is in `$XDG_RUNTIME_DIR/rex-tasks/<repo>-<branch>`
(`/tmp` if unset) and resets each time the tab is created.

Available in every task: `REX_REPO`, `REX_MAIN` (main checkout), `REX_WORKTREE`,
`REX_BRANCH`, `REX_BRANCH_SLUG`, and `REX_PORT_OFFSET`, a stable 0–990 number per
branch, so parallel worktrees can use `$((3000 + REX_PORT_OFFSET))`.

The file is read from the worktree, then the main checkout, so it can stay
git-ignored.

Tests: `luajit test/tasks_test.lua` and
`PATH="$PWD/vm/bin:$PATH" luajit test/worktree_test.lua`.

## Tuning

- `REX_FWD_IGNORE="9229 5432"` in the plist template skips those ports. Re-run `install.sh` after changing it.
- The forwarder skips a port that's already in use on the Mac. Forward it to a different local port with `rex -S devvm forward open <port>`.
- `pane.copy_mode.*` is on Rex's Bleeding Edge channel. If `rex keymap` reports it as unknown, remove that binding.
