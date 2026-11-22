if mp.get_script_name() ~= "profile_hud" then return end

local log_path = mp.command_native({"expand-path", "~~/mpv_test_runs.log"})
local current_session = nil
local osd_overlay = mp.create_osd_overlay("ass-events")
local osd_clear_timer = nil
local retry_timer = nil
local log_timer = nil

local function append_log(text)
    local f, err = io.open(log_path, "a")
    if f then
        f:write(text .. "\n")
        f:flush()
        f:close()
    else
        mp.msg.error("profile_hud failed to open log: " .. tostring(err))
    end
end

local function safe_num(prop, default)
    local val = mp.get_property_number(prop)
    if val == nil then return default end
    return val
end

local function safe_str(prop, default)
    local val = mp.get_property(prop)
    if val == nil or val == "" then return default end
    return val
end

local function clear_profile_osd()
    if osd_clear_timer then
        osd_clear_timer:kill()
        osd_clear_timer = nil
    end
    osd_overlay.data = ""
    osd_overlay:remove()
end

local function clear_log_timer()
    if log_timer then
        log_timer:kill()
        log_timer = nil
    end
end

-- Exact property lookup table matching mpv's built-in @auto_profiles.lua environment
local prop_proxy = setmetatable({}, {
    __index = function(_, key)
        return mp.get_property_native(key)
    end
})

local function env_get(name, default)
    local val = mp.get_property_native(name)
    if val == nil then return default end
    return val
end

-- Safely evaluates the exact profile-cond expressions defined in mpv.conf
local function get_active_profiles_label()
    local active = {}
    local profiles = mp.get_property_native("profile-list") or {}

    local eval_env = {
        p = prop_proxy,
        get = env_get,
        tonumber = tonumber,
        tostring = tostring,
        string = string,
        math = math,
        table = table,
        pairs = pairs,
        ipairs = ipairs,
        type = type,
    }

    local loader = loadstring or load

    for _, prof in ipairs(profiles) do
        local name = prof.name
        local cond = prof["profile-cond"]
        if name and cond and cond ~= "" and loader then
            local fn
            if setfenv then
                fn = loader("return (" .. cond .. ")")
                if fn then setfenv(fn, eval_env) end
            else
                fn = loader("return (" .. cond .. ")", "cond", "t", eval_env)
            end
            if fn then
                local ok, result = pcall(fn)
                if ok and result then
                    table.insert(active, name)
                end
            end
        end
    end

    if #active > 0 then
        return "[" .. table.concat(active, " + ") .. "]"
    end
    return "[default]"
end

-- Renders the active profile banner top-left (\an7) once playback is actively presenting frames
local function show_profile_osd()
    if not current_session or current_session.osd_shown then return end
    if mp.get_property_bool("pause", true) then return end

    local w = safe_num("video-params/w", 0)
    local vo_configured = mp.get_property_bool("vo-configured", false)
    if w <= 0 or not vo_configured then return end

    local label = get_active_profiles_label()
    if label == "[default]" and (current_session.attempts or 0) < 12 then
        current_session.attempts = (current_session.attempts or 0) + 1
        return
    end

    local disp_fps = safe_num("display-fps", 0)
    local gamma = safe_str("video-params/gamma", "")
    local matrix = safe_str("video-params/colormatrix", "")
    local hdr_state = (gamma == "pq" or gamma == "hlg" or matrix == "dolbyvision" or matrix:find("bt.2020")) and "HDR" or "SDR->PQ"

    local msg = string.format("%s | %s @ %.2f Hz", label, hdr_state, disp_fps)

    clear_profile_osd()
    -- {\an7} = top-left alignment (left-justified)
    osd_overlay.data = string.format("{\\an7\\fs26\\b1\\bord2\\shad1\\1c&HFFFFFF&\\3c&H000000&}%s", msg)
    osd_overlay:update()

    current_session.osd_shown = true
    if retry_timer then
        retry_timer:kill()
        retry_timer = nil
    end
    osd_clear_timer = mp.add_timeout(10.0, clear_profile_osd)
end

local function update_health_snapshot()
    if not current_session then return end

    local drops = mp.get_property_number("frame-drop-count")
    if drops ~= nil then current_session.drops = drops end

    local delayed = mp.get_property_number("vo-delayed-frame-count")
    if delayed ~= nil then current_session.delayed = delayed end

    local mistimed = mp.get_property_number("mistimed-frame-count")
    if mistimed ~= nil then current_session.mistimed = mistimed end

    local disp_fps = mp.get_property_number("display-fps")
    if disp_fps ~= nil and disp_fps > 0 then current_session.display_fps = disp_fps end

    local cont_fps = mp.get_property_number("container-fps")
    if cont_fps ~= nil and cont_fps > 0 then current_session.container_fps = cont_fps end

    local hwdec = mp.get_property("hwdec-current")
    if hwdec ~= nil and hwdec ~= "" and hwdec ~= "no" then
        current_session.hwdec = hwdec
    elseif current_session.hwdec == "none" and hwdec ~= nil then
        current_session.hwdec = hwdec
    end
end

-- Reads actual executed GPU render passes (filters out shaders bypassed by //!WHEN)
local function get_executed_passes()
    local passes = mp.get_property_native("vo-passes")
    if not passes or not passes.fresh or #passes.fresh == 0 then
        return "(none / waiting for frame)"
    end

    local list = {}
    for _, pass in ipairs(passes.fresh) do
        local desc = pass.desc or "unnamed"
        local avg_ms = (pass.avg or 0) / 1e6 -- convert nanoseconds to milliseconds
        table.insert(list, string.format("%s (%.2fms)", desc, avg_ms))
    end
    return table.concat(list, " -> ")
end

local function log_pipeline_state()
    if not current_session or current_session.pipeline_logged then return end

    local ok, err = pcall(function()
        local ts = os.date("%Y-%m-%d %H:%M:%S")
        local w = safe_num("video-params/w", 0)
        local h = safe_num("video-params/h", 0)
        local fps = safe_num("container-fps", 0)
        local matrix = safe_str("video-params/colormatrix", "nil")
        local gamma = safe_str("video-params/gamma", "nil")
        local dovi_prof = safe_str("current-tracks/video/dolby-vision-profile", "nil")
        if dovi_prof == "nil" and matrix == "dolbyvision" then
            dovi_prof = "unknown"
        end
        local hdr_fmt = safe_str("video-params/hdr-format", "nil")

        local tm = safe_str("tone-mapping", "nil")
        local inv = safe_str("inverse-tone-mapping", "no")
        local peak = safe_num("target-peak", 0)
        local comp_peak = safe_str("hdr-compute-peak", "no")
        local deband = safe_str("deband", "no")
        local contrast = safe_num("contrast", 0)
        local shaders = safe_str("glsl-shaders", "(none)")
        local executed_passes = get_executed_passes()
        local profiles_label = get_active_profiles_label()

        local entry = string.format(
            "=== [%s] FILE: \"%s\" ===\n" ..
            "  Profiles: %s\n" ..
            "  Res: %dx%d @ %.3f fps | Colormatrix: %s | Gamma: %s | DoVi-Profile: %s | HDR-Format: %s\n" ..
            "  Tone-Map: %s (inv=%s, peak=%d, compute-peak=%s) | Contrast: %d | Deband: %s\n" ..
            "  Loaded Shaders: %s\n" ..
            "  Executed Passes: %s",
            ts, current_session.path,
            profiles_label,
            w, h, fps, matrix, gamma, dovi_prof, hdr_fmt,
            tm, inv, peak, comp_peak, contrast, deband,
            shaders,
            executed_passes
        )

        append_log(entry)
    end)

    if not ok then
        append_log("=== [ERROR] log_pipeline_state failed: " .. tostring(err) .. " ===")
    end

    current_session.pipeline_logged = true
    update_health_snapshot()
    show_profile_osd()
end

-- Guards against cold-start race where video-params are not yet populated at 1.5s
local function schedule_pipeline_log(delay, attempt)
    clear_log_timer()
    log_timer = mp.add_timeout(delay, function()
        log_timer = nil
        if not current_session or current_session.pipeline_logged then return end

        local w = safe_num("video-params/w", 0)
        local matrix = mp.get_property("video-params/colormatrix")
        if (w > 0 and matrix ~= nil) or attempt >= 3 then
            log_pipeline_state()
        else
            schedule_pipeline_log(1.0, attempt + 1)
        end
    end)
end

local function start_osd_poll()
    if retry_timer then retry_timer:kill() end
    retry_timer = mp.add_periodic_timer(0.25, function()
        if not current_session or current_session.osd_shown then
            if retry_timer then
                retry_timer:kill()
                retry_timer = nil
            end
            return
        end
        show_profile_osd()
    end)
end

mp.observe_property("pause", "bool", function(_, paused)
    if paused == false and current_session and not current_session.osd_shown then
        start_osd_poll()
    end
end)

mp.register_event("playback-restart", function()
    if current_session and not current_session.osd_shown then
        start_osd_poll()
    end
end)

local health_timer = mp.add_periodic_timer(2.0, update_health_snapshot)
health_timer:kill()

mp.register_event("file-loaded", function()
    clear_profile_osd()
    clear_log_timer()
    if retry_timer then
        retry_timer:kill()
        retry_timer = nil
    end

    local media_path = safe_str("user-data/media-source/Path", safe_str("path", "unknown"))
    current_session = {
        path = media_path,
        start_time = mp.get_time(),
        pipeline_logged = false,
        osd_shown = false,
        attempts = 0,
        drops = 0,
        delayed = 0,
        mistimed = 0,
        display_fps = 0,
        container_fps = 0,
        hwdec = "none"
    }

    health_timer:resume()
    start_osd_poll()
    schedule_pipeline_log(1.5, 0)
end)

mp.register_event("end-file", function(event)
    health_timer:kill()
    clear_log_timer()
    if retry_timer then
        retry_timer:kill()
        retry_timer = nil
    end
    clear_profile_osd()
    if not current_session then return end

    update_health_snapshot()

    if not current_session.pipeline_logged then
        log_pipeline_state()
    end

    local duration = mp.get_time() - current_session.start_time
    local reason = (event and event.reason) or "unknown"

    local health_line = string.format(
        "  Health [%.1fs, reason=%s]: Drops=%d | Delayed=%d | Mistimed=%d | Display-FPS=%.3f vs Container-FPS=%.3f | HWDec=%s\n",
        duration,
        reason,
        current_session.drops,
        current_session.delayed,
        current_session.mistimed,
        current_session.display_fps,
        current_session.container_fps,
        current_session.hwdec
    )

    append_log(health_line)
    current_session = nil
end)