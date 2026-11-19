-- "Project: Worktree…" on the VM. Picks a repo under opts.root, then an
-- existing worktree or a new branch off origin/<opts.base>, copies the main
-- checkout's git-ignored .env files (and opts.copy) into it, and opens a tab
-- running opts.run above a spare shell. Running it again for the same branch
-- focuses that tab.
--
-- The pickers need Rex's custom UI (rex.ui, API revision 17). Without it, pass
-- the answers:  rex do worktree_open repo=myrepo branch=feature/x

local HOME = os.getenv("HOME")

local function sh(argv, cwd)
  local r, err = rex.exec(argv, { cwd = cwd, timeout = 300 })
  local cmd = table.concat(argv, " ")
  if not r then error(cmd .. ": " .. err, 0) end
  if not r.ok then
    error(cmd .. ": " .. (r.stderr ~= "" and r.stderr or r.stdout), 0)
  end
  return r.stdout
end

local function lines(s)
  local t = {}
  for l in s:gmatch("[^\n]+") do t[#t + 1] = l end
  return t
end

local function pick(spec)
  if not rex.ui then
    error(spec.title .. ": this Rex has no custom UI yet; pass the arguments", 0)
  end
  local v, why = rex.ui.pick(spec)
  if v == nil and why ~= "cancelled" then error(spec.title .. ": " .. why, 0) end
  return v
end

local function repos(root)
  local found = sh({ "find", root, "-mindepth", "2", "-maxdepth", "2",
                     "-name", ".git", "-type", "d" })
  local t = {}
  for _, git in ipairs(lines(found)) do t[#t + 1] = git:match("^(.*)/%.git$") end
  table.sort(t)
  return t
end

-- Linked worktrees only; the main checkout is listed first and skipped.
local function worktrees(main)
  local t, cur = {}, nil
  for _, l in ipairs(lines(sh({ "git", "worktree", "list", "--porcelain" }, main))) do
    local path = l:match("^worktree (.+)")
    if path then cur = { path = path }; t[#t + 1] = cur end
    local branch = l:match("^branch refs/heads/(.+)")
    if branch then cur.branch = branch end
  end
  table.remove(t, 1)
  return t
end

local function exists(path)
  return rex.exec({ "test", "-e", path }).ok
end

local function has_branch(main, branch)
  return rex.exec({ "git", "rev-parse", "--verify", "--quiet",
                    "refs/heads/" .. branch }, { cwd = main }).ok
end

local function create(main, branch, path, base)
  sh({ "git", "fetch", "origin", base }, main)
  if has_branch(main, branch) then
    sh({ "git", "worktree", "add", path, branch }, main)
  else
    sh({ "git", "worktree", "add", "-b", branch, path, "origin/" .. base }, main)
  end
end

-- Never overwrites, so edits made in the worktree survive a rerun.
local function copy_secrets(main, path, extra)
  local files = {}
  local ignored = sh({ "git", "ls-files", "--others", "--ignored",
                       "--exclude-standard", "--directory" }, main)
  for _, f in ipairs(lines(ignored)) do
    local name = f:match("[^/]+$")
    if name == ".env" or (name and name:match("^%.env%.")) then
      files[#files + 1] = f
    end
  end
  for _, f in ipairs(extra) do files[#files + 1] = f end

  local copied = {}
  for _, f in ipairs(files) do
    local src, dst = main .. "/" .. f, path .. "/" .. f
    if exists(src) and not exists(dst) then
      sh({ "mkdir", "-p", dst:match("^(.*)/") })
      sh({ "cp", "-p", src, dst })
      copied[#copied + 1] = f
    end
  end
  return copied
end

local function open_tab(label, path, run)
  local view = rex.session.view{}
  for _, w in ipairs(view and view.windows or {}) do
    if w.label == label then
      rex.session.focus_window{ window_id = w.window_id }
      return w.window_id
    end
  end
  local shell = function(input)
    return rex.layout.block{
      flavor  = "com.superlogical.terminal.shell",
      options = { cwd = path, initial_input = input },
    }
  end
  local made, err = rex.session.new_window{
    window_label = label,
    layout = rex.layout.vertical(0.6, shell(run ~= "" and (run .. "\r") or nil), shell(nil)),
  }
  if not made then error("new tab: " .. err, 0) end
  return made.window_id
end

return function(opts)
  local root = opts.root:gsub("^~", HOME)
  local base = opts.base or "main"
  local run = opts.run or ""

  rex.action{
    name        = "worktree_open",
    title       = "Project: Worktree…",
    category    = "Project",
    keywords    = "git worktree branch dev env app",
    description = "Open or create a worktree off origin/" .. base
                  .. ", copy its .env files" .. (run ~= "" and (", and run `" .. run .. "`") or "") .. ".",
    args        = { repo = "string?", branch = "string?" },
    run = function(ctx, args)
      local main
      if args.repo then
        main = args.repo:find("/") and args.repo or (root .. "/" .. args.repo)
      else
        local items = {}
        for _, r in ipairs(repos(root)) do
          items[#items + 1] = { id = r, title = r:match("[^/]+$"),
                                subtitle = r, icon = "folder" }
        end
        main = pick({ title = "Repo", placeholder = "Filter repos", items = items })
        if not main then return end
      end
      local name = main:match("[^/]+$")

      local branch, path = args.branch, nil
      if not branch then
        local existing, items = worktrees(main), {}
        for _, w in ipairs(existing) do
          items[#items + 1] = { id = w.path, title = w.branch or w.path,
                                subtitle = w.path, icon = "branch" }
        end
        local choice = pick({
          title       = name .. ": worktree",
          placeholder = "Pick one, or type a new branch off " .. base,
          items       = items,
          allow_other = true,
        })
        if not choice then return end
        if type(choice) == "table" then
          branch = choice.text
        else
          for _, w in ipairs(existing) do
            if w.path == choice then branch, path = w.branch, w.path end
          end
        end
      end
      path = path or (main .. ".worktrees/" .. branch:gsub("/", "-"))

      if not exists(path) then create(main, branch, path, base) end
      local copied = copy_secrets(main, path, opts.copy or {})
      local window_id = open_tab(name .. ":" .. branch, path, run)
      return { path = path, branch = branch, copied = copied,
               window_id = window_id }
    end,
  }
end
