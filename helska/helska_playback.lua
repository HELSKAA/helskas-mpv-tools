-- helska_playback.lua
-- Play the next / previous video in the current video's folder.
-- Keys: Ctrl+. (next), Ctrl+, (previous).
-- External dependencies: none.

local mp    = require "mp"
local utils = require "mp.utils"

----------------------------------------------------------------------
-- SETTINGS
----------------------------------------------------------------------

local ACTIONS = {
    next = {
        default_key = "Ctrl+.",
        display_key = "Ctrl+.",
        binding_name = "helska-playback-next",
    },
    previous = {
        default_key = "Ctrl+,",
        display_key = "Ctrl+,",
        binding_name = "helska-playback-previous",
    },
}

-- Files considered playable episodes/videos. Subtitle and other sidecar files
-- are intentionally excluded.
local VIDEO_EXTENSIONS = {
    ["3gp"] = true,
    ["avi"] = true,
    ["flv"] = true,
    ["m2ts"] = true,
    ["m4v"] = true,
    ["mkv"] = true,
    ["mov"] = true,
    ["mp4"] = true,
    ["mpeg"] = true,
    ["mpg"] = true,
    ["mts"] = true,
    ["ogm"] = true,
    ["ogv"] = true,
    ["ts"] = true,
    ["webm"] = true,
    ["wmv"] = true,
}

----------------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------------

local function script_dir()
    return utils.split_path(debug.getinfo(1, "S").source:sub(2))
end

local CONFIG_PATH = utils.join_path(script_dir(), "helska.conf")

----------------------------------------------------------------------
-- TOP-LEFT STATUS TOAST
----------------------------------------------------------------------

local toast = mp.create_osd_overlay("ass-events")
local toast_timer = nil

local function ass_escape(text)
    text = tostring(text or "")
    text = text:gsub("\\", "＼")
    text = text:gsub("{", "｛")
    text = text:gsub("}", "｝")
    return text
end

local function hide_toast()
    if toast_timer then
        toast_timer:kill()
        toast_timer = nil
    end
    toast.data = ""
    toast:update()
end

local function show_toast(title, detail, is_error)
    if toast_timer then
        toast_timer:kill()
        toast_timer = nil
    end

    local w = mp.get_property_number("osd-width", 1280)
    local h = mp.get_property_number("osd-height", 720)
    toast.res_x = w
    toast.res_y = h

    local scale = math.max(0.70, math.min(math.min(w / 1280, h / 720), 1.25))
    local x = math.floor(28 * scale + 0.5)
    local y = math.floor(30 * scale + 0.5)
    local fs_title = math.max(16, math.floor(22 * scale + 0.5))
    local fs_detail = math.max(13, math.floor(18 * scale + 0.5))

    -- Same warm family as the other shared menus. The error state changes only the
    -- title accent; geometry remains stable.
    local title_color = is_error and "&H7C9CFF&" or "&HFFDDAA&"
    local detail_color = "&HD7D7D7&"

    toast.data = string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b1\\bord2\\shad1\\1c%s\\3c&H201714&}%s" ..
        "\\N{\\fs%d\\b0\\1c%s}%s",
        x, y, fs_title, title_color, ass_escape(title),
        fs_detail, detail_color, ass_escape(detail or "")
    )
    toast:update()

    toast_timer = mp.add_timeout(is_error and 2.6 or 1.8, hide_toast)
end

local function basename(path)
    local _, name = utils.split_path(path or "")
    return name or ""
end

local function is_video_file(name)
    local ext = tostring(name or ""):match("%.([^%.\\/]+)$")
    return ext and VIDEO_EXTENSIONS[ext:lower()] or false
end

-- Natural comparison: digit runs are compared numerically, while all other
-- text is compared case-insensitively. This makes E9 sort before E10 without
-- requiring any particular episode naming convention.
local function natural_tokens(text)
    local tokens = {}
    local lower = tostring(text or ""):lower()
    local pos = 1

    while pos <= #lower do
        local s, e = lower:find("%d+", pos)
        if not s then
            tokens[#tokens + 1] = { kind = "text", value = lower:sub(pos) }
            break
        end

        if s > pos then
            tokens[#tokens + 1] = {
                kind = "text",
                value = lower:sub(pos, s - 1),
            }
        end

        local raw = lower:sub(s, e)
        tokens[#tokens + 1] = {
            kind = "number",
            value = tonumber(raw) or 0,
            raw = raw,
        }
        pos = e + 1
    end

    return tokens
end

local function natural_less(a, b)
    local ta = natural_tokens(a)
    local tb = natural_tokens(b)
    local count = math.max(#ta, #tb)

    for i = 1, count do
        local aa = ta[i]
        local bb = tb[i]

        if not aa then return true end
        if not bb then return false end

        if aa.kind == bb.kind then
            if aa.value ~= bb.value then
                return aa.value < bb.value
            end

            -- For equal numeric values, shorter zero-padding sorts first.
            if aa.kind == "number" and #aa.raw ~= #bb.raw then
                return #aa.raw < #bb.raw
            end
        else
            -- Stable deterministic ordering when text/number token boundaries
            -- differ between filenames.
            return aa.kind < bb.kind
        end
    end

    return a:lower() < b:lower()
end

local function same_path(a, b)
    if not a or not b then return false end

    -- Windows paths are case-insensitive in the normal mpv use case.
    if package.config:sub(1, 1) == "\\" then
        return a:gsub("/", "\\"):lower() == b:gsub("/", "\\"):lower()
    end

    return a == b
end

----------------------------------------------------------------------
-- VIDEO NAVIGATION
----------------------------------------------------------------------

local function navigate_video(direction)
    local label = direction > 0 and "Next episode" or "Previous episode"
    local current = mp.get_property("path")

    if not current or current == "" then
        show_toast(label:upper(), "No current file", true)
        return
    end

    -- URLs/protocol streams do not have a local sibling directory to scan.
    if current:match("^%a[%w+.-]*://") then
        show_toast(label:upper(), "Current video is not a local file", true)
        return
    end

    local directory, current_name = utils.split_path(current)
    if not directory or directory == "" or not current_name or current_name == "" then
        show_toast(label:upper(), "Could not determine video folder", true)
        return
    end

    local entries = utils.readdir(directory, "files")
    if not entries then
        show_toast(label:upper(), "Could not read video folder", true)
        return
    end

    local videos = {}
    for _, name in ipairs(entries) do
        if is_video_file(name) then
            videos[#videos + 1] = name
        end
    end

    table.sort(videos, natural_less)

    local current_index = nil
    for i, name in ipairs(videos) do
        local candidate = utils.join_path(directory, name)
        if same_path(candidate, current) or name == current_name then
            current_index = i
            break
        end
    end

    if not current_index then
        show_toast(label:upper(), "Current file not found in folder", true)
        return
    end

    local target_name = videos[current_index + direction]
    if not target_name then
        if direction > 0 then
            show_toast("NEXT", "Already at the last video", true)
        else
            show_toast("PREVIOUS", "Already at the first video", true)
        end
        return
    end

    local target_path = utils.join_path(directory, target_name)
    local success_title = direction > 0 and "NEXT" or "PREVIOUS"

    -- Confirm success only after mpv reports that the replacement file loaded.
    -- A one-shot hook avoids claiming success merely because loadfile was sent.
    local confirmed = false
    local function confirm_loaded()
        if confirmed then return end
        confirmed = true
        mp.unregister_event(confirm_loaded)

        local loaded = mp.get_property("path")
        if loaded and same_path(loaded, target_path) then
            show_toast(success_title, target_name, false)
        else
            show_toast(success_title, "Could not load " .. target_name, true)
        end
    end

    mp.register_event("file-loaded", confirm_loaded)
    mp.commandv("loadfile", target_path, "replace")

    -- If loading fails without a file-loaded event, surface that too.
    mp.add_timeout(4, function()
        if confirmed then return end
        confirmed = true
        mp.unregister_event(confirm_loaded)
        show_toast(success_title, "Could not load " .. target_name, true)
    end)
end

local function open_next_video()
    navigate_video(1)
end

local function open_previous_video()
    navigate_video(-1)
end

----------------------------------------------------------------------
-- SHARED HELSKA BINDING
----------------------------------------------------------------------

local function read_helska_binding(action_name)
    local file = io.open(CONFIG_PATH, "r")
    if not file then return nil end

    local wanted = "bind." .. action_name
    local value = nil

    for line in file:lines() do
        local key, candidate =
            line:match("^%s*([^#=%s][^=]-)%s*=%s*(.-)%s*$")
        if key == wanted then
            value = candidate
        end
    end

    file:close()
    return value
end

local function configured_key(action_name)
    local action = ACTIONS[action_name]
    if not action then return nil end

    local key = read_helska_binding(action_name)

    if key and key:lower() == "disabled" then
        return nil
    end

    if key and key ~= "" then
        return key
    end

    return action.default_key
end

local function install_main_bindings()
    for action_name, action in pairs(ACTIONS) do
        mp.remove_key_binding(action.binding_name)

        local key = configured_key(action_name)
        if key then
            local callback =
                action_name == "next" and open_next_video or open_previous_video
            mp.add_key_binding(key, action.binding_name, callback)
        end
    end
end

----------------------------------------------------------------------
-- HELSKA CONSOLE COMPATIBILITY
----------------------------------------------------------------------

local HELSKA_CONSOLE_ACTIONS = {
    {
        group = "PLAYBACK",
        name = "next",
        default_key = ACTIONS.next.display_key,
        description = "open next video in current folder",
        group_order = 50,
        action_order = 1,
    },
    {
        group = "PLAYBACK",
        name = "previous",
        default_key = ACTIONS.previous.display_key,
        description = "open previous video in current folder",
        group_order = 50,
        action_order = 2,
    },
}

local function advertise_to_helska_console()
    local owner = mp.get_script_name()

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

mp.register_script_message(
    "helska-console-discover",
    advertise_to_helska_console
)

mp.register_script_message("helska-console-run", function(action_name)
    if action_name == "next" then
        open_next_video()
    elseif action_name == "previous" then
        open_previous_video()
    end
end)

mp.register_script_message(
    "helska-console-reload-bindings",
    install_main_bindings
)

mp.register_script_message("next", open_next_video)
mp.register_script_message("previous", open_previous_video)

install_main_bindings()
advertise_to_helska_console()

-- Pause our next/previous hotkeys while the Console owns input.
mp.register_script_message("helska-console-focus", function(state)
    if state == "on" then
        for _, action in pairs(ACTIONS) do
            mp.remove_key_binding(action.binding_name)
        end
    elseif state == "off" then
        install_main_bindings()
    end
end)


mp.register_event("shutdown", function()
    hide_toast()
    toast:remove()
end)
