-- End to end with a stubbed `rex`: real git repo, real worktree, and the pane
-- command lines the action would type are executed with bash.
-- Run: PATH="$PWD/vm/bin:$PATH" luajit test/worktree_test.lua   (from the repo root)
package.path = "vm/config/?.lua;" .. package.path

local function sh(cmd)
  local f = io.popen(cmd .. " 2>&1; echo \"rc=$?\"")
  local out = f:read("*a"); f:close()
  local rc = tonumber(out:match("rc=(%d+)\n$"))
  return out:gsub("rc=%d+\n$", ""), rc
end

local tmp = sh("mktemp -d"):gsub("%s+$", "")
local root = tmp .. "/proj"
sh(("mkdir -p %s/app && cd %s/app && git init -q -b main && git config user.email t@t && git config user.name t"
    .. " && git commit -q --allow-empty -m init"
    .. " && git init -q --bare %s/origin.git && git remote add origin %s/origin.git && git push -q origin main"
    .. " && mkdir .rex"):format(root, root, tmp, tmp))
local f = io.open(root .. "/app/.rex/tasks.json", "w")
f:write([[{
 "tasks": [
  {"label":"install","command":"echo installing; sleep 1"},
  {"label":"svc","command":"sleep 30","service":true,"ready":{"delay":1}},
  {"label":"go","command":"echo go-$REX_BRANCH_SLUG-$PORT > out.txt","depends_on":["install","svc"],
   "env":{"PORT":"$((3000 + REX_PORT_OFFSET))"}},
  {"label":"other","command":"echo other"}],
 "groups":[{"label":"up","tasks":["go"]},{"label":"misc","tasks":["other"]}]}]])
f:close()

local window
local action
rex = {
  json = {},
  action = function(a) action = a end,
  exec = function(argv, o)
    local parts = {}
    for _, a in ipairs(argv) do parts[#parts + 1] = "'" .. a:gsub("'", "'\\''") .. "'" end
    local cmd = (o and o.cwd and ("cd '" .. o.cwd .. "' && ") or "") .. table.concat(parts, " ")
    local out, rc = sh(cmd .. " 2>/dev/null")
    return { ok = rc == 0, stdout = out:gsub("rc=%d+\n", ""), stderr = "" }
  end,
  layout = {
    block = function(t) return { block = t } end,
    vertical = function(r, a, b) return { split = "v", a, b } end,
  },
  session = {
    view = function() return { windows = {} } end,
    new_window = function(t) window = t; return { window_id = "w1" } end,
  },
}
-- JSON decode via python, for the stub only
local converter = tmp .. "/json2lua.py"
local cf = io.open(converter, "w")
cf:write([[
import json, sys
def lua(v):
    if isinstance(v, dict): return "{" + ",".join("[%s]=%s" % (json.dumps(k), lua(x)) for k, x in v.items()) + "}"
    if isinstance(v, list): return "{" + ",".join(lua(x) for x in v) + "}"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return repr(v)
    return json.dumps(v)
print("return " + lua(json.load(sys.stdin)))
]])
cf:close()
rex.json.decode = function(s)
  local h = io.open(tmp .. "/in.json", "w"); h:write(s); h:close()
  local out = sh("python3 " .. converter .. " < " .. tmp .. "/in.json")
  return load(out)()
end

require("worktree"){ root = root }
local result = action.run({}, { repo = "app", branch = "feat/x", group = "up" })
assert(result.group == "up")
assert(window.window_label == "app:feat/x", window.window_label)

local inputs, blocks = {}, 0
local function walk(n)
  if n.block then
    blocks = blocks + 1
    inputs[blocks] = n.block.options.initial_input
  else for _, c in ipairs(n) do walk(c) end end
end
walk(window.layout)
assert(blocks == 4, "install, svc, go + spare shell; got " .. blocks)
assert(inputs[4] == nil, "spare shell has no command")

local wt = result.path
for i = 1, 3 do
  local line = inputs[i]:gsub("\r$", "")
  sh(("cd '%s' && (%s > /dev/null 2>&1 &)"):format(wt, line))
end
sh("sleep 4")
local out = io.open(wt .. "/out.txt"):read("*a")
local port = 3000 + require("tasks").port_offset("feat/x")
assert(out == ("go-feat-x-%d\n"):format(port), "go ran after deps with context env: " .. out)
sh("pkill -f 'sleep 30'")

local _, e = pcall(action.run, {}, { repo = "app", branch = "feat/x", group = "nope" })
assert(tostring(e):match("unknown group: nope"), tostring(e))
sh("rm -rf " .. tmp)
print("ok")
