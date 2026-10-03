--[[ helska.lua
  Loader for the "helska" script bundle.

  mpv only auto-runs .lua files that sit directly in scripts/, so this file
  loads everything inside the helska/ folder instead (helska_console.lua first,
  the rest in sorted order). Add or delete a .lua there to add or remove a
  feature; no list to edit.

  All of them share one Lua context, so the console messages that several
  modules register are routed here to avoid clobbering each other.
]]

local mp = require "mp"
local utils = require "mp.utils"

-- 1) Locate this loader, then the "helska" folder sitting next to it.
local function script_dir()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return utils.split_path(src)
end

local SCRIPTS_DIR = script_dir()                             -- scripts/
local BUNDLE      = utils.join_path(SCRIPTS_DIR, "helska")   -- scripts/helska

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- 2) Bundle scripts that ask mpv for their "script directory" should get the
--    helska/ folder, NOT scripts/ (this matches where the config + bundled
--    tools live and keeps every module consistent under one mpv script).
mp.get_script_directory = function() return BUNDLE end

-- All modules run inside this ONE script, so mp.get_script_name() returns
-- the same value for every one of them. Captured once so the console protocol
-- (below) can recognize that shared owner.
local SCRIPT_NAME = mp.get_script_name() or "helska"

-- 3) Centralize the console protocol messages that several modules register.
--    Unique messages (console-audio-*, toggle-*, open-*, next/previous, ...)
--    pass straight through to the real mpv registration.
local SHARED = {
    ["helska-console-discover"]        = true,
    ["helska-console-run"]             = true,
    ["helska-console-reload-bindings"] = true,
    ["helska-console-focus"]           = true,
    ["console-reload-bindings"]        = true, -- legacy alias used by some modules
}

local handlers = {}
local real_register = mp.register_script_message

mp.register_script_message = function(name, fn)
    if SHARED[name] then
        local list = handlers[name]
        if not list then list = {}; handlers[name] = list end
        list[#list + 1] = fn
    elseif name == "helska-console-end-owner" then
        -- All modules share SCRIPT_NAME, so skip the console's stale-owner
        -- prune for the shared owner (it would wipe earlier modules' actions).
        real_register(name, function(owner)
            if owner == SCRIPT_NAME then return end
            fn(owner)
        end)
    else
        real_register(name, fn)
    end
end

-- 4) Load the modules: console first (the registration server), then the rest
--    in sorted order. Every *.lua in helska/ is picked up automatically, so
--    adding/removing a script needs no edit here. Load errors are reported
--    but do not take down the rest.
local CONSOLE_MODULE = "helska_console.lua"

-- Known module names, used ONLY as a fallback for ancient mpv builds that
-- lack utils.readdir. The normal path lists the folder directly.
local KNOWN_MODULES = {
    "helska_console.lua",
    "helska_audio-clipboard.lua",
    "helska_chinese.lua",
    "helska_extract-current-subtitle.lua",
    "helska_playback.lua",
    "helska_screenshot-clipboard.lua",
    "helska_subtitle-font.lua",
    "helska_subtitle_clipboard.lua",
}

local function discover_modules()
    if utils.readdir then
        local entries = utils.readdir(BUNDLE)
        if not entries then return nil end       -- folder missing / unreadable
        local list = {}
        for _, name in ipairs(entries) do
            if type(name) == "string" and name:sub(-4) == ".lua" then
                list[#list + 1] = name
            end
        end
        table.sort(list)
        return list
    end
    local list = {}
    for _, name in ipairs(KNOWN_MODULES) do
        if file_exists(utils.join_path(BUNDLE, name)) then
            list[#list + 1] = name
        end
    end
    if #list == 0 then return nil end
    return list
end

local discovered = discover_modules()
if not discovered then
    mp.msg.error("helska loader: could not find the 'helska' folder next to helska.lua")
    return
end

-- Console first, then the remaining modules alphabetically.
local modules = {}
for _, name in ipairs(discovered) do
    if name == CONSOLE_MODULE then modules[#modules + 1] = name end
end
for _, name in ipairs(discovered) do
    if name ~= CONSOLE_MODULE then modules[#modules + 1] = name end
end

local total  = #modules
local loaded = 0
for _, file in ipairs(modules) do
    local path = utils.join_path(BUNDLE, file)
    if not file_exists(path) then
        mp.msg.log("info", "helska loader: skipped (not present): " .. file)
    else
        local ok, err = pcall(dofile, path)
        if ok then
            loaded = loaded + 1
        else
            mp.msg.error("helska loader: " .. file .. " failed to load:\n" .. tostring(err))
        end
    end
end

-- 5) Install one real router per shared message.
mp.register_script_message = real_register -- put mpv's function back

for name, list in pairs(handlers) do
    if #list > 0 then
        real_register(name, function(...)
            for _, fn in ipairs(list) do pcall(fn, ...) end
        end)
    end
end

-- Re-advertise through the routers just installed, so the first TAB open
-- already shows the full menu.
mp.commandv("script-message", "helska-console-discover")

-- 6) Windows: clear the "downloaded from the internet" flag once on a fresh
--    install so Windows does not block the bundled tools (SmartScreen). This
--    runs a single time (marker file), so normal launches stay fast.
--
--    Recursively unblock everything under the bundle. A downloaded zip flags
--    not only the exes but the DLLs and .pyd modules they load; unblocking
--    just ffmpeg/opencc/python is not enough for a self-contained install.
local function windows_unblock_once()
    if package.config:sub(1, 1) ~= "\\" then return end
    local marker = utils.join_path(BUNDLE, ".unblocked")
    if file_exists(marker) then return end

    -- Escape single quotes for the embedded PowerShell command.
    local bundled = BUNDLE:gsub("'", "''")
    local cmd = "Get-ChildItem -LiteralPath '" .. bundled ..
        "' -Recurse -Force | Unblock-File -ErrorAction SilentlyContinue"
    local args = { "powershell", "-NoProfile", "-Command", cmd }
    pcall(utils.subprocess, { args = args, cancellable = false })

    local mf = io.open(marker, "w")
    if mf then mf:write("done\n"); mf:close() end
end
windows_unblock_once()

-- 7) Self-cleaning scratch folder: scripts/helska/temporary_files
--
--    Short-lived working files go here so the bundle only ever deletes files
--    inside its own folder (never the README). A leftover is removed only when
--    it is not on the clipboard and not loaded as a track.
local SCRATCH_DIR = utils.join_path(BUNDLE, "temporary_files")

local SCRATCH_README = [[HELSKA'S MPV TOOLS - temporary_files
====================================

This is the bundle's scratch folder. Features write their short-lived working
files here and delete them automatically: screenshots (Ctrl+S / Ctrl+Shift+S),
extracted audio clips (Ctrl+E / Ctrl+Shift+E), and the Chinese tone-colour /
conversion / preload subtitle tracks.

Only files inside this folder are ever removed, never this README, so nothing
else on your computer is ever touched. You can empty this folder at any time.

The ".helska-session-<pid>" entries are tiny markers that tell a second mpv
window which files are still in use; they disappear when that mpv closes.

A file left behind just means mpv was force-quit before cleanup ran: it is
removed on the next launch, and deleting it yourself is always safe.
]]

local function scratch_norm(path)
    local n = tostring(path):gsub("\\", "/")
    if package.config:sub(1, 1) == "\\" then n = n:lower() end
    return n
end

local function path_is_dir(path)
    if utils.file_info then
        local info = utils.file_info(path)
        if info then
            if info.is_dir ~= nil then return info.is_dir == true end
            return true
        end
    end
    return false
end

local function scratch_ensure()
    if not path_is_dir(SCRATCH_DIR) then
        if package.config:sub(1, 1) == "\\" then
            local d = SCRATCH_DIR:gsub("'", "''")
            pcall(utils.subprocess, {
                args = { "powershell", "-NoProfile", "-Command",
                    "New-Item -ItemType Directory -Force -Path '" .. d .. "' | Out-Null" },
                cancellable = false })
        else
            pcall(utils.subprocess, { args = { "mkdir", "-p", SCRATCH_DIR }, cancellable = false })
        end
    end
    local readme = utils.join_path(SCRATCH_DIR, "README.txt")
    if not file_exists(readme) then
        local f = io.open(readme, "w")
        if f then f:write(SCRATCH_README); f:close() end
    end
end

-- Non-blocking clipboard probe. This is the one expensive step of the sweep
-- (spawning PowerShell and loading WinForms can take a few hundred ms), so it
-- runs off the main thread: opening a file can never stall waiting for it.
local function query_clipboard_set(done)
    local args
    if package.config:sub(1, 1) == "\\" then
        args = { "powershell", "-NoProfile", "-STA", "-Command",
            "try { Add-Type -AssemblyName System.Windows.Forms; " ..
            "$f=[System.Windows.Forms.Clipboard]::GetFileDropList(); " ..
            "$f | ForEach-Object { $_ } } catch { }" }
    else
        args = { "/usr/bin/osascript", "-e", "try", "-e",
            "return POSIX path of (the clipboard as \xc2\xabclass furl\xc2\xbb)",
            "-e", "end try" }
    end
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        capture_stdout = true, capture_stderr = true, args = args,
    }, function(ok, r)
        local set, queried = {}, false
        if ok and r and r.status == 0 and r.stdout then
            queried = true
            for line in r.stdout:gmatch("[^\r\n]+") do
                set[scratch_norm(line)] = true
            end
        end
        done(set, queried)
    end)
end

local function alive_pids(pids)
    local set, queried = {}, false
    if #pids == 0 then return set, true end
    local list = table.concat(pids, ",")
    local args
    if package.config:sub(1, 1) == "\\" then
        -- "; exit 0" is required: Get-Process returns non-zero as soon as any
        -- requested pid is missing, which would look like a failed probe.
        args = { "powershell", "-NoProfile", "-Command",
            "Get-Process -Id " .. list ..
            " -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id; exit 0" }
    else
        -- ps(1) likewise exits non-zero when no pid matches; force success so
        -- a legitimate "none of them are alive" answer is not mistaken for a
        -- broken probe.
        args = { "sh", "-c", "ps -p " .. list .. " -o pid= 2>/dev/null || true" }
    end
    local ok, r = pcall(utils.subprocess, { args = args, cancellable = false })
    if ok and r and r.status == 0 and r.stdout then
        queried = true
        for line in r.stdout:gmatch("[^\r\n]+") do
            local id = line:match("%d+")
            if id then set[id] = true end
        end
    end
    return set, queried
end

-- Read the mpv pid a leftover belongs to from its name (internal files are
-- named helska-...-<pid>-<millis>.<ext>). User-visible tracks carry no pid
-- and are protected by the clipboard / loaded-track / other-session checks.
local function scratch_pid_of(name)
    -- Old prefixed naming: helska-tmp-<pid>-...
    local pid = name:match("^helska%-tmp%-(%d+)%-")
    if pid then return pid end
    -- Current INTERNAL naming: helska-chinese-<label>-<pid>-<millis>.<ext>.
    -- Only internal names are parsed, so a user-visible file whose name merely
    -- ends with "-<digits>-<digits>.<ext>" (e.g. a video with such a title) can
    -- never be mistaken for an owner and deleted early.
    if name:sub(1, 16) == "helska-chinese-" then
        return name:match("%-(%d+)%-%d+%.[^%.]+$")
    end
    return nil
end

-- Multi-instance safety
-- Each running mpv writes one "<pid>" marker; while that process is alive,
-- another instance must not delete its files. Dead markers are swept later.
local SESSION_PREFIX = ".helska-session-"

local function session_marker_path(pid)
    return utils.join_path(SCRATCH_DIR, SESSION_PREFIX .. tostring(pid))
end

local function is_session_marker(name)
    return name:sub(1, #SESSION_PREFIX) == SESSION_PREFIX
end

local function session_pid_of(name)
    return name:match("^%.helska%-session%-(%d+)$")
end

local SELF_PID = tostring(mp.get_property_number("pid", 0))

local function scratch_session_start()
    local f = io.open(session_marker_path(SELF_PID), "w")
    if f then
        f:write("helska mpv session " .. SELF_PID .. "\n")
        f:close()
    end
end

local function scratch_session_stop()
    pcall(os.remove, session_marker_path(SELF_PID))
end

-- The external paths mpv currently has loaded as tracks. A file that is on
-- screen right now must never be swept, even when it is not on the clipboard.
local function loaded_track_sets()
    local path, base = {}, {}
    local tracks = mp.get_property_native("track-list") or {}
    for _, t in ipairs(tracks) do
        local p = t["external-filename"]
        if type(p) == "string" and p ~= "" then
            path[scratch_norm(p)] = true
            local b = p:match("[^/\\]+$")
            if b then base[b:lower()] = true end
        end
    end
    return { path = path, base = base }
end

-- Remove leftovers from a previous run. A file is deleted only when it is not
-- this run's, not on the clipboard, not loaded as a track, and not owned by a
-- live process. Only one sweep runs at a time.
local sweep_busy = false
local function scratch_sweep()
    if sweep_busy then return end
    if not (utils.readdir and utils.file_info) then return end
    local entries = utils.readdir(SCRATCH_DIR)
    if not entries then return end

    -- First settle the session markers, so we know whether another live mpv
    -- window may be using the pid-less (cleanly named) files.
    local marker_pids = {}
    for _, name in ipairs(entries) do
        if type(name) == "string" and is_session_marker(name) then
            local pid = session_pid_of(name)
            if not pid then
                pcall(os.remove, utils.join_path(SCRATCH_DIR, name))
            elseif pid ~= SELF_PID then
                marker_pids[#marker_pids + 1] = pid
            end
        end
    end
    local others_alive = false
    if #marker_pids > 0 then
        local alive, ok = alive_pids(marker_pids)
        if ok then
            for _, pid in ipairs(marker_pids) do
                if alive[pid] then
                    others_alive = true
                else
                    pcall(os.remove, session_marker_path(pid))
                end
            end
        else
            -- Could not verify: assume another window may be live (keep files).
            others_alive = true
        end
    end

    local candidates, pidlist, seen = {}, {}, {}
    for _, name in ipairs(entries) do
        if type(name) == "string"
           and name:lower() ~= "readme.txt"
           and not is_session_marker(name) then
            local pid = scratch_pid_of(name)
            -- Never touch a file that belongs to the run happening right now.
            if pid ~= SELF_PID then
                candidates[#candidates + 1] = { name = name, pid = pid }
                if pid and not seen[pid] then
                    seen[pid] = true
                    pidlist[#pidlist + 1] = pid
                end
            end
        end
    end
    if #candidates == 0 then return end

    -- Fast path: a file already loaded as a track here is safe, so the common
    -- case never spawns a subprocess.
    local loaded = loaded_track_sets()
    local need_probe = false
    for _, item in ipairs(candidates) do
        local path = utils.join_path(SCRATCH_DIR, item.name)
        if not (loaded.path[scratch_norm(path)]
                or loaded.base[item.name:lower()]) then
            need_probe = true
            break
        end
    end
    if not need_probe then return end

    -- The clipboard probe is async, so deletion happens in its callback.
    sweep_busy = true
    local onclip = {}
    local clip_ok = false
    local alive, alive_ok = alive_pids(pidlist)

    query_clipboard_set(function(set, ok)
        onclip, clip_ok = set, ok
        sweep_busy = false

        -- With no clipboard answer we can't know what an in-flight paste still
        -- needs, so delete nothing this round.
        if not clip_ok then return end

        local removed = 0
        for _, item in ipairs(candidates) do
            local path = utils.join_path(SCRATCH_DIR, item.name)
            local keep = onclip[scratch_norm(path)]
                or loaded.path[scratch_norm(path)]
                or loaded.base[item.name:lower()]
            if not keep then
                if item.pid then
                    -- Delete only once its owner is gone; keep it if the probe
                    -- failed this round.
                    keep = not (alive_ok and not alive[item.pid])
                else
                    -- No owner recorded: keep unless no other mpv is running.
                    keep = others_alive
                end
            end
            if not keep and os.remove and pcall(os.remove, path) then
                removed = removed + 1
            end
        end
        if removed > 0 then
            mp.msg.log("info", "helska loader: removed " .. removed ..
                " leftover temporary file(s)")
        end
    end)
end

scratch_ensure()
scratch_session_start()
mp.add_timeout(3, function() pcall(scratch_sweep) end)
mp.register_event("file-loaded", function() pcall(scratch_sweep) end)
mp.register_event("shutdown", function() pcall(scratch_session_stop) end)

mp.msg.log("info", "helska loader: " .. loaded .. " of " .. total .. " scripts loaded")