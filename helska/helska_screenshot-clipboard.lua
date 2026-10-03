--[[
    Helska Screenshot Clipboard
    =============================

    A cross-platform MPV script for quickly copying the current video
    frame to the clipboard on Windows and macOS.

    Hotkeys:
      Ctrl+S         = Copy screenshot WITH subtitles
      Ctrl+Shift+S   = Copy screenshot WITHOUT subtitles

    Usage:
      1. Press one of the screenshot hotkeys while watching a video.
      2. The current frame is automatically copied to the clipboard.
      3. Paste the image into any compatible application.

    The screenshot is written to the bundle's own temporary_files folder
    (scripts/helska/temporary_files) before being copied to the clipboard,
    and is deleted again immediately afterwards - the clipboard holds the
    image DATA, so the file is not needed once the copy has succeeded.

    Dependencies:
      Windows: PowerShell (bundled with Windows) is used to set the image
               clipboard. FFmpeg is NOT required.
      macOS:   osascript (built-in) is used to set the image clipboard.
--]]

local mp = require "mp"
local utils = require "mp.utils"


----------------------------------------------------------------------
-- OPTIONAL SHARED HELSKA CONFIG
--
-- The shared helska.conf is read when present. Missing bind.* entries use
-- built-in defaults, so the file itself is never required.
----------------------------------------------------------------------

local function helska_script_dir()
    return utils.split_path(debug.getinfo(1, "S").source:sub(2))
end

local HELSKA_CONFIG_PATH =
    utils.join_path(helska_script_dir(), "helska.conf")

local function helska_config_value(key)
    local file = io.open(HELSKA_CONFIG_PATH, "r")
    if not file then return nil end

    local result = nil

    for line in file:lines() do
        local config_key, value =
            line:match("^%s*([^#=%s][^=]-)%s*=%s*(.-)%s*$")

        if config_key == key then
            result = value
            break
        end
    end

    file:close()

    if result == "" then return nil end
    return result
end

local function helska_bind(command_name, default_key)
    local value = helska_config_value("bind." .. command_name)

    if value and value:lower() == "disabled" then
        return nil
    end

    return value or default_key
end

local path_separator = package.config:sub(1, 1)
local is_windows = path_separator == "\\"
local is_macos = false

if not is_windows then
    local uname = utils.subprocess({
        args = { "uname", "-s" },
        cancellable = false
    })

    if uname.status == 0 and uname.stdout then
        is_macos = uname.stdout:match("Darwin") ~= nil
    end
end

------------------------------------------------------------------------
-- TEMPORARY FILES  (self-cleaning scratch folder)
--
-- This feature's short-lived working file goes into
--     scripts/helska/temporary_files/
-- under its original, human-friendly name. Only a file that sits INSIDE
-- that folder (and is not the README) is ever removed, so no unrelated file
-- anywhere else on the computer can ever be touched.
------------------------------------------------------------------------
local SCRATCH = (function()
    local function norm(path)
        local n = tostring(path):gsub("\\", "/")
        if package.config:sub(1, 1) == "\\" then n = n:lower() end
        return n
    end

    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    local dir = utils.join_path(utils.split_path(src), "temporary_files")
    local dir_norm = norm(dir) .. "/"

    local api = { dir = dir, norm = norm }

    function api.path(name)
        return utils.join_path(dir, tostring(name))
    end

    function api.is_ours(path)
        if type(path) ~= "string" or path == "" then return false end
        local n = norm(path)
        if n:sub(1, #dir_norm) ~= dir_norm then return false end
        local base = n:match("[^/]*$") or ""
        return base:lower() ~= "readme.txt"
    end

    function api.remove(path)
        if not api.is_ours(path) then return false end
        pcall(os.remove, path)
        return true
    end

    return api
end)()

local function copy_image_to_clipboard(path)
    if is_windows then
        local ps = string.format(
            [[Add-Type -AssemblyName System.Windows.Forms; ]] ..
            [[Add-Type -AssemblyName System.Drawing; ]] ..
            [[$img = [System.Drawing.Image]::FromFile('%s'); ]] ..
            [[$copy = New-Object System.Drawing.Bitmap $img; ]] ..
            [[$img.Dispose(); ]] ..
            [[[System.Windows.Forms.Clipboard]::SetImage($copy); ]] ..
            [[$copy.Dispose()]],
            path:gsub("'", "''")
        )

        return utils.subprocess({
            args = {
                "powershell",
                "-NoProfile",
                "-STA",
                "-Command",
                ps
            },
            cancellable = false
        })
    end

    if is_macos then
        -- Read the PNG as image data and place that image on the macOS
        -- clipboard, so pasting behaves like a normal copied screenshot.
        local script =
            'set the clipboard to (read (POSIX file ' ..
            string.format('%q', path) ..
            ') as «class PNGf»)'

        return utils.subprocess({
            args = {
                "osascript",
                "-e",
                script
            },
            cancellable = false
        })
    end

    return {
        status = 1,
        stderr = "Unsupported operating system for image clipboard"
    }
end

local function copy_to_clipboard(mode, message)
    local path = SCRATCH.path("helska-mpv-screenshot.png")

    -- Take screenshot
    mp.commandv("screenshot-to-file", path, mode)

    -- Copy the PNG image data to the platform clipboard.
    local result = copy_image_to_clipboard(path) or { status = 1 }

    if result.status == 0 then
        -- The image is on the clipboard as DATA (not a file reference), so it
        -- can be pasted any number of times even though the file is now gone.
        SCRATCH.remove(path)
        mp.osd_message(message)
    else
        -- The copy failed, so nothing references the file: drop it now rather
        -- than leaving it for the next sweep.
        SCRATCH.remove(path)
        mp.msg.error(
            "Screenshot clipboard failed: " ..
            tostring(result.stderr or "unknown error")
        )
        mp.osd_message("Failed to copy screenshot to clipboard!")
    end
end

local function screenshot_with_subtitles()
    copy_to_clipboard(
        "subtitles",
        "Screenshot copied to clipboard! (with subtitles)"
    )
end

local function screenshot_clean()
    copy_to_clipboard(
        "video",
        "Screenshot copied to clipboard! (no subtitles)"
    )
end

local function install_main_bindings()
    mp.remove_key_binding("helska-screenshot-subs")
    mp.remove_key_binding("helska-screenshot-clean")

    local key = helska_bind("screenshot", "Ctrl+s")
    if key then
        mp.add_key_binding(key, "helska-screenshot-subs", screenshot_with_subtitles)
    end

    key = helska_bind("screenshot-clean", "Ctrl+Shift+s")
    if key then
        mp.add_key_binding(key, "helska-screenshot-clean", screenshot_clean)
    end
end

install_main_bindings()

mp.register_script_message("console-screenshot", screenshot_with_subtitles)
mp.register_script_message("console-screenshot-clean", screenshot_clean)
mp.register_script_message("console-reload-bindings", install_main_bindings)

-- Cooperate with Helska Console: pause our hotkeys while it owns input.
-- Fully independent when no console is present (handler simply never called).
mp.register_script_message("helska-console-focus", function(state)
    if state == "on" then
        mp.remove_key_binding("helska-screenshot-subs")
        mp.remove_key_binding("helska-screenshot-clean")
    elseif state == "off" then
        install_main_bindings()
    end
end)


----------------------------------------------------------------------
-- HELSKA CONSOLE COMPATIBILITY (v1)
--
-- This script owns its actions and key bindings. Helska Console only
-- discovers metadata and sends generic run/reload messages.
----------------------------------------------------------------------

local HELSKA_CONSOLE_ACTIONS = {
    {
        group = "SCREENSHOT CLIPBOARD",
        name = "screenshot",
        default_key = "Ctrl+s",
        description = "copy frame with subtitles to clipboard",
        group_order = 20,
        action_order = 1,
    },
    {
        group = "SCREENSHOT CLIPBOARD",
        name = "screenshot-clean",
        default_key = "Ctrl+Shift+s",
        description = "copy frame without subtitles to clipboard",
        group_order = 20,
        action_order = 2,
    },
}

local function advertise_to_helska_console()
    local owner = mp.get_script_name()

    -- One batch replaces this owner's previous registration set without
    -- intermediate menu redraws.
    mp.commandv("script-message", "helska-console-begin-owner", owner)

    for _, action in ipairs(HELSKA_CONSOLE_ACTIONS) do
        mp.commandv(
            "script-message",
            "helska-console-register",
            owner,
            action.group,
            action.name,
            action.default_key,
            action.description,
            tostring(action.group_order),
            tostring(action.action_order)
        )
    end

    mp.commandv("script-message", "helska-console-end-owner", owner)
end

local HELSKA_CONSOLE_RUNNERS = {
    ["screenshot"] = screenshot_with_subtitles,
    ["screenshot-clean"] = screenshot_clean,
}

mp.register_script_message("helska-console-discover", advertise_to_helska_console)

mp.register_script_message("helska-console-run", function(action_name)
    local run = HELSKA_CONSOLE_RUNNERS[action_name]
    if run then
        run()
    else
        mp.msg.warn("Unknown Helska Console action: " .. tostring(action_name))
    end
end)

mp.register_script_message("helska-console-reload-bindings", install_main_bindings)

-- Proactive registration handles either script load order. The console also
-- broadcasts discovery whenever it opens, so late/reloaded scripts recover.
advertise_to_helska_console()
