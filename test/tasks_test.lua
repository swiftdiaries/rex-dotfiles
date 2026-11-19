-- Run: luajit test/tasks_test.lua   (from the repo root)
package.path = "vm/config/?.lua;" .. package.path
local tasks = require("tasks")

local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function labels(list)
  local t = {}
  for _, x in ipairs(list) do t[#t + 1] = x.label end
  return table.concat(t, ",")
end

local spec = {
  tasks = {
    { label = "install", command = "npm ci" },
    { label = "db", command = "db up", service = true, ready = { port = 5432 } },
    { label = "migrate", command = "migrate", depends_on = { "install", "db" } },
    { label = "app", command = "run", depends_on = { "migrate" }, service = true },
    { label = "test", command = "npm test", depends_on = { "install" } },
  },
  groups = { { label = "up", tasks = { "app" } }, { label = "t", tasks = { "test" } } },
}

eq(labels(tasks.plan(spec, "up")), "install,db,migrate,app", "group closure, deps first")
eq(labels(tasks.plan(spec, "t")), "install,test", "other group skips unrelated tasks")
eq(labels(tasks.plan(spec)), "install,db,migrate,app,test", "no group runs everything")

local _, err = tasks.plan(spec, "nope")
eq(err, "unknown group: nope")

_, err = tasks.plan({ tasks = { { label = "a", command = "x", depends_on = { "b" } } } })
eq(err, "unknown task: b (needed by a)")

_, err = tasks.plan({ tasks = {
  { label = "a", command = "x", depends_on = { "b" } },
  { label = "b", command = "x", depends_on = { "a" } } } })
eq(err, "dependency cycle through a")

_, err = tasks.plan({ tasks = { { label = "a", command = "x" }, { label = "a", command = "y" } } })
eq(err, "duplicate task: a")

_, err = tasks.plan({ tasks = { { label = "a b", command = "x" } } })
assert(err and err:match("label must be"), "label with a space is rejected")

eq(tasks.script({ label = "t", command = "make", args = { "a b", "it's" },
                  cwd = "svc", env = { B = "$X", A = '"q"' } }),
   [[export A="\"q\""; export B="$X"; cd "svc" && make 'a b' 'it'\''s']], "script")

eq(tasks.invocation({ label = "app", command = "run", depends_on = { "x", "y" },
                      service = true, ready = { port = 80 } }, "/s", { REX_BRANCH = "f/x" }),
   [[REX_BRANCH='f/x' rex-task run '/s' app --needs x,y --service --ready-port 80 -- 'run']], "invocation")

eq(tasks.port_offset("feature/x"), tasks.port_offset("feature/x"), "offset is stable")
assert(tasks.port_offset("feature/x") % 10 == 0 and tasks.port_offset("a") < 1000, "offset range")
print("ok")
