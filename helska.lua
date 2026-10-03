--[[ helska.lua
  Loader for the "helska" bundle of Lua scripts.

  INSTALL (Windows):
    1. Copy this file  AND  the "helska" folder together into mpv's
       scripts/ directory (the folder that already contains input.conf).
    2. Start / restart mpv. That's it.

  WHY THIS FILE EXISTS -------------------------------------------------------
  mpv only auto-runs *.lua that sit directly in scripts/ (it never recurses
  into subfolders). Everything in the helska/ folder is kept together (so it
  can be added/removed as one unit and can carry its own bundled tools), and
  this single file takes over loading them.

  mpv gives each auto-loaded .lua its own Lua context, so normally no two
  scripts ever fight. But because this loader pulls every helska script into
  ONE Lua context, several scripts would clobber each other when they all
  register the same Helska Console messages. The loader handles that here:
  it keeps the feature scripts byte-for-byte unchanged (they still run fine
  standalone) and just routes the shared messages to every interested module.

  DISCOVERY --------------------------------------------------------------
  Every *.lua file found inside the helska/ folder is loaded automatically
  (helska_console.lua first, the rest in sorted order). A user can therefore
  drop their OWN Console-compatible script into helska/ and it is picked up
  with no edit to this file, while deleting a file simply disables it.
----------------------------------------------------------------------------]]

local mp = require "mp"
local utils = require "mp.utils"

-- ---------------------------------------------------------------------------
-- 1) Locate this loader, then the "helska" folder sitting next to it.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 2) Bundle scripts that ask mpv for their "script directory" should get the
--    helska/ folder, NOT scripts/ (this matches where the config + bundled
--    tools live and keeps every module consistent under one mpv script).
-- ---------------------------------------------------------------------------
mp.get_script_directory = function() return BUNDLE end

-- All modules run inside this ONE script, so mp.get_script_name() returns
-- the same value for every one of them. Captured once so the console protocol
-- (below) can recognize that shared owner.
local SCRIPT_NAME = mp.get_script_name() or "helska"

-- ---------------------------------------------------------------------------
-- 3) Centralize the console protocol messages that several modules register.
--    Unique messages (console-audio-*, toggle-*, open-*, next/previous, ...)
--    pass straight through to the real mpv registration.
-- ---------------------------------------------------------------------------
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
        -- All modules share SCRIPT_NAME (single merged script). The console's
        -- end-owner handler prunes "this owner's" entries missing from the
        -- just-finished advertise batch; with one shared owner that would wipe
        -- each previous module's actions in turn. Bundle actions are static
        -- (explicit removal uses helska-console-unregister-owner), so skip the
        -- prune for the shared owner. Distinct real owners still prune.
        real_register(name, function(owner)
            if owner == SCRIPT_NAME then return end
            fn(owner)
        end)
    else
        real_register(name, fn)
    end
end

-- ---------------------------------------------------------------------------
-- 4) Load the modules. The console must load FIRST (it is the registration
--    server every other module advertises to); the rest load in sorted order
--    so startup is deterministic. EVERY *.lua in the helska/ folder is picked
--    up automatically, so a user can add their OWN Console-compatible script
--    with no edit here, and deleting a file simply disables that feature.
--    Load errors are reported but do not take down the rest of the bundle.
-- ---------------------------------------------------------------------------
local CONSOLE_MODULE = "helska_console.lua"

-- Known module names, used ONLY as a fallback for ancient mpv builds that
-- lack utils.readdir. The normal path lists the folder directly.
local KNOWN_MODULES = {
    "helska_console.lua",
    "helska_audio-clipboard.lua",
    "helska_chinese.lua",
    "helska_extract-current-subtitle.lua",
    "helska_hold-to-speed.lua",
    "helska_playback.lua",
    "helska_rebind_mouse4-5_to_arrow_keys.lua",
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

-- ---------------------------------------------------------------------------
-- 5) Install one real router per shared message. For "run" we quiet only the
--    expected "Unknown Helska Console action" warnings (spawned by the modules
--    that do not own the action being invoked); real warnings still show.
-- ---------------------------------------------------------------------------
mp.register_script_message = real_register -- put mpv's function back

local real_warn = mp.msg.warn
for name, list in pairs(handlers) do
    if #list > 0 then
        if name == "helska-console-run" then
            real_register(name, function(action)
                local saved = real_warn
                mp.msg.warn = function(m, ...)
                    local parts = { m, ... }
                    local text = table.concat(parts, " ")
                    if not text:find("Unknown Helska Console action", 1, true) then
                        saved(m, ...)
                    end
                end
                for _, fn in ipairs(list) do pcall(fn, action) end
                mp.msg.warn = saved
            end)
        else
            real_register(name, function(...)
                for _, fn in ipairs(list) do pcall(fn, ...) end
            end)
        end
    end
end

-- The load-time advertise of each module already accumulated cleanly (the
-- shared end-owner above no longer prunes). A final discover re-advertises
-- everything through the just-installed routers, so even the FIRST TAB open
-- already shows the full menu.
mp.commandv("script-message", "helska-console-discover")

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- 6) Windows: clear the "downloaded from the internet" flag once on a fresh
--    install so Windows does not block the bundled tools (SmartScreen). This
--    runs a single time (marker file), so normal launches stay fast.
--
--    Recursively unblock EVERYTHING under the bundle. Windows attaches a
--    Zone.Identifier flag to each file of a downloaded zip/email and blocks
--    not just the executables but also the DLLs they load and the .pyd
--    extension modules that embedded Python imports (e.g. _ctypes.pyd).
--    Unblocking only ffmpeg.exe/opencc.exe/python.exe is NOT enough: if
--    sibling DLLs stay flagged, python.exe starts but then fails when it
--    imports what it needs, so the tone-coloring python probe fails on a
--    machine with no system Python. Clearing the whole tree makes a fresh
--    install fully self-contained.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 7) Self-cleaning scratch folder: scripts/helska/temporary_files
--
--    Features that need a short-lived working file write it HERE instead of
--    scattering files across the operating system's temporary directory. This
--    keeps every byte the bundle creates in ONE known place, which is exactly
--    what makes safe auto-deletion possible: only a file that sits INSIDE this
--    folder (and is not the README) is ever removed, so no unrelated file
--    anywhere else on the machine can ever be touched.
--
--    Files keep their original, human-friendly names (for example the pasted
--    audio clip stays "<video>_<start>-<end>_<hash>.mp3"), so what you paste is
--    never decorated with an internal prefix. The tracks that ARE visible in
--    mpv's list are named to read clearly there too (for example the generated
--    tone track is "Tone colors (sub 2).ass").
--
--    On startup the folder is created if missing (together with a README that
--    explains it) and a conservative sweep removes leftovers from a previous
--    run. The sweep runs once at startup and again whenever a file is loaded.
--    A leftover is only deleted when it is NOT still on the clipboard, NOT
--    loaded as a track in this mpv, and (when its name still records the owning
--    mpv process id) that process is no longer running - so an in-flight paste
--    or a track on screen is never broken. Each run also writes a tiny
--    ".helska-session-<pid>" marker so a second mpv window never deletes the
--    first window's files. The sweep does nothing when there are no leftovers.
-- ---------------------------------------------------------------------------
local SCRATCH_DIR = utils.join_path(BUNDLE, "temporary_files")

local SCRATCH_README = [[HELSKA - temporary_files
========================

This folder is the helska bundle's own scratch space.

Every feature that has to write a short-lived working file writes it HERE
instead of scattering files across the operating system's temporary folder.
Files appear and remove themselves automatically as you use the features:

  * Screenshots (Ctrl+S / Ctrl+Shift+S) are written here, placed on the
    clipboard, and then deleted again immediately.
  * Extracted audio clips (Ctrl+E / Ctrl+Shift+E) are written here and kept
    only until the clipboard stops pointing at them (so you can still paste
    the file), then deleted automatically.
  * The Chinese tone-colour / Hanzi-conversion tracks and the "preload-subs"
    track use short-lived files here that are removed when the track is
    switched off or mpv closes. Because these ARE shown in mpv's track list,
    they are named to read clearly there, e.g. "Tone colors (sub 2).ass" or
    "Preloaded subs (sub 2).srt".

Only files inside this folder are ever removed, and never this README, so
nothing else on your computer is ever touched. Files keep their normal,
friendly names - for example an extracted audio clip is named like
"<video>_<start>-<end>_<hash>.mp3", exactly as it appears when you paste it.

This README is permanent and is never deleted. You can safely empty this
folder at any time; the next action simply creates a fresh file.

The ".helska-session-<pid>" entries are not junk: they are tiny one-line
markers that tell a second mpv window which files are still in use, and they
vanish when that mpv closes. Fine to leave them alone.

If you ever see a working file left behind, it only means mpv was force-quit
before the cleanup could run - it is removed on the next launch, and deleting
it yourself is always safe.
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
        -- The trailing "; exit 0" is essential. Get-Process exits non-zero as
        -- soon as ANY requested pid is missing, so a list that still contains
        -- one dead pid used to look like a FAILED probe and aborted the whole
        -- sweep - which is exactly why leftovers were never cleaned up.
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

-- Read the mpv process id a leftover file belongs to, if its name still
-- records one. Internal working files are named like
--   helska-chinese-source-<pid>-<millis>.<ext>
-- so the trailing "<pid>-<millis>" carries the owner. Files left by an earlier
-- build that used the "helska-tmp-<pid>-..." prefix are also recognised. The
-- user-visible tracks (tone colors, preload, ...) keep clean names and carry
-- no pid, so they are protected by the clipboard / loaded-track / other-session
-- checks instead.
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

-- Multi-instance safety ------------------------------------------------------
-- Every running mpv writes ONE tiny marker (named "<pid>"). While a marker's
-- process is alive, another instance must not delete THAT instance's files, so
-- opening a second mpv window can never pull a subtitle file out from under the
-- first. Markers whose process has exited are cleaned up by the sweep.
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

-- Remove leftovers from a previous run. Safe by construction: a file is only
-- deleted when it is NOT this run's, NOT on the clipboard anymore, NOT loaded
-- as a track in this mpv, and NOT owned by a live process (or, for files whose
-- name carries no pid, when no other live mpv instance is present).
-- Only one sweep may be in flight at a time (its final step is asynchronous).
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

    -- Fast path: a candidate already loaded as a track in THIS mpv (the tone
    -- -colour or preload file currently on screen, for example) is safe by
    -- definition. When every candidate is safe there is nothing to probe, so
    -- the common case costs nothing and never spawns a subprocess.
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

    -- The clipboard probe is asynchronous, so the deletion decision happens in
    -- its callback. The pid liveness probe (rare: only leftover internal files
    -- carry one) stays synchronous and cheap.
    sweep_busy = true
    local onclip = {}
    local clip_ok = false
    local alive, alive_ok = alive_pids(pidlist)

    query_clipboard_set(function(set, ok)
        onclip, clip_ok = set, ok
        sweep_busy = false

        -- Be conservative: with no clipboard answer we cannot know what an
        -- in-flight paste still needs, so delete nothing this round.
        if not clip_ok then return end

        local removed = 0
        for _, item in ipairs(candidates) do
            local path = utils.join_path(SCRATCH_DIR, item.name)
            local keep = onclip[scratch_norm(path)]
                or loaded.path[scratch_norm(path)]
                or loaded.base[item.name:lower()]
            if not keep then
                if item.pid then
                    -- Only delete once its owner is provably gone. If the
                    -- liveness probe failed this round, keep it (conservative).
                    keep = not (alive_ok and not alive[item.pid])
                else
                    -- No owner recorded: safe only when no other mpv is running,
                    -- otherwise the file may belong to that other window.
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