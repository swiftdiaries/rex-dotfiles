-- Task DAG for the worktree action. Pure: no rex.* calls, so it runs under
-- plain Lua (see test/tasks_test.lua).
--
-- .rex/tasks.json:
--   { "tasks":  [ { "label": "db", "command": "docker compose up db",
--                   "service": true, "ready": { "port": 5432 } },
--                 { "label": "app", "command": "make app", "args": [],
--                   "env": { "PORT": "$((3000 + REX_PORT_OFFSET))" },
--                   "cwd": "services/api", "depends_on": ["db"],
--                   "service": true } ],
--     "groups": [ { "label": "up", "tasks": ["app"] } ] }
--
-- command, env values and cwd are shell text, so $REX_WORKTREE, ${VAR:-x} and
-- the like expand in the pane. Labels are file names: letters, digits, . _ -

local M = {}

local function shq(s) return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'" end
local function dq(s) return '"' .. (tostring(s):gsub('(["\\`])', "\\%1")) .. '"' end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function check_task(i, t)
  if type(t.label) ~= "string" or not t.label:match("^[%w._-]+$") then
    return "task " .. i .. ": label must be letters, digits, . _ -"
  end
  if type(t.command) ~= "string" or t.command == "" then
    return t.label .. ": command is required"
  end
  for _, k in ipairs(sorted_keys(t.env)) do
    if not k:match("^[%a_][%w_]*$") then return t.label .. ": bad env name " .. k end
  end
  local r = t.ready
  if r and (r.port ~= nil and type(r.port) ~= "number"
         or r.delay ~= nil and type(r.delay) ~= "number") then
    return t.label .. ": ready.port and ready.delay must be numbers"
  end
end

-- Tasks needed by `group` (every task when nil), dependencies first.
function M.plan(spec, group)
  local by, order = {}, {}
  for i, t in ipairs(spec.tasks or {}) do
    local err = check_task(i, t)
    if err then return nil, err end
    if by[t.label] then return nil, "duplicate task: " .. t.label end
    by[t.label] = t
    order[#order + 1] = t.label
  end

  local roots = order
  if group then
    roots = nil
    for _, g in ipairs(spec.groups or {}) do
      if g.label == group then roots = g.tasks or {} end
    end
    if not roots then return nil, "unknown group: " .. group end
  end

  local out, mark = {}, {}
  local function visit(label, from)
    local t = by[label]
    if not t then
      return "unknown task: " .. label .. (from and " (needed by " .. from .. ")" or "")
    end
    if mark[label] == "done" then return end
    if mark[label] == "open" then return "dependency cycle through " .. label end
    mark[label] = "open"
    for _, d in ipairs(t.depends_on or {}) do
      local err = visit(d, label)
      if err then return err end
    end
    mark[label] = "done"
    out[#out + 1] = t
  end
  for _, label in ipairs(roots) do
    local err = visit(label)
    if err then return nil, err end
  end
  return out
end

function M.group_labels(spec)
  local t = {}
  for _, g in ipairs(spec.groups or {}) do t[#t + 1] = g.label end
  return t
end

-- Stable per-branch number so parallel worktrees can pick different ports.
function M.port_offset(branch)
  local n = 0
  for i = 1, #branch do n = (n * 31 + branch:byte(i)) % 100 end
  return n * 10
end

function M.context(repo, main, path, branch)
  return {
    REX_REPO = repo,
    REX_MAIN = main,
    REX_WORKTREE = path,
    REX_BRANCH = branch,
    REX_BRANCH_SLUG = (branch:gsub("/", "-")),
    REX_PORT_OFFSET = M.port_offset(branch),
  }
end

-- The shell text rex-task runs: env exports, cd, then the command.
function M.script(t)
  local parts = {}
  for _, k in ipairs(sorted_keys(t.env)) do
    parts[#parts + 1] = "export " .. k .. "=" .. dq(t.env[k])
  end
  local cmd = t.command
  for _, a in ipairs(t.args or {}) do cmd = cmd .. " " .. shq(a) end
  if t.cwd then cmd = "cd " .. dq(t.cwd) .. " && " .. cmd end
  parts[#parts + 1] = cmd
  return table.concat(parts, "; ")
end

-- The line typed into the task's pane.
function M.invocation(t, state, ctx)
  local words = {}
  for _, k in ipairs(sorted_keys(ctx)) do words[#words + 1] = k .. "=" .. shq(ctx[k]) end
  words[#words + 1] = "rex-task run " .. shq(state) .. " " .. t.label
  if t.depends_on and #t.depends_on > 0 then
    words[#words + 1] = "--needs " .. table.concat(t.depends_on, ",")
  end
  if t.service then words[#words + 1] = "--service" end
  if t.ready and t.ready.port then
    words[#words + 1] = string.format("--ready-port %d", t.ready.port)
  end
  if t.ready and t.ready.delay then
    words[#words + 1] = string.format("--ready-delay %d", t.ready.delay)
  end
  words[#words + 1] = "-- " .. shq(M.script(t))
  return table.concat(words, " ")
end

return M
