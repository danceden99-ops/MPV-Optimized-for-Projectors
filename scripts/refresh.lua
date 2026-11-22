local ps_script = mp.command_native({"expand-path", "~~/set_display.ps1"})
local desktop_hz = 23
local active_state = nil

local settle_secs  = 10     -- Epson 5050UB HDMI resync settle time (seconds after PowerShell exits)
local settle_timer = nil
local settling     = false
local want_play    = true

local function ps_args(hdr_flag, target_hz)
    return {
        "powershell.exe",
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", ps_script,
        "-hz", tostring(target_hz),
        "-hdr", tostring(hdr_flag)
    }
end

-- Catch Jellyfin Shim unpausing (~0.15s-0.35s after load) while waiting for projector HDMI lock
mp.observe_property("pause", "bool", function(_, paused)
    if mp.get_script_name() ~= "refresh" then return end
    if settling and paused == false then
        want_play = true
        mp.set_property_bool("pause", true)
    end
end)

local function end_settle()
    settling = false
    settle_timer = nil
    -- Uncomment the line below ONLY if exclusive WASAPI audio is silent after projector resync:
    -- mp.command("ao-reload")
    if want_play then
        mp.set_property_bool("pause", false)
    end
end

local function set_display(hdr_flag, target_hz, on_done)
    if mp.get_script_name() ~= "refresh" then return false end
    local state_key = tostring(hdr_flag) .. "_" .. tostring(target_hz)
    if state_key == active_state then return false end

    local mode_label = (hdr_flag == 1) and "HDR" or "SDR"
    mp.osd_message(mode_label .. " @ " .. target_hz .. " Hz", 3)

    if on_done then
        local t0 = mp.get_time()
        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            args = ps_args(hdr_flag, target_hz)
        }, function(success, res)
            local elapsed = mp.get_time() - t0
            if success and res and res.status == 0 then
                active_state = state_key
                mp.msg.info(string.format("refresh: Switched to %s in %.2fs", state_key, elapsed))
                on_done(true)
            else
                mp.msg.warn("refresh: set_display.ps1 exited with status " .. tostring(res and res.status))
                on_done(false)
            end
        end)
    else
        active_state = state_key
        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            detach = true,
            args = ps_args(hdr_flag, target_hz)
        })
    end
    return true
end

-- Automatically selects the best English Dolby Atmos / Dolby Digital / Surround track
local function select_best_audio()
    if mp.get_script_name() ~= "refresh" then return end
    local tracks = mp.get_property_native("track-list")
    if not tracks then return end

    local best_aid = nil
    local best_score = -1

    for _, track in ipairs(tracks) do
        if track.type == "audio" then
            local score = 0
            local lang = (track.lang or ""):lower()
            local codec = (track.codec or ""):lower()
            local title = (track.title or ""):lower()
            local channels = track["demux-channel-count"] or 2

            if title:find("commentary") or title:find("description") or title:find("sdh") then
                score = score - 5000
            end

            if lang == "eng" or lang == "en" or lang == "en-us" then
                score = score + 2000
            elseif lang == "" or lang == "und" then
                score = score + 1000
            end

            if codec:find("truehd") then
                score = score + 600
            elseif codec:find("eac3") then
                score = score + 500
            elseif codec:find("dts") then
                score = score + 450
            elseif codec:find("ac3") then
                score = score + 400
            elseif codec:find("flac") or codec:find("pcm") then
                score = score + 200
            elseif codec:find("aac") then
                score = score + 50
            end

            if title:find("atmos") then
                score = score + 150
            end

            score = score + (channels * 10)

            if score > best_score then
                best_score = score
                best_aid = track.id
            end
        end
    end

    local current_aid = mp.get_property_number("aid")
    if best_aid and best_aid ~= current_aid then
        mp.set_property_number("aid", best_aid)
        mp.msg.info("refresh: Switched to best audio track --aid=" .. best_aid .. " (score=" .. best_score .. ")")
    end
end

-- Reads FPS reliably across demuxer, video track metadata, and decoder estimates
local function detect_fps()
    local fps = mp.get_property_number("container-fps")
    if fps and fps > 0 then return fps end

    local tracks = mp.get_property_native("track-list") or {}
    for _, track in ipairs(tracks) do
        if track.type == "video" and track.selected and track["demux-fps"] and track["demux-fps"] > 0 then
            return track["demux-fps"]
        end
    end

    fps = mp.get_property_number("estimated-vf-fps")
    if fps and fps > 0 then return fps end

    return nil
end

-- Nearest-neighbor FPS-to-Hz map (prevents 23.976/24.000 and 29.970/30.000 tolerance overlap;
-- maps 50/59.94/60 fps to 2:1 HDMI 2.0 18 Gbps bandwidth-safe cadence)
local fps_map = {
    { src = 23.976, hz = 23 },
    { src = 24.000, hz = 24 },
    { src = 25.000, hz = 25 },
    { src = 29.970, hz = 29 },
    { src = 30.000, hz = 30 },
    { src = 50.000, hz = 25 },
    { src = 59.940, hz = 29 },
    { src = 60.000, hz = 30 },
}

local function pick_target_hz(fps)
    local best_hz = desktop_hz
    local best_diff = 0.05
    for _, entry in ipairs(fps_map) do
        local diff = math.abs(fps - entry.src)
        if diff < best_diff then
            best_diff = diff
            best_hz = entry.hz
        end
    end
    return best_hz
end

-- ==============================================================================
-- ASYNC DISPLAY SWITCH + HDMI RESYNC SETTLE PAUSE
-- ==============================================================================
local function on_file_loaded()
    if mp.get_script_name() ~= "refresh" then return end

    mp.add_timeout(0.15, select_best_audio)

    local fps = detect_fps()
    if not fps then
        mp.msg.warn("refresh: Could not detect video FPS; skipping display switch")
        return
    end

    local target = pick_target_hz(fps)
    if ("1_" .. tostring(target)) == active_state then return end

    want_play = true
    settling = true
    mp.set_property_bool("pause", true)

    set_display(1, target, function(ok)
        if ok then
            mp.msg.info("refresh: Waiting " .. settle_secs .. "s for projector HDMI resync")
            settle_timer = mp.add_timeout(settle_secs, end_settle)
        else
            end_settle()
        end
    end)
end

mp.register_event("file-loaded", on_file_loaded)

mp.register_event("end-file", function()
    if settle_timer then
        settle_timer:kill()
        settle_timer = nil
    end
    settling = false
    set_display(0, desktop_hz, nil)
end)

mp.register_event("shutdown", function()
    if settle_timer then
        settle_timer:kill()
        settle_timer = nil
    end
    settling = false
    set_display(0, desktop_hz, nil)
end)

-- ==============================================================================
-- FORCED EXIT KEYBINDINGS (Blocks Jellyfin Shim from hijacking ESC / MCE Back)
-- ==============================================================================
if mp.get_script_name() == "refresh" then
    mp.add_forced_key_binding("ESC", "shim_force_quit_esc", function()
        mp.command("script-message custom-bind bind1")
    end)

    mp.add_forced_key_binding("alt+bs", "shim_force_quit_back", function()
        mp.command("script-message custom-bind bind1")
    end)
end