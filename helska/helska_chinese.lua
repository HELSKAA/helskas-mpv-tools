-- helska_chinese.lua
-- Chinese subtitle tools: Mandarin tone colouring and Simplified/Traditional
-- conversion. The original subtitle is never changed in place; at most one
-- generated subtitle track is kept.
--
-- Tools, bundled under helska/ and falling back to PATH:
--   python (+ pypinyin)  tone colouring
--   OpenCC               Hanzi conversion
--   ffmpeg               embedded-subtitle preload
-- helska_tone_colors.py must sit beside this file.

local mp = require "mp"
local utils = require "mp.utils"

local ACTION_NAME = "tones"
local CONVERT_ACTION = "hanzi-convert"
local COLOR_ACTION = "tones-color"
local DEFAULT_KEY = "Ctrl+t"
local CONVERT_DEFAULT_KEY = "Ctrl+Alt+c"
local COLOR_DEFAULT_KEY = "Alt+t"
local BINDING_NAME = "helska-chinese-tones"
local CONVERT_BINDING_NAME = "helska-hanzi-convert"
local COLOR_BINDING_NAME = "helska-tones-color"

local tones_enabled = false
local conversion_enabled = false
local enabled = false
local source_conversion_direction = nil
local source_conversion_sid = nil
local mode = nil
local generated_sid = nil
local generated_path = nil
local generation_serial = 0
local switching_to_generated = false
local source_sid = nil
local source_secondary_sid = nil
local track_change_timer = nil
local status = mp.create_osd_overlay("ass-events")
local status_timer = nil
local operation_status = nil

local function conversion_label(direction, reverse)
    if direction == "s2t" then
        return reverse and "Traditional → Simplified" or "Simplified → Traditional"
    elseif direction == "t2s" then
        return reverse and "Simplified → Traditional" or "Traditional → Simplified"
    end
    return reverse and "Returning to original Chinese" or "Converting Chinese"
end

local function script_dir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1,1) == "@" then source = source:sub(2) end
    local dir = utils.split_path(source)
    return dir
end

local SCRIPT_DIR = script_dir()
local HELPER = utils.join_path(SCRIPT_DIR, "helska_tone_colors.py")
local CONFIG = utils.join_path(SCRIPT_DIR, "helska.conf")

------------------------------------------------------------------------
-- TEMPORARY FILES  (self-cleaning scratch folder)
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

local DEFAULT_TONE_HEX={
    [1]="#EC464F",
    [2]="#FF8F40",
    [3]="#6CBF43",
    [4]="#39BAE6",
    [5]="#FCFCFC",
}
local tone_hex={}

local function normalize_hex(value)
    local v=tostring(value or ""):gsub("%s+",""):upper()
    if v:sub(1,1)~="#" then v="#"..v end
    if v:match("^#[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]$") then
        return v
    end
    return nil
end

local function read_config_values()
    local out={}
    local f=io.open(CONFIG,"r")
    if not f then return out end
    for line in f:lines() do
        local k,v=line:match("^%s*([^#=%s][^=]-)%s*=%s*(.-)%s*$")
        if k then out[k]=v end
    end
    f:close()
    return out
end

local function reload_tone_palette()
    local cfg=read_config_values()
    for i=1,5 do
        tone_hex[i]=normalize_hex(cfg["tone_color_"..i]) or DEFAULT_TONE_HEX[i]
    end
end

local function ensure_tone_defaults_in_config()
    local cfg=read_config_values()
    local missing=false
    for i=1,5 do
        if not normalize_hex(cfg["tone_color_"..i]) then missing=true break end
    end
    if not missing then return true end

    local lines={}
    local f=io.open(CONFIG,"r")
    if f then
        for line in f:lines() do lines[#lines+1]=line end
        f:close()
    else
        lines={
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
    local present={}
    for _,line in ipairs(lines) do
        local k=line:match("^%s*([^#=%s][^=]-)%s*=")
        if k then present[k]=true end
    end
    for i=1,5 do
        local key="tone_color_"..i
        if not present[key] then lines[#lines+1]=key.."="..DEFAULT_TONE_HEX[i] end
    end
    local out=io.open(CONFIG,"w")
    if not out then return false end
    out:write(table.concat(lines,"\n").."\n")
    out:close()
    return true
end

local function rewrite_config(mutator)
    local lines={}
    local f=io.open(CONFIG,"r")
    if f then
        for line in f:lines() do lines[#lines+1]=line end
        f:close()
    else
        lines={
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
    lines=mutator(lines) or lines
    local out=io.open(CONFIG,"w")
    if not out then return false end
    out:write(table.concat(lines,"\n").."\n")
    out:close()
    return true
end

local function set_config_value(key,value)
    return rewrite_config(function(lines)
        local result={}
        local replaced=false
        for _,line in ipairs(lines) do
            local k=line:match("^%s*([^#=%s][^=]-)%s*=")
            if k==key then
                if not replaced then
                    result[#result+1]=key.."="..value
                    replaced=true
                end
            else
                result[#result+1]=line
            end
        end
        if not replaced then result[#result+1]=key.."="..value end
        return result
    end)
end

local function remove_tone_color_overrides()
    return rewrite_config(function(lines)
        local result={}
        for _,line in ipairs(lines) do
            local k=line:match("^%s*([^#=%s][^=]-)%s*=")
            if not (k and k:match("^tone_color_[1-5]$")) then
                result[#result+1]=line
            end
        end
        return result
    end)
end

local function hex_to_ass(hex)
    local h=normalize_hex(hex) or "#FFFFFF"
    local r,g,b=h:sub(2,3),h:sub(4,5),h:sub(6,7)
    return "&H"..b..g..r.."&"
end

ensure_tone_defaults_in_config()
reload_tone_palette()

local function ass_escape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "＼"):gsub("{", "｛"):gsub("}", "｝")
    return s
end

local function mpv_color_to_ass(value, fallback)
    local s=tostring(value or ""):gsub("^#","")
    local a,r,g,b
    if #s==8 then
        a,r,g,b=s:sub(1,2),s:sub(3,4),s:sub(5,6),s:sub(7,8)
    elseif #s==6 then
        a,r,g,b="FF",s:sub(1,2),s:sub(3,4),s:sub(5,6)
    else
        return fallback
    end
    -- mpv alpha: FF opaque. ASS alpha: 00 opaque.
    local mpva=tonumber(a,16) or 255
    local assa=string.format("%02X",255-mpva)
    return "&H"..assa..b..g..r.."&"
end

local function ass_alignment(style)
    local x = style.align_x
    local y = style.align_y
    local col = (x=="left" and 1) or (x=="right" and 3) or 2
    local row = (y=="top" and 6) or (y=="center" and 3) or 0
    return row + col
end

local function ass_justify(style)
    local j=style.justify
    if j=="auto" then j=style.align_x end
    -- libass \q does wrapping mode, not line justification. For the live
    -- overlay, alignment is the closest exact primitive available; centered
    -- normal subtitles therefore remain centered as mpv defaults them.
    return j
end

local function subtitle_style()
    local bold=mp.get_property_native("sub-bold")
    local italic=mp.get_property_native("sub-italic")
    return {
        font=mp.get_property("sub-font") or "sans-serif",
        font_size=mp.get_property_number("sub-font-size",55),
        bold=bold and -1 or 0,
        italic=italic and -1 or 0,
        outline=mp.get_property_number("sub-outline-size",
            mp.get_property_number("sub-border-size",1.65)),
        outline_color=mpv_color_to_ass(
            mp.get_property("sub-outline-color") or mp.get_property("sub-border-color"),
            "&H00000000&"),
        shadow=mp.get_property_number("sub-shadow-offset",0),
        shadow_color=mpv_color_to_ass(
            mp.get_property("sub-back-color") or mp.get_property("sub-shadow-color"),
            "&H00000000&"),
        spacing=mp.get_property_number("sub-spacing",0),
        blur=mp.get_property_number("sub-blur",0),
        scale=mp.get_property_number("sub-scale",1),
        align_x=mp.get_property("sub-align-x") or "center",
        align_y=mp.get_property("sub-align-y") or "bottom",
        justify=mp.get_property("sub-justify") or "auto",
        margin_x=mp.get_property_number("sub-margin-x",19),
        margin_y=mp.get_property_number("sub-margin-y",34)
            + mp.get_property_number("sub-margin-y-offset",0),
    }
end

local function show_status(title, detail, bad, seconds)
    if status_timer then status_timer:kill() end
    local w = mp.get_property_number("osd-width",1280)
    local h = mp.get_property_number("osd-height",720)
    status.res_x,status.res_y=w,h

    -- Scale with the window so the toast reads the same at any size. The
    -- formula matches the responsive sizing used by the other shared popups,
    -- but the base sizes here are ~50% larger so headers stay clearly readable.
    local scale = math.max(0.5, math.min(math.min(w / 1280, h / 720), 1.4))
    local x = math.max(16, math.floor(34 * scale + 0.5))
    local y = math.max(30, math.floor(96 * scale + 0.5))
    local fs_title = math.max(20, math.floor(38 * scale + 0.5))
    local fs_detail = math.max(15, math.floor(27 * scale + 0.5))

    status.data=string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b1\\bord2\\shad1\\1c%s\\3c&H201714&}%s"..
        "\\N{\\fs%d\\b0\\1c&HD7D7D7&}%s",
        x, y, fs_title,
        bad and "&H7C9CFF&" or "&HFFDDAA&",
        ass_escape(title),
        fs_detail,
        ass_escape(detail or ""))
    status:update()
    if seconds ~= 0 then
        status_timer=mp.add_timeout(seconds or (bad and 3 or 1.8),function()
            status.data=""; status:update()
        end)
    end
end

local function read_binding(action,default_key)
    local f=io.open(CONFIG,"r")
    if not f then return default_key end
    local found=nil
    for line in f:lines() do
        local k,v=line:match("^%s*([^#=%s][^=]-)%s*=%s*(.-)%s*$")
        if k=="bind."..action then found=v end
    end
    f:close()
    if found and found:lower()=="disabled" then return nil end
    return found and found~="" and found or default_key
end

local function install_binding()
    mp.remove_key_binding(BINDING_NAME)
    mp.remove_key_binding(CONVERT_BINDING_NAME)
    mp.remove_key_binding(COLOR_BINDING_NAME)
    local tone_key=read_binding(ACTION_NAME,DEFAULT_KEY)
    if tone_key then
        mp.add_key_binding(tone_key,BINDING_NAME,function()
            mp.commandv("script-message-to",mp.get_script_name(),"toggle-tones")
        end)
    end
    local convert_key=read_binding(CONVERT_ACTION,CONVERT_DEFAULT_KEY)
    if convert_key then
        mp.add_key_binding(convert_key,CONVERT_BINDING_NAME,function()
            mp.commandv("script-message-to",mp.get_script_name(),"toggle-convert")
        end)
    end
    local color_key=read_binding(COLOR_ACTION,COLOR_DEFAULT_KEY)
    if color_key then
        mp.add_key_binding(color_key,COLOR_BINDING_NAME,function()
            mp.commandv("script-message-to",mp.get_script_name(),"open-tone-colors")
        end)
    end
end

local function python_candidates()
    -- mpv's utils.join_path takes exactly TWO components and silently drops any
    -- extra argument, so the bundled interpreter path MUST be nested (otherwise
    -- the "path" degrades to the python/ directory and spawning it always fails,
    -- silently falling back to a system Python that need not exist).
    local root=utils.join_path(SCRIPT_DIR,"python")
    if package.config:sub(1,1)=="\\" then
        return {utils.join_path(root,"python.exe"),"python","py"}
    end
    return {utils.join_path(root,"bin/python3"),"python3","python"}
end

-- Log the resolved paths once at load so an mpv log immediately shows whether the
-- bundled interpreter and helper are visible from mpv's point of view.
do
    local bundled=python_candidates()[1]
    mp.msg.info("helska chinese: SCRIPT_DIR="..SCRIPT_DIR..
        " | bundled_python="..bundled.." exists="..tostring(utils.file_info(bundled)~=nil)..
        " | helper="..HELPER.." exists="..tostring(utils.file_info(HELPER)~=nil))
end

local function current_track()
    local sid=mp.get_property_number("sid")
    if not sid then return nil end
    local tracks=mp.get_property_native("track-list") or {}
    for _,t in ipairs(tracks) do
        if t.type=="sub" and tonumber(t.id)==tonumber(sid) then return t end
    end
end

-- True when a subtitle track is selected/on screen (current_track() only
-- resolves a concrete sid, so an auto-selected track is checked too). Used to
-- refuse enabling with no subtitle, instead of a misleading ON/OFF toast.
local function has_selected_subtitle()
    if current_track() then return true end
    local tracks=mp.get_property_native("track-list") or {}
    for _,t in ipairs(tracks) do
        if t.type=="sub" and t.selected then return true end
    end
    return false
end

local function embedded_preload_kind(track)
    if not track then return nil end
    local codec=tostring(track.codec or ""):lower()
    if codec=="ass" or codec=="ssa" or codec=="ass-text"
       or codec:find("ass",1,true)~=nil then
        return "ass"
    end
    if codec=="subrip" or codec=="srt" or codec=="subrip-text"
       or codec:find("subrip",1,true)~=nil then
        return "srt"
    end
    return nil
end

local function absolute_media_path()
    local path=mp.get_property("path")
    if not path or path=="" or path:match("^%a[%w+.-]*://") then return nil end
    if path:match("^%a:[/\\]") or path:sub(1,1)=="/" or path:sub(1,2)=="\\\\" then
        return path
    end
    return utils.join_path(mp.get_property("working-directory") or ".",path)
end

local function temp_source_path(kind)
    local ext=kind=="srt" and ".srt" or ".ass"
    local pid=tostring(mp.get_property_number("pid",0))
    local now=tostring(math.floor(mp.get_time()*1000))
    return SCRATCH.path("helska-chinese-source-"..pid.."-"..now..ext)
end

local ffmpeg_probe_cache=nil

local function find_ffmpeg(done)
    local exe=package.config:sub(1,1)=="\\" and "ffmpeg.exe" or "ffmpeg"
    local bundled=utils.join_path(utils.join_path(SCRIPT_DIR,"ffmpeg"),exe)
    if utils.file_info(bundled) then
        done(bundled)
        return
    end
    if ffmpeg_probe_cache~=nil then
        done(ffmpeg_probe_cache or nil)
        return
    end
    mp.command_native_async({
        name="subprocess",playback_only=false,capture_stdout=true,capture_stderr=true,
        args={exe,"-version"},
    },function(success,result)
        if success and result and result.status==0 then
            ffmpeg_probe_cache=exe
            done(exe)
        else
            ffmpeg_probe_cache=false
            done(nil)
        end
    end)
end

local function absolute_external_path(track)
    if not track then return nil end
    local path=track["external-filename"]
    if not path or path=="" then return nil end
    if path:match("^%a:[/\\]") or path:sub(1,1)=="/" or path:sub(1,2)=="\\\\" then
        return path
    end
    local video=mp.get_property("path")
    if not video then return path end
    local dir=utils.split_path(video)
    return utils.join_path(dir,path)
end

-- The generated subtitle is loaded as an external track, so its FILE NAME is
-- what mpv shows in the track list. Name it to read clearly there, and include
-- the mpv subtitle-track number the user sees in the UI (source_sid).
local function sub_label(sid)
    local n=tonumber(sid)
    if n then return " (sub "..n..")" end
    return ""
end

local function track_title_for(path)
    local base=path:match("[^/\\]+$") or path
    return (base:gsub("%.[^%.]+$",""))
end

-- Recognise a track this module generated - by its title OR by its external
-- file name - so an old derivative is always removed, without ever touching the
-- separately managed "Preloaded subs" track (which also lives in this folder).
local function is_chinese_generated(t)
    local title=tostring(t.title or "")
    if title:sub(1,11)=="Tone colors" or title:sub(1,16)=="Hanzi conversion" then
        return true
    end
    local p=t["external-filename"]
    if type(p)=="string" then
        local base=p:match("[^/\\]+$") or ""
        if base:sub(1,11)=="Tone colors" or base:sub(1,16)=="Hanzi conversion" then
            return true
        end
    end
    return false
end

-- Tone colors and Hanzi conversion can both be active on the SAME track, so the
-- combined result gets its own distinct label; the pure tone / pure conversion
-- labels stay separate, which also guarantees the transient converted file can
-- never collide with the tone file while a build is in flight.
local function temp_ass_path(sid,combined)
    local label=combined and "Tone colors + Hanzi" or "Tone colors"
    return SCRATCH.path(label..sub_label(sid)..".ass")
end

local function remove_generated_track()
    -- Never leave an old tone-color track behind. In particular, an earlier
    -- generated track must not survive as mpv's secondary subtitle.
    local tracks = mp.get_property_native("track-list") or {}
    local remove_ids = {}
    for _, t in ipairs(tracks) do
        if t.type == "sub" and is_chinese_generated(t) then
            remove_ids[#remove_ids + 1] = t.id
        end
    end

    local secondary = mp.get_property_number("secondary-sid")
    for _, id in ipairs(remove_ids) do
        if secondary and tonumber(secondary) == tonumber(id) then
            mp.set_property("secondary-sid", "no")
        end
        pcall(mp.commandv, "sub-remove", tostring(id))
    end

    generated_sid=nil
    if generated_path then
        SCRATCH.remove(generated_path)
        generated_path=nil
    end
end

local function find_track_id_by_filename(path)
    local tracks=mp.get_property_native("track-list") or {}
    for _,t in ipairs(tracks) do
        if t.type=="sub" and t["external-filename"] then
            local a=t["external-filename"]:gsub("\\","/"):lower()
            local b=path:gsub("\\","/"):lower()
            if a==b then return t.id end
        end
    end
end

----------------------------------------------------------------------
-- FULL EXTERNAL SUBTITLE PREPROCESSING
----------------------------------------------------------------------

local function extract_embedded_text(ffmpeg,track,kind,done)
    local input=absolute_media_path()
    if not input then
        done(nil,"Current media is not a local file")
        return
    end

    -- FFmpeg maps subtitle streams by their zero-based order among subtitle
    -- streams, not by mpv's track id.
    local tracks=mp.get_property_native("track-list") or {}
    local sub_index=-1
    local n=0
    for _,t in ipairs(tracks) do
        if t.type=="sub" then
            if tonumber(t.id)==tonumber(track.id) then
                sub_index=n
                break
            end
            n=n+1
        end
    end
    if sub_index<0 then
        done(nil,"Couldn't resolve embedded subtitle stream")
        return
    end

    local out=temp_source_path(kind)
    mp.command_native_async({
        name="subprocess",playback_only=false,capture_stdout=true,capture_stderr=true,
        args={
            ffmpeg,"-hide_banner","-loglevel","error","-y",
            "-i",input,"-map","0:s:"..sub_index,"-c:s",(kind=="srt" and "srt" or "ass"),out
        },
    },function(success,result)
        if success and result and result.status==0 and utils.file_info(out) then
            done(out,nil)
        else
            SCRATCH.remove(out)
            local detail=result and result.stderr or "FFmpeg extraction failed"
            done(nil,tostring(detail):gsub("[\r\n]+"," "):sub(1,180))
        end
    end)
end

local function build_tones_external(input_path,cleanup_input)
    mode="building"
    generation_serial=generation_serial+1
    local mine=generation_serial
    local out=temp_ass_path(source_sid,conversion_enabled)
    generated_path=out
    if not operation_status then
        show_status("TONE COLORS","Preparing tone colors...",false,0)
    end

    local style=subtitle_style()
    local req=utils.format_json({
        input=input_path,output=out,
        font=style.font,
        font_size=style.font_size * style.scale,
        bold=style.bold,
        italic=style.italic,
        outline=style.outline,
        outline_color=style.outline_color,
        shadow=style.shadow,
        shadow_color=style.shadow_color,
        spacing=style.spacing,
        blur=style.blur,
        alignment=ass_alignment(style),
        margin_x=style.margin_x,
        margin_y=style.margin_y,
        tone_sandhi=false,
        tone_colors=tone_hex,
    })
    local candidates=python_candidates()

    local function attempt(i)
        local py=candidates[i]
        if not py then
            if cleanup_input then SCRATCH.remove(input_path) end
            tones_enabled=false
            enabled=conversion_enabled
            mp.msg.error("helska chinese: no usable Python interpreter for tone colors. tried=["..
                table.concat(candidates,", ").."] helper="..tostring(HELPER))
            show_status("TONE COLORS","Preloading failed - tone coloring turned off",true,3)
            return
        end
        mp.command_native_async({
            name="subprocess",playback_only=false,capture_stdout=true,capture_stderr=true,
            args={py,HELPER,"build",req},
        },function(success,result)
            if not enabled or mine~=generation_serial then
                SCRATCH.remove(out)
                if cleanup_input then SCRATCH.remove(input_path) end
                return
            end
            if not success or not result or result.status~=0 then
                mp.msg.error("helska chinese: python '"..tostring(py).."' failed (status="..
                    tostring(result and result.status).."): "..tostring(result and result.stderr))
                attempt(i+1); return
            end
            local data=utils.parse_json(result.stdout or "")
            if not data or not data.ok then
                mp.msg.error("helska chinese: python '"..tostring(py).."' produced no usable JSON: stdout="..
                    tostring(result.stdout).." stderr="..tostring(result.stderr))
                attempt(i+1); return
            end
            -- Log which interpreter actually worked.
            mp.msg.verbose("helska chinese: tone colors built by python '"..tostring(py).."'")
            if cleanup_input then
                SCRATCH.remove(input_path)
                cleanup_input=false
            end

            -- Load it directly as the PRIMARY subtitle replacement. "auto"
            -- can let mpv make an unwanted track-selection decision, including
            -- interactions with secondary subtitles.
            local secondary_before = mp.get_property("secondary-sid")
            switching_to_generated = true
            mp.commandv("sub-add",out,"select",track_title_for(out))
            generated_sid=find_track_id_by_filename(out)
            if generated_sid then
                mp.set_property_number("sid",generated_sid)
                -- sub-add/select must not change the user's secondary subtitle.
                if secondary_before and secondary_before ~= "" then
                    mp.set_property("secondary-sid",secondary_before)
                end
                switching_to_generated = false
                mp.set_property("sub-visibility","yes")
                mode="preprocessed"
                if operation_status then
                    show_status(operation_status.title,operation_status.detail,false,2.8)
                    operation_status=nil
                else
                    show_status("TONE COLORS","READY - "..tostring(data.events).." lines preloaded",false,2.2)
                end
            else
                switching_to_generated = false
                tones_enabled=false
                enabled=conversion_enabled
                show_status("TONE COLORS","Generated temporary track could not be selected",true,3)
                -- Conversion remains enabled; no live tone renderer is used.
            end
        end)
    end
    attempt(1)
end


local opencc_probe_cache=nil

-- The bundled OpenCC lives in helska/OpenCC with a Windows-style layout:
--   helska/OpenCC/bin/<opencc[.exe]>
--   helska/OpenCC/share/opencc/<config>.json   (dictionary data)
-- Note: mpv's utils.join_path accepts exactly two components, so nest calls.
local OPENCC_ROOT     = utils.join_path(SCRIPT_DIR, "OpenCC")
local OPENCC_BIN_DIR  = utils.join_path(OPENCC_ROOT, "bin")
local OPENCC_DATA_DIR = utils.join_path(utils.join_path(OPENCC_ROOT, "share"), "opencc")

local function read_binary(path)
    local f=io.open(path,"rb")
    if not f then return nil end
    local data=f:read("*a")
    f:close()
    return data
end

local function byte_diff(a,b)
    a=a or ""; b=b or ""
    local n=math.min(#a,#b)
    local d=math.abs(#a-#b)
    for i=1,n do if a:byte(i)~=b:byte(i) then d=d+1 end end
    return d
end

local function temp_convert_path(input_path,label,visible)
    local ext=tostring(input_path):match("(%.[^./\\]+)$") or ".srt"
    if visible then
        -- Loaded directly as the visible Hanzi-conversion track.
        return SCRATCH.path("Hanzi conversion"..sub_label(source_sid)..ext)
    end
    local pid=tostring(mp.get_property_number("pid",0))
    local now=tostring(math.floor(mp.get_time()*1000))
    return SCRATCH.path("helska-chinese-"..label.."-"..pid.."-"..now..ext)
end

local function find_opencc(done)
    local exe=package.config:sub(1,1)=="\\" and "opencc.exe" or "opencc"
    local bundled=utils.join_path(OPENCC_BIN_DIR,exe)
    if utils.file_info(bundled) then done(bundled); return end
    if opencc_probe_cache~=nil then done(opencc_probe_cache or nil); return end
    mp.command_native_async({
        name="subprocess",playback_only=false,capture_stdout=true,capture_stderr=true,
        args={exe,"--version"},
    },function(success,result)
        if success and result and result.status==0 then
            opencc_probe_cache=exe; done(exe)
        else
            opencc_probe_cache=false; done(nil)
        end
    end)
end

local function opencc_config(config)
    local bundled=utils.join_path(OPENCC_DATA_DIR,config)
    if utils.file_info(bundled) then return bundled end
    return config
end

local function run_opencc(opencc,input_path,output_path,config,done)
    config=opencc_config(config)
    mp.command_native_async({
        name="subprocess",playback_only=false,capture_stdout=true,capture_stderr=true,
        args={opencc,"-i",input_path,"-o",output_path,"-c",config},
    },function(success,result)
        if success and result and result.status==0 and utils.file_info(output_path) then
            done(true,nil)
        else
            SCRATCH.remove(output_path)
            done(false,result and result.stderr or "OpenCC conversion failed")
        end
    end)
end

local function prepare_converted_source(input_path,mine,done)
    find_opencc(function(opencc)
        if mine~=generation_serial or not enabled then return end
        if not opencc then
            done(nil,"OpenCC not found in helska/OpenCC/bin or PATH")
            return
        end

        -- Direction belongs to the untouched ORIGINAL source. Detect it once
        -- per source track, then keep toggling against that same source.
        if source_conversion_sid==source_sid and source_conversion_direction then
            if tones_enabled and conversion_enabled then
                operation_status={
                    title=conversion_label(source_conversion_direction,false),
                    detail="CHINESE + TONE COLORS".." - regenerating tone colors"
                }
                show_status(operation_status.title,operation_status.detail,false,0)
            end
            local out=temp_convert_path(input_path,"converted",not tones_enabled)
            local cfg=source_conversion_direction=="s2t" and "s2t.json" or "t2s.json"
            run_opencc(opencc,input_path,out,cfg,function(ok,err)
                if mine~=generation_serial or not enabled then SCRATCH.remove(out); return end
                done(ok and out or nil,err)
            end)
            return
        end

        local s2t=temp_convert_path(input_path,"detect-s2t")
        local t2s=temp_convert_path(input_path,"detect-t2s")
        run_opencc(opencc,input_path,s2t,"s2t.json",function(ok1,err1)
            if mine~=generation_serial or not enabled then SCRATCH.remove(s2t); return end
            if not ok1 then done(nil,err1); return end
            run_opencc(opencc,input_path,t2s,"t2s.json",function(ok2,err2)
                if mine~=generation_serial or not enabled then
                    SCRATCH.remove(s2t); SCRATCH.remove(t2s); return
                end
                if not ok2 then SCRATCH.remove(s2t); done(nil,err2); return end
                local original=read_binary(input_path) or ""
                local ds=byte_diff(original,read_binary(s2t) or "")
                local dt=byte_diff(original,read_binary(t2s) or "")
                local chosen
                if ds==0 and dt==0 then
                    SCRATCH.remove(s2t); SCRATCH.remove(t2s)
                    done(nil,"No Simplified/Traditional difference detected")
                    return
                elseif ds>=dt then
                    source_conversion_direction="s2t"; chosen=s2t; SCRATCH.remove(t2s)
                else
                    source_conversion_direction="t2s"; chosen=t2s; SCRATCH.remove(s2t)
                end
                source_conversion_sid=source_sid
                if tones_enabled and conversion_enabled then
                    operation_status={
                        title=conversion_label(source_conversion_direction,false),
                        detail="CHINESE + TONE COLORS".." - regenerating tone colors"
                    }
                    show_status(operation_status.title,operation_status.detail,false,0)
                end
                if not tones_enabled then
                    -- Conversion only: this file IS the visible track, so give
                    -- it the readable name mpv will show in the track list.
                    local readable=temp_convert_path(chosen,"converted",true)
                    if pcall(os.rename,chosen,readable) then chosen=readable end
                end
                done(chosen,nil)
            end)
        end)
    end)
end

local function load_generated_direct(path,cleanup_original)
    local secondary_before=mp.get_property("secondary-sid")
    switching_to_generated=true
    mp.commandv("sub-add",path,"select",track_title_for(path))
    generated_path=path
    generated_sid=find_track_id_by_filename(path)
    if generated_sid then
        mp.set_property_number("sid",generated_sid)
        if secondary_before and secondary_before~="" then
            mp.set_property("secondary-sid",secondary_before)
        end
        mode="preprocessed"
        mp.set_property("sub-visibility","yes")
        show_status(conversion_label(source_conversion_direction,false),
            "CHINESE CONVERT",false,2.5)
    else
        SCRATCH.remove(path)
        generated_path=nil
        show_status("CHINESE CONVERT","Generated track could not be selected",true,3)
    end
    switching_to_generated=false
    if cleanup_original then SCRATCH.remove(cleanup_original) end
end

local function build_external(input_path,cleanup_input)
    generation_serial=generation_serial+1
    local mine=generation_serial

    if not conversion_enabled then
        if tones_enabled then
            build_tones_external(input_path,cleanup_input)
        else
            if cleanup_input then SCRATCH.remove(input_path) end
        end
        return
    end

    if not operation_status then
        show_status("CHINESE CONVERT","Preparing converted subtitle...",false,0)
    end
    prepare_converted_source(input_path,mine,function(converted,err)
        if mine~=generation_serial or not enabled then
            if converted then SCRATCH.remove(converted) end
            if cleanup_input then SCRATCH.remove(input_path) end
            return
        end
        if not converted then
            if cleanup_input then SCRATCH.remove(input_path) end
            conversion_enabled=false
            enabled=tones_enabled
            operation_status=nil
            show_status("CHINESE CONVERT",tostring(err or "Conversion failed"),true,3)
            if tones_enabled then
                -- Rebuild the untouched source with tones only.
                start()
            end
            return
        end
        if tones_enabled then
            if cleanup_input then SCRATCH.remove(input_path) end
            build_tones_external(converted,true)
        else
            load_generated_direct(converted,cleanup_input and input_path or nil)
        end
    end)
end

local function start()
    ensure_tone_defaults_in_config()
    reload_tone_palette()
    enabled=tones_enabled or conversion_enabled
    if not enabled then return end
    if tones_enabled and not utils.file_info(HELPER) then
        tones_enabled=false
        enabled=conversion_enabled
        show_status("TONE COLORS","Missing helska_tone_colors.py",true,3)
        if not enabled then return end
    end
    source_sid=mp.get_property_number("sid")
    if source_secondary_sid == nil then
        source_secondary_sid = mp.get_property("secondary-sid") or "no"
    end
    local track=current_track()
    local path=absolute_external_path(track)
    local lower=path and path:lower() or ""
    if path and (lower:match("%.srt$") or lower:match("%.ass$") or lower:match("%.ssa$"))
       and utils.file_info(path) then
        build_external(path)
    elseif not path and embedded_preload_kind(track) then
        mode="building"
        local requested_sid=source_sid
        local kind=embedded_preload_kind(track)
        local label=kind=="srt" and "SRT" or "ASS"
        show_status("TONE COLORS","Checking FFmpeg for embedded "..label.." preload...",false,0)
        find_ffmpeg(function(ffmpeg)
            if not enabled or tonumber(source_sid)~=tonumber(requested_sid) then return end
            if not ffmpeg then
                tones_enabled=false
                conversion_enabled=false
                enabled=false
                show_status("HELSKA CHINESE","FFmpeg not found - embedded subtitles cannot be preloaded",true,3)
                return
            end
            show_status("TONE COLORS","Extracting embedded "..label.." track...",false,0)
            extract_embedded_text(ffmpeg,track,kind,function(extracted,err)
                if not enabled or tonumber(source_sid)~=tonumber(requested_sid) then
                    if extracted then SCRATCH.remove(extracted) end
                    return
                end
                if extracted then
                    build_external(extracted,true)
                else
                    tones_enabled=false
                    enabled=conversion_enabled
                    show_status("TONE COLORS","Embedded "..label.." extraction failed - no live fallback is used",true,3)
                end
            end)
        end)
    else
        if conversion_enabled then conversion_enabled=false end
        if tones_enabled then tones_enabled=false end
        enabled=false
        show_status("HELSKA CHINESE","This subtitle format cannot be preloaded as a complete track",true,3)
    end
end

local function stop_all()
    generation_serial=generation_serial+1
    remove_generated_track()
    if source_sid then
        switching_to_generated=true
        mp.set_property_number("sid",source_sid)
        switching_to_generated=false
    end
    if source_secondary_sid then mp.set_property("secondary-sid",source_secondary_sid) end
    mp.set_property("sub-visibility","yes")
    source_sid=nil
    source_secondary_sid=nil
    source_conversion_direction=nil
    source_conversion_sid=nil
    mode=nil
    enabled=false
end

local function rebuild_from_original()
    enabled=tones_enabled or conversion_enabled
    if not enabled then
        stop_all()
        return
    end

    generation_serial=generation_serial+1

    -- Never use the generated derivative as input. source_sid always points
    -- at the user's untouched original track.
    if generated_sid then
        remove_generated_track()
        if source_sid then
            switching_to_generated=true
            mp.set_property_number("sid",source_sid)
            switching_to_generated=false
        end
    end
    start()
end


----------------------------------------------------------------------
-- TONE COLOR MENU
----------------------------------------------------------------------

local color_overlay=mp.create_osd_overlay("ass-events")
local color_menu_open=false
local color_selected=1 -- 1..5 tones, 6 reset, 7 config, 8 save & exit
local color_working={}
local color_dirty=false
local color_handlers={}
local color_handler_serial=0

-- Same visual language as the other shared menus.
local MC_COMMAND="&HFFDDAA&"
local MC_KEY="&H56D8FF&"
local MC_MUTED="&H9A9A9A&"
local MC_WHITE="&HFFFFFF&"
local MC_PANEL="&H201714&"
local MC_BORDER="&H70543B&"
local MC_SELECTED="&H493A2A&"

local function menu_rect(x1,y1,x2,y2,color,alpha)
    return string.format(
        "{\\an7\\pos(0,0)\\bord0\\shad0\\1c%s\\1a&H%02X&}"..
        "{\\p1}m %d %d l %d %d %d %d %d %d{\\p0}",
        color,alpha or 0,x1,y1,x2,y1,x2,y2,x1,y2)
end

local function menu_scale(w,h)
    local scale=math.min(w/1280,h/720)*0.70
    return math.max(0.52,math.min(scale,1.15))
end

local function working_is_dirty()
    for i=1,5 do
        if normalize_hex(color_working[i])~=normalize_hex(tone_hex[i]) then return true end
    end
    return false
end

local function color_menu_render()
    if not color_menu_open then return end
    color_dirty=working_is_dirty()
    local w=mp.get_property_number("osd-width",1280)
    local h=mp.get_property_number("osd-height",720)
    local scale=menu_scale(w,h)
    color_overlay.res_x=w
    color_overlay.res_y=h

    local panel_w=math.min(math.floor(760*scale+.5),w-28)
    local pad=math.max(12,math.floor(18*scale+.5))
    local title_h=math.max(30,math.floor(42*scale+.5))
    local instruction_h=math.max(68,math.floor(92*scale+.5))
    local row_h=math.max(35,math.floor(48*scale+.5))
    local action_h=math.max(37,math.floor(50*scale+.5))
    local footer_h=math.max(40,math.floor(54*scale+.5))
    local panel_h=pad+title_h+instruction_h+row_h*5+12+action_h*3+footer_h+pad
    local x1=math.floor((w-panel_w)/2+.5)
    local x2=x1+panel_w
    local y1=math.floor((h-panel_h)/2+.5)
    local y2=y1+panel_h
    local instruction_y=y1+pad+title_h
    local rows_y=instruction_y+instruction_h
    local fs=math.max(17,math.floor(25*scale+.5))
    local small=math.max(11,math.floor(16*scale+.5))
    local instruction_fs=math.max(13,math.floor(19*scale+.5))
    local title_fs=math.max(15,math.floor(21*scale+.5))
    local ass={}

    ass[#ass+1]=menu_rect(x1,y1,x2,y2,MC_PANEL,18)
    ass[#ass+1]=menu_rect(x1,y1,x2,y1+2,MC_BORDER,0)
    ass[#ass+1]=menu_rect(x1,y2-2,x2,y2,MC_BORDER,0)
    ass[#ass+1]=menu_rect(x1,y1,x1+2,y2,MC_BORDER,0)
    ass[#ass+1]=menu_rect(x2-2,y1,x2,y2,MC_BORDER,0)
    ass[#ass+1]=string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b1\\bord0\\shad0\\1c%s}TONE COLORS%s",
        x1+pad,y1+pad,title_fs,MC_COMMAND,color_dirty and "  *" or "")

    ass[#ass+1]=string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b1\\bord0\\shad0\\1c%s}"..
        "SELECT A TONE BELOW\\N{\\fs%d\\b0\\1c%s}"..
        "Copy a #RRGGBB hex code, then press Ctrl+V to paste it into the selected tone."..
        "\\N{\\1c%s}Changes are temporary until you choose SAVE & EXIT.  macOS: Cmd+V",
        x1+pad,instruction_y+2,instruction_fs,MC_WHITE,
        small,MC_COMMAND,MC_MUTED)

    for i=1,5 do
        local y=rows_y+(i-1)*row_h
        if color_selected==i then
            ass[#ass+1]=menu_rect(x1+9,y-2,x2-9,y+row_h-4,MC_SELECTED,22)
            ass[#ass+1]=menu_rect(x1+9,y-2,x1+13,y+row_h-4,MC_COMMAND,0)
        end
        ass[#ass+1]=string.format(
            "{\\an7\\pos(%d,%d)\\fs%d\\b%d\\bord0\\shad0\\1c%s}Tone %d",
            x1+pad,y+5,fs,color_selected==i and 1 or 0,MC_COMMAND,i)

        local square=math.max(16,math.floor(22*scale+.5))
        local sx=x1+math.floor(panel_w*.47)
        local sy=y+math.floor((row_h-square)/2)-2
        ass[#ass+1]=menu_rect(sx,sy,sx+square,sy+square,hex_to_ass(color_working[i]),0)
        ass[#ass+1]=string.format(
            "{\\an9\\pos(%d,%d)\\fs%d\\b0\\bord0\\shad0\\1c%s}%s",
            x2-pad,y+7,fs,MC_KEY,ass_escape(color_working[i]))
    end

    local reset_y=rows_y+row_h*5+12
    if color_selected==6 then
        ass[#ass+1]=menu_rect(x1+9,reset_y-2,x2-9,reset_y+action_h-4,MC_SELECTED,22)
        ass[#ass+1]=menu_rect(x1+9,reset_y-2,x1+13,reset_y+action_h-4,MC_COMMAND,0)
    end
    ass[#ass+1]=string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b%d\\bord0\\shad0\\1c%s}RESET TO DEFAULTS",
        x1+pad,reset_y+7,fs,color_selected==6 and 1 or 0,MC_COMMAND)

    local config_y=reset_y+action_h
    if color_selected==7 then
        ass[#ass+1]=menu_rect(x1+9,config_y-2,x2-9,config_y+action_h-4,MC_SELECTED,22)
        ass[#ass+1]=menu_rect(x1+9,config_y-2,x1+13,config_y+action_h-4,MC_COMMAND,0)
    end
    ass[#ass+1]=string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b%d\\bord0\\shad0\\1c%s}OPEN CONFIG FILE",
        x1+pad,config_y+7,fs,color_selected==7 and 1 or 0,MC_COMMAND)

    local save_y=config_y+action_h
    if color_selected==8 then
        ass[#ass+1]=menu_rect(x1+9,save_y-2,x2-9,save_y+action_h-4,MC_SELECTED,22)
        ass[#ass+1]=menu_rect(x1+9,save_y-2,x1+13,save_y+action_h-4,MC_COMMAND,0)
    end
    ass[#ass+1]=string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b%d\\i%d\\bord0\\shad0\\1c%s}SAVE & EXIT%s",
        x1+pad,save_y+7,fs,color_selected==8 and 1 or 0,color_dirty and 1 or 0,
        color_dirty and MC_WHITE or MC_COMMAND,color_dirty and "  *" or "")

    local footer_y=save_y+action_h+7
    ass[#ass+1]=menu_rect(x1+pad,footer_y-4,x2-pad,footer_y-3,MC_BORDER,45)
    ass[#ass+1]=string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\b0\\i0\\bord0\\shad0\\1c%s}"..
        "↑↓ / TAB select   Ctrl+V paste   ENTER / SPACE action   ESC discard & close",
        x1+pad,footer_y+8,small,MC_MUTED)

    color_overlay.data=table.concat(ass,"\n")
    color_overlay:update()
end

local function color_unregister()
    for _,name in ipairs(color_handlers) do mp.remove_key_binding(name) end
    color_handlers={}
end

local function color_close_discard()
    if not color_menu_open then return end
    color_menu_open=false
    color_dirty=false
    color_working={}
    color_unregister()
    color_overlay.data=""
    color_overlay:update()
end

local function color_after_saved_palette_change()
    reload_tone_palette()
    if tones_enabled then
        operation_status=nil
        rebuild_from_original()
    end
end

local function stage_pasted_tone_color(value)
    if color_selected<1 or color_selected>5 then
        show_status("TONE COLORS","Select Tone 1-5 before pasting a color",true,2.5)
        return
    end
    value=normalize_hex(value)
    if not value then
        show_status("TONE COLORS","Clipboard must contain a #RRGGBB hex color",true,3)
        return
    end
    color_working[color_selected]=value
    color_menu_render()
end

local function color_reset_defaults()
    for i=1,5 do color_working[i]=DEFAULT_TONE_HEX[i] end
    color_menu_render()
end

local function write_working_palette()
    return rewrite_config(function(lines)
        local result={}
        local written={}
        for _,line in ipairs(lines) do
            local k=line:match("^%s*([^#=%s][^=]-)%s*=")
            local n=k and k:match("^tone_color_([1-5])$")
            if n then
                n=tonumber(n)
                if not written[n] then
                    result[#result+1]="tone_color_"..n.."="..color_working[n]
                    written[n]=true
                end
            else
                result[#result+1]=line
            end
        end
        for i=1,5 do
            if not written[i] then result[#result+1]="tone_color_"..i.."="..color_working[i] end
        end
        return result
    end)
end

local function color_save_and_exit()
    if not write_working_palette() then
        show_status("TONE COLORS","Could not save helska.conf",true,3)
        return
    end
    color_after_saved_palette_change()
    show_status("TONE COLORS","Colors saved",false,1.8)
    color_close_discard()
end

local function ensure_config_exists()
    if not ensure_tone_defaults_in_config() then return false end
    return true
end

local function open_config_file()
    if not ensure_config_exists() then
        show_status("TONE COLORS","Could not create helska.conf",true,3)
        return
    end
    local is_windows=package.config:sub(1,1)=="\\"
    local args
    if is_windows then
        args={"cmd","/c","start","","notepad",CONFIG}
    else
        local uname=utils.subprocess({args={"uname","-s"},cancellable=false})
        if uname.status==0 and uname.stdout and uname.stdout:match("Darwin") then
            args={"open","-e",CONFIG}
        else
            args={"xdg-open",CONFIG}
        end
    end
    mp.command_native_async({
        name="subprocess",playback_only=false,capture_stdout=true,capture_stderr=true,
        args=args,
    },function(success,result)
        if not success or not result or result.status~=0 then
            show_status("TONE COLORS","Could not open helska.conf",true,3)
        end
    end)
end

local function color_activate()
    if color_selected==6 then
        color_reset_defaults()
    elseif color_selected==7 then
        open_config_file()
    elseif color_selected==8 then
        color_save_and_exit()
    elseif color_selected>=1 and color_selected<=5 then
        show_status("TONE COLORS","Copy a #RRGGBB color, then press Ctrl+V",false,2.5)
    end
end

-- Register one palette hotkey as a FORCED key binding, exactly like Helska
-- Console and the subtitle-font picker. Forced is the highest priority mpv
-- accepts, so the palette reliably outranks the console's always-on forced
-- opener (TAB) and mpv's native defaults while it is open. (The previous
-- define-section/enable-section approach is deprecated in modern mpv and lost
-- the race against the console's forced opener, so TAB opened the console.)
-- Handlers run under pcall so a Lua error can never leave the palette holding
-- input (which would look exactly like a freeze).
local function add_color_hotkey(key,id,fn,repeatable)
    if type(fn)~="function" then
        mp.msg.error("helska tone colors: missing handler for key "..tostring(key))
        return
    end
    color_handler_serial=color_handler_serial+1
    local name="helska-tone-color-"..id.."-"..color_handler_serial
    mp.add_forced_key_binding(key,name,function(event)
        if event and event.event then
            local ok=event.event=="down" or event.event=="press"
                or (repeatable and event.event=="repeat")
            if not ok then return end
        end
        local ok,err=pcall(fn)
        if not ok then
            mp.msg.error("helska tone colors: "..tostring(err))
            color_close_discard()
        end
    end,{complex=true})
    color_handlers[#color_handlers+1]=name
end

local function color_paste_from_clipboard()
    if color_selected<1 or color_selected>5 then
        show_status("TONE COLORS","Select Tone 1-5 before pressing Ctrl+V",true,2.5)
        return
    end
    local is_windows=package.config:sub(1,1)=="\\"
    local args
    if is_windows then
        args={"powershell","-NoProfile","-NonInteractive","-Command","Get-Clipboard -Raw"}
    else
        local uname=utils.subprocess({args={"uname","-s"},cancellable=false})
        if uname.status==0 and uname.stdout and uname.stdout:match("Darwin") then
            args={"pbpaste"}
        else
            args={"wl-paste","--no-newline"}
        end
    end
    local result=utils.subprocess({args=args,cancellable=false})
    if (not result or result.status~=0) and not is_windows then
        result=utils.subprocess({args={"xclip","-selection","clipboard","-o"},cancellable=false})
    end
    if not result or result.status~=0 then
        show_status("TONE COLORS","Could not read clipboard",true,2.5)
        return
    end
    local pasted=tostring(result.stdout or ""):gsub("^%s+",""):gsub("%s+$","")
    stage_pasted_tone_color(pasted)
end

local function color_install_keys()
    color_unregister()
    local function move(delta)
        color_selected=color_selected+delta
        if color_selected<1 then color_selected=8 end
        if color_selected>8 then color_selected=1 end
        color_menu_render()
    end
    add_color_hotkey("UP","up",function() move(-1) end,true)
    add_color_hotkey("DOWN","down",function() move(1) end,true)
    add_color_hotkey("TAB","tab",function() move(1) end,true)
    add_color_hotkey("Shift+TAB","shift-tab",function() move(-1) end,true)
    add_color_hotkey("ENTER","enter",color_activate)
    add_color_hotkey("KP_ENTER","kp-enter",color_activate)
    add_color_hotkey("SPACE","space",color_activate)
    add_color_hotkey("Ctrl+v","paste",color_paste_from_clipboard)
    add_color_hotkey("Meta+v","paste-mac",color_paste_from_clipboard)
    add_color_hotkey("ESC","escape",color_close_discard)

    -- Swallow printable typing so it cannot leak to native bindings, and catch
    -- every remaining key so nothing escapes the menu (in particular TAB must
    -- never open Helska Console from inside the palette).
    add_color_hotkey("ANY_UNICODE","text",function() end,true)
    add_color_hotkey("UNMAPPED","unmapped",function() end,false)

    -- Swallow mouse buttons so a click cannot leak to other bindings, but do
    -- NOT dismiss the palette: auto-closing on any click annoyed users mid-edit.
    local mouse={"MBTN_LEFT","MBTN_RIGHT","MBTN_MID","MBTN_BACK","MBTN_FORWARD"}
    for i,key in ipairs(mouse) do
        add_color_hotkey(key,"mouse-"..i,function() end)
    end
end

local function open_tone_color_menu()
    if color_menu_open then return end
    ensure_tone_defaults_in_config()
    reload_tone_palette()
    for i=1,5 do color_working[i]=tone_hex[i] end
    color_selected=1
    color_dirty=false
    color_menu_open=true
    color_menu_render()
    color_install_keys()
end

local function toggle_tones()
    if not tones_enabled and not has_selected_subtitle() then
        operation_status=nil
        show_status("TONE COLORS",
            "No subtitle track selected - load or select a subtitle first",true,3)
        return
    end
    operation_status=nil
    tones_enabled=not tones_enabled
    rebuild_from_original()
    show_status("TONE COLORS",tones_enabled and "ON" or "OFF",false,1.5)
end

local function toggle_conversion()
    if not conversion_enabled and not has_selected_subtitle() then
        operation_status=nil
        show_status("HANZI CONVERT",
            "No subtitle track selected - load or select a subtitle first",true,3)
        return
    end
    local was_converted=conversion_enabled
    conversion_enabled=not conversion_enabled

    if was_converted and not conversion_enabled then
        local detail=conversion_label(source_conversion_direction,true)
        if tones_enabled then
            operation_status={
                title=detail,
                detail="CHINESE + TONE COLORS".." - regenerating tone colors"
            }
            show_status(operation_status.title,operation_status.detail,false,0)
        else
            operation_status=nil
            show_status(detail,"CHINESE CONVERT",false,2.5)
        end
    else
        operation_status=nil
    end

    rebuild_from_original()
end

mp.register_script_message("toggle-tones",toggle_tones)
mp.register_script_message("convert",toggle_conversion)
mp.register_script_message("toggle-convert",toggle_conversion)

-- Optional integration with helska_subtitle-font.lua. The font switcher only
-- broadcasts this message; it has no dependency on this script. If a generated
-- Chinese subtitle is active, rebuild that ONE derivative from the untouched
-- source so tone colors and/or converted Hanzi use the new font immediately.
mp.register_script_message("helska-subtitle-font-changed", function()
    if not (tones_enabled or conversion_enabled) then return end

    operation_status=nil
    rebuild_from_original()

    if tones_enabled and conversion_enabled then
        show_status("CHINESE + TONE COLORS",
            "Subtitle font changed - regenerating converted Hanzi + tone colors",
            false,0)
    elseif tones_enabled then
        show_status("TONE COLORS",
            "Subtitle font changed - regenerating tone colors",
            false,0)
    elseif conversion_enabled then
        show_status("HANZI CONVERT",
            "Subtitle font changed - regenerating converted Hanzi",
            false,0)
    end
end)

----------------------------------------------------------------------
-- SUBTITLE-TRACK CHANGES
----------------------------------------------------------------------

local function rebuild_for_selected_track()
    if not enabled then return end

    local selected = mp.get_property_number("sid")
    if not selected then
        generation_serial = generation_serial + 1
        remove_generated_track()
        source_sid = nil
        mode = nil
        return
    end

    -- Selecting our generated ASS is an internal implementation detail, not a
    -- user request to recolor another track.
    if generated_sid and tonumber(selected) == tonumber(generated_sid) then
        return
    end

    generation_serial = generation_serial + 1

    -- A user-selected track becomes the new source of truth. Remove the old
    -- generated track only after remembering that source selection.
    source_sid = selected
    source_conversion_direction=nil
    source_conversion_sid=nil
    remove_generated_track()
    mp.set_property_number("sid", selected)
    mp.set_property("sub-visibility", "yes")

    -- source_sid/current sid are the user's selected uncolored track and
    -- determine which track is processed.
    start()
end

mp.observe_property("sid", "number", function(_, value)
    if not enabled or switching_to_generated then return end
    if generated_sid and value and tonumber(value) == tonumber(generated_sid) then return end

    -- mpv can emit several track-list/sid changes around one user action.
    -- Debounce them into one rebuild and invalidate any conversion already
    -- running so a stale result can never take over later.
    generation_serial = generation_serial + 1
    if track_change_timer then track_change_timer:kill() end
    track_change_timer = mp.add_timeout(0.12, function()
        track_change_timer = nil
        rebuild_for_selected_track()
    end)
end)

-- If a new file loads while tone coloring is enabled, rebuild for its selected
-- external subtitle after mpv has had a moment to finish subtitle autoloading.
mp.register_event("file-loaded",function()
    if not enabled then return end
    generation_serial=generation_serial+1
    remove_generated_track()
    source_sid=nil
    source_secondary_sid=nil
    mp.add_timeout(0.35,function()
        if enabled then start() end
    end)
end)

local function advertise()
    local owner=mp.get_script_name()
    mp.commandv("script-message","helska-console-begin-owner",owner)
    mp.commandv("script-message","helska-console-register",owner,"CHINESE",
        ACTION_NAME,DEFAULT_KEY,"toggle automatic Mandarin tone coloring (uses a temporary subtitle-track)","45","1")
    mp.commandv("script-message","helska-console-register",owner,"CHINESE",
        CONVERT_ACTION,CONVERT_DEFAULT_KEY,"toggle between traditional and simplified Chinese characters (uses a temporary subtitle-track)","45","2")
    mp.commandv("script-message","helska-console-register",owner,"CHINESE",
        COLOR_ACTION,COLOR_DEFAULT_KEY,"customize Mandarin tone colors","45","3")
    mp.commandv("script-message","helska-console-end-owner",owner)
end
mp.register_script_message("helska-console-discover",advertise)
mp.register_script_message("open-tone-colors",open_tone_color_menu)
mp.register_script_message("helska-console-run",function(name)
    if name==ACTION_NAME then toggle_tones()
    elseif name==CONVERT_ACTION then toggle_conversion()
    elseif name==COLOR_ACTION then open_tone_color_menu() end
end)
mp.register_script_message("helska-console-reload-bindings",install_binding)

mp.register_event("shutdown",function()
    status:remove()
    generation_serial=generation_serial+1
    if track_change_timer then track_change_timer:kill(); track_change_timer=nil end
    remove_generated_track()
end)

install_binding()
advertise()

-- Pause our hotkeys while the Console owns input.
mp.register_script_message("helska-console-focus", function(state)
    if state == "on" then
        mp.remove_key_binding(BINDING_NAME)
        mp.remove_key_binding(CONVERT_BINDING_NAME)
        mp.remove_key_binding(COLOR_BINDING_NAME)
    elseif state == "off" then
        install_binding()
    end
end)
