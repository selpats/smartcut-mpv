-- smartcut.lua - MPV script for lossless video cutting (smartcut) and cropped clips (FFmpeg) with OSD Menu
local options = require 'mp.options'
local utils = require 'mp.utils'

-- Default options
local opts = {
    ffmpeg_path = "ffmpeg",
    smartcut_path = "smartcut",
    output_dir = "~/Videos",
    filename_template = "clip_%Y-%m-%d_%H-%M-%S",
    mark_key = "c",
    crop_key = "r",
    cut_key = "C",
    menu_key = "n",
    
    default_cut_mode = "smartcut",
    default_crop_mode = "mp4",
    
    -- MP4 settings
    vcodec = "libx264",
    crf = "18",
    vpreset_mp4 = "medium",
    acodec = "copy",
    
    -- AVIF settings
    crf_avif = "30",
    vpreset_avif = "6",
    
    -- GIF settings
    gif_fps = "15",
    gif_scale = "-1"
}

-- Load config from script-opts/smartcut.conf
options.read_options(opts, "smartcut")

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
local menu_active = false
local menu_options = {}
local menu_sel = 1

local function get_home()
    return os.getenv("USERPROFILE") or os.getenv("HOME") or "."
end

local function resolve_path(path)
    if path:sub(1, 1) == "~" then
        path = get_home() .. path:sub(2)
    end
    -- Normalize slashes for Windows/Unix
    path = path:gsub("\\", "/")
    return path
end

local function format_time(seconds)
    if not seconds then return "00:00:00.000" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    local ms = math.floor((seconds % 1) * 1000)
    return string.format("%02d:%02d:%02d.%03d", h, m, s, ms)
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
    local min_x = math.min(x1, x2)
    local max_x = math.max(x1, x2)
    local min_y = math.min(y1, y2)
    local max_y = math.max(y1, y2)
    
    local box_w = max_x - min_x
    local box_h = max_y - min_y
    
    local w, h = mp.get_osd_size()
    if w and h then
        overlay.res_x = w
        overlay.res_y = h
    end
    
    -- Draw empty red box (transparent fill, red border)
    local ass_data = string.format(
        "{\\an7\\pos(%d,%d)\\bord2\\3c&H0000FF&\\1a&HFF&\\3a&H00&\\p1}m 0 0 l %d 0 l %d %d l 0 %d l 0 0{\\p0}",
        min_x, min_y, box_w, box_w, box_h, box_h
    )
    overlay.data = ass_data
    overlay:update()
end

local function mouse_move()
    if not first_point_set then return end
    local mx, my = mp.get_mouse_pos()
    draw_crop_box(drag_start_x, drag_start_y, mx, my)
end

local function click_handler()
    local mx, my = mp.get_mouse_pos()
    if not first_point_set then
        drag_start_x = mx
        drag_start_y = my
        first_point_set = true
        drag_timer = mp.add_periodic_timer(0.05, mouse_move)
        mp.osd_message("Start point set! Click again to set end point.", 4)
        print("smartcut: First point set at " .. mx .. ", " .. my)
    else
        first_point_set = false
        if drag_timer then
            drag_timer:kill()
            drag_timer = nil
        end
        screen_x1 = drag_start_x
        screen_y1 = drag_start_y
        screen_x2 = mx
        screen_y2 = my
        draw_crop_box(screen_x1, screen_y1, screen_x2, screen_y2)
        mp.osd_message("Crop area set! Press " .. opts.cut_key .. " to render default, or " .. opts.menu_key .. " for menu.", 4)
        print("smartcut: Second point set at " .. mx .. ", " .. my)
    end
end

local function toggle_crop_mode()
    if not crop_mode_active then
        crop_mode_active = true
        first_point_set = false
        mp.osd_message("Crop Mode: Click once to set start point, then click again to set end point.", 5)
        mp.add_forced_key_binding("mbtn_left", "smartcut-click", click_handler)
    else
        crop_mode_active = false
        first_point_set = false
        if drag_timer then
            drag_timer:kill()
            drag_timer = nil
        end
        mp.osd_message("Crop Mode deactivated.", 2)
        mp.remove_key_binding("smartcut-click")
        overlay.data = ""
        overlay:update()
        screen_x1, screen_y1, screen_x2, screen_y2 = nil, nil, nil, nil
    end
end

-- Key binding to toggle start/end timecodes
local function mark_time()
    local pos = mp.get_property_number("time-pos")
    if not pos then
        mp.osd_message("Error: Could not get current position")
        return
    end

    if not start_time or (start_time and end_time) then
        start_time = pos
        end_time = nil
        mp.osd_message("Start set: " .. format_time(start_time), 3)
        print("smartcut: Set start time to " .. start_time)
    else
        if pos <= start_time then
            mp.osd_message("Error: End time must be after start time", 3)
            return
        end
        end_time = pos
        mp.osd_message("End set: " .. format_time(end_time) .. "\nPress " .. opts.cut_key .. " to cut, or " .. opts.menu_key .. " for menu!", 4)
        print("smartcut: Set end time to " .. end_time)
    end
end

-- Formats description helper
local function get_format_desc(fmt)
    if fmt == "smartcut" then
        return "Lossless Keyframe Cut"
    elseif fmt == "smartcut_mp4" then
        return "Lossless Keyframe Cut (MP4)"
    elseif fmt == "mp4" then
        return "MP4 Video (H.264, CRF " .. opts.crf .. ")"
    elseif fmt == "gif" then
        return "GIF Animation (" .. opts.gif_fps .. " fps)"
    elseif fmt == "avif" then
        return "AVIF Video (SVT-AV1, CRF " .. opts.crf_avif .. ")"
    else
        return ""
    end
end

-- Escape path characters for FFmpeg filtergraph syntax (Windows compatibility)
local function escape_filter_path(path)
    -- Normalize backslashes to forward slashes to avoid escaping issues
    path = path:gsub("\\", "/")
    -- Escape colons (e.g. C: -> C\:)
    path = path:gsub(":", "\\:")
    -- Escape single quotes (e.g. ' -> \')
    path = path:gsub("'", "\\'")
    return path
end

-- Retrieve active subtitle track information (internal index or external path)
local function get_active_sub_info()
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

-- Actual render execution logic
local function run_render(current_format)
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

    if current_format == "smartcut" or current_format == "smartcut_mp4" then
        if has_crop then
            mp.osd_message("Error: smartcut (lossless) does not support cropping!\nOpen menu (" .. opts.menu_key .. ") to choose MP4/GIF/AVIF.", 5)
            return
        end

        local ext
        if current_format == "smartcut_mp4" then
            ext = ".mp4"
        else
            ext = input_path:match("^.+(%.[^.]+)$") or ".mkv"
        end
        local output_dir = resolve_path(opts.output_dir)
        local filename = os.date(opts.filename_template) .. ext
        local output_path = output_dir .. "/" .. filename

        mp.osd_message("Creating lossless clip (" .. current_format .. ")...\n" .. format_time(start_time) .. " - " .. format_time(end_time), 3)
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

        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            args = args
        }, function(success, result, error)
            if success and result and result.status == 0 then
                mp.osd_message("Lossless clip created successfully!\nSaved to: " .. filename, 5)
                print("smartcut: Lossless cut completed successfully.")
                
                -- Reset markers
                start_time = nil
                end_time = nil
            else
                local err_msg = "Error creating lossless clip!"
                if result and result.stderr then
                    err_msg = err_msg .. "\n" .. result.stderr
                end
                mp.osd_message(err_msg, 7)
                print("smartcut: Lossless cut failed. Status: " .. (result and result.status or "nil") .. ", Error: " .. (error or "nil"))
            end
        end)
    else
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

        local output_dir = resolve_path(opts.output_dir)
        local filename = os.date(opts.filename_template) .. "." .. current_format
        local output_path = output_dir .. "/" .. filename

        -- Check for active subtitles to burn in
        local sub_info = get_active_sub_info()

        if has_crop then
            local msg = "Rendering cropped " .. current_format:upper() .. " clip...\n(Trimming & Re-encoding"
            if sub_info then
                msg = msg .. " + Subtitles"
            end
            msg = msg .. ")"
            mp.osd_message(msg, 5)
            print("smartcut: Running crop...")
            print("smartcut: Crop filter: crop=" .. crop_w .. ":" .. crop_h .. ":" .. crop_x .. ":" .. crop_y)
        else
            local msg = "Rendering full " .. current_format:upper() .. " clip...\n(Trimming & Re-encoding"
            if sub_info then
                msg = msg .. " + Subtitles"
            end
            msg = msg .. ")"
            mp.osd_message(msg, 5)
            print("smartcut: Running encode (no crop)...")
        end
        print("smartcut: Format: " .. current_format)
        print("smartcut: Input: " .. input_path)
        print("smartcut: Output: " .. output_path)

        -- Construct ffmpeg arguments
        local args = { resolve_path(opts.ffmpeg_path), "-y" }

        -- Time input arguments (placed before input for fast seeking)
        table.insert(args, "-ss")
        table.insert(args, tostring(start_time))
        table.insert(args, "-to")
        table.insert(args, tostring(end_time))
        table.insert(args, "-i")
        table.insert(args, input_path)

        -- Format specific arguments
        if current_format == "mp4" then
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
                table.insert(vf_items, sub_filter)
            end
            if #vf_items > 0 then
                table.insert(args, "-vf")
                table.insert(args, table.concat(vf_items, ","))
            end
            table.insert(args, "-c:v")
            table.insert(args, opts.vcodec)
            table.insert(args, "-crf")
            table.insert(args, opts.crf)
            table.insert(args, "-preset")
            table.insert(args, opts.vpreset_mp4)
            table.insert(args, "-c:a")
            table.insert(args, opts.acodec)
        elseif current_format == "gif" then
            -- Build customizable GIF filtergraph
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
                table.insert(vf_items, sub_filter)
            end
            if opts.gif_fps ~= "" and opts.gif_fps ~= "-1" then
                table.insert(vf_items, "fps=" .. opts.gif_fps)
            end
            if opts.gif_scale ~= "" and opts.gif_scale ~= "-1" then
                table.insert(vf_items, "scale=" .. opts.gif_scale .. ":-1")
            end
            
            local base_vf = table.concat(vf_items, ",")
            local gif_vf = ""
            if base_vf ~= "" then
                gif_vf = base_vf .. ",split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
            else
                gif_vf = "split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
            end
            
            table.insert(args, "-vf")
            table.insert(args, gif_vf)
            table.insert(args, "-an")
        elseif current_format == "avif" then
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
                table.insert(vf_items, sub_filter)
            end
            if #vf_items > 0 then
                table.insert(args, "-vf")
                table.insert(args, table.concat(vf_items, ","))
            end
            table.insert(args, "-c:v")
            table.insert(args, "libsvtav1")
            table.insert(args, "-crf")
            table.insert(args, opts.crf_avif)
            table.insert(args, "-preset")
            table.insert(args, opts.vpreset_avif)
            table.insert(args, "-an")
        end

        table.insert(args, output_path)

        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            args = args
        }, function(success, result, error)
            if success and result and result.status == 0 then
                mp.osd_message(current_format:upper() .. " clip created successfully!\nSaved to: " .. filename, 5)
                print("smartcut: Crop/Cut completed successfully.")
                
                -- Reset markers and overlay
                start_time = nil
                end_time = nil
                screen_x1, screen_y1, screen_x2, screen_y2 = nil, nil, nil, nil
                overlay.data = ""
                overlay:update()
                crop_mode_active = false
                mp.remove_key_binding("smartcut-click")
            else
                local err_msg = "Error creating cropped/cut clip!"
                if result and result.stderr then
                    err_msg = err_msg .. "\n" .. result.stderr
                end
                mp.osd_message(err_msg, 7)
                print("smartcut: Crop/Cut failed. Status: " .. (result and result.status or "nil") .. ", Error: " .. (error or "nil"))
            end
        end)
    end
end

-- OSD Menu Drawing function
local function draw_menu()
    local has_crop = (screen_x1 and screen_y1 and screen_x2 and screen_y2)
    local w, h = mp.get_osd_size()
    if w and h then
        menu_overlay.res_x = w
        menu_overlay.res_y = h
    end
    
    local ass = "{\\an7\\pos(30,150)\\fs22\\fnArial\\b1\\1c&HFFFF00&\\3c&H000000&\\3a&H00&\\bord2}"
    ass = ass .. "=== SMART CLIP SELECTOR ==={\\b0}\\N"
    
    if has_crop then
        ass = ass .. "{\\fs16\\1c&H00FF00&}Mode: Cropping Active{\\fs22\\1c&HFFFFFF&}\\N\\N"
    else
        ass = ass .. "{\\fs16\\1c&H00FFFF&}Mode: Full-Frame Cutting{\\fs22\\1c&HFFFFFF&}\\N\\N"
    end
    
    for i, opt in ipairs(menu_options) do
        if i == menu_sel then
            ass = ass .. "{\\1c&H00FFFF&\\b1}  ➤  [" .. opt:upper() .. "] " .. get_format_desc(opt) .. "{\\b0\\1c&HFFFFFF&}\\N"
        else
            ass = ass .. "{\\1c&HCCCCCC&}      [" .. opt:upper() .. "] " .. get_format_desc(opt) .. "{\\1c&HFFFFFF&}\\N"
        end
    end
    
    if has_crop then
        ass = ass .. "{\\1c&H666666&}      [SMARTCUT] (Disabled - cropping active){\\1c&HFFFFFF&}\\N"
        ass = ass .. "{\\1c&H666666&}      [SMARTCUT_MP4] (Disabled - cropping active){\\1c&HFFFFFF&}\\N"
    end
    
    ass = ass .. "\\N{\\fs14\\1c&H888888&}[Up/Down] Navigate   [Enter] Confirm & Render   [Esc/" .. opts.menu_key .. "] Close Menu{\\1c&HFFFFFF&}"
    
    menu_overlay.data = ass
    menu_overlay:update()
end

local function close_menu()
    mp.remove_key_binding("menu-up")
    mp.remove_key_binding("menu-down")
    mp.remove_key_binding("menu-enter")
    mp.remove_key_binding("menu-close")
    mp.remove_key_binding("menu-toggle-close")
    menu_overlay.data = ""
    menu_overlay:update()
    menu_active = false
    print("smartcut: Menu closed.")
end

local function menu_up()
    if not menu_active then return end
    menu_sel = menu_sel - 1
    if menu_sel < 1 then
        menu_sel = #menu_options
    end
    draw_menu()
end

local function menu_down()
    if not menu_active then return end
    menu_sel = menu_sel + 1
    if menu_sel > #menu_options then
        menu_sel = 1
    end
    draw_menu()
end

local function menu_enter()
    if not menu_active then return end
    local selected_format = menu_options[menu_sel]
    close_menu()
    run_render(selected_format)
end

-- Key binding to toggle format selection menu
local function toggle_menu()
    if menu_active then
        close_menu()
        return
    end

    if not start_time or not end_time then
        mp.osd_message("Error: Set start and end times first!", 3)
        return
    end

    local has_crop = (screen_x1 and screen_y1 and screen_x2 and screen_y2)
    
    if has_crop then
        menu_options = {"mp4", "gif", "avif"}
        menu_sel = 1
        local def = opts.default_crop_mode:lower()
        for i, opt in ipairs(menu_options) do
            if opt == def then
                menu_sel = i
                break
            end
        end
    else
        menu_options = {"smartcut", "smartcut_mp4", "mp4", "gif", "avif"}
        menu_sel = 1
        local def = opts.default_cut_mode:lower()
        for i, opt in ipairs(menu_options) do
            if opt == def then
                menu_sel = i
                break
            end
        end
    end

    menu_active = true
    draw_menu()

    mp.add_forced_key_binding("UP", "menu-up", menu_up)
    mp.add_forced_key_binding("DOWN", "menu-down", menu_down)
    mp.add_forced_key_binding("ENTER", "menu-enter", menu_enter)
    mp.add_forced_key_binding("ESC", "menu-close", close_menu)
    mp.add_forced_key_binding(opts.menu_key, "menu-toggle-close", close_menu)
    
    print("smartcut: Menu opened.")
end

-- Key binding to confirm and run clip generation with default mode
local function make_clip()
    if not start_time or not end_time then
        mp.osd_message("Error: Set start and end times first!", 3)
        return
    end

    if menu_active then
        close_menu()
    end

    local has_crop = (screen_x1 and screen_y1 and screen_x2 and screen_y2)
    local target_format
    if has_crop then
        target_format = opts.default_crop_mode:lower()
        if target_format == "smartcut" or target_format == "smartcut_mp4" then
            target_format = "mp4"
        end
    else
        target_format = opts.default_cut_mode:lower()
    end

    run_render(target_format)
end

mp.add_key_binding(opts.mark_key, "smartcut-mark", mark_time)
mp.add_key_binding(opts.crop_key, "smartcut-crop", toggle_crop_mode)
mp.add_key_binding(opts.cut_key, "smartcut-cut", make_clip)
mp.add_key_binding(opts.menu_key, "smartcut-menu", toggle_menu)
