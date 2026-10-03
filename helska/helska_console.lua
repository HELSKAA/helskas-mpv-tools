--[[
    Helska Console
    ==============

    The menu of every action in the bundle. TAB opens it.

    Console-compatible scripts advertise themselves over a small message
    protocol: helska-console-discover / -run / -reload-bindings, and
    helska-console-begin-owner / -register / -end-owner. See FEATURES.txt.
]]

local mp = require("mp")
local utils = require("mp.utils")

-- CONSTANTS

local DEFAULT_OPEN_KEY = "TAB"
local MAX_VISIBLE = 18

-- ASS uses BGR hexadecimal order.
local C_COMMAND     = "&HFFDDAA&"
local C_SPECIAL     = "&HFF8CC5&" -- purple/lavender
local C_KEYBIND     = "&H56D8FF&"
local C_DESCRIPTION = "&HD7D7D7&"
local C_MUTED       = "&H9A9A9A&"
local C_WHITE       = "&HFFFFFF&"
local C_PANEL       = "&H201714&"
local C_BORDER      = "&H70543B&"
local C_SELECTED    = "&H493A2A&"
local C_CAPTURE     = "&H00FFFF&"
local C_ACTIVE      = "&H55FFDD&" -- warm lime/yellow action-state accent (ASS BGR)

local RESERVED = {
    console = true,
    bind = true,
    unbind = true,
    defaultbind = true,
    all = true,
}

-- STATE

local overlay = mp.create_osd_overlay("ass-events")

local registry = {}
local batches = {}
local user_bindings = {}

local is_open = false
local mode = "root" -- derived completion context; capture is explicit
local query = ""      -- committed command-line text; this alone filters rows
local soft_query = nil  -- selected completion shown visually, never used to filter
local select_all_armed = false
local selected = 0
local scroll_top = 1
local rows = {}

local capture_target = nil
local capture_key = nil

local caret_visible = true
local caret_timer = nil



-- GENERIC HELPERS

local function script_dir()
    return utils.split_path(debug.getinfo(1, "S").source:sub(2))
end

local CONFIG_PATH = utils.join_path(script_dir(), "helska.conf")

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ass_escape(text)
    text = tostring(text or "")
    text = text:gsub("\\", "＼")
    text = text:gsub("{", "｛")
    text = text:gsub("}", "｝")
    return text
end

local function draw_rect(x1, y1, x2, y2, color, alpha)
    return string.format(
        "{\\an7\\pos(0,0)\\bord0\\shad0\\1c%s\\1a&H%02X&\\p1}" ..
        "m %d %d l %d %d %d %d %d %d{\\p0}",
        color, alpha or 0,
        x1, y1, x2, y1, x2, y2, x1, y2
    )
end

local function responsive_scale(w, h)
    local scale = math.min(w / 1280, h / 720) * 0.70
    return math.max(0.42, math.min(scale, 1.15))
end

local function valid_action_name(name)
    return type(name) == "string"
        and name:match("^[a-z0-9][a-z0-9._%-]*$") ~= nil
        and not RESERVED[name]
end

local function send(owner, message, ...)
    if owner and owner ~= "" then
        mp.commandv("script-message-to", owner, message, ...)
    end
end

-- SHARED CONFIG

local function read_config()
    local values = {}
    local f = io.open(CONFIG_PATH, "r")
    if not f then return values end

    for line in f:lines() do
        local key, value = line:match("^%s*([^#=%s][^=]-)%s*=%s*(.-)%s*$")
        if key and value then values[key] = value end
    end
    f:close()
    return values
end

local function write_config_value(key, value)
    local lines = {}
    local found = false
    local f = io.open(CONFIG_PATH, "r")

    if f then
        for line in f:lines() do
            local existing = line:match("^%s*([^#=%s][^=]-)%s*=")
            if existing == key then
                lines[#lines + 1] = key .. "=" .. value
                found = true
            else
                lines[#lines + 1] = line
            end
        end
        f:close()
    else
        lines = {
            "# helska shared configuration",
            "#",
            "# This is the SHARED configuration file used by all helska scripts.",
            "#",
            "# A setting only needs to appear here when you want to override a",
            "# script's built-in default; anything that is not present simply",
            "# uses that script's built-in default.",
            "#",
        }
    end

    if not found then lines[#lines + 1] = key .. "=" .. value end

    local out = io.open(CONFIG_PATH, "w")
    if not out then return false end
    out:write(table.concat(lines, "\n") .. "\n")
    out:close()
    return true
end

local function delete_config_value(key)
    local f = io.open(CONFIG_PATH, "r")
    if not f then return true end

    local lines = {}
    for line in f:lines() do
        local existing = line:match("^%s*([^#=%s][^=]-)%s*=")
        if existing ~= key then lines[#lines + 1] = line end
    end
    f:close()

    local out = io.open(CONFIG_PATH, "w")
    if not out then return false end
    if #lines > 0 then out:write(table.concat(lines, "\n") .. "\n") end
    out:close()
    return true
end

local function load_bindings()
    user_bindings = {}
    local values = read_config()
    for key, value in pairs(values) do
        local name = key:match("^bind%.(.+)$")
        if name and value ~= "" then user_bindings[name] = value end
    end
end

local function configured_key(name, default_key)
    local value = user_bindings[name]
    if value == "disabled" then return nil end
    if value and value ~= "" then return value end
    return default_key
end

local MODIFIER_TITLES = {
    ctrl = "Ctrl", alt = "Alt", shift = "Shift",
    meta = "Meta", super = "Super", win = "Win",
}
local MODIFIER_ORDER = { Ctrl = 1, Alt = 2, Shift = 3, Meta = 4, Super = 5, Win = 6 }

-- Format a stored binding key for display only. Storage keeps mpv-canonical
-- names; letters show uppercase, modifiers in a fixed order.
local function display_key(raw)
    if not raw then return "" end
    local text = tostring(raw)
    if text == "" or text == "disabled" then return text end

    local mods, mains = {}, {}
    local mod_seen = {}
    local has_shift = false
    for token in text:gmatch("[^+]+") do
        local title = MODIFIER_TITLES[token:lower()]
        if title then
            -- De-duplicate modifiers so a redundant "Shift" can never double up.
            if not mod_seen[title] then
                mod_seen[title] = true
                mods[#mods + 1] = title
            end
            if title == "Shift" then has_shift = true end
        else
            local low = token:lower()
            if low:match("^f%d+$") then
                -- F-keys have no case, so they are simply upper-cased.
                mains[#mains + 1] = low:upper()   -- f4 -> F4
            elseif low:match("^%a$") then
                -- mpv folds Shift into the letter's case: an uppercase stored
                -- letter means Shift+<letter>.
                if token == token:upper() and not has_shift then
                    has_shift = true
                    mod_seen.Shift = true
                    mods[#mods + 1] = "Shift"
                end
                mains[#mains + 1] = low:upper()   -- a -> A
            else
                mains[#mains + 1] = token         -- SPACE, MBTN_LEFT, "—", ...
            end
        end
    end

    table.sort(mods, function(a, b)
        return (MODIFIER_ORDER[a] or 9) < (MODIFIER_ORDER[b] or 9)
    end)

    local out = table.concat(mods, "+")
    for _, m in ipairs(mains) do
        if out ~= "" then out = out .. "+" end
        out = out .. m
    end
    return out
end

-- DYNAMIC REGISTRY

local function sorted_actions()
    local out = {}
    for _, action in pairs(registry) do out[#out + 1] = action end

    table.sort(out, function(a, b)
        if a.group_order ~= b.group_order then
            return a.group_order < b.group_order
        end
        local ag, bg = a.group:lower(), b.group:lower()
        if ag ~= bg then return ag < bg end
        if a.action_order ~= b.action_order then
            return a.action_order < b.action_order
        end
        return a.name < b.name
    end)

    return out
end

local function request_discovery()
    mp.commandv("script-message", "helska-console-discover")
end

mp.register_script_message("helska-console-begin-owner", function(owner)
    if not owner or owner == "" then return end
    batches[owner] = { seen = {} }
end)

mp.register_script_message("helska-console-register",
    function(owner, group, name, default_key, description, group_order, action_order)
        if not owner or owner == "" or not valid_action_name(name) then return end

        local existing = registry[name]
        if existing and existing.owner ~= owner then
            mp.msg.warn(
                "Helska Console: command collision for '" .. name ..
                "' between " .. existing.owner .. " and " .. owner
            )
            return
        end

        local batch = batches[owner]
        if not batch then
            batch = { seen = {} }
            batches[owner] = batch
        end
        batch.seen[name] = true

        registry[name] = {
            kind = "script",
            owner = owner,
            group = (group and group ~= "") and group or "SCRIPT",
            name = name,
            default_key = (default_key and default_key ~= "") and default_key or "—",
            description = description or "",
            group_order = tonumber(group_order) or 1000,
            action_order = tonumber(action_order) or 1000,
        }
    end
)

mp.register_script_message("helska-console-end-owner", function(owner)
    local batch = batches[owner]
    if not batch then return end

    for name, action in pairs(registry) do
        if action.owner == owner and not batch.seen[name] then
            registry[name] = nil
        end
    end
    batches[owner] = nil
end)

mp.register_script_message("helska-console-unregister-owner", function(owner)
    for name, action in pairs(registry) do
        if action.owner == owner then registry[name] = nil end
    end
    batches[owner] = nil
end)

mp.register_script_message("helska-console-refresh", request_discovery)

-- NATIVE / TARGET MODELS

local function console_rows()
    return {
        {
            kind = "native", group = "CONSOLE", name = "console",
            default_key = DEFAULT_OPEN_KEY,
            description = "open console",
            order = 1,
        },
        {
            kind = "native", group = "CONSOLE", name = "bind",
            default_key = "—",
            description = "set a custom key for a command",
            order = 2,
        },
        {
            kind = "native", group = "CONSOLE", name = "unbind",
            default_key = "—",
            description = "disable a command keybind",
            order = 3,
        },
        {
            kind = "native", group = "CONSOLE", name = "defaultbind",
            default_key = "—",
            description = "restore a command's built-in default key",
            order = 4,
        },
    }
end

local function bindable_targets()
    local out = {}

    -- The opener is bindable; other native actions are not key commands.
    out[#out + 1] = {
        kind = "target",
        target_kind = "console",
        group = "CONSOLE",
        name = "console",
        default_key = DEFAULT_OPEN_KEY,
        description = "open console",
        group_order = -1000,
        action_order = 1,
    }

    for _, action in ipairs(sorted_actions()) do
        out[#out + 1] = {
            kind = "target",
            target_kind = "script",
            owner = action.owner,
            group = action.group,
            name = action.name,
            default_key = action.default_key,
            description = action.description,
            group_order = action.group_order,
            action_order = action.action_order,
        }
    end

    return out
end

local function bulk_row(current_mode)
    if current_mode == "unbind" then
        return {
            kind = "bulk", group = "ALL COMMANDS", name = "all",
            default_key = "—",
            description = "disable every script command keybind",
        }
    elseif current_mode == "defaultbind" then
        return {
            kind = "bulk", group = "ALL COMMANDS", name = "all",
            default_key = "—",
            description = "restore every script command to its built-in default key",
        }
    end
    return nil
end

-- COMMAND-LINE PARSING

local function parse_commandline()
    if mode == "capture" then
        return "capture", "", capture_target and capture_target.name or ""
    end

    local head, rest = query:match("^%s*([^%s]*)%s?(.*)$")
    head = (head or ""):lower()
    rest = rest or ""

    -- A binding verb becomes its completion context only once complete.
    if head == "bind" or head == "unbind" or head == "defaultbind" then
        return head, rest, head
    end
    return "root", query, head
end

local function sync_mode_from_commandline()
    if mode == "capture" then return end
    local context = parse_commandline()
    mode = context
end

local function completion_fragment()
    local context, fragment = parse_commandline()
    if context == "capture" then return "" end
    return fragment or ""
end

-- The completion token inside a command line. Highlighting uses the visible
-- text (soft_query or query), so a Tab preview highlights its own row too.
local function fragment_of(text)
    if mode == "capture" then return "" end
    local head, rest = text:match("^%s*([^%s]*)%s?(.*)$")
    head = (head or ""):lower()
    if head == "bind" or head == "unbind" or head == "defaultbind" then
        return trim(rest or "")
    end
    return trim(text or "")
end

local function selected_completion_text(row)
    if not row then return query end
    local context = parse_commandline()
    if context == "root" then return row.name end
    return context .. " " .. row.name
end

local function update_soft_fill()
    local row = rows[selected]
    soft_query = row and selected_completion_text(row) or nil
end

local function commit_soft_fill()
    if soft_query and soft_query ~= "" then
        query = soft_query
    end
    soft_query = nil
end

-- FILTERING / ROW BUILDING

local function row_matches(row, needle)
    if needle == "" then return true end
    return row.name:lower():find(needle, 1, true) ~= nil
        or row.group:lower():find(needle, 1, true) ~= nil
        or tostring(row.description):lower():find(needle, 1, true) ~= nil
end

-- Filtering is broad; ranking favours command-name matches (lower score wins).
local function command_name_rank(row, needle)
    if needle == "" then return 0, 0 end

    local name = row.name:lower()
    if name == needle then
        return 0, 0
    end

    if name:sub(1, #needle) == needle then
        return 1, #name - #needle
    end

    local pos = name:find(needle, 1, true)
    if pos then
        return 2, pos
    end

    -- If the token's characters appear in order in the name, rank above
    -- metadata-only matches but below a literal name match.
    local ni = 1
    local first = nil
    for qi = 1, #needle do
        local ch = needle:sub(qi, qi)
        local found = name:find(ch, ni, true)
        if not found then
            return 4, 0
        end
        if not first then first = found end
        ni = found + 1
    end
    return 3, first or 0
end

local function sort_filtered_rows(list, needle)
    if needle == "" then return end

    table.sort(list, function(a, b)
        local ar, ad = command_name_rank(a, needle)
        local br, bd = command_name_rank(b, needle)

        if ar ~= br then return ar < br end
        if ad ~= bd then return ad < bd end

        -- Deterministic tie-breakers for equally relevant name matches.
        local an, bn = a.name:lower(), b.name:lower()
        if an ~= bn then return an < bn end

        local ag, bg = tostring(a.group):lower(), tostring(b.group):lower()
        if ag ~= bg then return ag < bg end

        return tostring(a.description):lower() < tostring(b.description):lower()
    end)
end

local function rebuild_rows()
    rows = {}
    sync_mode_from_commandline()

    local needle = trim(completion_fragment()):lower()

    if mode == "root" then
        for _, action in ipairs(sorted_actions()) do
            if row_matches(action, needle) then rows[#rows + 1] = action end
        end
        for _, native in ipairs(console_rows()) do
            if row_matches(native, needle) then rows[#rows + 1] = native end
        end
    elseif mode == "bind" or mode == "unbind" or mode == "defaultbind" then
        for _, target in ipairs(bindable_targets()) do
            if row_matches(target, needle) then rows[#rows + 1] = target end
        end

        local bulk = bulk_row(mode)
        if bulk and row_matches(bulk, needle) then rows[#rows + 1] = bulk end
    elseif mode == "capture" then
        rows = {}
    end

    -- An empty token keeps the registry's natural group/action ordering.
    -- A real token reorders surviving rows by command-name relevance only.
    sort_filtered_rows(rows, needle)

    -- Highlight from the visible text (soft_query or query), so a Tab preview
    -- highlights its own row before it is committed.
    local visible_fragment = fragment_of(soft_query or query):lower()
    local exact_index = nil
    if visible_fragment ~= "" then
        for i, row in ipairs(rows) do
            if row.name:lower() == visible_fragment then
                exact_index = i
                break
            end
        end
    end

    if exact_index then
        selected = exact_index
    elseif #rows > 0 then
        -- No complete command: keep a valid manual selection, otherwise clear
        -- it. Never auto-highlight the first row.
        if selected < 1 or selected > #rows then selected = 0 end
    else
        selected = 0
        scroll_top = 1
    end

    -- Selection is visual only; soft_query is owned by Tab completion and
    -- manual editing, never by rebuilding recommendations.
end

local function ensure_visible(limit)
    limit = math.max(1, tonumber(limit) or MAX_VISIBLE)

    if selected <= 0 then
        scroll_top = 1
        return
    end

    local max_top = math.max(1, #rows - limit + 1)

    -- Proportional scroll anchors: hold the highlight near 2/3 down / 1/3 up.
    local lower_anchor = math.max(1, math.ceil(limit * 2 / 3))
    local upper_anchor = math.max(1, limit - lower_anchor + 1)

    local lower_trigger = scroll_top + lower_anchor - 1
    if selected > lower_trigger and scroll_top < max_top then
        scroll_top = math.min(max_top, selected - lower_anchor + 1)
    end

    local upper_trigger = scroll_top + upper_anchor - 1
    if selected < upper_trigger and scroll_top > 1 then
        scroll_top = math.max(1, selected - upper_anchor + 1)
    end

    -- Hard visibility guards for page jumps and unusually short windows.
    if selected < scroll_top then
        scroll_top = selected
    elseif selected > scroll_top + limit - 1 then
        scroll_top = selected - limit + 1
    end

    -- At the ends, pin the viewport; the highlight travels freely between.
    if scroll_top < 1 then scroll_top = 1 end
    if scroll_top > max_top then scroll_top = max_top end
end

-- BINDING OPERATIONS

local install_open_binding

local function reload_owner(target)
    if target and target.owner then
        send(target.owner, "helska-console-reload-bindings")
    end
end

local function save_target_binding(target, key)
    if not target or not key or key == "" then return false end
    if not write_config_value("bind." .. target.name, key) then
        mp.osd_message("Could not save Helska binding", 3)
        return false
    end

    user_bindings[target.name] = key
    if target.target_kind == "console" then
        install_open_binding()
    else
        reload_owner(target)
    end
    -- Stored key stays mpv-canonical; only the confirmation label is formatted.
    mp.osd_message(target.name .. " bound to " .. display_key(key), 2)
    return true
end

local function disable_target(target)
    if not target then return false end

    -- The opener can never be disabled, or "unbind all" would lock you out.
    if target.target_kind == "console" then
        mp.osd_message("Console opener cannot be disabled; rebind it instead", 3)
        return false
    end

    if not write_config_value("bind." .. target.name, "disabled") then
        mp.osd_message("Could not disable Helska binding", 3)
        return false
    end

    user_bindings[target.name] = "disabled"
    reload_owner(target)
    mp.osd_message(target.name .. " keybind disabled", 2)
    return true
end

local function restore_target_default(target)
    if not target then return false end
    if not delete_config_value("bind." .. target.name) then
        mp.osd_message("Could not restore default Helska binding", 3)
        return false
    end

    user_bindings[target.name] = nil
    if target.target_kind == "console" then
        install_open_binding()
    else
        reload_owner(target)
    end
    mp.osd_message(target.name .. " restored to its default key", 2)
    return true
end

local function bulk_unbind()
    local count = 0
    for _, target in ipairs(bindable_targets()) do
        if target.target_kind == "script" then
            if write_config_value("bind." .. target.name, "disabled") then
                user_bindings[target.name] = "disabled"
                count = count + 1
            end
        end
    end

    local owners = {}
    for _, target in ipairs(bindable_targets()) do
        if target.target_kind == "script" and target.owner then
            owners[target.owner] = true
        end
    end
    for owner in pairs(owners) do
        send(owner, "helska-console-reload-bindings")
    end

    mp.osd_message(string.format("%d script command keybinds disabled", count), 2)
end

local function bulk_defaultbind()
    local count = 0
    for _, target in ipairs(bindable_targets()) do
        if target.target_kind == "script" then
            if delete_config_value("bind." .. target.name) then
                user_bindings[target.name] = nil
                count = count + 1
            end
        end
    end

    local owners = {}
    for _, target in ipairs(bindable_targets()) do
        if target.target_kind == "script" and target.owner then
            owners[target.owner] = true
        end
    end
    for owner in pairs(owners) do
        send(owner, "helska-console-reload-bindings")
    end

    mp.osd_message(string.format("%d script commands restored to default keys", count), 2)
end

-- RENDERER

local function title_for_mode()
    -- Binding operations are command-line contexts, not separate screens.
    return "CONSOLE"
end

local function commandline_text()
    if mode == "capture" then
        local text = query
        if capture_key and capture_key ~= "" then
            text = text .. " " .. display_key(capture_key)
        end
        return text
    end
    return soft_query or query
end

local function row_color(row)
    if row.kind == "native" or row.kind == "bulk" then return C_SPECIAL end
    if row.target_kind == "console" then return C_SPECIAL end
    return C_COMMAND
end

local function row_key(row)
    if row.kind == "native" then
        if row.name == "console" then
            local k = configured_key("console", DEFAULT_OPEN_KEY)
            return k and display_key(k) or "DISABLED"
        end
        return "—"
    end

    if row.kind == "bulk" then return "—" end
    local k = configured_key(row.name, row.default_key)
    return k and display_key(k) or "DISABLED"
end

local function render()
    if not is_open then return end

    rebuild_rows()
    ensure_visible()

    local w = mp.get_property_number("osd-width", 1280)
    local h = mp.get_property_number("osd-height", 720)
    local scale = responsive_scale(w, h)

    overlay.res_x = w
    overlay.res_y = h

    -- Large bottom-left workspace, bounded and scrollable for any row count.
    local edge = math.max(10, math.floor(24 * scale + 0.5))
    local panel_w = math.min(
        math.floor(1500 * scale + 0.5),
        math.floor(w * 0.97 + 0.5),
        w - edge * 2
    )
    local pad = math.max(10, math.floor(16 * scale + 0.5))
    local title_h = math.max(27, math.floor(38 * scale + 0.5))
    local row_h = math.max(23, math.floor(32 * scale + 0.5))
    local prompt_h = math.max(52, math.floor(70 * scale + 0.5))
    local font_size = math.max(17, math.floor(27 * scale + 0.5))
    local small_size = math.max(11, math.floor(16 * scale + 0.5))
    local category_size = math.max(9, math.floor(13 * scale + 0.5))
    local title_size = math.max(14, math.floor(20 * scale + 0.5))

    local x1 = edge
    local x2 = x1 + panel_w
    local y2 = h - edge
    local fixed_prompt_y = y2 - prompt_h - pad

    -- Fill available vertical space with rows, up to MAX_VISIBLE.
    local available_rows_h = math.max(
        row_h,
        fixed_prompt_y - edge - title_h - pad - 8
    )
    local fit_rows = math.max(1, math.floor(available_rows_h / row_h))
    local visible_limit = math.min(MAX_VISIBLE, fit_rows)
    ensure_visible(visible_limit)

    local visible = math.min(math.max(#rows, 1), visible_limit)
    local row_y = fixed_prompt_y - visible * row_h - 8
    local y1 = row_y - title_h - pad

    local key_x = math.floor(panel_w * 0.30)
    local desc_x = math.floor(panel_w * 0.40)

    local ass = {}
    local binding_active =
        mode == "bind" or mode == "unbind" or
        mode == "defaultbind" or mode == "capture"
    local frame_color = binding_active and C_ACTIVE or C_BORDER
    local frame_width = binding_active and 3 or 2

    ass[#ass + 1] = draw_rect(x1, y1, x2, y2, C_PANEL, 28)
    ass[#ass + 1] = draw_rect(x1, y1, x2, y1 + frame_width, frame_color, 0)
    ass[#ass + 1] = draw_rect(x1, y2 - frame_width, x2, y2, frame_color, 0)
    ass[#ass + 1] = draw_rect(x1, y1, x1 + frame_width, y2, frame_color, 0)
    ass[#ass + 1] = draw_rect(x2 - frame_width, y1, x2, y2, frame_color, 0)

    ass[#ass + 1] = string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b1\\bord0\\shad0\\1c%s}%s",
        x1 + pad, y1 + pad, title_size,
        binding_active and C_ACTIVE or C_COMMAND,
        ass_escape(title_for_mode())
    )

    ass[#ass + 1] = string.format(
        "{\\an9\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}%d result%s",
        x2 - pad, y1 + pad + 1, small_size, C_MUTED,
        #rows, #rows == 1 and "" or "s"
    )

    if mode == "capture" and capture_target then
        -- Capture replaces the results list, drawn where row 1 was.
        local y = row_y + 3
        ass[#ass + 1] = string.format(
            "{\\an7\\pos(%d,%d)\\fs%d\\b1\\bord0\\shad0\\1c%s}[ PRESS ANY KEY ]",
            x1 + pad, y, font_size, C_CAPTURE
        )
        if capture_key then
            ass[#ass + 1] = string.format(
                "{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}ENTER confirms: %s",
                x1 + pad, y + row_h, small_size, C_DESCRIPTION,
                ass_escape(display_key(capture_key))
            )
        end
    elseif #rows == 0 then
        ass[#ass + 1] = string.format(
            "{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}No matching commands",
            x1 + pad, row_y + 3, font_size, C_MUTED
        )
    else
        local last = math.min(#rows, scroll_top + visible_limit - 1)
        local previous_group = nil

        for i = scroll_top, last do
            local row = rows[i]
            local y = row_y + (i - scroll_top) * row_h
            local color = row_color(row)

            if i == selected then
                ass[#ass + 1] = draw_rect(
                    x1 + 9, y - 2, x2 - 9, y + row_h - 3,
                    C_SELECTED, 22
                )
                ass[#ass + 1] = draw_rect(
                    x1 + 9, y - 2, x1 + 13, y + row_h - 3,
                    binding_active and C_ACTIVE or color, 0
                )
            end

            -- Category shown compactly at the right edge, saving scroll slots.
            if row.group ~= previous_group then
                previous_group = row.group
            end

            ass[#ass + 1] = string.format(
                "{\\an7\\pos(%d,%d)\\clip(%d,%d,%d,%d)" ..
                "\\fs%d\\b1\\bord0\\shad0\\1c%s}%s",
                x1 + pad, y + 2,
                x1 + pad, y - 2, x1 + key_x - pad, y + row_h - 3,
                font_size, color, ass_escape(row.name)
            )

            ass[#ass + 1] = string.format(
                "{\\an9\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}%s",
                x1 + key_x - pad, y + 7,
                category_size, row.kind == "bulk" and C_SPECIAL or C_MUTED,
                ass_escape(row.group)
            )

            ass[#ass + 1] = string.format(
                "{\\an7\\pos(%d,%d)\\clip(%d,%d,%d,%d)" ..
                "\\fs%d\\bord0\\shad0\\1c%s}%s",
                x1 + key_x, y + 4,
                x1 + key_x, y - 2, x1 + desc_x - pad, y + row_h - 3,
                font_size - 4, C_KEYBIND, ass_escape(row_key(row))
            )

            ass[#ass + 1] = string.format(
                "{\\an7\\pos(%d,%d)\\clip(%d,%d,%d,%d)" ..
                "\\fs%d\\bord0\\shad0\\1c%s}%s",
                x1 + desc_x, y + 4,
                x1 + desc_x, y - 2, x2 - pad, y + row_h - 3,
                font_size - 5, C_DESCRIPTION, ass_escape(row.description)
            )
        end
    end

    ass[#ass + 1] = draw_rect(
        x1 + pad, fixed_prompt_y - 7, x2 - pad, fixed_prompt_y - 6,
        binding_active and C_ACTIVE or C_BORDER, binding_active and 18 or 45
    )

    local prompt_color = binding_active and C_ACTIVE or C_COMMAND
    ass[#ass + 1] = string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b1\\bord0\\shad0\\1c%s}›" ..
        "{\\b0\\1c%s}  %s",
        x1 + pad, fixed_prompt_y + 8, font_size + 1,
        prompt_color, C_WHITE,
        ass_escape(commandline_text()) ..
            (caret_visible and "{\\1c" .. C_CAPTURE .. "}█" or "")
    )

    local help
    if mode == "capture" then
        help = "press a key   ENTER confirm   ESC return to bind"
    elseif mode == "root" then
        help = "TAB autocomplete   ↑↓ select   type / SPACE / BS edit   ENTER run   ESC close"
    else
        help = "TAB autocomplete   ↑↓ select   type / SPACE / BS edit   ENTER apply   ESC back"
    end
    ass[#ass + 1] = string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}%s",
        x1 + pad, fixed_prompt_y + 8 + font_size + 8,
        small_size, C_MUTED, help
    )

    overlay.data = table.concat(ass, "\n")
    overlay:update()
end

-- UTF-8 EDITING

local function utf8_backspace(text)
    if text == "" then return "" end
    local i = #text
    while i > 1 do
        local b = text:byte(i)
        if not b or b < 128 or b >= 192 then break end
        i = i - 1
    end
    return text:sub(1, i - 1)
end

local function reset_selection()
    selected = 0
    scroll_top = 1
    soft_query = nil
end

local maybe_commit_bind_space

local function append_text(text)
    select_all_armed = false
    if mode == "capture" then return end

    local added = tostring(text or "")
    commit_soft_fill()
    query = query .. added
    selected = 0
    scroll_top = 1
    sync_mode_from_commandline()

    -- A trailing space completing "bind <target> " starts bind-capture here
    -- (covering both the ANY_UNICODE and dedicated SPACE paths).
    if added == " " and maybe_commit_bind_space() then
        return
    end
    render()
end

local function backspace()
    if select_all_armed and mode ~= "capture" then
        select_all_armed = false
        query = ""
        soft_query = nil
        capture_target = nil
        capture_key = nil
        mode = "root"
        selected = 0
        scroll_top = 1
        render()
        return
    end

    select_all_armed = false
    if mode == "capture" then
        capture_key = nil
        render()
        return
    end

    -- Backspace edits what is visible: a soft completion becomes a hard fill
    -- first, then loses one character.
    local visible = soft_query or query
    soft_query = nil
    query = utf8_backspace(visible)

    selected = 0
    scroll_top = 1
    sync_mode_from_commandline()
    render()
end

local function ctrl_backspace()
    if mode == "capture" then
        capture_key = nil
        render()
        return
    end

    -- Edit what is visible; a Tab soft fill is committed before deleting the token.
    local visible = soft_query or query
    soft_query = nil

    -- Drop trailing whitespace, then the preceding token: "bind x" -> "bind ".
    visible = visible:gsub("%s+$", "")
    visible = visible:gsub("%S+$", "")
    query = visible

    selected = 0
    scroll_top = 1
    sync_mode_from_commandline()
    render()
end

local function clear_commandline()
    if mode == "capture" then
        capture_key = nil
    end

    query = ""
    soft_query = nil
    capture_target = nil
    capture_key = nil
    mode = "root"
    selected = 0
    scroll_top = 1
    render()
end

-- NAVIGATION / EXECUTION

-- Input helpers are defined later, but close_console needs them.
local unregister_console_input
local register_mouse_capture
local unregister_mouse_capture

local function move_selection(delta, make_soft_fill)
    if mode == "capture" then return end
    rebuild_rows()
    if #rows == 0 then return end

    if selected < 1 then
        selected = delta > 0 and 1 or #rows
    else
        selected = selected + delta
        if selected < 1 then selected = #rows end
        if selected > #rows then selected = 1 end
    end

    -- Selection alone never changes the command line. Only Tab/Shift+Tab pass
    -- make_soft_fill=true and are therefore allowed to create a soft fill.
    if make_soft_fill then
        update_soft_fill()
    else
        soft_query = nil
    end

    ensure_visible()
    render()
end

local function enter_submenu(new_mode)
    query = new_mode .. " "
    mode = new_mode
    reset_selection()
    render()
end

-- Ask cooperating scripts to pause their hotkeys while the console is open
-- ("on") or resume them ("off"). Scripts without the handler ignore it.
local function broadcast_focus(state)
    mp.commandv("script-message", "helska-console-focus", state)
end

local function close_console()
    if not is_open then return end
    is_open = false
    mode = "root"
    query = ""
    soft_query = nil
    selected = 0
    scroll_top = 1
    capture_target = nil
    capture_key = nil
    if caret_timer then
        caret_timer:kill()
        caret_timer = nil
    end

    unregister_console_input()

    overlay.data = ""
    overlay:update()
    install_open_binding()
    broadcast_focus("off")
end

local function find_exact_row(name)
    local wanted = trim(name):lower()
    if wanted == "" then return nil end
    for _, candidate in ipairs(rows) do
        if candidate.name:lower() == wanted then return candidate end
    end
    return nil
end

local function begin_bind_capture(row)
    if not row or row.kind ~= "target" then return false end
    query = "bind " .. row.name
    soft_query = nil
    capture_target = row
    capture_key = nil
    mode = "capture"
    selected = 0
    scroll_top = 1
    register_mouse_capture()
    render()
    return true
end

local function execute_selected()
    if mode == "capture" then
        if capture_target and capture_key then
            if save_target_binding(capture_target, capture_key) then
                query = "bind "
                mode = "bind"
                capture_target = nil
                capture_key = nil
                unregister_mouse_capture()
                reset_selection()
                render()
            end
        end
        return
    end

    rebuild_rows()
    commit_soft_fill()
    rebuild_rows()
    local context, fragment = parse_commandline()
    local row = find_exact_row(fragment)

    -- ENTER runs only what is written on the line; the selector alone does nothing.
    if not row then return end

    if context == "root" then
        if row.kind == "script" then
            close_console()
            send(row.owner, "helska-console-run", row.name)
            return
        end

        if row.kind == "native" then
            if row.name == "bind" then
                query = "bind "
                reset_selection()
                render()
            elseif row.name == "unbind" then
                query = "unbind "
                reset_selection()
                render()
            elseif row.name == "defaultbind" then
                query = "defaultbind "
                reset_selection()
                render()
            elseif row.name == "console" then
                mp.osd_message("Use BIND to change the console opening key", 2)
            end
        end
        return
    end

    if context == "bind" then
        begin_bind_capture(row)
        return
    end

    if context == "unbind" then
        if row.kind == "bulk" then
            bulk_unbind()
        elseif row.kind == "target" then
            disable_target(row)
        end
        query = "unbind "
        reset_selection()
        render()
        return
    end

    if context == "defaultbind" then
        if row.kind == "bulk" then
            bulk_defaultbind()
        elseif row.kind == "target" then
            restore_target_default(row)
        end
        query = "defaultbind "
        reset_selection()
        render()
    end
end

-- INPUT

-- Keyboard uses mp.add_forced_key_binding rather than input sections: modern
-- mpv rejects custom section names, so a section-based console would get no
-- keys. Bindings exist only while the console is open.

local function accepted_event(event, repeatable)
    if not event or not event.event then return true end
    return event.event == "down"
        or event.event == "press"
        or (repeatable and event.event == "repeat")
end

local function capture_event_key(event, fallback)
    if mode ~= "capture" then return false end
    local key = event and event.key_name or fallback
    if not key or key == "" then return true end

    local upper = tostring(key):upper()
    if upper == "MOUSE_MOVE"
        or upper == "MOUSE-MOVE"
        or upper == "MOUSEMOVE"
        or upper == "MOUSE_ENTER"
        or upper == "MOUSE_LEAVE"
    then
        return true
    end

    capture_key = key
    render()
    return true
end

local function try_commit_bind()
    -- Jump straight into bind-capture when the visible line is a complete
    -- "bind <target>". Works whether the text was hard-typed or produced by a
    -- Tab preview, and is resilient to surrounding whitespace.
    local visible = commandline_text()
    query = visible
    soft_query = nil
    sync_mode_from_commandline()
    rebuild_rows()
    local context, fragment = parse_commandline()
    local row = context == "bind" and find_exact_row(fragment) or nil
    return row and begin_bind_capture(row) or false
end

-- Called from append_text when a space is typed. If the line becomes a complete
-- "bind <target> ", start bind-capture. Must assign to the forward declaration
-- above append_text (a `local function` here would shadow it and crash).
maybe_commit_bind_space = function()
    if mode ~= "bind" then return false end
    local text = commandline_text()
    if text:sub(-1) ~= " " then return false end
    return try_commit_bind()
end

local function make_handler(key, fn, repeatable, capture_as_key)
    return function(event)
        if not accepted_event(event, repeatable) then return end
        if capture_as_key and capture_event_key(event, key) then return end
        fn(event)
    end
end

-- Keep mpv itself closable while the modal console owns input: close the
-- console state first, then ask mpv to terminate directly.
local function quit_mpv()
    close_console()
    mp.commandv("quit")
end

local active_console_keys = {}

-- Register one console hotkey as a forced binding (highest priority, beats
-- input.conf and native defaults while the console is open).
local function add_console_key(key, id, fn, repeatable, capture_as_key)
    local name = "helska-console-" .. id
    mp.add_forced_key_binding(
        key,
        name,
        make_handler(key, fn, repeatable, capture_as_key),
        { complex = true }
    )
    active_console_keys[#active_console_keys + 1] = name
end

-- Remove every console hotkey added by register_console_input (called on close).
unregister_console_input = function()
    for _, name in ipairs(active_console_keys) do
        mp.remove_key_binding(name)
    end
    active_console_keys = {}
end

local mouse_key_names = {}
local MOUSE_KEYS = {
    "MBTN_LEFT", "MBTN_RIGHT", "MBTN_MID", "MBTN_BACK", "MBTN_FORWARD"
}

-- Mouse buttons are proposal sources only during bind-capture, so outside
-- capture clicks behave exactly like normal mpv.
register_mouse_capture = function()
    unregister_mouse_capture()
    for i, key in ipairs(MOUSE_KEYS) do
        add_console_key(key, "mouse-" .. i, function(event)
            capture_event_key(event, key)
        end, false, false)
        mouse_key_names[#mouse_key_names + 1] = "helska-console-mouse-" .. i
    end
end

unregister_mouse_capture = function()
    for _, name in ipairs(mouse_key_names) do
        mp.remove_key_binding(name)
    end
    mouse_key_names = {}
end

-- Install the console keyboard (only while the console is open).
local function register_console_input()
    -- Arbitrary Unicode/IME typing; being forced, it also swallows mpv's
    -- printable default shortcuts while the console is open.
    add_console_key("ANY_UNICODE", "text", function(event)
        if mode == "capture" then
            capture_event_key(event)
            return
        end
        if event and event.key_text and event.key_text ~= "" then
            append_text(event.key_text)
        end
    end, true, false)

    add_console_key("TAB", "tab",
        function() move_selection(1, true) end, true, true)
    add_console_key("Shift+TAB", "shift-tab",
        function() move_selection(-1, true) end, true, true)

    -- SPACE inserts a space; if it completes a "bind <target> " line,
    -- append_text starts bind-capture immediately.
    add_console_key("SPACE", "space", function()
        append_text(" ")
    end, false, false)

    add_console_key("UP", "up",
        function() move_selection(-1, false) end, true, true)
    add_console_key("DOWN", "down",
        function() move_selection(1, false) end, true, true)
    add_console_key("LEFT", "left", function() end, false, true)
    add_console_key("RIGHT", "right", function() end, false, true)
    add_console_key("HOME", "home", function() end, false, true)
    add_console_key("END", "end", function() end, false, true)
    add_console_key("PGUP", "pgup",
        function() move_selection(-MAX_VISIBLE, false) end, true, true)
    add_console_key("PGDWN", "pgdown",
        function() move_selection(MAX_VISIBLE, false) end, true, true)

    -- ENTER confirms capture instead of becoming a captured shortcut.
    add_console_key("ENTER", "enter", execute_selected, false, false)
    add_console_key("KP_ENTER", "kp-enter", execute_selected, false, false)

    -- ESC always has a reliable escape route.
    add_console_key("ESC", "escape", function()
        if mode == "capture" then
            query = capture_target and ("bind " .. capture_target.name) or "bind "
            mode = "bind"
            capture_target = nil
            capture_key = nil
            unregister_mouse_capture()
            reset_selection()
            render()
        elseif mode ~= "root" then
            query = ""
            mode = "root"
            reset_selection()
            render()
        else
            close_console()
        end
    end, false, false)

    add_console_key("Ctrl+a", "select-all", function()
        if mode ~= "capture" then
            select_all_armed = true
            render()
        end
    end, false, false)

    -- Backspace edits the line; Ctrl+Backspace deletes the previous token;
    -- Ctrl+A arms select-all for the next edit.
    add_console_key("Ctrl+BS", "word-backspace", ctrl_backspace, true, false)
    add_console_key("Ctrl+DEL", "word-delete", ctrl_backspace, true, false)
    add_console_key("BS", "backspace", backspace, true, false)
    add_console_key("DEL", "delete", backspace, true, false)

    -- Player-lifecycle escape hatches: close the console state, then quit.
    add_console_key("CLOSE_WIN", "quit-close-window", quit_mpv, false, false)
    add_console_key("Ctrl+q", "quit-ctrl-q", quit_mpv, false, false)
    add_console_key("Alt+F4", "quit-alt-f4", quit_mpv, false, false)

    -- Catch remaining keys so the keyboard stays fully modal; in bind-capture
    -- an unmapped key becomes the proposed shortcut.
    add_console_key("UNMAPPED", "unmapped", function(event)
        if mode == "capture" then capture_event_key(event) end
    end, false, false)
end

-- OPEN KEY / LIFECYCLE

local OPEN_BINDING_NAME = "helska-console-open"

local function current_open_key()
    -- The opener is deliberately never treated as disabled.
    local value = user_bindings.console
    if value and value ~= "" and value ~= "disabled" then return value end
    return DEFAULT_OPEN_KEY
end

local function stop_caret_timer()
    if caret_timer then
        caret_timer:kill()
        caret_timer = nil
    end
end

local function start_caret_timer()
    stop_caret_timer()
    caret_visible = true
    caret_timer = mp.add_periodic_timer(0.53, function()
        if not is_open then return end
        caret_visible = not caret_visible
        render()
    end)
end

local function open_console()
    if is_open then return end

    load_bindings()
    request_discovery()

    is_open = true
    mode = "root"
    query = ""
    soft_query = nil
    selected = 0
    scroll_top = 1
    capture_target = nil
    capture_key = nil

    -- Remove the opener while open so held TAB cannot recursively reopen it.
    mp.remove_key_binding(OPEN_BINDING_NAME)
    register_console_input()
    broadcast_focus("on")
    start_caret_timer()
    render()
end

install_open_binding = function()
    mp.remove_key_binding(OPEN_BINDING_NAME)
    mp.add_forced_key_binding(
        current_open_key(),
        OPEN_BINDING_NAME,
        open_console
    )
end

-- Compatible scripts may ask the console to reload its own binding.
mp.register_script_message("helska-console-reload-self", function()
    load_bindings()
    if not is_open then install_open_binding() end
end)

load_bindings()
install_open_binding()

mp.register_event("shutdown", function()
    is_open = false
    stop_caret_timer()
    overlay.data = ""
    overlay:update()
end)

-- Advertise at load too, so either script load order works.
request_discovery()
