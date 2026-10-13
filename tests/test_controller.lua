-- tests/test_controller.lua - sandbox the LuCI controller like the dispatcher does.
-- Verifies: index() never throws, never mutates global package.path,
-- never registers modules in package.loaded (no require() of private libs).
local failures = 0
local function check(cond, msg)
    if cond then print('PASS ' .. msg)
    else failures = failures + 1; print('FAIL ' .. msg) end
end

local function make_env(nixio_stub)
    local entries = {}
    local env = setmetatable({}, { __index = _G })
    env.module = function() end -- no-op: defs land in env via setfenv
    env.nixio = nixio_stub
    env._ = function(s) return s end
    env.firstchild = function() return 'firstchild' end
    env.call = function(n) return 'call:' .. n end
    env.template = function(n) return 'template:' .. n end
    env.cbi = function(n) return 'cbi:' .. n end
    env.entry = function(path, target, title, order)
        local node = {}
        entries[#entries + 1] = path
        return node
    end
    env._entries = entries
    return env
end

local function load_controller(env)
    local chunk = assert(loadfile('luasrc/controller/singbox_lite.lua'))
    setfenv(chunk, env)
    local ok, err = pcall(chunk)
    return ok, err
end

-- case 1: normal dispatcher env ------------------------------------------------
do
    local env = make_env({ fs = { access = function(p)
        return p == '/etc/config/singbox_lite' end } })
    local ok, err = load_controller(env)
    check(ok, 'controller loads without error' .. (err and (': ' .. tostring(err)) or ''))
    local path_before = package.path
    local ok2, err2 = pcall(env.index)
    check(ok2, 'index() does not throw' .. (err2 and (': ' .. tostring(err2)) or ''))
    check(package.path == path_before, 'global package.path untouched')
    check(package.loaded['json'] == nil, 'no "json" in package.loaded')
    check(package.loaded['clash'] == nil, 'no "clash" in package.loaded')
    check(#env._entries == 13, '13 entries registered (got ' .. #env._entries .. ')')
end

-- case 2: nixio missing entirely (must not crash the dispatcher) ---------------
do
    local env = make_env(nil)
    local ok, err = load_controller(env)
    check(ok, 'controller loads with nixio=nil')
    local ok2, err2 = pcall(env.index)
    check(ok2, 'index() safe with nixio=nil' .. (err2 and (': ' .. tostring(err2)) or ''))
    check(#env._entries == 0, 'no entries registered when nixio missing')
end

-- case 3: config file absent -> silent skip --------------------------------------
do
    local env = make_env({ fs = { access = function(p) return false end } })
    load_controller(env)
    pcall(env.index)
    check(#env._entries == 0, 'no entries when config absent')
end

-- case 4: load_lib failure paths (missing files) --------------------------------
do
    local env = make_env({ fs = { access = function(p) return true end } })
    load_controller(env)
    -- point LIB at nothing by redefining? load_lib uses upvalue LIB; instead
    -- verify json()/clash helpers degrade: call api_traffic with stubbed luci
    env.luci = {
        sys = { call = function() return 1 end }, -- not running
        http = { prepare_content = function() end, write = function() end },
    }
    local ok, err = pcall(env.api_traffic)
    check(ok, 'api_traffic degrades when service down' .. (err and (': ' .. tostring(err)) or ''))
end

if failures > 0 then print(failures .. ' FAILURES'); os.exit(1) end
print('ALL CONTROLLER TESTS PASSED')
