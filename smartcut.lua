-- smartcut.lua - MPV script for lossless video cutting (smartcut) and cropped clips (FFmpeg) with OSD Menu
local options = require 'mp.options'
local utils = require 'mp.utils'

-- Default options
local opts = {
    ffmpeg_path = "ffmpeg",
    smartcut_path = "smartcut",
    output_dir = "~/Videos",
    filename_template = "clip_%Y-%m-%d_%H-%M-%S",
    
    default_cut_mode = "smartcut",
    default_crop_mode = "mp4"
}

-- Load config from script-opts/smartcut.conf
options.read_options(opts, "smartcut")

local profiles = {}
local profiles_file = mp.command_native({"expand-path", "~~/script-opts/smartcut_profiles.json"})

local function load_profiles()
    local f = io.open(profiles_file, "r")
    if not f then
        print("smartcut: Error: Could not find smartcut_profiles.json in script-opts!")
        return
    end

    local content = f:read("*all")
    f:close()
    
    local parsed, err = utils.parse_json(content)
    if not parsed then
        print("smartcut: Failed to parse JSON profiles: " .. tostring(err))
        return
    end

    profiles = {}
    local seen_ids = {}

    for i, p in ipairs(parsed) do
        local profile_errs = {}
        
        if type(p) ~= "table" then
            table.insert(profile_errs, "not an object")
        else
            if type(p.id) ~= "string" then table.insert(profile_errs, "missing/invalid 'id'") end
            if type(p.name) ~= "string" then table.insert(profile_errs, "missing/invalid 'name'") end
            if p.type ~= "smartcut" and p.type ~= "ffmpeg" then table.insert(profile_errs, "invalid 'type'") end
            if type(p.ext) ~= "string" then table.insert(profile_errs, "missing/invalid 'ext'") end
            if p.args and type(p.args) ~= "table" then table.insert(profile_errs, "invalid 'args'") end
            if p.mode then
                if type(p.mode) ~= "string" or (p.mode ~= "smartcut" and p.mode ~= "keyframes") then
                    table.insert(profile_errs, "invalid 'mode'")
                end
            end
            if p.vf and type(p.vf) ~= "string" then table.insert(profile_errs, "invalid 'vf'") end

            if type(p.id) == "string" then
                if seen_ids[p.id] then
                    table.insert(profile_errs, "duplicate id '" .. p.id .. "'")
                else
                    seen_ids[p.id] = true
                end
            end
        end

        if #profile_errs > 0 then
            local pid = (type(p) == "table" and type(p.id) == "string") and p.id or ("#" .. tostring(i))
            local err_msg = table.concat(profile_errs, ", ")
            
            if type(p) ~= "table" then p = {} end
            p.id = (type(p.id) == "string" and p.id ~= "") and p.id or pid
            p.name = (type(p.name) == "string" and p.name ~= "") and p.name or "Broken Profile"
            p.broken = err_msg
            
            print("smartcut: Loaded broken profile '" .. p.id .. "': " .. err_msg)
            table.insert(profiles, p)
        else
            table.insert(profiles, p)
        end
    end
end

load_profiles()

local start_time = nil
local end_time = nil

local screen_x1 = nil
local screen_y1 = nil
local screen_x2 = nil
local screen_y2 = nil

local crop_mode_active = false
local first_point_set = false
local drag_start_x = nil
local drag_start_y = nil
local drag_timer = nil

local overlay = mp.create_osd_overlay("ass-events")
local menu_overlay = mp.create_osd_overlay("ass-events")
menu_overlay.z = 100
local render_overlay = mp.create_osd_overlay("ass-events")
render_overlay.z = 200
local menu_active = false
local menu_options = {}
local menu_sel = 1

local active_renders = 0

local function show_render_progress(text)
    active_renders = active_renders + 1
    local w, h = mp.get_osd_size()
    if w and h then
        render_overlay.res_x = w
        render_overlay.res_y = h
        local msg = text
        if active_renders > 1 then
            msg = msg .. " (+" .. (active_renders - 1) .. " more)"
        end
        render_overlay.data = "{\\an9\\pos(" .. (w - 25) .. ",25)\\fs24\\b1\\1c&HFFFFFF&}⏳ " .. msg
        render_overlay:update()
    end
end

local function hide_render_progress()
    active_renders = math.max(0, active_renders - 1)
    if active_renders == 0 then
        render_overlay.data = ""
        render_overlay:update()
    else
        local w, h = mp.get_osd_size()
        if w and h then
            render_overlay.res_x = w
            render_overlay.res_y = h
            render_overlay.data = "{\\an9\\pos(" .. (w - 25) .. ",25)\\fs24\\b1\\1c&HFFFFFF&}⏳ " .. active_renders .. " render(s) in progress..."
            render_overlay:update()
        end
    end
end

local draw_menu
local update_menu_options
local check_active_state
local cancel_all
local undo_timecode
local set_osc_visibility
local refresh_ui

local function check_config()
    if #profiles == 0 then
        mp.osd_message("Error: No profiles loaded! Check smartcut_profiles.json", 5)
        return false
    end
    return true
end

local function get_home()
    return os.getenv("USERPROFILE") or os.getenv("HOME") or "."
end

local function resolve_path(path)
    if path:sub(1, 1) == "~" then
        path = get_home() .. path:sub(2)
    end
    path = path:gsub("\\", "/")
    return path
end

local function ensure_dir(dir)
    if not dir or dir == "" then return end
    local info = utils.file_info(dir)
    if info and info.is_dir then return end
    
    if package.config:sub(1, 1) == "\\" then
        -- Windows
        mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = {"cmd", "/c", "mkdir", dir:gsub("/", "\\")}
        })
    else
        -- Unix / Linux / macOS
        mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = {"mkdir", "-p", dir}
        })
    end
end

local function format_time(seconds)
    if not seconds then return "00:00:00.000" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    local ms = math.floor((seconds * 1000) % 1000)
    return string.format("%02d:%02d:%02d.%03d", h, m, s, ms)
end

local function update_time_overlay()
    if not start_time then
        menu_overlay.data = ""
        menu_overlay:update()
        return
    end
    local start_str = format_time(start_time)
    local end_str = end_time and format_time(end_time) or "..."
    local ass = "{\\an7\\pos(25,200)\\fs28\\b1\\1c&HFFFFFF&}" .. start_str .. " - " .. end_str
    
    ass = ass .. "\\N{\\fs18\\b0\\1c&H999999&}[x] Mark  ·  [X] Render  ·  [n] Menu  ·  [r] Crop"
    ass = ass .. "\\N{\\fs18\\b0\\1c&H999999&}[BS] Undo  ·  [Esc] Cancel"
    
    menu_overlay.data = ass
    menu_overlay:update()
end

refresh_ui = function()
    if crop_mode_active then
        menu_overlay.data = ""
        menu_overlay:update()
    elseif menu_active then
        draw_menu()
    else
        update_time_overlay()
    end
end

check_active_state = function()
    local is_active = start_time or menu_active or crop_mode_active or screen_x1
    
    if is_active then
        mp.add_forced_key_binding("ESC", "smartcut-cancel", cancel_all)
        if start_time then
            mp.add_forced_key_binding("BS", "smartcut-undo", undo_timecode)
        else
            mp.remove_key_binding("smartcut-undo")
        end
    else
        mp.remove_key_binding("smartcut-cancel")
        mp.remove_key_binding("smartcut-undo")
    end
end

cancel_all = function()
    if menu_active then
        menu_active = false
        mp.remove_key_binding("menu-up")
        mp.remove_key_binding("menu-down")
        mp.remove_key_binding("menu-enter")
    end
    
    if crop_mode_active or screen_x1 then
        crop_mode_active = false
        first_point_set = false
        if drag_timer then
            drag_timer:kill()
            drag_timer = nil
        end
        mp.remove_key_binding("smartcut-click")
        screen_x1, screen_y1, screen_x2, screen_y2 = nil, nil, nil, nil
        overlay.data = ""
        overlay:update()
        set_osc_visibility("auto")
    end
    
    start_time = nil
    end_time = nil
    
    refresh_ui()
    check_active_state()
end

undo_timecode = function()
    if end_time then
        end_time = nil
    elseif start_time then
        start_time = nil
    end
    refresh_ui()
    check_active_state()
end

-- Calculate video actual bounds relative to OSD size (for letterbox/pillarbox)
local function get_video_display_rect()
    local video_w = mp.get_property_number("video-out-params/w")
    local video_h = mp.get_property_number("video-out-params/h")
    local osd_w, osd_h = mp.get_osd_size()
    
    if not video_w or not video_h or not osd_w or not osd_h then
        return nil
    end
    
    local video_aspect = video_w / video_h
    local osd_aspect = osd_w / osd_h
    
    local display_w, display_h, offset_x, offset_y
    if osd_aspect > video_aspect then
        display_h = osd_h
        display_w = osd_h * video_aspect
        offset_x = (osd_w - display_w) / 2
        offset_y = 0
    else
        display_w = osd_w
        display_h = osd_w / video_aspect
        offset_x = 0
        offset_y = (osd_h - display_h) / 2
    end
    
    return {
        x = offset_x,
        y = offset_y,
        w = display_w,
        h = display_h,
        video_w = video_w,
        video_h = video_h
    }
end

-- Convert screen coordinate to video space coordinate
local function screen_to_video(sx, sy, rect)
    local cx = math.max(rect.x, math.min(rect.x + rect.w, sx))
    local cy = math.max(rect.y, math.min(rect.y + rect.h, sy))
    
    local rx = (cx - rect.x) / rect.w
    local ry = (cy - rect.y) / rect.h
    
    local vx = math.floor(rx * rect.video_w)
    local vy = math.floor(ry * rect.video_h)
    
    return vx, vy
end

local function draw_crop_box(x1, y1, x2, y2)
    local min_x = math.floor(math.min(x1, x2))
    local max_x = math.floor(math.max(x1, x2))
    local min_y = math.floor(math.min(y1, y2))
    local max_y = math.floor(math.max(y1, y2))
    
    local box_w = max_x - min_x
    local box_h = max_y - min_y
    
    local w, h = mp.get_osd_size()
    if not w or not h or w == 0 or h == 0 then return end
    
    overlay.res_x = w
    overlay.res_y = h
    
    -- 1. Dimmed background (dark overlay with a hole for the crop area)
    local dim_ass = string.format(
        "{\\an7\\pos(0,0)\\1c&H000000&\\1a&H88&\\bord0\\iclip(%d,%d,%d,%d)\\p1}m 0 0 l %d 0 l %d %d l 0 %d l 0 0{\\p0}",
        min_x, min_y, max_x, max_y,
        w, w, h, h
    )
    
    -- 2. Clean, sharp border (drawn by filling the box area and clipping out the inside)
    local bt = math.max(2, math.floor(h / 400)) -- Dynamic border thickness
    local border_ass = ""
    
    if box_w > bt * 2 and box_h > bt * 2 then
        border_ass = string.format(
            "{\\an7\\pos(%d,%d)\\1c&HFFDD00&\\1a&H00&\\bord0\\iclip(%d,%d,%d,%d)\\p1}m 0 0 l %d 0 l %d %d l 0 %d l 0 0{\\p0}",
            min_x, min_y,
            min_x + bt, min_y + bt, max_x - bt, max_y - bt,
            box_w, box_w, box_h, box_h
        )
    end
    
    if border_ass ~= "" then
        overlay.data = dim_ass .. "\n" .. border_ass
    else
        overlay.data = dim_ass
    end
    
    overlay:update()
end


local original_osd_level = nil
local restore_osd_timer = nil

set_osc_visibility = function(mode)
    if not original_osd_level then
        original_osd_level = mp.get_property("osd-level")
    end
    
    mp.set_property("osd-level", 0)
    mp.commandv("script-message", "osc-visibility", mode)
    
    if restore_osd_timer then
        restore_osd_timer:kill()
    end
    
    restore_osd_timer = mp.add_timeout(0.05, function()
        if original_osd_level then
            mp.set_property("osd-level", original_osd_level)
            original_osd_level = nil
        end
        restore_osd_timer = nil
    end)
end

local function click_handler()
    if not first_point_set then
        -- First click: start drag
        drag_start_x, drag_start_y = mp.get_mouse_pos()
        first_point_set = true
        
        if drag_timer then drag_timer:kill() end
        drag_timer = mp.add_periodic_timer(1/60, function()
            local mx, my = mp.get_mouse_pos()
            draw_crop_box(drag_start_x, drag_start_y, mx, my)
        end)
    else
        -- Second click: finish crop
        if drag_timer then
            drag_timer:kill()
            drag_timer = nil
        end
        local mx, my = mp.get_mouse_pos()
        draw_crop_box(drag_start_x, drag_start_y, mx, my)
        
        screen_x1 = drag_start_x
        screen_y1 = drag_start_y
        screen_x2 = mx
        screen_y2 = my
        
        -- Deactivate crop mode but keep the frame
        crop_mode_active = false
        first_point_set = false
        
        -- Stop intercepting mouse clicks
        mp.remove_key_binding("smartcut-click")
        
        -- Restore OSC visibility silently
        set_osc_visibility("auto")
        
        update_menu_options()
        refresh_ui()
        check_active_state()
    end
end

local function toggle_crop_mode()
    if not check_config() then return end

    if not crop_mode_active then
        -- If a crop area is already drawn, just clear it and don't enter crop mode yet
        if screen_x1 then
            screen_x1, screen_y1, screen_x2, screen_y2 = nil, nil, nil, nil
            overlay.data = ""
            overlay:update()
            
            update_menu_options()
            refresh_ui()
            check_active_state()
            return
        end
        
        crop_mode_active = true
        first_point_set = false
        mp.add_forced_key_binding("mbtn_left", "smartcut-click", click_handler)
        
        update_menu_options()
        refresh_ui()
        check_active_state()
        
        -- Hide the default On-Screen Controller (OSC) completely and silently
        set_osc_visibility("never")
        
        local w, h = mp.get_osd_size()
        if w and h then
            overlay.res_x = w
            overlay.res_y = h
            overlay.data = string.format(
                "{\\an7\\pos(0,0)\\1c&H000000&\\1a&H88&\\bord0\\p1}m 0 0 l %d 0 l %d %d l 0 %d l 0 0{\\p0}",
                w, w, h, h
            )
            overlay:update()
        end

    else
        crop_mode_active = false
        first_point_set = false
        if drag_timer then
            drag_timer:kill()
            drag_timer = nil
        end
        mp.remove_key_binding("smartcut-click")
        overlay.data = ""
        overlay:update()
        screen_x1, screen_y1, screen_x2, screen_y2 = nil, nil, nil, nil
        
        set_osc_visibility("auto")
        
        update_menu_options()
        refresh_ui()
        
        check_active_state()
    end
end

-- Key binding to toggle start/end timecodes

local function mark_time()
    if not check_config() then return end

    local pos = mp.get_property_number("time-pos")
    if not pos then
        mp.osd_message("Error: Could not get current position")
        return
    end

    if start_time and end_time then
        -- Both timecodes already set, do not overwrite. User must use [BS] to undo first.
        return
    elseif not start_time then
        start_time = pos
        end_time = nil
    else
        if pos <= start_time then
            mp.osd_message("Error: End time must be after start time", 3)
            return
        else
            end_time = pos
        end
    end
    
    refresh_ui()
    check_active_state()
end

local function escape_filter_path(path)
    -- Normalize backslashes to forward slashes to avoid escaping issues
    path = path:gsub("\\", "/")
    -- Escape colons (e.g. C: -> C\:)
    path = path:gsub(":", "\\:")
    -- Escape single quotes (e.g. ' -> \')
    path = path:gsub("'", "\\'")
    return path
end

-- Retrieve active track FFmpeg index by type ("video" or "audio")
local function get_active_track_ff_index(track_type)
    local prop = (track_type == "video") and "vid" or "aid"
    local tid = mp.get_property(prop)
    if not tid or tid == "no" or tid == "auto" then return nil end
    tid = tonumber(tid)
    if not tid then return nil end

    local track_list = mp.get_property_native("track-list")
    if not track_list then return nil end

    for _, track in ipairs(track_list) do
        if track.type == track_type and track.id == tid then
            return track["ff-index"]
        end
    end
    return nil
end

local function get_active_sub_info()
    local sub_vis = mp.get_property_native("sub-visibility")
    if sub_vis == false then
        return nil
    end

    local sid = mp.get_property("sid")
    if not sid or sid == "no" or sid == "auto" then
        return nil
    end
    
    sid = tonumber(sid)
    if not sid then
        return nil
    end

    local track_list = mp.get_property_native("track-list")
    if not track_list then
        return nil
    end

    local internal_sub_idx = 0
    for _, track in ipairs(track_list) do
        if track.type == "sub" then
            if track.id == sid then
                if track.external then
                    return {
                        external = true,
                        filename = track["external-filename"]
                    }
                else
                    return {
                        external = false,
                        si = internal_sub_idx
                    }
                end
            end
            if not track.external then
                internal_sub_idx = internal_sub_idx + 1
            end
        end
    end
    return nil
end

local function execute_render(args, filename, msg)
    cancel_all()
    show_render_progress(msg)

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = args
    }, function(success, result, error)
        hide_render_progress()
        if success and result and result.status == 0 then
            mp.osd_message("Clip created successfully!\nSaved to: " .. filename, 5)
            print("smartcut: Render completed successfully.")
        else
            local err_msg = "Error creating clip!"
            if result and result.stderr then
                err_msg = err_msg .. "\n" .. result.stderr
            end
            mp.osd_message(err_msg, 7)
            print("smartcut: Render failed. Status: " .. (result and result.status or "nil") .. ", Error: " .. (error or "nil"))
        end
    end)
end

-- Actual render execution logic
local function run_render(profile_id)
    local profile = nil
    for _, p in ipairs(profiles) do
        if p.id == profile_id then profile = p; break end
    end
    if not profile then
        mp.osd_message("Error: Profile '" .. tostring(profile_id) .. "' not found. Check config!", 5)
        return
    end


    local input_path = mp.get_property("path")
    if not input_path or input_path == "" then
        mp.osd_message("Error: No file currently playing", 3)
        return
    end

    -- Resolve relative input path
    if not input_path:match("^%a+:") and not input_path:match("^/") and not input_path:match("^\\") then
        local working_dir = mp.get_property("working-directory")
        if working_dir then
            input_path = working_dir .. "/" .. input_path
        end
    end

    local has_crop = (screen_x1 and screen_y1 and screen_x2 and screen_y2)

    local ext = profile.ext
    if ext == "auto" then
        ext = input_path:match("^.+(%.[^.]+)$") or ".mkv"
    elseif ext:sub(1,1) ~= "." then
        ext = "." .. ext
    end
    local output_dir = resolve_path(opts.output_dir)
    ensure_dir(output_dir)
    local filename = os.date(opts.filename_template) .. ext
    local output_path = output_dir .. "/" .. filename

    local mute = mp.get_property_native("mute")
    local vol = mp.get_property_number("volume")
    local aid_prop = mp.get_property_native("aid")
    local drop_audio = (mute == true) or (vol and vol <= 0) or (aid_prop == "no" or aid_prop == false or aid_prop == nil)

    if profile.type == "smartcut" then

        local msg = "Rendering lossless clip (" .. profile.name .. ")..."
        print("smartcut: Running smartcut...")
        print("smartcut: Input: " .. input_path)
        print("smartcut: Output: " .. output_path)


        local args = {
            resolve_path(opts.smartcut_path),
            input_path,
            output_path,
            "-k",
            tostring(start_time) .. "," .. tostring(end_time)
        }

        if profile.mode then
            table.insert(args, "-m")
            table.insert(args, profile.mode)
        end

        if drop_audio then
            table.insert(args, "-a")
            table.insert(args, "-1")
            print("smartcut: Auto-detected muted/no audio. Passing -a -1 to drop audio.")
        else
            local aid_num = mp.get_property_number("aid")
            if aid_num then
                table.insert(args, "-a")
                table.insert(args, tostring(aid_num - 1))
                print("smartcut: Currently playing audio track: " .. aid_num .. " (0-based index: " .. (aid_num - 1) .. ")")
            end
        end



        execute_render(args, filename, msg)
    elseif profile.type == "ffmpeg" then
        -- FFmpeg crop or encode
        local rect = nil
        local crop_w, crop_h, crop_x, crop_y = nil, nil, nil, nil

        if has_crop then
            rect = get_video_display_rect()
            if not rect then
                mp.osd_message("Error: Could not calculate video coordinates", 3)
                return
            end

            local vx1, vy1 = screen_to_video(screen_x1, screen_y1, rect)
            local vx2, vy2 = screen_to_video(screen_x2, screen_y2, rect)

            crop_w = math.abs(vx2 - vx1)
            crop_h = math.abs(vy2 - vy1)
            crop_x = math.min(vx1, vx2)
            crop_y = math.min(vy1, vy2)

            if crop_w == 0 or crop_h == 0 then
                mp.osd_message("Error: Invalid crop area width/height", 3)
                return
            end
        end

        -- Check for active subtitles to burn in
        local sub_info = get_active_sub_info()

        local msg = "Rendering clip"
        if has_crop then
            msg = "Rendering cropped clip"
        end
        if sub_info then msg = msg .. " with subtitles" end
        msg = msg .. " (" .. profile.name .. ")..."
        
        if has_crop then
            print("smartcut: Running crop...")
            print("smartcut: Crop filter: crop=" .. crop_w .. ":" .. crop_h .. ":" .. crop_x .. ":" .. crop_y)
        else
            print("smartcut: Running encode (no crop)...")
        end
        print("smartcut: Format: " .. profile.name)
        print("smartcut: Input: " .. input_path)
        print("smartcut: Output: " .. output_path)


        -- Construct ffmpeg arguments
        local args = { resolve_path(opts.ffmpeg_path), "-y", "-hide_banner", "-loglevel", "error" }

        -- Time input arguments (placed before input for fast seeking)
        table.insert(args, "-ss")
        table.insert(args, tostring(start_time))
        table.insert(args, "-to")
        table.insert(args, tostring(end_time))
        table.insert(args, "-i")
        table.insert(args, input_path)

        -- Map correct streams
        local ff_video_idx = get_active_track_ff_index("video")
        local ff_audio_idx = get_active_track_ff_index("audio")

        if ff_video_idx then
            table.insert(args, "-map")
            table.insert(args, "0:" .. ff_video_idx)
        end
        if ff_audio_idx and not drop_audio then
            table.insert(args, "-map")
            table.insert(args, "0:" .. ff_audio_idx)
        end

        -- Format specific arguments
        local vf_items = {}
        
        if has_crop then
            table.insert(vf_items, "crop=" .. crop_w .. ":" .. crop_h .. ":" .. crop_x .. ":" .. crop_y)
        end
        if sub_info then
            local sub_filter = ""
            if sub_info.external then
                sub_filter = "subtitles='" .. escape_filter_path(sub_info.filename) .. "'"
            else
                sub_filter = "subtitles='" .. escape_filter_path(input_path) .. "':si=" .. sub_info.si
            end
            
            -- Fix subtitle sync: since we use -ss before -i, video frames start at PTS 0.
            -- We temporarily shift the video timestamps forward by start_time so the subtitles
            -- filter burns the correct text, then we normalize them back to 0.
            table.insert(vf_items, "setpts=PTS+" .. tostring(start_time) .. "/TB")
            table.insert(vf_items, sub_filter)
            table.insert(vf_items, "setpts=PTS-STARTPTS")
        end
        
        if profile.vf and type(profile.vf) == "string" then
            table.insert(vf_items, profile.vf)
        end
        
        if #vf_items > 0 then
            table.insert(args, "-vf")
            table.insert(args, table.concat(vf_items, ","))
        end

        if profile.args and type(profile.args) == "table" then
            for _, arg in ipairs(profile.args) do
                table.insert(args, arg)
            end
        end



        table.insert(args, output_path)

        execute_render(args, filename, msg)
    end
end

update_menu_options = function()
    local has_crop = (screen_x1 and screen_y1 and screen_x2 and screen_y2)
    local def = has_crop and opts.default_crop_mode:lower() or opts.default_cut_mode:lower()
    menu_options = {}
    
    for _, p in ipairs(profiles) do
        if not has_crop or p.type == "ffmpeg" or p.broken then
            table.insert(menu_options, p.id)
        end
    end
    
    menu_sel = 1
    for i, opt in ipairs(menu_options) do
        if opt == def then 
            menu_sel = i
            break 
        end
    end
end

-- OSD Menu Drawing function
draw_menu = function()
    local has_crop = (screen_x1 and screen_y1 and screen_x2 and screen_y2)
    local w, h = mp.get_osd_size()
    if w and h then
        menu_overlay.res_x = w
        menu_overlay.res_y = h
    end
    
    -- Base style: Top-left, lowered to prevent overlap with standard mp.osd_message
    local ass = "{\\an7\\pos(25,200)}"
    
    -- Title
    ass = ass .. "{\\fs32\\b1\\1c&HFFFFFF&}SMARTCUT {\\b0\\1c&HAAAAAA&}MENU{\\b0}\\N"
    
    -- Mode indicator
    if has_crop then
        ass = ass .. "{\\fs20\\1c&H77FF77&}● Cropping Active{\\1c&HFFFFFF&}\\N"
    else
        ass = ass .. "{\\fs20\\1c&H00A5FF&}● Full-Frame Mode{\\1c&HFFFFFF&}\\N"
    end
    
    if start_time then
        local start_str = format_time(start_time)
        local end_str = end_time and format_time(end_time) or "..."
        ass = ass .. "{\\fs28\\b1\\1c&HFFFFFF&}" .. start_str .. " - " .. end_str .. "\\N"
    else
        ass = ass .. "{\\fs28\\b1\\1c&H666666&}No Timecodes Set\\N"
    end
    
    ass = ass .. "{\\fs18\\b0\\1c&H999999&}[x] Mark  ·  [r] Crop  ·  [BS] Undo\\N\\N"
    
    -- Options
    for i, opt_id in ipairs(menu_options) do
        local profile = nil
        for _, p in ipairs(profiles) do
            if p.id == opt_id then profile = p; break end
        end
        local desc = profile and profile.name or opt_id

        if profile and profile.broken then
            if i == menu_sel then
                ass = ass .. "{\\fs30\\1c&H0000FF&\\b1}▶  " .. opt_id:upper() .. "  {\\fs22\\1c&H0000AA&\\b0}[BROKEN] " .. desc .. "{\\1c&HFFFFFF&}\\N"
            else
                ass = ass .. "{\\fs28\\1c&H5555FF&}    " .. opt_id:upper() .. "  {\\fs20\\1c&H5555AA&}[BROKEN] " .. desc .. "{\\1c&HFFFFFF&}\\N"
            end
        else
            if i == menu_sel then
                -- Selected item: Yellow accent, bold
                ass = ass .. "{\\fs30\\1c&HFFDD00&\\b1}▶  " .. opt_id:upper() .. "  {\\fs22\\1c&HDDDDDD&\\b0}" .. desc .. "{\\1c&HFFFFFF&}\\N"
            else
                -- Unselected item: White
                ass = ass .. "{\\fs28\\1c&HFFFFFF&}    " .. opt_id:upper() .. "  {\\fs20\\1c&H888888&}" .. desc .. "{\\1c&HFFFFFF&}\\N"
            end
        end
    end
    
    -- Show disabled options if cropping
    if has_crop then
        for _, p in ipairs(profiles) do
            if p.type ~= "ffmpeg" and not p.broken then
                ass = ass .. "{\\fs22\\1c&H555555&}    " .. p.id:upper() .. "  (Requires Full-Frame)\\N"
            end
        end
    end
    
    -- Footer controls
    ass = ass .. "\\N{\\fs18\\1c&H999999&}[↑/↓] Navigate  ·  [Enter] Render  ·  [Esc] Close"
    
    menu_overlay.data = ass
    menu_overlay:update()
end
local function close_menu()
    mp.remove_key_binding("menu-up")
    mp.remove_key_binding("menu-down")
    mp.remove_key_binding("menu-enter")
    menu_active = false
    refresh_ui()
    check_active_state()
    print("smartcut: Menu closed.")
end

local function menu_up()
    if not menu_active then return end
    menu_sel = menu_sel - 1
    if menu_sel < 1 then
        menu_sel = #menu_options
    end
    refresh_ui()
end

local function menu_down()
    if not menu_active then return end
    menu_sel = menu_sel + 1
    if menu_sel > #menu_options then
        menu_sel = 1
    end
    refresh_ui()
end

local function validate_render_ready()
    if not check_config() then return false end
    
    if not start_time or not end_time then
        mp.osd_message("Error: Set start and end times first!", 3)
        return false
    end
    return true
end

local function menu_enter()
    if not menu_active then return end
    if not validate_render_ready() then return end
    local selected_format = menu_options[menu_sel]
    
    local profile = nil
    for _, p in ipairs(profiles) do
        if p.id == selected_format then profile = p; break end
    end
    
    if profile and profile.broken then
        mp.osd_message("Error: Profile '" .. profile.id .. "' is broken: " .. profile.broken, 5)
        return
    end

    close_menu()
    run_render(selected_format)
end

-- Key binding to toggle format selection menu
local function toggle_menu()
    if not check_config() then return end

    if menu_active then
        close_menu()
        return
    end

    update_menu_options()

    menu_active = true
    refresh_ui()

    mp.add_forced_key_binding("UP", "menu-up", menu_up)
    mp.add_forced_key_binding("DOWN", "menu-down", menu_down)
    mp.add_forced_key_binding("ENTER", "menu-enter", menu_enter)
    
    check_active_state()
    print("smartcut: Menu opened.")
end

-- Key binding to confirm and run clip generation with default mode
local function make_clip()
    if menu_active then
        return
    end

    if not validate_render_ready() then
        return
    end

    local has_crop = (screen_x1 and screen_y1 and screen_x2 and screen_y2)
    local target_format
    if has_crop then
        target_format = opts.default_crop_mode:lower()
        local valid = false
        for _, p in ipairs(profiles) do
            if p.id == target_format and p.type == "ffmpeg" and not p.broken then
                valid = true
                break
            end
        end
        if not valid then
            target_format = "mp4"
        end
    else
        target_format = opts.default_cut_mode:lower()
    end

    local profile = nil
    for _, p in ipairs(profiles) do
        if p.id == target_format then profile = p; break end
    end
    if profile and profile.broken then
        mp.osd_message("Error: Profile '" .. profile.id .. "' is broken: " .. profile.broken, 5)
        return
    end

    run_render(target_format)
end

mp.add_key_binding("x", "smartcut-mark", mark_time)
mp.add_key_binding("r", "smartcut-crop", toggle_crop_mode)
mp.add_key_binding("X", "smartcut-cut", make_clip)
mp.add_key_binding("n", "smartcut-menu", toggle_menu)
