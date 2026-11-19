-- "VM: Connect" runs the rex CLI against the VM's endpoints, which runs ssh
-- and autostarts the VM's server, then finds or creates its "dev" session.
-- It can't use rex.server(): a config action only reaches servers the
-- calling app is already connected to. The app's session.select only finds
-- sessions on the host the app is showing, so switching the view to the VM
-- stays a sidebar click.
--
-- "VM: Choose Host…" saves the VM's ssh alias to host.lua, the file
-- init.lua and rex-autoforward read.

local SESSION = "dev"
local HOME = os.getenv("HOME")
local HOST_FILE = (os.getenv("XDG_CONFIG_HOME") or (HOME .. "/.config")) .. "/rex/host.lua"

-- The app's PATH is the GUI one, so a bare "rex" is often not found. REX_BIN
-- wins, then the usual install locations, then whatever PATH has.
local function rex_bin()
  local candidates = {
    os.getenv("REX_BIN"),
    HOME .. "/.local/bin/rex",
    "/opt/homebrew/bin/rex",
    "/usr/local/bin/rex",
    HOME .. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
  }
  for _, path in ipairs(candidates) do
    local r = path and rex.exec({ "/bin/test", "-x", path })
    if r and r.ok then return path end
  end
  return "rex"
end

local function vm_call(endpoints, method, args)
  local why
  for _, ep in ipairs(endpoints) do
    local r, err = rex.exec({ rex_bin(), "-S", ep, "--timeout", "30s", "api", "call",
                              method, rex.json.encode(args) }, { timeout = 60 })
    if not r then return nil, "rex CLI: " .. err end
    if r.ok then return rex.json.decode(r.stdout) end
    why = why or r.stderr:gsub("^Error: ", ""):gsub("%s+$", "")
  end
  return nil, why
end

local function find_session(endpoints)
  local list, err = vm_call(endpoints, "session.list", {})
  if not list then return nil, err end
  for _, s in ipairs(list.sessions or {}) do
    if s.label == SESSION then return s.session_id end
  end
  local made, cerr = vm_call(endpoints, "session.create", {
    label = SESSION,
    initial_windows = { {
      window_label = "shell",
      layout = rex.layout.block{ flavor = "com.superlogical.terminal.shell" },
    } },
  })
  if not made then return nil, cerr end
  return made.session_id
end

-- Concrete Host names from ~/.ssh/config; patterns such as * are skipped.
local function ssh_hosts()
  local t, f = {}, io.open(HOME .. "/.ssh/config")
  if not f then return t end
  for line in f:lines() do
    local names = line:match("^%s*[Hh][Oo][Ss][Tt]%s+(.+)")
    for name in (names or ""):gmatch("%S+") do
      if not name:find("[%*%?!]") then t[#t + 1] = name end
    end
  end
  f:close()
  return t
end

-- Rex's hosts that connect over ssh:// first, then ~/.ssh/config.
local function choose(current)
  if not rex.ui then
    error("this Rex has no custom UI yet; pass ssh=<alias> or rerun install.sh", 0)
  end
  local items, seen = {}, {}
  local function add(alias, subtitle)
    if seen[alias] then return end
    seen[alias] = true
    items[#items + 1] = { id = alias, subtitle = subtitle, icon = "server",
                          detail = alias == current and "current" or nil }
  end
  local hosts = rex.call("hosts.list", {})
  for _, h in ipairs(hosts and hosts.hosts or {}) do
    for _, e in ipairs(h.endpoints) do
      local alias = e:match("^ssh://([^/:]+)")
      if alias then add(alias, "Rex host " .. h.label) end
    end
  end
  for _, h in ipairs(ssh_hosts()) do add(h, "~/.ssh/config") end
  local pick, why = rex.ui.pick{
    title       = "VM ssh host",
    placeholder = "Pick a Host from ~/.ssh/config, or type an alias",
    items       = items,
    allow_other = true,
  }
  if pick == nil and why ~= "cancelled" then error("VM ssh host: " .. why, 0) end
  return type(pick) == "table" and pick.text or pick
end

local function save(ssh)
  if not ssh:match("^[%w%._@%-]+$") then
    error("not an ssh host alias: " .. ssh, 0)
  end
  local f = assert(io.open(HOST_FILE, "w"))
  f:write(string.format("return { label = %q, ssh = %q }\n", ssh, ssh))
  f:close()
  local uid = rex.exec({ "id", "-u" }).stdout:gsub("%s+$", "")
  rex.exec({ "launchctl", "kickstart", "-k", "gui/" .. uid .. "/com.rex.autoforward" })
  -- An action can't reload the file it runs from; a detached CLI can.
  local _, err = rex.exec.start({ "rex", "config", "reload" }, { detach = true })
  if err then error("saved " .. ssh .. "; run rex config reload: " .. err, 0) end
end

return function(host, endpoints)
  rex.action{
    name        = "vm_connect",
    title       = "VM: Connect to " .. host.label,
    category    = "Host",
    keywords    = "ssh remote vm connect " .. host.ssh,
    description = "Connect to " .. host.label .. " over ssh and open its "
                  .. SESSION .. " session.",
    run = function()
      local id, err = find_session(endpoints)
      if not id then error(host.label .. ": " .. err, 0) end
      return { host = host.label, session_id = id }
    end,
  }

  rex.action{
    name        = "vm_choose_host",
    title       = "VM: Choose Host…",
    category    = "Host",
    keywords    = "ssh remote vm host alias change set",
    description = "Choose the dev VM's ssh alias. Now " .. host.ssh .. ".",
    args        = { ssh = "string?" },
    run = function(ctx, args)
      local ssh = args.ssh or choose(host.ssh)
      if not ssh then return end
      save(ssh)
      return { ssh = ssh }
    end,
  }
end
