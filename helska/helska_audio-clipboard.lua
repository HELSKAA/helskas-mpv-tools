--[[
    Helska Audio Clipboard
    ======================

    Ctrl+E        copy the current subtitle's audio to the clipboard (MP3)
    Ctrl+Shift+E  manual clip: 1st press = start, 2nd press = end
    Alt+E         audio-boost menu (gain applied to extracted clips only)

    While marking a manual clip: Left/Right = 0.1s, Shift+Left/Right = 0.5s,
    Ctrl+Left/Right = nearest subtitle start, Alt+Left/Right = nearest end,
    Esc = cancel.

    FFmpeg: helska/ffmpeg/ffmpeg(.exe), else whatever is on PATH.
    Clipboard: PowerShell (Windows) / osascript (macOS).
--]]

local mp = require("mp")
local utils = require("mp.utils")

-- PLATFORM + TEMP DIRECTORY

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

-- TEMPORARY FILES
--
-- The extracted MP3 goes into scripts/helska/temporary_files/ and is removed
-- automatically once the clipboard no longer points at it.
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

-- SETTINGS

local padding_before = 0.10
local padding_after  = 0.15

local fine_seek   = 0.10
local coarse_seek = 0.50

-- Used when no saved configuration exists.
local default_audio_boost_db = 0.0

-- Audio Boost adjustment range.
local min_audio_boost_db = -40.0
local max_audio_boost_db = 20.0

-- SCRIPT PATHS

local script_path =
    debug.getinfo(1, "S").source:sub(2)

local script_dir =
    utils.split_path(script_path)

local config_path =
    utils.join_path(
        script_dir,
        "helska.conf"
    )

local legacy_config_path =
    utils.join_path(
        script_dir,
        "helska_audio-clipboard.conf"
    )

-- STATE

local manual_start = nil
local manual_active = false
local manual_osd_timer = nil

local boost_menu_active = false
local boost_original_db = nil

local audio_boost_db =
    default_audio_boost_db

-- GENERAL HELPERS

local function round_to_half(value)
    return math.floor(value * 2 + 0.5) / 2
end

local function clamp(value, minimum, maximum)

    if value < minimum then
        return minimum
    end

    if value > maximum then
        return maximum
    end

    return value
end

-- AUDIO BOOST HELPERS

local function db_to_percent(db)

    local multiplier =
        10 ^ (db / 20)

    return (multiplier - 1) * 100
end

local function format_boost_db(db)

    if db > 0 then

        return string.format(
            "+%.1f dB",
            db
        )

    elseif db < 0 then

        return string.format(
            "%.1f dB",
            db
        )

    else

        return "0.0 dB"
    end
end

local function format_boost_percent(db)

    local percent =
        db_to_percent(db)

    if math.abs(percent) < 0.5 then

        return "0%"

    elseif percent > 0 then

        return string.format(
            "+%.0f%%",
            percent
        )

    else

        return string.format(
            "%.0f%%",
            percent
        )
    end
end

-- OPTIONAL SHARED HELSKA CONFIG

local function read_shared_config()
    local values = {}
    local file = io.open(config_path, "r")

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

local function shared_config_value(key)
    return read_shared_config()[key]
end

local function helska_bind(command_name, default_key)
    local value = shared_config_value("bind." .. command_name)

    if value and value:lower() == "disabled" then
        return nil
    end

    return value or default_key
end

local function read_legacy_boost()
    local file = io.open(legacy_config_path, "r")
    if not file then return nil end

    local result = nil

    for line in file:lines() do
        local value =
            line:match("^%s*audio_boost_db%s*=%s*([%+%-]?[%d%.]+)")

        if value then result = tonumber(value) end
    end

    file:close()
    return result
end

local function write_shared_value(key, value)
    value = tostring(value or ""):gsub("[\r\n]", " ")
    local lines = {}
    local found = false
    local file = io.open(config_path, "r")

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

    local output = io.open(config_path, "w")
    if not output then
        mp.msg.error("Could not write shared config file: " .. config_path)
        return false
    end

    output:write(table.concat(lines, "\n") .. "\n")
    output:close()
    return true
end

local function load_config()
    local number = tonumber(shared_config_value("audio_boost_db"))

    if number == nil then
        number = read_legacy_boost()
    end

    if number == nil then
        audio_boost_db = default_audio_boost_db
        return
    end

    audio_boost_db =
        clamp(number, min_audio_boost_db, max_audio_boost_db)
end

local function save_config()
    local ok =
        write_shared_value(
            "audio_boost_db",
            string.format("%.1f", audio_boost_db)
        )

    if not ok then
        mp.osd_message("Could not save Audio Clipboard Boost setting")
    end

    return ok
end

load_config()

-- FIND FFMPEG

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end

    file:close()
    return true
end

local function find_ffmpeg()
    local bundled_name

    if is_windows then
        bundled_name = "ffmpeg\\ffmpeg.exe"
    else
        bundled_name = "ffmpeg/ffmpeg"
    end

    local bundled_ffmpeg =
        utils.join_path(
            script_dir,
            bundled_name
        )

    if file_exists(bundled_ffmpeg) then
        return bundled_ffmpeg
    end

    if is_macos then
        -- GUI-launched mpv may not inherit PATH; check Homebrew paths first.
        local mac_candidates = {
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        }

        for _, candidate in ipairs(mac_candidates) do
            if file_exists(candidate) then
                return candidate
            end
        end
    end

    return "ffmpeg"
end

-- FILENAME HELPERS

local function sanitize_filename(name)

    name =
        name:gsub(
            "%.[^%.]+$",
            ""
        )

    name =
        name:gsub(
            '[<>:"/\\|%?%*]',
            "_"
        )

    name =
        name:gsub(
            "%s+",
            " "
        )

    name =
        name:gsub(
            "^%s+",
            ""
        )

    name =
        name:gsub(
            "%s+$",
            ""
        )

    if #name > 80 then

        name =
            name:sub(
                1,
                80
            )
    end

    if name == "" then
        name = "video"
    end

    return name
end

local function format_filename_time(seconds)

    local hours =
        math.floor(
            seconds / 3600
        )

    local minutes =
        math.floor(
            (seconds % 3600) / 60
        )

    local secs =
        seconds % 60

    if hours > 0 then

        return string.format(
            "%02dh%02dm%06.3fs",
            hours,
            minutes,
            secs
        )
    end

    return string.format(
        "%02dm%06.3fs",
        minutes,
        secs
    )
end

local function format_display_time(seconds)

    if not seconds then
        return "--:--.---"
    end

    local hours =
        math.floor(
            seconds / 3600
        )

    local minutes =
        math.floor(
            (seconds % 3600) / 60
        )

    local secs =
        seconds % 60

    if hours > 0 then

        return string.format(
            "%02d:%02d:%06.3f",
            hours,
            minutes,
            secs
        )
    end

    return string.format(
        "%02d:%06.3f",
        minutes,
        secs
    )
end

-- DETERMINISTIC SHORT HASH

local function make_hash(text)

    local hash = 5381

    for i = 1, #text do

        hash =
            (
                hash * 33 +
                text:byte(i)
            )
            % 4294967296
    end

    return string.format(
        "%08x",
        hash
    )
end

-- GET SOURCE FILE

local function get_source()

    local source =
        mp.get_property(
            "path"
        )

    if not source
       or source == "" then

        return nil
    end

    -- MAKE RELATIVE PATH ABSOLUTE

    local is_absolute =
        source:match("^%a:[/\\]") ~= nil
        or source:match("^[/\\][/\\]") ~= nil
        or source:match("^/") ~= nil

    if not is_absolute then

        local working_directory =
            mp.get_property(
                "working-directory"
            )

        source =
            utils.join_path(
                working_directory,
                source
            )
    end

    return source
end

-- GET SUBTITLE LINES

local function get_subtitle_lines()

    local lines =
        mp.get_property_native(
            "sub-lines"
        )

    if type(lines) ~= "table" then
        return nil
    end

    -- Subtitle timestamps are track positions; apply sub-delay when using
    -- them as positions in the media.

    local sub_delay =
        mp.get_property_number(
            "sub-delay",
            0
        ) or 0

    if sub_delay == 0 then
        return lines
    end

    local adjusted = {}

    for i, subtitle in ipairs(lines) do
        local item = {}

        for key, value in pairs(subtitle) do
            item[key] = value
        end

        if item.start then
            item.start = item.start + sub_delay
        end

        if item["end"] then
            item["end"] = item["end"] + sub_delay
        end

        adjusted[i] = item
    end

    return adjusted
end

-- COUNT SUBTITLES IN SELECTED RANGE

local function count_subtitles_in_range(
    start_time,
    end_time
)

    if not start_time
       or not end_time then

        return nil
    end

    local range_start =
        math.min(
            start_time,
            end_time
        )

    local range_end =
        math.max(
            start_time,
            end_time
        )

    local lines =
        get_subtitle_lines()

    if not lines then
        return nil
    end

    local count = 0

    for _, subtitle in ipairs(lines) do

        local sub_start =
            subtitle.start

        local sub_end =
            subtitle["end"]

        -- SUBTITLE WITH START + END

        if sub_start and sub_end then

            -- Count any subtitle overlapping the selected range.

            if sub_start <= range_end
               and sub_end >= range_start then

                count =
                    count + 1
            end

        -- SUBTITLE WITHOUT KNOWN END

        elseif sub_start then

            if sub_start >= range_start
               and sub_start <= range_end then

                count =
                    count + 1
            end
        end
    end

    return count
end

-- COPY FILE TO CLIPBOARD

local function copy_file_to_clipboard(path)
    if is_windows then
        local ps =
            string.format(
                [[Add-Type -AssemblyName System.Windows.Forms; ]] ..
                [[$files = New-Object System.Collections.Specialized.StringCollection; ]] ..
                [[$files.Add('%s'); ]] ..
                [[[System.Windows.Forms.Clipboard]::SetFileDropList($files)]],
                path:gsub(
                    "'",
                    "''"
                )
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
        -- Put a real file on the macOS pasteboard (like Finder). Pass the path
        -- as an argv value so spaces and punctuation are safe.
        return utils.subprocess({
            args = {
                "/usr/bin/osascript",
                "-e", "on run argv",
                "-e", "set theFile to POSIX file (item 1 of argv)",
                "-e", "set the clipboard to theFile",
                "-e", "end run",
                path
            },
            cancellable = false
        })
    end

    return {
        status = 1,
        stderr = "Unsupported operating system for file clipboard"
    }
end

-- SELF-CLEANING: remove the clip once the clipboard lets go of it
--
-- The MP3 is on the clipboard as a file reference, so it stays until the
-- clipboard stops pointing at it. A non-blocking timer polls and deletes it;
-- a file the clipboard still holds is always kept.
local pending_clip = {}          -- [normalized path] = true
local clip_busy = false
local clip_timer = nil

local function clipboard_query_args()
    if is_windows then
        return { "powershell", "-NoProfile", "-STA", "-Command",
            "try { Add-Type -AssemblyName System.Windows.Forms; " ..
            "$f=[System.Windows.Forms.Clipboard]::GetFileDropList(); " ..
            "$f | ForEach-Object { $_ } } catch { }" }
    end
    if is_macos then
        return { "/usr/bin/osascript", "-e", "try", "-e",
            "return POSIX path of (the clipboard as \xc2\xabclass furl\xc2\xbb)",
            "-e", "end try" }
    end
    return nil
end

local function pending_any()
    for _ in pairs(pending_clip) do return true end
    return false
end

local clip_misses = {}          -- [path] = consecutive polls where it was absent

local function collect_referenced(list, okq)
    if not okq then return end  -- probe failed: keep every file this round
    local onclip = {}
    for _, p in ipairs(list or {}) do onclip[SCRATCH.norm(p)] = true end
    for p in pairs(pending_clip) do
        if onclip[p] then
            clip_misses[p] = nil
        else
            -- Two consecutive absent reads required, so one failed read can't
            -- drop a file too soon.
            clip_misses[p] = (clip_misses[p] or 0) + 1
            if clip_misses[p] >= 2 then
                SCRATCH.remove(p)
                pending_clip[p] = nil
                clip_misses[p] = nil
            end
        end
    end
end

local function clip_poll()
    if clip_busy then return end
    if not pending_any() then
        if clip_timer then clip_timer:kill(); clip_timer = nil end
        return
    end
    local args = clipboard_query_args()
    if not args then
        -- No file-clipboard API on this platform: nothing to wait for.
        for p in pairs(pending_clip) do SCRATCH.remove(p); pending_clip[p] = nil end
        return
    end
    clip_busy = true
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        capture_stdout = true, capture_stderr = true, args = args,
    }, function(ok, res)
        clip_busy = false
        local out = (ok and res and res.stdout) or ""
        local list = {}
        for line in out:gmatch("[^\r\n]+") do list[#list + 1] = line end
        collect_referenced(list, (ok == true) and (res ~= nil))
    end)
end

local function watch_clip_file(path)
    if not SCRATCH.is_ours(path) then return end
    pending_clip[SCRATCH.norm(path)] = true
    if not clip_timer then
        clip_timer = mp.add_periodic_timer(2.0, clip_poll)
    end
end

local function flush_clip_files()
    -- Last chance at exit; files still on the clipboard are kept for a later
    -- paste and swept on the next launch.
    if not pending_any() then return end
    local args = clipboard_query_args()
    if not args then
        for p in pairs(pending_clip) do SCRATCH.remove(p) end
        pending_clip = {}
        return
    end
    local ok, r = pcall(utils.subprocess, { args = args, cancellable = false })
    if not (ok and r and r.status == 0 and r.stdout) then
        pending_clip = {}
        return   -- cannot verify now: the next launch's sweep will finish this
    end
    local onclip = {}
    for line in r.stdout:gmatch("[^\r\n]+") do onclip[SCRATCH.norm(line)] = true end
    for p in pairs(pending_clip) do
        if not onclip[p] then SCRATCH.remove(p) end
    end
    pending_clip = {}
end

mp.register_event("shutdown", flush_clip_files)

-- EXTRACT AUDIO RANGE

local function active_audio_map_arg()
    -- Return the ffmpeg "-map" for the user's active audio track (otherwise
    -- ffmpeg picks its own default). Prefer ff-index, else "0:a:N".
    local tracks =
        mp.get_property_native(
            "track-list"
        )

    if type(tracks) ~= "table" then
        return nil
    end

    local selected_ff_index = nil
    local selected_audio_ordinal = -1
    local audio_ordinal = 0

    for _, track in ipairs(tracks) do

        if track.type == "audio" then

            if track.selected then
                selected_ff_index =
                    track["ff-index"]
                selected_audio_ordinal =
                    audio_ordinal
            end

            audio_ordinal =
                audio_ordinal + 1
        end
    end

    if selected_ff_index ~= nil then
        return string.format(
            "0:%d",
            selected_ff_index
        )
    end

    if selected_audio_ordinal >= 0 then
        return string.format(
            "0:a:%d",
            selected_audio_ordinal
        )
    end

    -- No active audio track: leave ffmpeg's own selection.
    return nil
end

local function extract_range(
    start_time,
    end_time
)

    if not start_time
       or not end_time then

        return
    end

    if end_time <= start_time then

        mp.osd_message(
            "Invalid audio selection"
        )

        return
    end

    local source =
        get_source()

    if not source then

        mp.osd_message(
            "Could not find media file"
        )

        return
    end

    local duration =
        end_time - start_time

    -- OUTPUT FILENAME

    local video_name =
        mp.get_property(
            "filename"
        )
        or "video"

    video_name =
        sanitize_filename(
            video_name
        )

    local identity =
        string.format(
            "%s|%.3f|%.3f",
            source,
            start_time,
            end_time
        )

    local suffix =
        make_hash(
            identity
        )

    local audio_filename =
        string.format(
            "%s_%s-%s_%s.mp3",
            video_name,
            format_filename_time(
                start_time
            ),
            format_filename_time(
                end_time
            ),
            suffix
        )

    local output =
        SCRATCH.path(
            audio_filename
        )

    -- BUILD FFMPEG COMMAND

    local ffmpeg =
        find_ffmpeg()

    mp.osd_message(
        "Extracting audio..."
    )

    local args = {
        ffmpeg,
        "-y",

        "-ss",
        string.format(
            "%.3f",
            start_time
        ),

        "-i",
        source,

        "-t",
        string.format(
            "%.3f",
            duration
        ),

        "-vn"
    }

    -- Extract from the active audio track (see active_audio_map_arg), not
    -- ffmpeg's default first stream.
    local map_arg =
        active_audio_map_arg()

    if map_arg then
        table.insert(
            args,
            "-map"
        )
        table.insert(
            args,
            map_arg
        )
    end

    -- AUDIO BOOST + CLIPPING PROTECTION

    if math.abs(
        audio_boost_db
    ) > 0.001 then

        table.insert(
            args,
            "-af"
        )

        table.insert(
            args,
            string.format(
                "volume=%.1fdB,alimiter=limit=0.95",
                audio_boost_db
            )
        )
    end

    -- MP3 ENCODING

    table.insert(
        args,
        "-c:a"
    )

    table.insert(
        args,
        "libmp3lame"
    )

    table.insert(
        args,
        "-q:a"
    )

    table.insert(
        args,
        "3"
    )

    table.insert(
        args,
        output
    )

    -- RUN FFMPEG

    local result =
        utils.subprocess({
            args = args,
            cancellable = false
        })

    if not result then

        mp.msg.error(
            "FFmpeg could not be started"
        )

        mp.osd_message(
            "Audio extraction FAILED\nCould not start FFmpeg",
            6
        )

        return
    end

    if result.status ~= 0 then

        mp.msg.error(
            "FFmpeg failed: " ..
            (
                result.stderr
                or "unknown error"
            )
        )

        local reason =
            result.error_string
            or result.stderr
            or "unknown FFmpeg error"

        reason = tostring(reason):gsub("[\r\n]+", " ")
        if #reason > 180 then
            reason = reason:sub(1, 180) .. "..."
        end

        mp.osd_message(
            "Audio extraction FAILED\n" .. reason,
            6
        )

        return
    end

    -- COPY MP3 TO CLIPBOARD

    local clipboard_result =
        copy_file_to_clipboard(
            output
        )

    if clipboard_result
       and clipboard_result.status == 0 then

        -- Keep the MP3 until the clipboard stops pointing at it, then delete
        -- it automatically (see the self-cleaning section above).
        watch_clip_file(output)

        local boost_text = ""

        if math.abs(
            audio_boost_db
        ) > 0.001 then

            boost_text =
                " | " ..
                format_boost_db(
                    audio_boost_db
                )
        end

        mp.osd_message(
            string.format(
                "Audio copied to clipboard! (%.2f sec%s)",
                duration,
                boost_text
            ),
            2
        )

    else

        mp.msg.error(
            "Clipboard failed: " ..
            (
                (clipboard_result and clipboard_result.stderr)
                or "unknown error"
            )
        )

        mp.osd_message(
            "Could not copy audio to clipboard"
        )
    end
end

-- QUICK SUBTITLE CLIP

local function extract_subtitle_audio()

    local sub_start =
        mp.get_property_number(
            "sub-start"
        )

    local sub_end =
        mp.get_property_number(
            "sub-end"
        )

    if not sub_start
       or not sub_end then

        mp.osd_message(
            "No subtitle on screen"
        )

        return
    end

    -- sub-start / sub-end are the event's original timestamps; if sub-delay
    -- is set, extract from where the subtitle is actually shown.

    local sub_delay =
        mp.get_property_number(
            "sub-delay",
            0
        ) or 0

    local start_time =
        math.max(
            0,
            sub_start + sub_delay - padding_before
        )

    local end_time =
        sub_end + sub_delay + padding_after

    extract_range(
        start_time,
        end_time
    )
end

-- MANUAL CLIP OSD

local function update_manual_osd()

    if not manual_active
       or not manual_start then

        return
    end

    local current =
        mp.get_property_number(
            "time-pos"
        )

    if not current then
        return
    end

    -- DURATION

    local difference =
        current - manual_start

    local difference_text

    if difference >= 0 then

        difference_text =
            string.format(
                "+%.2fs",
                difference
            )

    else

        difference_text =
            string.format(
                "-%.2fs",
                math.abs(
                    difference
                )
            )
    end

    -- SUBTITLE COUNT

    local subtitle_count =
        count_subtitles_in_range(
            manual_start,
            current
        )

    local subtitle_count_text

    if subtitle_count == nil then

        subtitle_count_text =
            "Unavailable"

    else

        subtitle_count_text =
            tostring(
                subtitle_count
            )
    end

    -- OPTIONAL AUDIO BOOST LINE

    local boost_status = ""

    if math.abs(
        audio_boost_db
    ) > 0.001 then

        boost_status =
            "{\\fs20\\1c&HAAAAAA&}" ..
            "AUDIO BOOST " ..

            "{\\1c&HFFFFFF&}" ..
            format_boost_db(
                audio_boost_db
            ) ..

            " (" ..
            format_boost_percent(
                audio_boost_db
            ) ..
            ")\\N"
    end

    -- OSD

    local text =
        string.format(

            -- TITLE

            "{\\an7\\pos(20,20)" ..
            "\\fs30\\bord2\\shad0" ..
            "\\1c&HFFFF00&}" ..

            "AUDIO CLIP\\N" ..

            "\\N" ..

            -- START

            "{\\fs26\\1c&H00FFFF&}" ..
            "START       " ..

            "{\\1c&HFFFFFF&}" ..
            "%s\\N" ..

            -- END

            "{\\1c&H00FFFF&}" ..
            "END         " ..

            -- Italic means END is still provisional.
            "{\\1c&HFFFFFF&\\i1}" ..
            "%s" ..

            "{\\i0}" ..

            "{\\1c&H00FFFF&}" ..
            "  (%s)\\N" ..

            -- SUBTITLE COUNT

            "{\\fs21\\1c&HAAAAAA&}" ..
            "SUBTITLES   " ..

            "{\\1c&HFFFFFF&}" ..
            "%s\\N" ..

            -- OPTIONAL BOOST

            "%s" ..

            "\\N" ..

            -- EXPLANATION

            "{\\fs24\\1c&H00FFFF&}" ..
            "Press " ..

            "{\\1c&HFFFFFF&}" ..
            "Ctrl+Shift+E " ..

            "{\\1c&H00FFFF&}" ..
            "again to set END and copy audio to clipboard.\\N" ..

            "\\N" ..

            -- KEYBINDS

            "{\\fs22\\1c&HFFFFFF&}" ..
            "Ctrl+Shift+E" ..

            "{\\1c&HAAAAAA&}" ..
            "   Set END & Copy to Clipboard\\N" ..


            "{\\1c&HFFFFFF&}" ..
            "Left / Right" ..

            "{\\1c&HAAAAAA&}" ..
            "   Adjust by 0.1 sec\\N" ..


            "{\\1c&HFFFFFF&}" ..
            "Shift+Left / Right" ..

            "{\\1c&HAAAAAA&}" ..
            "   Adjust by 0.5 sec\\N" ..


            "{\\1c&HFFFFFF&}" ..
            "Ctrl+Left / Right" ..

            "{\\1c&HAAAAAA&}" ..
            "   Jump to subtitle start\\N" ..


            "{\\1c&HFFFFFF&}" ..
            "Alt+Left / Right" ..

            "{\\1c&HAAAAAA&}" ..
            "   Jump to subtitle end\\N" ..


            "{\\1c&HFFFFFF&}" ..
            "Esc" ..

            "{\\1c&HAAAAAA&}" ..
            "   Cancel",

            format_display_time(
                manual_start
            ),

            format_display_time(
                current
            ),

            difference_text,

            subtitle_count_text,

            boost_status
        )

    local w =
        mp.get_property_number(
            "osd-width",
            1280
        )

    local h =
        mp.get_property_number(
            "osd-height",
            720
        )

    mp.set_osd_ass(
        w,
        h,
        text
    )
end

-- MANUAL FINE / COARSE SEEK

local function manual_seek(amount)

    if not manual_active then
        return
    end

    mp.commandv(
        "no-osd",
        "seek",
        tostring(
            amount
        ),
        "relative",
        "exact"
    )

    update_manual_osd()
end

-- JUMP TO SUBTITLE START

local function seek_subtitle_start(direction)

    if not manual_active then
        return
    end

    mp.commandv(
        "no-osd",
        "sub-seek",
        tostring(
            direction
        )
    )

    update_manual_osd()
end

-- JUMP TO NEAREST ACTUAL SUBTITLE END

local function seek_subtitle_end(direction)

    if not manual_active then
        return
    end

    local current =
        mp.get_property_number(
            "time-pos"
        )

    if not current then
        return
    end

    local lines =
        get_subtitle_lines()

    if not lines then

        mp.osd_message(
            "Subtitle end timestamps unavailable"
        )

        return
    end

    -- SEEK TOLERANCE
    --
    -- mpv may land a few ms off a timestamp, so treat anything within 50 ms as
    -- the current boundary, making repeated Alt+Left/Right always move to a
    -- different subtitle end.

    local tolerance = 0.050

    local closest = nil

    -- SEARCH AVAILABLE SUBTITLE END TIMESTAMPS

    for _, subtitle in ipairs(lines) do

        local sub_end =
            subtitle["end"]

        if sub_end then

            -- ALT + RIGHT
            --
            -- Closest subtitle end definitely ahead of the current boundary.

            if direction > 0 then

                if sub_end > current + tolerance then

                    if not closest
                       or sub_end < closest then

                        closest =
                            sub_end
                    end
                end

            -- ALT + LEFT
            --
            -- Closest subtitle end definitely behind the current boundary.

            else

                if sub_end < current - tolerance then

                    if not closest
                       or sub_end > closest then

                        closest =
                            sub_end
                    end
                end
            end
        end
    end

    -- NO END FOUND IN REQUESTED DIRECTION

    if not closest then

        if direction > 0 then

            mp.osd_message(
                "No later subtitle end found"
            )

        else

            mp.osd_message(
                "No earlier subtitle end found"
            )
        end

        return
    end

    -- SEEK DIRECTLY TO THAT SUBTITLE END

    mp.commandv(
        "no-osd",
        "seek",
        string.format(
            "%.6f",
            closest
        ),
        "absolute",
        "exact"
    )

    update_manual_osd()
end
-- REMOVE MANUAL CLIP BINDINGS

local function remove_manual_bindings()

    mp.remove_key_binding(
        "helska-audio-fine-left"
    )

    mp.remove_key_binding(
        "helska-audio-fine-right"
    )

    mp.remove_key_binding(
        "helska-audio-coarse-left"
    )

    mp.remove_key_binding(
        "helska-audio-coarse-right"
    )

    mp.remove_key_binding(
        "helska-audio-sub-start-left"
    )

    mp.remove_key_binding(
        "helska-audio-sub-start-right"
    )

    mp.remove_key_binding(
        "helska-audio-sub-end-left"
    )

    mp.remove_key_binding(
        "helska-audio-sub-end-right"
    )

    mp.remove_key_binding(
        "helska-audio-cancel"
    )
end

-- CANCEL MANUAL CLIP

local function cancel_manual_mode()

    if not manual_active then
        return
    end

    manual_active = false
    manual_start = nil

    if manual_osd_timer then

        manual_osd_timer:kill()
        manual_osd_timer = nil
    end

    remove_manual_bindings()

    mp.set_osd_ass(
        0,
        0,
        ""
    )

    mp.osd_message(
        "Audio clip cancelled"
    )
end

-- ADD MANUAL CLIP BINDINGS

local function add_manual_bindings()

    -- 0.1 SECOND ADJUSTMENT

    mp.add_forced_key_binding(
        "LEFT",
        "helska-audio-fine-left",

        function()

            manual_seek(
                -fine_seek
            )
        end
    )

    mp.add_forced_key_binding(
        "RIGHT",
        "helska-audio-fine-right",

        function()

            manual_seek(
                fine_seek
            )
        end
    )

    -- 0.5 SECOND ADJUSTMENT

    mp.add_forced_key_binding(
        "Shift+LEFT",
        "helska-audio-coarse-left",

        function()

            manual_seek(
                -coarse_seek
            )
        end
    )

    mp.add_forced_key_binding(
        "Shift+RIGHT",
        "helska-audio-coarse-right",

        function()

            manual_seek(
                coarse_seek
            )
        end
    )

    -- SUBTITLE STARTS

    mp.add_forced_key_binding(
        "Ctrl+LEFT",
        "helska-audio-sub-start-left",

        function()

            seek_subtitle_start(
                -1
            )
        end
    )

    mp.add_forced_key_binding(
        "Ctrl+RIGHT",
        "helska-audio-sub-start-right",

        function()

            seek_subtitle_start(
                1
            )
        end
    )

    -- SUBTITLE ENDS

    mp.add_forced_key_binding(
        "Alt+LEFT",
        "helska-audio-sub-end-left",

        function()

            seek_subtitle_end(
                -1
            )
        end
    )

    mp.add_forced_key_binding(
        "Alt+RIGHT",
        "helska-audio-sub-end-right",

        function()

            seek_subtitle_end(
                1
            )
        end
    )

    -- CANCEL

    mp.add_forced_key_binding(
        "ESC",
        "helska-audio-cancel",
        cancel_manual_mode
    )
end

-- MANUAL CLIP MODE

local function toggle_manual_clip()

    -- DO NOT OPEN OVER AUDIO BOOST MENU

    if boost_menu_active then
        return
    end

    -- FIRST PRESS = SET START

    if not manual_active then

        local current =
            mp.get_property_number(
                "time-pos"
            )

        if not current then

            mp.osd_message(
                "Could not get playback position"
            )

            return
        end

        manual_start =
            current

        manual_active =
            true

        add_manual_bindings()

        manual_osd_timer =
            mp.add_periodic_timer(
                0.05,
                update_manual_osd
            )

        update_manual_osd()

        return
    end

    -- SECOND PRESS = SET END

    local end_time =
        mp.get_property_number(
            "time-pos"
        )

    if not end_time then
        return
    end

    local start_time =
        manual_start

    -- CLOSE MANUAL CLIP UI

    manual_active =
        false

    manual_start =
        nil

    if manual_osd_timer then

        manual_osd_timer:kill()
        manual_osd_timer = nil
    end

    remove_manual_bindings()

    mp.set_osd_ass(
        0,
        0,
        ""
    )

    -- SUPPORT SELECTING BACKWARDS

    if end_time < start_time then

        start_time,
        end_time =
            end_time,
            start_time
    end

    -- EXTRACT + COPY TO CLIPBOARD

    extract_range(
        start_time,
        end_time
    )
end

-- AUDIO BOOST OSD

local function update_boost_osd()

    if not boost_menu_active then
        return
    end

    local percent =
        format_boost_percent(
            audio_boost_db
        )

    local volume_multiplier =
        10 ^ (
            audio_boost_db / 20
        )

    local equivalent_volume =
        volume_multiplier * 100

    local text =
        string.format(

            -- TITLE

            "{\\an7\\pos(20,20)" ..
            "\\fs30\\bord2\\shad0" ..
            "\\1c&HFFFF00&}" ..

            "AUDIO BOOST\\N" ..

            "\\N" ..

            -- BOOST VALUE

            "{\\fs28\\1c&H00FFFF&}" ..
            "BOOST   " ..

            "{\\1c&HFFFFFF&}" ..
            "%s " ..

            "{\\1c&H00FFFF&}" ..
            "(%s)\\N" ..

            -- INTUITIVE VOLUME EQUIVALENT

            "{\\fs21\\1c&HAAAAAA&}" ..
            "About %.0f%% of the original audio level\\N" ..

            "\\N" ..

            -- EXPLANATION

            "{\\fs23\\1c&H00FFFF&}" ..
            "This boost is applied to extracted audio only.\\N" ..

            "\\N" ..

            -- CONTROLS

            "{\\fs22\\1c&HFFFFFF&}" ..
            "Left / Right" ..

            "{\\1c&HAAAAAA&}" ..
            "   Adjust by 1 dB\\N" ..


            "{\\1c&HFFFFFF&}" ..
            "Shift+Left / Right" ..

            "{\\1c&HAAAAAA&}" ..
            "   Adjust by 0.5 dB\\N" ..


            "{\\1c&HFFFFFF&}" ..
            "Alt+E" ..

            "{\\1c&HAAAAAA&}" ..
            "   Save & Close\\N" ..


            "{\\1c&HFFFFFF&}" ..
            "Esc" ..

            "{\\1c&HAAAAAA&}" ..
            "   Cancel",

            format_boost_db(
                audio_boost_db
            ),

            percent,

            equivalent_volume
        )

    local w =
        mp.get_property_number(
            "osd-width",
            1280
        )

    local h =
        mp.get_property_number(
            "osd-height",
            720
        )

    mp.set_osd_ass(
        w,
        h,
        text
    )
end

-- ADJUST AUDIO BOOST

local function adjust_audio_boost(amount)

    if not boost_menu_active then
        return
    end

    audio_boost_db =
        audio_boost_db + amount

    audio_boost_db =
        round_to_half(
            audio_boost_db
        )

    audio_boost_db =
        clamp(
            audio_boost_db,
            min_audio_boost_db,
            max_audio_boost_db
        )

    update_boost_osd()
end

-- REMOVE AUDIO BOOST BINDINGS

local function remove_boost_bindings()

    mp.remove_key_binding(
        "helska-boost-left"
    )

    mp.remove_key_binding(
        "helska-boost-right"
    )

    mp.remove_key_binding(
        "helska-boost-fine-left"
    )

    mp.remove_key_binding(
        "helska-boost-fine-right"
    )

    mp.remove_key_binding(
        "helska-boost-cancel"
    )
end

-- CANCEL AUDIO BOOST MENU

local function cancel_boost_menu()

    if not boost_menu_active then
        return
    end

    audio_boost_db =
        boost_original_db

    boost_original_db =
        nil

    boost_menu_active =
        false

    remove_boost_bindings()

    mp.set_osd_ass(
        0,
        0,
        ""
    )

    mp.osd_message(
        "Audio Boost change cancelled"
    )
end

-- ADD AUDIO BOOST BINDINGS

local function add_boost_bindings()

    -- 1 dB

    mp.add_forced_key_binding(
        "LEFT",
        "helska-boost-left",

        function()

            adjust_audio_boost(
                -1.0
            )
        end
    )

    mp.add_forced_key_binding(
        "RIGHT",
        "helska-boost-right",

        function()

            adjust_audio_boost(
                1.0
            )
        end
    )

    -- 0.5 dB

    mp.add_forced_key_binding(
        "Shift+LEFT",
        "helska-boost-fine-left",

        function()

            adjust_audio_boost(
                -0.5
            )
        end
    )

    mp.add_forced_key_binding(
        "Shift+RIGHT",
        "helska-boost-fine-right",

        function()

            adjust_audio_boost(
                0.5
            )
        end
    )

    -- CANCEL

    mp.add_forced_key_binding(
        "ESC",
        "helska-boost-cancel",
        cancel_boost_menu
    )
end

-- OPEN / SAVE AUDIO BOOST MENU

local function toggle_boost_menu()

    -- DO NOT OPEN OVER MANUAL CLIP MENU

    if manual_active then
        return
    end

    -- OPEN

    if not boost_menu_active then

        boost_original_db =
            audio_boost_db

        boost_menu_active =
            true

        add_boost_bindings()

        update_boost_osd()

        return
    end

    -- SAVE AND CLOSE

    local changed =
        math.abs(
            audio_boost_db -
            boost_original_db
        ) > 0.001

    boost_menu_active =
        false

    boost_original_db =
        nil

    remove_boost_bindings()

    mp.set_osd_ass(
        0,
        0,
        ""
    )

    -- CREATE / UPDATE CONFIG ONLY AFTER A CHANGE

    if changed then

        if save_config() then

            mp.osd_message(
                "Audio Boost saved: " ..
                format_boost_db(
                    audio_boost_db
                ) ..
                " (" ..
                format_boost_percent(
                    audio_boost_db
                ) ..
                ")",
                2
            )
        end

    else

        mp.osd_message(
            "Audio Boost: " ..
            format_boost_db(
                audio_boost_db
            ),
            2
        )
    end
end

-- RESET TEMPORARY UI WHEN A NEW FILE LOADS

mp.register_event(
    "file-loaded",

    function()

        -- MANUAL CLIP

        manual_active =
            false

        manual_start =
            nil

        if manual_osd_timer then

            manual_osd_timer:kill()
            manual_osd_timer = nil
        end

        remove_manual_bindings()

        -- AUDIO BOOST MENU

        if boost_menu_active then

            audio_boost_db =
                boost_original_db
                or audio_boost_db

            boost_menu_active =
                false

            boost_original_db =
                nil

            remove_boost_bindings()
        end

        -- CLEAR SCRIPT OSD

        mp.set_osd_ass(
            0,
            0,
            ""
        )
    end
)

-- MAIN KEY BINDINGS

local function install_main_bindings()
    mp.remove_key_binding("helska-subtitle-audio-to-clipboard")
    mp.remove_key_binding("helska-manual-audio-clip")
    mp.remove_key_binding("helska-audio-boost")

    local key = helska_bind("audio-clipboard", "Ctrl+e")
    if key then
        mp.add_forced_key_binding(key, "helska-subtitle-audio-to-clipboard", extract_subtitle_audio)
    end

    key = helska_bind("audio-clipboard-manual", "Ctrl+Shift+e")
    if key then
        mp.add_forced_key_binding(key, "helska-manual-audio-clip", toggle_manual_clip)
    end

    key = helska_bind("audio-clipboard-boost", "Alt+e")
    if key then
        mp.add_forced_key_binding(key, "helska-audio-boost", toggle_boost_menu)
    end
end

install_main_bindings()

-- Pause this script's hotkeys while the Console owns input (its menus force-bind
-- the arrow keys, which would clash). Binding state is restored on "off".
local function remove_audio_hotkeys()
    mp.remove_key_binding("helska-subtitle-audio-to-clipboard")
    mp.remove_key_binding("helska-manual-audio-clip")
    mp.remove_key_binding("helska-audio-boost")
    for _, name in ipairs({
        "helska-audio-fine-left", "helska-audio-fine-right",
        "helska-audio-coarse-left", "helska-audio-coarse-right",
        "helska-audio-sub-start-left", "helska-audio-sub-start-right",
        "helska-audio-sub-end-left", "helska-audio-sub-end-right",
        "helska-audio-cancel",
        "helska-boost-left", "helska-boost-right",
        "helska-boost-fine-left", "helska-boost-fine-right",
        "helska-boost-cancel",
    }) do
        mp.remove_key_binding(name)
    end
end

mp.register_script_message("helska-console-focus", function(state)
    if state == "on" then
        remove_audio_hotkeys()
    elseif state == "off" then
        install_main_bindings()
        if manual_active then add_manual_bindings() end
        if boost_menu_active then add_boost_bindings() end
    end
end)

-- HELSKA CONSOLE INTEGRATION

mp.register_script_message("console-audio-copy", extract_subtitle_audio)
mp.register_script_message("console-audio-manual", toggle_manual_clip)
mp.register_script_message(
    "console-audio-clipboard-boost-menu",
    toggle_boost_menu
)

mp.register_script_message(
    "console-audio-clipboard-boost-get",
    function()
        mp.osd_message(
            "Audio Clipboard Boost: " ..
            format_boost_db(audio_boost_db) ..
            " (" .. format_boost_percent(audio_boost_db) .. ")",
            2
        )
    end
)

mp.register_script_message(
    "console-audio-clipboard-boost-set",
    function(value)
        local number = tonumber(value)

        if not number then
            mp.osd_message("Usage: audio-clipboard-boost <dB>")
            return
        end

        audio_boost_db =
            clamp(
                round_to_half(number),
                min_audio_boost_db,
                max_audio_boost_db
            )

        if save_config() then
            mp.osd_message(
                "Audio Clipboard Boost saved: " ..
                format_boost_db(audio_boost_db) ..
                " (" .. format_boost_percent(audio_boost_db) .. ")",
                2
            )
        end
    end
)

mp.register_script_message("console-reload-bindings", install_main_bindings)


-- HELSKA CONSOLE COMPATIBILITY
--
-- This script owns its actions and bindings; the Console only discovers
-- metadata and sends generic run/reload messages.

local HELSKA_CONSOLE_ACTIONS = {
    {
        group = "AUDIO CLIPBOARD",
        name = "audio-clipboard",
        default_key = "Ctrl+e",
        description = "copy current subtitle audio to clipboard",
        group_order = 10,
        action_order = 1,
    },
    {
        group = "AUDIO CLIPBOARD",
        name = "audio-clipboard-manual",
        default_key = "Ctrl+Shift+e",
        description = "start or finish a manual audio clip",
        group_order = 10,
        action_order = 2,
    },
    {
        group = "AUDIO CLIPBOARD",
        name = "audio-clipboard-boost",
        default_key = "Alt+e",
        description = "open extracted-audio boost controls",
        group_order = 10,
        action_order = 3,
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
    ["audio-clipboard"] = extract_subtitle_audio,
    ["audio-clipboard-manual"] = toggle_manual_clip,
    ["audio-clipboard-boost"] = toggle_boost_menu,
}

mp.register_script_message("helska-console-discover", advertise_to_helska_console)

mp.register_script_message("helska-console-run", function(action_name)
    local run = HELSKA_CONSOLE_RUNNERS[action_name]
    if run then
        run()
    else
        -- Every console action is broadcast to every module, so "not mine" is
        -- the normal case, not a warning.
        mp.msg.verbose("helska audio-clipboard: ignoring action " .. tostring(action_name))
    end
end)

mp.register_script_message("helska-console-reload-bindings", install_main_bindings)

advertise_to_helska_console()
