--[[
    Helska Subtitle Clipboard

    Ctrl+C = copy the current subtitle text
    Ctrl+A = toggle auto-copy of every new subtitle

    Uses mpv's built-in clipboard/text, so no external tools are needed.
]]

local mp = require("mp")
local utils = require("mp.utils")
-- SHARED CONFIG  (helska.conf; any missing entry uses its default)

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


-- BINDINGS  (Ctrl+C copy, Ctrl+A toggle auto-copy; needs mpv 0.41+)

local autocopy = false
local last_autocopied = nil


-- CLEAN SUBTITLE TEXT

local function clean_subtitle(text)
    if not text or text == "" then
        return nil
    end

    -- Normalize line endings
    text = text:gsub("\r\n", "\n")
    text = text:gsub("\r", "\n")

    -- Handle ASS line breaks
    text = text:gsub("\\N", "\n")
    text = text:gsub("\\n", "\n")

    -- Put multi-line subtitles onto one clipboard line
    text = text:gsub("\n", " ")

    -- Collapse repeated whitespace
    text = text:gsub("%s+", " ")

    -- Trim beginning/end
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")

    if text == "" then
        return nil
    end

    return text
end


-- COPY TO CLIPBOARD

local function copy_to_clipboard(text, show_osd)
    text = clean_subtitle(text)

    if not text then
        if show_osd then
            mp.osd_message("No subtitle on screen")
        end
        return false
    end

    -- Native mpv clipboard support.
    -- No PowerShell or external process required.
    local ok, err = pcall(
        mp.set_property,
        "clipboard/text",
        text
    )

    if not ok then
        mp.msg.error(
            "Clipboard copy failed: " .. tostring(err)
        )

        if show_osd then
            mp.osd_message("Clipboard copy FAILED")
        end

        return false
    end

    if show_osd then
        mp.osd_message("Subtitle copied")
    end

    return true
end


-- CTRL+C
-- Copy subtitle currently visible on screen

local function copy_current_subtitle()
    copy_to_clipboard(
        mp.get_property("sub-text"),
        true
    )
end


-- AUTO COPY

local function subtitle_changed(_, value)
    if not autocopy then
        return
    end

    local text = clean_subtitle(value)

    -- Ignore gaps between subtitles
    if not text then
        return
    end

    -- Don't repeatedly copy the same subtitle
    if text == last_autocopied then
        return
    end

    if copy_to_clipboard(text, false) then
        last_autocopied = text
    end
end


local function toggle_autocopy()
    autocopy = not autocopy

    if autocopy then
        last_autocopied = nil

        mp.osd_message("Subtitle autocopy: ON")

        -- If a subtitle is already visible when autocopy
        -- is enabled, copy it immediately.
        local text = clean_subtitle(
            mp.get_property("sub-text")
        )

        if text then
            if copy_to_clipboard(text, false) then
                last_autocopied = text
            end
        end

    else
        mp.osd_message("Subtitle autocopy: OFF")
    end
end


-- RESET BETWEEN FILES

mp.register_event(
    "file-loaded",
    function()
        last_autocopied = nil
    end
)


-- WATCH SUBTITLE CHANGES

mp.observe_property(
    "sub-text",
    "string",
    subtitle_changed
)


-- KEY BINDINGS

local function install_main_bindings()
    mp.remove_key_binding("helska-copy-subtitle")
    mp.remove_key_binding("helska-autocopy-subtitle")

    local key = helska_bind("subtitle-clipboard", "Ctrl+c")
    if key then
        mp.add_forced_key_binding(key, "helska-copy-subtitle", copy_current_subtitle)
    end

    key = helska_bind("subtitle-clipboard-auto", "Ctrl+a")
    if key then
        mp.add_forced_key_binding(key, "helska-autocopy-subtitle", toggle_autocopy)
    end
end

install_main_bindings()

mp.register_script_message("console-subtitle-copy", copy_current_subtitle)
mp.register_script_message("console-subtitle-auto", toggle_autocopy)
mp.register_script_message("console-reload-bindings", install_main_bindings)

-- Pause our hotkeys while the Console owns input.
mp.register_script_message("helska-console-focus", function(state)
    if state == "on" then
        mp.remove_key_binding("helska-copy-subtitle")
        mp.remove_key_binding("helska-autocopy-subtitle")
    elseif state == "off" then
        install_main_bindings()
    end
end)


-- HELSKA CONSOLE COMPATIBILITY

local HELSKA_CONSOLE_ACTIONS = {
    {
        group = "SUBTITLE CLIPBOARD",
        name = "subtitle-clipboard",
        default_key = "Ctrl+c",
        description = "copy current subtitle to clipboard",
        group_order = 30,
        action_order = 1,
    },
    {
        group = "SUBTITLE CLIPBOARD",
        name = "subtitle-clipboard-auto",
        default_key = "Ctrl+a",
        description = "toggle automatic subtitle copying",
        group_order = 30,
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

local HELSKA_CONSOLE_RUNNERS = {
    ["subtitle-clipboard"] = copy_current_subtitle,
    ["subtitle-clipboard-auto"] = toggle_autocopy,
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

advertise_to_helska_console()
