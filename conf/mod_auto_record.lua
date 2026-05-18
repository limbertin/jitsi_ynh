-- mod_auto_record.lua
--
-- Triggers a systemd template unit when a target MUC reaches a minimum
-- count of "real" participants, and stops the unit when the room empties.
--
-- Load this on the conference MUC component:
--
--     Component "conference.example.com" "muc"
--         auto_record_room = "equipe"          -- room localpart, no MUC suffix
--         auto_record_min_occupants = 2        -- start when >= this many real users
--         modules_enabled = { "auto_record"; ... }
--
-- "Real" participants exclude focus (jicofo), jvb (videobridge), and the
-- recorder bot itself, identified by the nick "recorder".
--
-- The unit name is `jitsi-recorder@<room>.service`. The room localpart is
-- sanitized — only [A-Za-z0-9_-] is accepted; anything else is rejected
-- to avoid shell injection via the os.execute call.

local jid = require "util.jid"

local target_room    = module:get_option_string("auto_record_room", "")
local min_occupants  = module:get_option_number("auto_record_min_occupants", 2)
local recorder_nick  = module:get_option_string("auto_record_bot_nick", "recorder")

if target_room == "" then
    module:log("info", "auto_record_room is empty, module is loaded but inert")
end

-- room.jid -> true once we've started a recording for this session.
-- Cleared when the room drops to zero real participants.
local triggered = {}

local function room_local(room)
    return (jid.split(room.jid))
end

local function is_target(room)
    return target_room ~= "" and room_local(room) == target_room
end

local function is_real(occupant)
    if not occupant or not occupant.bare_jid then return false end
    local node = jid.split(occupant.bare_jid)
    if node == "focus" or node == "jvb" then return false end
    if occupant.nick == recorder_nick then return false end
    return true
end

local function count_real(room)
    local n = 0
    if room._occupants then
        for _, occ in pairs(room._occupants) do
            if is_real(occ) then n = n + 1 end
        end
    end
    return n
end

local function safe_unit(name)
    -- Only allow characters guaranteed safe in a systemd template instance.
    -- Anything else returns nil, which the caller treats as "refuse to act".
    if name:match("^[%w_-]+$") then return name end
    return nil
end

local function trigger(action, room_localpart)
    local unit = safe_unit(room_localpart)
    if not unit then
        module:log("warn", "refusing to %s recorder for unsafe room name '%s'", action, room_localpart)
        return
    end
    local cmd = "systemctl --no-block " .. action .. " jitsi-recorder@" .. unit .. ".service"
    module:log("info", "%s", cmd)
    os.execute(cmd)
end

module:hook("muc-occupant-joined", function (event)
    local room = event.room
    if not is_target(room) then return end
    local n = count_real(room)
    if n >= min_occupants and not triggered[room.jid] then
        triggered[room.jid] = true
        trigger("start", room_local(room))
    end
end)

module:hook("muc-occupant-left", function (event)
    local room = event.room
    if not is_target(room) then return end
    local n = count_real(room)
    if n == 0 and triggered[room.jid] then
        triggered[room.jid] = nil
        trigger("stop", room_local(room))
    end
end)

module:log("info", "loaded; target_room=%s min_occupants=%d",
    target_room == "" and "<unset>" or target_room, min_occupants)
