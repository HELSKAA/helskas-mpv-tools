--[[
    Helska Subtitle Font

    Ctrl+J = subtitle font picker. The choice applies immediately and is saved
    to helska.conf as subtitle_font=<family>.

    Font discovery: PowerShell (Windows), system_profiler (macOS), fc-list (Unix).
--]]

local mp = require "mp"
local utils = require "mp.utils"

-- CONFIGURATION
--
-- This script is standalone: it can create and maintain helska.conf itself.
-- Helska Console is optional and simply shares the same configuration file.

local function script_dir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    local dir = utils.split_path(source)
    return dir
end

local HELSKA_CONFIG_PATH = utils.join_path(script_dir(), "helska.conf")

local function read_helska_config()
    local values = {}
    local file = io.open(HELSKA_CONFIG_PATH, "r")
    if not file then return values end

    for line in file:lines() do
        local key, value =
            line:match("^%s*([^#;=%s][^=]-)%s*=%s*(.-)%s*$")
        if key and value then
            values[key] = value
        end
    end

    file:close()
    return values
end

local function write_helska_config_value(key, value)
    value = tostring(value or ""):gsub("[\r\n]", " ")
    local lines = {}
    local found = false
    local file = io.open(HELSKA_CONFIG_PATH, "r")

    if file then
        for line in file:lines() do
            local existing =
                line:match("^%s*([^#;=%s][^=]-)%s*=")

            if existing == key then
                if not found then
                    lines[#lines + 1] = key .. "=" .. value
                    found = true
                end
                -- Drop duplicate active assignments for this setting.
            else
                lines[#lines + 1] = line
            end
        end
        file:close()
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

    if not found then
        lines[#lines + 1] = key .. "=" .. value
    end

    local out = io.open(HELSKA_CONFIG_PATH, "w")
    if not out then
        mp.msg.error("Could not write helska.conf: " .. HELSKA_CONFIG_PATH)
        return false
    end

    out:write(table.concat(lines, "\n") .. "\n")
    out:close()
    return true
end

local function configured_binding()
    local value = read_helska_config()["bind.subtitle-font"]
    if value and value:lower() == "disabled" then
        return nil
    end
    return value or "Ctrl+j"
end

-- PLATFORM / FONT DISCOVERY

local is_windows = package.config:sub(1, 1) == "\\"
local is_macos = false

if not is_windows then
    local result = utils.subprocess({
        args = { "uname", "-s" },
        cancellable = false,
    })
    is_macos =
        result.status == 0
        and result.stdout
        and result.stdout:match("Darwin") ~= nil
end

local function add_font_name(set, list, name)
    name = tostring(name or "")
        :gsub("\r", "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")

    -- Some fontconfig families are comma-separated aliases. Each family is
    -- independently useful to libass, so keep each clean alias.
    for family in name:gmatch("[^,]+") do
        family = family:gsub("^%s+", ""):gsub("%s+$", "")
        local key = family:lower()
        if family ~= "" and not set[key] then
            set[key] = true
            list[#list + 1] = family
        end
    end
end

local function discover_windows_fonts(set, list)
    local ps = [[
Add-Type -AssemblyName System.Drawing
$fonts = New-Object System.Drawing.Text.InstalledFontCollection
$fonts.Families |
    ForEach-Object { $_.Name } |
    Sort-Object -Unique
]]
    local result = utils.subprocess({
        args = {
            "powershell",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            ps,
        },
        cancellable = false,
    })

    if result.status ~= 0 or not result.stdout then
        return false
    end

    for line in result.stdout:gmatch("[^\n]+") do
        add_font_name(set, list, line)
    end
    return #list > 0
end

local function discover_fontconfig_fonts(set, list)
    local result = utils.subprocess({
        args = { "fc-list", "-f", "%{family}\n" },
        cancellable = false,
    })

    if result.status ~= 0 or not result.stdout then
        return false
    end

    for line in result.stdout:gmatch("[^\n]+") do
        add_font_name(set, list, line)
    end
    return #list > 0
end

local function discover_macos_fonts(set, list)
    -- system_profiler is available on stock macOS. Its text format exposes
    -- actual family names and avoids depending on Homebrew/fontconfig.
    local result = utils.subprocess({
        args = { "system_profiler", "SPFontsDataType" },
        cancellable = false,
    })

    if result.status ~= 0 or not result.stdout then
        return false
    end

    for line in result.stdout:gmatch("[^\n]+") do
        local family = line:match("^%s*Family:%s*(.-)%s*$")
        if family then
            add_font_name(set, list, family)
        end
    end
    return #list > 0
end

local fonts = nil

local function discover_fonts()
    if fonts then return fonts end

    local set = {}
    local list = {}

    if is_windows then
        discover_windows_fonts(set, list)
    elseif is_macos then
        -- Prefer the native inventory; fontconfig is a useful fallback for
        -- custom mpv installations that provide it.
        if not discover_macos_fonts(set, list) then
            discover_fontconfig_fonts(set, list)
        end
    else
        discover_fontconfig_fonts(set, list)
    end

    -- Never let a discovery failure make the picker empty.
    add_font_name(set, list, mp.get_property("sub-font", ""))

    table.sort(list, function(a, b)
        return a:lower() < b:lower()
    end)

    fonts = list
    return fonts
end

-- MENU STATE

local overlay = mp.create_osd_overlay("ass-events")
local is_open = false
local query = ""
local committed_query = ""
local matches = {}
local selected = 0
local tab_preview = false
local tab_choices = nil
local tab_index = 0
local scroll_top = 1

-- Named input sections are deprecated in modern mpv (see install_menu_keys).
local active_menu_keys = {}

local MAX_VISIBLE = 8

-- VISUALS

local C_PANEL       = "&H201714&"
local C_BORDER      = "&H70543B&"
local C_COMMAND     = "&HFFDDAA&"
local C_SELECTED    = "&H493A2A&"
local C_KEY         = "&H56D8FF&"
local C_TEXT        = "&HD7D7D7&"
local C_MUTED       = "&H9A9A9A&"
local C_WHITE       = "&HFFFFFF&"

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
        color,
        alpha or 0,
        x1, y1,
        x2, y1,
        x2, y2,
        x1, y2
    )
end

local function responsive_scale(w, h)
    local scale = math.min(w / 1280, h / 720) * 0.70
    return math.max(0.42, math.min(scale, 1.15))
end

local function current_font()
    return mp.get_property("sub-font", "")
end

local function ensure_visible()
    if selected <= 0 then
        scroll_top = 1
        return
    end

    local visible = math.min(math.max(#matches, 1), MAX_VISIBLE)
    local max_top = math.max(1, #matches - visible + 1)

    -- Font browsing benefits from context in both directions. Once the
    -- selection reaches roughly the middle of the visible window, move the
    -- viewport with it so the highlighted font stays near the center.
    -- At the beginning/end, pin the viewport so every font remains reachable.
    local anchor = math.max(1, math.floor((visible + 1) / 2))
    local desired_top = selected - anchor + 1

    if desired_top < 1 then desired_top = 1 end
    if desired_top > max_top then desired_top = max_top end
    scroll_top = desired_top
end

local function render()
    if not is_open then return end

    local w = mp.get_property_number("osd-width", 1280)
    local h = mp.get_property_number("osd-height", 720)
    local scale = responsive_scale(w, h)

    overlay.res_x = w
    overlay.res_y = h

    local edge_margin = math.max(10, math.floor(24 * scale + 0.5))
    local panel_w = math.min(
        math.floor(760 * scale + 0.5),
        w - edge_margin * 2
    )
    local pad = math.max(10, math.floor(16 * scale + 0.5))
    local title_h = math.max(27, math.floor(38 * scale + 0.5))
    local row_h = math.max(23, math.floor(32 * scale + 0.5))
    local prompt_h = math.max(54, math.floor(74 * scale + 0.5))
    local font_size = math.max(17, math.floor(27 * scale + 0.5))
    local small_size = math.max(11, math.floor(16 * scale + 0.5))
    local title_size = math.max(14, math.floor(20 * scale + 0.5))

    local visible = math.min(math.max(#matches, 1), MAX_VISIBLE)
    local panel_h = pad + title_h + visible * row_h + prompt_h + pad

    -- The search field is the visual anchor. Its position stays fixed even
    -- when filtering changes the number of recommendation rows. The results
    -- area grows/shrinks upward instead of making the typing field jump.
    local x1 = math.floor((w - panel_w) / 2 + 0.5)
    local x2 = x1 + panel_w
    local fixed_prompt_y = math.floor(h * 0.58 + 0.5)
    local row_y = fixed_prompt_y - visible * row_h - 8
    local y1 = row_y - title_h - pad
    local y2 = fixed_prompt_y + prompt_h + pad

    local ass = {}
    ass[#ass + 1] = draw_rect(x1, y1, x2, y2, C_PANEL, 18)
    ass[#ass + 1] = draw_rect(x1, y1, x2, y1 + 2, C_BORDER, 0)
    ass[#ass + 1] = draw_rect(x1, y2 - 2, x2, y2, C_BORDER, 0)
    ass[#ass + 1] = draw_rect(x1, y1, x1 + 2, y2, C_BORDER, 0)
    ass[#ass + 1] = draw_rect(x2 - 2, y1, x2, y2, C_BORDER, 0)

    ass[#ass + 1] = string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b1\\bord0\\shad0\\1c%s}SUBTITLE FONT",
        x1 + pad, y1 + pad, title_size, C_COMMAND
    )

    ass[#ass + 1] = string.format(
        "{\\an9\\pos(%d,%d)\\fs%d\\b0\\bord0\\shad0\\1c%s}%d fonts",
        x2 - pad, y1 + pad + 1, small_size, C_MUTED, #(fonts or {})
    )

    if #matches == 0 then
        ass[#ass + 1] = string.format(
            "{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}No matching fonts",
            x1 + pad, row_y + 3, font_size, C_MUTED
        )
    else
        ensure_visible()
        local last = math.min(#matches, scroll_top + MAX_VISIBLE - 1)

        for i = scroll_top, last do
            local y = row_y + (i - scroll_top) * row_h
            local font = matches[i]

            if i == selected then
                ass[#ass + 1] = draw_rect(
                    x1 + 9, y - 2, x2 - 9, y + row_h - 3,
                    C_SELECTED, 22
                )
                ass[#ass + 1] = draw_rect(
                    x1 + 9, y - 2, x1 + 13, y + row_h - 3,
                    C_COMMAND, 0
                )
            end

            -- Preview the font-name glyphs in their own typeface, clipped to a
            -- fixed box so an unusual font can't resize the row or escape.
            local preview_right = x2 - pad - math.max(
                72, math.floor(112 * scale + 0.5)
            )
            local preview_top = y - 2
            local preview_bottom = y + row_h - 3

            ass[#ass + 1] = string.format(
                "{\\an7\\pos(%d,%d)\\clip(%d,%d,%d,%d)" ..
                "\\fn%s\\fs%d\\b0\\bord0\\shad0\\1c%s}%s",
                x1 + pad, y + 2,
                x1 + pad, preview_top, preview_right, preview_bottom,
                ass_escape(font), font_size, C_COMMAND, ass_escape(font)
            )

            if font:lower() == current_font():lower() then
                ass[#ass + 1] = string.format(
                    "{\\an9\\pos(%d,%d)\\fs%d\\b0\\bord0\\shad0\\1c%s}CURRENT",
                    x2 - pad, y + 4, small_size, C_KEY
                )
            end
        end
    end

    local prompt_y = fixed_prompt_y
    ass[#ass + 1] = draw_rect(
        x1 + pad, prompt_y - 7, x2 - pad, prompt_y - 6, C_BORDER, 45
    )

    ass[#ass + 1] = string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b1\\bord0\\shad0\\1c%s}›  %s",
        x1 + pad, prompt_y + 5, font_size, C_WHITE, ass_escape(query)
    )

    ass[#ass + 1] = string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b0\\bord0\\shad0\\1c%s}" ..
        "Type to search   TAB autofill   ↑↓ select   ENTER apply   Ctrl+V paste   ESC close",
        x1 + pad, y2 - math.floor(25 * scale + 0.5),
        small_size, C_MUTED
    )

    -- Each positioned fragment must be its own ASS event. Concatenating
    -- them directly makes later \pos tags share one event/baseline and can
    -- collapse the entire list into a single horizontal line.
    overlay.data = table.concat(ass, "\n")
    overlay:update()
end

-- SEARCH / SOFT AUTOFILL

local function score_font(font, needle)
    local f = font:lower()
    if needle == "" then return 3 end
    if f == needle then return 0 end
    if f:sub(1, #needle) == needle then return 1 end
    if f:find(needle, 1, true) then return 2 end
    return nil
end

local function update_matches()
    local filter = tab_preview and committed_query or query
    local needle = filter:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local ranked = {}

    for _, font in ipairs(discover_fonts()) do
        local score = score_font(font, needle)
        if score ~= nil then
            ranked[#ranked + 1] = { font = font, score = score }
        end
    end

    table.sort(ranked, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        return a.font:lower() < b.font:lower()
    end)

    matches = {}
    for _, item in ipairs(ranked) do
        matches[#matches + 1] = item.font
    end

    if #matches == 0 then
        selected = 0
        scroll_top = 1
        return
    end

    if not tab_preview then
        local clean = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
        local exact = nil
        for i, font in ipairs(matches) do
            if font:lower() == clean and clean ~= "" then
                exact = i
                break
            end
        end

        if exact then
            selected = exact
        elseif selected < 1 or selected > #matches then
            selected = 1
        end
    elseif selected < 1 or selected > #matches then
        selected = 1
    end

    ensure_visible()
end

local function commit_preview()
    if not tab_preview then return end
    committed_query = query
    tab_preview = false
    tab_choices = nil
    tab_index = 0
end

local function begin_preview()
    committed_query = query
    tab_preview = true
    tab_index = 0
    update_matches()

    tab_choices = {}
    for _, font in ipairs(matches) do
        tab_choices[#tab_choices + 1] = font
    end
end

local function cycle_tab(direction)
    if not tab_preview then
        begin_preview()
    end

    if not tab_choices or #tab_choices == 0 then
        render()
        return
    end

    tab_index = tab_index + direction
    if tab_index < 1 then tab_index = #tab_choices end
    if tab_index > #tab_choices then tab_index = 1 end

    local choice = tab_choices[tab_index]
    query = choice

    -- The recommendation pool remains frozen from the pre-TAB query, while
    -- the highlight is allowed to follow the soft-filled choice.
    update_matches()
    for i, font in ipairs(matches) do
        if font == choice then
            selected = i
            break
        end
    end

    ensure_visible()
    render()
end

local function move_selection(direction)
    if #matches == 0 then return end

    -- Arrow movement is visual selection only. If TAB froze a recommendation
    -- pool, keep that pool intact while the highlight moves through it.
    selected = selected + direction
    if selected < 1 then selected = #matches end
    if selected > #matches then selected = 1 end
    ensure_visible()
    render()
end

-- APPLY / OPEN / CLOSE

local function apply_font(font)
    if not font or font == "" then return false end

    mp.set_property("sub-font", font)

    -- Optional integration point. This is a broadcast, so the font switcher
    -- remains completely standalone: if no other script listens, nothing
    -- changes. helska_chinese listens and rebuilds its temporary derivative
    -- with the newly selected subtitle font.
    mp.commandv("script-message", "helska-subtitle-font-changed", font)

    if not write_helska_config_value("subtitle_font", font) then
        mp.osd_message("Font applied, but could not save the shared config", 3)
        return false
    end

    mp.osd_message("Subtitle font: " .. font, 2)
    return true
end

-- Input uses mp.add_forced_key_binding, not input sections: modern mpv rejects
-- custom section names, so section-based keys would fall through to the
-- console instead of cycling fonts.

local function accepted_event(event, repeatable)
    if not event or not event.event then return true end
    return event.event == "down"
        or event.event == "press"
        or (repeatable and event.event == "repeat")
end

-- Register one modal hotkey as a forced binding (added at open time so it wins
-- over the console's forced opener; removed on close). close_menu is
-- forward-declared so the error guard can call it.
local close_menu

local function add_menu_hotkey(key, id, fn, repeatable)
    if type(fn) ~= "function" then
        mp.msg.error("helska font picker: missing handler for key " .. tostring(key))
        return
    end
    local name = "helska-subtitle-font-" .. id
    mp.add_forced_key_binding(
        key,
        name,
        function(event)
            if not accepted_event(event, repeatable) then return end
            -- Never let a Lua error leave the modal forced bindings installed:
            -- that would swallow every key and look exactly like a freeze.
            local ok, err = pcall(fn, event)
            if not ok then
                mp.msg.error("helska font picker: " .. tostring(err))
                close_menu()
            end
        end,
        { complex = true }
    )
    active_menu_keys[#active_menu_keys + 1] = name
end

local function unregister_menu_keys()
    for _, name in ipairs(active_menu_keys) do
        mp.remove_key_binding(name)
    end
    active_menu_keys = {}
end

close_menu = function()
    if not is_open then return end
    is_open = false
    unregister_menu_keys()
    overlay.data = ""
    overlay:update()
end

-- ENTER / KP_ENTER handler: apply the highlighted font (falling back to an
-- exact query match) but KEEP the menu open, so the user can rapidly audition
-- several fonts in a row. The overlay stays up and is repainted to reflect the
-- newly applied font.
local function choose_selected()
    local font = matches[selected]
    if not font then
        local clean = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
        if clean ~= "" then
            for _, candidate in ipairs(matches) do
                if candidate:lower() == clean then
                    font = candidate
                    break
                end
            end
        end
    end
    if not font then return end

    apply_font(font)

    -- Keep the highlight on the font we just applied and repaint the list.
    for i, candidate in ipairs(matches) do
        if candidate == font then
            selected = i
            break
        end
    end
    ensure_visible()
    render()
end

-- Remove one UTF-8 codepoint from the end of a string (Backspace).
local function utf8_pop(text)
    text = tostring(text or "")
    if text == "" then return "" end
    local i = #text
    while i > 1 do
        local b = text:byte(i)
        if not b or b < 128 or b >= 192 then break end
        i = i - 1
    end
    return text:sub(1, i - 1)
end

-- Best-effort clipboard text read (used by Ctrl+V in the search field).
local function read_clipboard()
    local is_windows = package.config:sub(1, 1) == "\\"
    local args
    if is_windows then
        args = {
            "powershell", "-NoProfile", "-NonInteractive",
            "-Command", "Get-Clipboard -Raw",
        }
    else
        local uname = utils.subprocess({ args = { "uname", "-s" }, cancellable = false })
        if uname and uname.status == 0 and uname.stdout
            and uname.stdout:match("Darwin") then
            args = { "pbpaste" }
        else
            args = { "wl-paste", "--no-newline" }
        end
    end
    local result = utils.subprocess({ args = args, cancellable = false })
    if (not result or result.status ~= 0) and not is_windows then
        result = utils.subprocess({
            args = { "xclip", "-selection", "clipboard", "-o" },
            cancellable = false,
        })
    end
    if not result or result.status ~= 0 then return nil end
    return tostring(result.stdout or "")
end

-- Ctrl+V: append the clipboard text to the search query. Only the first line
-- is used, and surrounding whitespace is stripped, so a pasted multi-line blob
-- cannot corrupt the single-line search field.
local function paste_from_clipboard()
    if not is_open then return end
    local text = read_clipboard()
    if not text then
        mp.osd_message("Font picker: could not read the clipboard", 2)
        return
    end
    text = text:gsub("\r", "\n"):match("^[^\n]*") or ""
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return end
    if tab_preview then commit_preview() end
    query = query .. text
    committed_query = query
    selected = 0
    scroll_top = 1
    update_matches()
    render()
end

local function install_menu_keys()
    unregister_menu_keys()

    -- Typing: swallow all printable input with ANY_UNICODE. This also blocks
    -- mpv printable defaults (s, i, o, [ ], m, ...) while the menu is open
    -- because forced is the highest priority mpv accepts.
    add_menu_hotkey("ANY_UNICODE", "text", function(event)
        if not is_open or not event then return end
        if event.key_text and event.key_text ~= "" then
            if tab_preview then commit_preview() end
            query = query .. event.key_text
            committed_query = query
            selected = 0
            scroll_top = 1
            update_matches()
            render()
        end
    end)

    add_menu_hotkey("TAB", "tab", function() cycle_tab(1) end, true)
    add_menu_hotkey("Shift+TAB", "shift-tab", function() cycle_tab(-1) end, true)
    add_menu_hotkey("UP", "up", function() move_selection(-1) end, true)
    add_menu_hotkey("DOWN", "down", function() move_selection(1) end, true)
    add_menu_hotkey("ENTER", "enter", choose_selected)
    add_menu_hotkey("KP_ENTER", "kp-enter", choose_selected)
    -- Backspace: repeatable so a held key keeps deleting. Ctrl+Backspace wipes
    -- the whole query in one press.
    add_menu_hotkey("BS", "backspace", function()
        if tab_preview then commit_preview() end
        query = utf8_pop(query)
        committed_query = query
        selected = 0
        scroll_top = 1
        update_matches()
        render()
    end, true)

    add_menu_hotkey("Ctrl+BS", "clear", function()
        if tab_preview then commit_preview() end
        query = ""
        committed_query = ""
        selected = 0
        scroll_top = 1
        update_matches()
        render()
    end, true)

    -- Paste the clipboard into the search field (parity with the tone palette).
    add_menu_hotkey("Ctrl+v", "paste", paste_from_clipboard)
    add_menu_hotkey("Meta+v", "paste-mac", paste_from_clipboard)

    add_menu_hotkey("ESC", "escape", close_menu)

    -- Swallow mouse buttons so a click cannot leak to another script binding,
    -- but do NOT dismiss the menu: closing the picker on any click felt like a
    -- bug while browsing.
    for i, key in ipairs({
        "MBTN_LEFT", "MBTN_RIGHT", "MBTN_MID", "MBTN_BACK", "MBTN_FORWARD"
    }) do
        add_menu_hotkey(key, "mouse-" .. i, function() end)
    end
end

local function open_menu()
    if is_open then
        cycle_tab(1)
        return
    end

    discover_fonts()

    query = ""
    committed_query = ""
    selected = 0
    scroll_top = 1
    tab_preview = false
    tab_choices = nil
    tab_index = 0
    is_open = true

    update_matches()

    -- Start on the currently active font when it exists in the inventory.
    local active = current_font():lower()
    for i, font in ipairs(matches) do
        if font:lower() == active then
            selected = i
            break
        end
    end

    ensure_visible()
    install_menu_keys()
    render()
end

-- MAIN BINDING

local function install_main_binding()
    mp.remove_key_binding("helska-subtitle-font-open")

    local key = configured_binding()
    if key then
        mp.add_key_binding(
            key,
            "helska-subtitle-font-open",
            open_menu
        )
    end
end

-- Restore the saved font independently of Helska Console.
local saved_font = read_helska_config()["subtitle_font"]
if saved_font and saved_font ~= "" then
    mp.set_property("sub-font", saved_font)
end

install_main_binding()

-- Pause the open-menu key (and close the picker) while the Console owns input.
mp.register_script_message("helska-console-focus", function(state)
    if state == "on" then
        mp.remove_key_binding("helska-subtitle-font-open")
        if is_open then close_menu() end
    elseif state == "off" then
        install_main_binding()
    end
end)

-- HELSKA CONSOLE COMPATIBILITY

local HELSKA_CONSOLE_ACTIONS = {
    {
        group = "SUBTITLE FONT",
        name = "subtitle-font",
        default_key = "Ctrl+j",
        description = "open subtitle font menu",
        group_order = 40,
        action_order = 1,
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

mp.register_script_message("helska-console-discover", advertise_to_helska_console)

mp.register_script_message("helska-console-run", function(action_name)
    if action_name == "subtitle-font" then
        open_menu()
    end
end)

mp.register_script_message(
    "helska-console-reload-bindings",
    install_main_binding
)

advertise_to_helska_console()

mp.register_event("shutdown", function()
    if is_open then
        close_menu()
    end
end)
