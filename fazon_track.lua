-- Fazon Nexus Tracker for mpv: log what you watch to your fazon.nexus Track.
-- https://github.com/SomeRandomGuy64/Fazon-Nexus-MPV-Tracker
--
--   Ctrl+a  track what's playing as ACTIVE immersion  (press again to stop)
--   Ctrl+p  track what's playing as PASSIVE immersion (press again to stop)
--
-- Off whenever mpv starts. Only one can be on at a time: pressing the other key switches over.
-- The sub-category is the video's title (you can edit it first); it's created on the site if you
-- don't have it yet. Only time spent actually playing counts (not paused, seeking or buffering),
-- in real time, so 30 minutes at 1.5x speed logs 30 minutes. Time is sent every few minutes and
-- when you stop or quit; anything that can't be sent (offline) is saved and retried the next time
-- mpv starts.
--
-- Settings: script-opts/fazon_track.conf in your mpv config folder (api_key=fz_... at minimum).
-- Rebind in input.conf with:  KEY script-binding fazon_track/track-active  (or track-passive)

local VERSION = "1.0.0"

local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"
local options = require "mp.options"

local o = {
    api_key = "",                 -- a Read & write key from your profile; else $FAZON_API_KEY
    api_url = "https://api.fazon.nexus/v1/api/track",
    key_active = "Ctrl+a",
    key_passive = "Ctrl+p",
    prompt = true,                -- ask for the sub-category name before tracking
    subcat = "",                  -- suggest this name instead of the video's title
    continue_on_next_file = true, -- keep tracking when the playlist moves on, as the new title
    flush_minutes = 5,            -- how often to send time while tracking
}
options.read_options(o, "fazon_track")
if o.api_key == "" then o.api_key = os.getenv("FAZON_API_KEY") or "" end

local LABEL = { active = "Active immersion", passive = "Passive immersion" }
local PLATFORM = mp.get_property("platform")
    or (package.config:sub(1, 1) == "\\" and "windows" or "linux")
local STATE_DIR = mp.command_native({ "expand-path", "~~state/fazon_track" })
if not STATE_DIR or STATE_DIR == "" or STATE_DIR:find("^~~") then
    STATE_DIR = (os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or ".") .. "/.local/state")) .. "/mpv/fazon_track"
end

local track = nil    -- {category, name, path, secs, hold}; hold = don't count (switching names)
local busy = false   -- a prompt or sub-category lookup is in progress
local acc, acc_week = 0, nil  -- seconds played for track, not yet banked, and their week
local pending = {}   -- {week, category, name, h}: hundredths of an hour waiting to be sent
local inflight = nil -- the batch being sent right now
local last_tick = nil

local function osd(text, secs) mp.osd_message("Track: " .. text, secs or 3) end

local function fmt_dur(secs)
    local m = math.floor(secs / 60 + 0.5)
    return string.format("%dh %02dm", math.floor(m / 60), m % 60)
end

-- The key (Saturday label) of the Track week containing t: weeks start Sunday 03:00 UTC.
local function week_key(t)
    t = (t or os.time()) - 3 * 3600
    local sunday = t - (os.date("!*t", t).wday - 1) * 86400
    return os.date("!%Y-%m-%d", sunday - 86400)
end

-- The site's sub-category names: 1-40 characters, no control characters.
local function clean_name(s)
    s = (s or ""):gsub("%c", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    local out, n = {}, 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        n = n + 1
        if n > 40 then break end
        out[n] = ch
    end
    return (table.concat(out):gsub(" $", ""))
end

local function default_name()
    if o.subcat ~= "" then return clean_name(o.subcat) end
    local title = mp.get_property("media-title", "")
    local file = mp.get_property("filename", "")
    if title == "" or title == file then
        -- No real title: use the file name, with underscores as spaces (my_show_01 → my show 01).
        title = mp.get_property("filename/no-ext", file):gsub("%.condensed$", ""):gsub("_", " ")
    end
    return clean_name(title)
end

-- Whether a program is on the PATH (Linux/macOS).
local function have(prog)
    for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
        if utils.file_info(dir .. "/" .. prog) then return true end
    end
    return false
end

------------------------------------------------------------------ pending time, saved to disk

local function add_pending(week, category, name, h)
    for _, p in ipairs(pending) do
        if p.week == week and p.category == category and p.name == name then
            p.h = p.h + h
            return
        end
    end
    pending[#pending + 1] = { week = week, category = category, name = name, h = h }
end

local function load_saved()
    for _, f in ipairs(utils.readdir(STATE_DIR, "files") or {}) do
        if f:match("^pending%-.*%.json$") then
            local path = utils.join_path(STATE_DIR, f)
            local fh = io.open(path, "r")
            local list = fh and utils.parse_json(fh:read("*a")) or nil
            if fh then fh:close() end
            for _, p in ipairs(type(list) == "table" and list or {}) do
                add_pending(p.week, p.category, p.name, p.h)
            end
            os.remove(path)
        end
    end
end

local function save_unsent()
    if #pending == 0 then return end
    local mkdir = PLATFORM == "windows" and { "cmd", "/d", "/c", "mkdir", (STATE_DIR:gsub("/", "\\")) }
        or { "mkdir", "-p", STATE_DIR }
    mp.command_native({ name = "subprocess", args = mkdir, playback_only = false, capture_stderr = true })
    local path = utils.join_path(STATE_DIR, string.format("pending-%d-%d.json", os.time(), math.random(1e6)))
    local json = utils.format_json(pending) -- (it returns json, nil: keep only the first)
    local fh = io.open(path, "w")
    if fh then
        fh:write(json)
        fh:close()
        msg.warn(string.format("saved %d unsent entr%s to %s", #pending, #pending == 1 and "y" or "ies", path))
        pending = {}
    else
        msg.error("couldn't save unsent time to " .. path)
    end
end

-- Move counted seconds into pending, in whole hundredths of an hour (36 s) so nothing is lost
-- to rounding; final rounds the remainder to the nearest hundredth, as the site would.
local function bank(final)
    if track and acc_week then
        local h = math.floor(acc / 36 + (final and 0.5 or 0))
        if h > 0 then add_pending(acc_week, track.category, track.name, h) end
        acc = math.max(0, acc - h * 36)
    end
    if final then acc, acc_week = 0, nil end
end

------------------------------------------------------------------ HTTP (curl)

local function curl_cmd(method, path, body, timeout)
    local args = { "curl", "-sS", "--max-time", tostring(timeout), "-X", method,
        "-H", "@-", "-w", "\n%{http_code}" }
    if body then
        args[#args + 1] = "-H"; args[#args + 1] = "Content-Type: application/json"
        args[#args + 1] = "--data-binary"; args[#args + 1] = utils.format_json(body)
    end
    args[#args + 1] = o.api_url .. path
    -- The key goes in on stdin (-H @-) so it never shows up in the process list.
    return { name = "subprocess", args = args, capture_stdout = true, capture_stderr = true,
        playback_only = false, stdin_data = "Authorization: Bearer " .. o.api_key .. "\n" }
end

local HINT = {
    [401] = " (check api_key in script-opts/fazon_track.conf)",
    [403] = " (this key is read-only: create a Read & write key on your profile)",
}

local function parse_res(res)
    local out = res and res.stdout or ""
    local body, code = out:match("^(.*)\n(%d%d%d)$")
    code = tonumber(code) or 0
    local data = body and body:sub(1, 1) == "{" and utils.parse_json(body) or nil
    local err = (type(data) == "table" and data.error)
        or (res and res.stderr and res.stderr ~= "" and res.stderr)
        or (code == 0 and "no response (is curl installed?)") or "no response"
    return code, data, tostring(err):gsub("%s+$", "") .. (HINT[code] or "")
end

local function request(method, path, body, cb)
    mp.command_native_async(curl_cmd(method, path, body, 20), function(_, res) cb(parse_res(res)) end)
end

-- Make sure the category has an active sub-category called name; cb(name as stored) or cb(nil, err).
local function ensure_subcat(category, name, cb)
    request("GET", "/subcats", nil, function(code, data, err)
        if code ~= 200 then return cb(nil, code .. ": " .. err) end
        for _, s in ipairs(type(data) == "table" and data.subcats or {}) do
            if s.category == category and not s.archived and s.name:lower() == name:lower() then
                return cb(s.name)
            end
        end
        request("POST", "/subcats", { category = category, name = name }, function(code2, d2, err2)
            if code2 == 201 and type(d2) == "table" then return cb(d2.name) end
            if code2 == 409 and err2:find("already") then return cb(name) end
            cb(nil, code2 .. ": " .. err2)
        end)
    end)
end

-- Send the oldest week's pending entries in one atomic PATCH; on success, carry on with the next.
-- sync (on quit) blocks with a short timeout instead of running in the background.
local function send(sync)
    if inflight or #pending == 0 or o.api_key == "" then return end
    local week = pending[1].week
    local batch, entries = {}, {}
    for _, p in ipairs(pending) do
        if p.week == week then
            batch[#batch + 1] = { p = p, h = p.h }
            entries[#entries + 1] = { category = p.category, subcat = p.name, add = string.format("%.2f", p.h / 100) }
        end
    end
    local function done(res)
        inflight = nil
        local code, _, err = parse_res(res)
        local function drop_batch()
            for _, b in ipairs(batch) do b.p.h = b.p.h - b.h end -- time added meanwhile stays
            for i = #pending, 1, -1 do if pending[i].h <= 0 then table.remove(pending, i) end end
        end
        if code == 200 then
            msg.info("sent " .. #entries .. " entr" .. (#entries == 1 and "y" or "ies") .. " to week " .. week)
            drop_batch()
            send(sync)
        elseif code == 400 and err:find("create it first") then
            -- The sub-category was archived or renamed on the site: recreate it, retry later
            -- (on quit, it's saved and retried next time).
            local i = tonumber(err:match("entries%[(%d+)%]")) or 0
            local p = batch[i + 1] and batch[i + 1].p
            if p and not sync then ensure_subcat(p.category, p.name, function() end) end
        elseif code == 400 or code == 403 then
            msg.error("Track rejected week " .. week .. ": " .. err)
            osd("couldn't log time: " .. err, 6)
            drop_batch() -- it would fail the same way forever
            send(sync)
        else
            msg.warn("couldn't reach Track (" .. code .. ": " .. err .. "), will retry")
        end
    end
    if sync then
        done(mp.command_native(curl_cmd("PATCH", "/weeks/" .. week .. "/hours", { entries = entries }, 5)))
    else
        inflight = batch
        mp.command_native_async(curl_cmd("PATCH", "/weeks/" .. week .. "/hours", { entries = entries }, 20),
            function(_, res) done(res) end)
    end
end

------------------------------------------------------------------ tracking

local function tick()
    local now = mp.get_time()
    local dt = last_tick and now - last_tick or 0
    last_tick = now
    if not track or track.hold then return end
    if dt > 5 then dt = 0 end -- the machine was asleep
    local week = week_key()
    if acc_week and week ~= acc_week then bank(true) end -- a new week started mid-video
    acc_week = week
    if not mp.get_property_bool("core-idle", true) then
        acc = acc + dt
        track.secs = track.secs + dt
    end
    if acc >= o.flush_minutes * 60 then
        bank(false)
        send()
    end
end

local function stop(quiet)
    if not track then return end
    bank(true)
    send()
    if not quiet then
        osd(string.format("stopped. %s → %s › %s", fmt_dur(track.secs), LABEL[track.category], track.name), 4)
    end
    track = nil
end

-- A native dialog asking for the name, when mpv itself can't (before 0.39).
local function dialog_args(title, text, name)
    if PLATFORM == "windows" then
        local function ps(s) return "'" .. s:gsub("'", "''") .. "'" end
        return { "powershell", "-NoProfile", "-Command",
            "[Console]::OutputEncoding = [Text.Encoding]::UTF8; Add-Type -AssemblyName Microsoft.VisualBasic; "
            .. "$r = [Microsoft.VisualBasic.Interaction]::InputBox(" .. ps(text) .. ", " .. ps(title) .. ", "
            .. ps(name) .. "); if ($r -eq '') { exit 1 }; $r" }
    elseif PLATFORM == "darwin" then
        local function as(s) return '"' .. s:gsub('[\\"]', "\\%0") .. '"' end
        return { "osascript", "-e", "text returned of (display dialog " .. as(text) .. " default answer "
            .. as(name) .. " with title " .. as(title) .. ")" }
    elseif have("kdialog") then
        return { "kdialog", "--title", title, "--inputbox", text, name }
    elseif have("zenity") then
        return { "zenity", "--entry", "--title", title, "--text", text, "--entry-text", name }
    end
end

local function ask_name(category, name, cb)
    if not o.prompt then return cb(name) end
    local title = "Fazon Track: " .. LABEL[category]
    local text = "Sub-category (max 40 characters):"
    local was_paused = mp.get_property_bool("pause")
    local function finish(result)
        mp.set_property_bool("pause", was_paused)
        cb(result)
    end
    local ok, input = pcall(require, "mp.input")
    if ok and input and input.get then
        -- mpv 0.39+: ask in the player.
        local answered = false
        mp.set_property_bool("pause", true)
        input.get({
            prompt = LABEL[category] .. " sub-category:",
            default_text = name,
            submit = function(text_in)
                answered = true
                input.terminate()
                finish(text_in)
            end,
            closed = function() if not answered then answered = true; finish(nil) end end,
        })
        return
    end
    local args = dialog_args(title, text, name)
    if not args then return cb(name) end -- no way to ask: use the title as it is
    mp.set_property_bool("pause", true)
    osd("name it in the dialog (Esc cancels)", 5)
    mp.command_native_async({ name = "subprocess", args = args, capture_stdout = true, playback_only = false },
        function(_, res)
            if res and res.status == 0 then finish(res.stdout) else finish(nil) end
        end)
end

local function start(category)
    if o.api_key == "" then
        return osd("no API key: set api_key in script-opts/fazon_track.conf", 6)
    end
    if mp.get_property("path") == nil then return osd("nothing is playing") end
    busy = true
    ask_name(category, default_name(), function(name)
        name = clean_name(name)
        if name == "" then busy = false; return osd("cancelled") end
        osd("setting up " .. LABEL[category] .. " › " .. name .. " …", 10)
        ensure_subcat(category, name, function(stored, err)
            busy = false
            if not stored then return osd("couldn't set up the sub-category: " .. err, 8) end
            if track then stop(true) end
            track = { category = category, name = stored, path = mp.get_property("path"), secs = 0 }
            last_tick = mp.get_time()
            osd("● " .. LABEL[category] .. " › " .. stored, 4)
        end)
    end)
end

local function toggle(category)
    if busy then return end
    if track and track.category == category then return stop() end
    start(category) -- switching from the other category stops it once the new one is ready
end

-- The playlist moved on: keep tracking the same category, as the new video's title.
mp.register_event("file-loaded", function()
    if not track or track.path == mp.get_property("path") then return end
    if not o.continue_on_next_file then return stop() end
    bank(true)
    local name = default_name()
    if name == track.name then track.path = mp.get_property("path"); return end
    track.hold = true
    ensure_subcat(track.category, name, function(stored, err)
        if not track then return end
        track.hold = false
        last_tick = mp.get_time()
        if not stored then
            osd("couldn't set up " .. name .. " (" .. err .. "); stopped", 8)
            return stop(true)
        end
        track.name, track.path, track.secs = stored, mp.get_property("path"), 0
        osd("● " .. LABEL[track.category] .. " › " .. stored, 4)
    end)
end)

mp.register_event("shutdown", function()
    bank(true)
    if inflight then
        -- Its answer won't arrive now. It almost always succeeds, so count it as sent rather
        -- than risk logging it twice.
        for _, b in ipairs(inflight) do b.p.h = b.p.h - b.h end
        for i = #pending, 1, -1 do if pending[i].h <= 0 then table.remove(pending, i) end end
        inflight = nil
    end
    send(true)
    save_unsent()
end)

mp.add_key_binding(o.key_active, "track-active", function() toggle("active") end)
mp.add_key_binding(o.key_passive, "track-passive", function() toggle("passive") end)
mp.add_periodic_timer(1, tick)
mp.add_periodic_timer(60, function() send() end) -- retry anything that couldn't be sent

math.randomseed(os.time())
msg.verbose("Fazon Nexus Tracker " .. VERSION .. ", unsent time in " .. STATE_DIR)
load_saved()
send()
