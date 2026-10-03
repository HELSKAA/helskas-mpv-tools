--[[
    Extract Current Subtitle

    Ctrl+Shift+X = save the current subtitle track to a file beside the video.
    The Console also offers "preload-subs", which loads the track without
    saving it.

    FFmpeg: ffmpeg.exe on PATH or helska/ffmpeg/ffmpeg(.exe).
]]

local mp = require("mp")
local utils = require("mp.utils")

local OWNER = mp.get_script_name()
local COMMAND = "extract-subtitle"
local DEFAULT_KEY = "Ctrl+Shift+x"
local GROUP = "SUBTITLES"
local DESCRIPTION = "extract current subtitle track to external file"
local PRELOAD_COMMAND = "preload-subs"
local PRELOAD_DESCRIPTION = "extract current subtitle track without saving it as a new file and load it on a temporary track"

local script_dir = mp.get_script_directory() or "."
local config_path = utils.join_path(script_dir, "helska.conf")

-- TEMPORARY FILES  (self-cleaning scratch folder)
--
-- The "preload-subs" working file goes into scripts/helska/temporary_files/.
-- Only files inside that folder (never the README) are ever removed.
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
local bound_key = nil
local preload_bound_key = nil
local running = false
local temporary_files = {}

local function osd(text, seconds)
    mp.osd_message(text, seconds or 2.5)
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function get_config_value(key)
    local s = read_file(config_path)
    if not s then return nil end
    for line in s:gmatch("[^\r\n]+") do
        local k,v = line:match("^%s*([^#;][^=]-)%s*=%s*(.-)%s*$")
        if k and v and k:gsub("%s+$","") == key then
            return v
        end
    end
    return nil
end

local function reload_binding()
    -- Has a default key: a missing/empty helska.conf entry falls back to it.
    if bound_key then
        mp.remove_key_binding("helska-extract-subtitle")
        bound_key = nil
    end
    local key = get_config_value("bind." .. COMMAND)
    if not key or key == "" then key = DEFAULT_KEY end
    if key:lower() ~= "disabled" then
        bound_key = key
        mp.add_key_binding(key, "helska-extract-subtitle", function()
            mp.commandv("script-message-to", OWNER, "helska-extract-subtitle-run")
        end)
    end

    -- Preload command. This one ships UNBOUND (no default key), so it must only
    -- be registered when the shared config actually assigns it a key. Without
    -- this branch a console "bind preload-subs <key>" would be saved and the
    -- console would ask for a reload, but no key would ever be installed.
    if preload_bound_key then
        mp.remove_key_binding("helska-preload-subs")
        preload_bound_key = nil
    end
    local preload_key = get_config_value("bind." .. PRELOAD_COMMAND)
    if preload_key and preload_key ~= "" and preload_key:lower() ~= "disabled" then
        preload_bound_key = preload_key
        mp.add_key_binding(preload_key, "helska-preload-subs", function()
            mp.commandv("script-message-to", OWNER, "helska-preload-subs-run")
        end)
    end
end

local function advertise()
    mp.commandv("script-message", "helska-console-begin-owner", OWNER)
    mp.commandv("script-message", "helska-console-register",
        OWNER, GROUP, COMMAND, DEFAULT_KEY, DESCRIPTION, "30", "3")
    mp.commandv("script-message", "helska-console-register",
        OWNER, GROUP, PRELOAD_COMMAND, "", PRELOAD_DESCRIPTION, "30", "4")
    mp.commandv("script-message", "helska-console-end-owner", OWNER)
end

local function find_selected_sub()
    local sid = mp.get_property_number("sid")
    if not sid then return nil end
    local tracks = mp.get_property_native("track-list") or {}
    for _,t in ipairs(tracks) do
        if t.type == "sub" and t.id == sid then return t end
    end
    return nil
end

local ffmpeg_probe_cache = nil

local function find_ffmpeg(done)
    local exe = package.config:sub(1,1) == "\\" and "ffmpeg.exe" or "ffmpeg"
    local bundled = utils.join_path(utils.join_path(script_dir, "ffmpeg"), exe)
    if utils.file_info(bundled) then done(bundled); return end
    if ffmpeg_probe_cache ~= nil then done(ffmpeg_probe_cache or nil); return end
    mp.command_native_async({
        name="subprocess", playback_only=false, capture_stdout=true, capture_stderr=true,
        args={exe, "-version"}
    }, function(success,result)
        if success and result and result.status == 0 then
            ffmpeg_probe_cache = exe
            done(exe)
        else
            ffmpeg_probe_cache = false
            done(nil)
        end
    end)
end

local function temp_output(ext,sid)
    -- The preloaded subtitle is an external track, so mpv shows its file name
    -- in the track list; name it so it reads clearly there.
    local n=tonumber(sid)
    local suffix=n and (" (sub "..n..")") or ""
    return SCRATCH.path("Preloaded subs"..suffix.."."..ext)
end

local function remember_temp(path)
    temporary_files[#temporary_files+1] = path
end

local function cleanup_temporary_files()
    for _,path in ipairs(temporary_files) do SCRATCH.remove(path) end
    temporary_files = {}
end

local function sanitize(s)
    s = tostring(s or ""):gsub('[<>:"/\\|?*]', "_")
    s = s:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","")
    return s
end

local function choose_extension(track)
    local c = (track.codec or ""):lower()
    if c == "ass" or c == "ssa" then return "ass" end
    if c == "webvtt" or c == "vtt" then return "vtt" end
    if c == "subrip" or c == "srt" then return "srt" end
    if c:find("pgs",1,true) or c:find("dvd_subtitle",1,true)
       or c:find("dvb_subtitle",1,true) or c:find("xsub",1,true) then
        return nil, "image"
    end
    -- FFmpeg can normally convert other text subtitle codecs to SubRip.
    return "srt"
end

local function unique_output(dir, stem, ext)
    local candidate = utils.join_path(dir, stem .. "." .. ext)
    local n = 2
    while utils.file_info(candidate) do
        candidate = utils.join_path(dir, stem .. " (" .. n .. ")." .. ext)
        n = n + 1
    end
    return candidate
end

local function extract(preload)
    if running then
        osd("SUBTITLE EXTRACTION\nAlready running")
        return
    end

    local input = mp.get_property("path")
    if not input or input == "" then
        osd("SUBTITLE EXTRACTION\nNo media file")
        return
    end
    if input:match("^%a[%w+.-]*://") then
        osd("SUBTITLE EXTRACTION\nCurrent media is not a local file")
        return
    end

    local track = find_selected_sub()
    if not track then
        osd("SUBTITLE EXTRACTION\nNo primary subtitle track selected")
        return
    end

    if track.external then
        osd((preload and "PRELOAD SUBS" or "SUBTITLE EXTRACTION") ..
            "\nThis sub-track is already external")
        return
    end

    local ext,kind = choose_extension(track)
    if kind == "image" then
        osd("SUBTITLE EXTRACTION\nCurrent track is image-based, not text")
        return
    end

    local input_abs = input
    if not input_abs:match("^%a:[/\\]") and input_abs:sub(1,1) ~= "/" then
        input_abs = utils.join_path(mp.get_property("working-directory") or ".", input_abs)
    end

    local dir = utils.split_path(input_abs)
    local base = sanitize(mp.get_property("filename/no-ext") or "subtitle")

    -- FFmpeg's subtitle stream index is zero-based among subtitle streams,
    -- while the filename uses a friendly one-based subtitle-track number.
    local sub_index = -1
    local sub_number = nil
    local tracks = mp.get_property_native("track-list") or {}
    local count = 0
    for _,t in ipairs(tracks) do
        if t.type == "sub" then
            if t.id == track.id then
                sub_index = count
                sub_number = count + 1
                break
            end
            count = count + 1
        end
    end

    local stem = base .. "_track" .. tostring(sub_number or (sub_index + 1))
    local output = preload and temp_output(ext, track.id) or unique_output(dir, stem, ext)
    if sub_index < 0 then
        osd("SUBTITLE EXTRACTION\nCouldn't resolve subtitle stream")
        return
    end

    running = true
    osd((preload and "PRELOAD SUBS" or "SUBTITLE EXTRACTION") ..
        "\n" .. (preload and "Temporarily extracting current track…" or "Extracting current track…"))

    find_ffmpeg(function(ffmpeg)
        if not ffmpeg then
            running = false
            osd((preload and "PRELOAD SUBS" or "SUBTITLE EXTRACTION") ..
                "\nFFmpeg not found in helska/ffmpeg or PATH", 4)
            return
        end

        local args = {
            ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
            "-i", input_abs,
            "-map", "0:s:" .. sub_index,
            "-c:s", ext == "ass" and "ass" or (ext == "vtt" and "webvtt" or "srt"),
            output
        }

        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            capture_stdout = true,
            capture_stderr = true,
            args = args
        }, function(success, result, error)
            running = false
            if success and result and result.status == 0 and utils.file_info(output) then
                if preload then
                    cleanup_temporary_files()
                    remember_temp(output)
                end
                local out_base = output:match("[^/\\]+$") or output
                mp.commandv("sub-add", output, "select",
                    (out_base:gsub("%.[^%.]+$", "")))
                if preload then
                    osd("SUBTITLES PRELOADED EXTERNALLY\nTemporary file - not saved beside episode", 4)
                else
                    osd("SUBTITLE EXTRACTED + SELECTED\n" ..
                        (output:match("[^/\\]+$") or output), 4)
                end
            else
                if preload then SCRATCH.remove(output) end
                local detail = ""
                if result and result.stderr and result.stderr ~= "" then
                    detail = result.stderr:gsub("[\r\n]+"," "):sub(1,160)
                elseif error then
                    detail = tostring(error)
                end
                osd((preload and "PRELOAD SUBS FAILED" or "SUBTITLE EXTRACTION FAILED") ..
                    (detail ~= "" and ("\n" .. detail) or ""), 5)
            end
        end)
    end)
end

mp.register_script_message("helska-extract-subtitle-run", function() extract(false) end)
mp.register_script_message("helska-preload-subs-run", function() extract(true) end)

mp.register_script_message("helska-console-discover", advertise)
mp.register_script_message("helska-console-run", function(name)
    if name == COMMAND then
        extract(false)
    elseif name == PRELOAD_COMMAND then
        extract(true)
    end
end)
mp.register_script_message("helska-console-reload-bindings", reload_binding)
 
mp.register_event("shutdown", cleanup_temporary_files)

reload_binding()
advertise()

-- Pause our hotkey while the Console owns input.
mp.register_script_message("helska-console-focus", function(state)
    if state == "on" then
        mp.remove_key_binding("helska-extract-subtitle")
        mp.remove_key_binding("helska-preload-subs")
    elseif state == "off" then
        reload_binding()
    end
end)
