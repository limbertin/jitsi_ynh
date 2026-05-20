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
    local bare_node = jid.split(occupant.bare_jid)
    -- System participants registered on the auth vhost.
    if bare_node == "focus" or bare_node == "jvb" then return false end
    -- Recorder bot. Match against the bare-JID local-part (always "recorder"
    -- because scripts/install provisions a YNH user with that exact name) OR
    -- the resource portion of the nick. Prosody's occupant.nick may hold
    -- either the bare nickname OR the full room@muc/resource MUC JID
    -- depending on version — observed as the latter on this server, which
    -- caused the simple equality check on occupant.nick to miss the bot and
    -- keep count_real stuck at 1 indefinitely.
    if bare_node == recorder_nick then return false end
    local _, _, nick_resource = jid.split(occupant.nick or "")
    if (nick_resource or occupant.nick) == recorder_nick then return false end
    return true
end

local function count_real(room, exclude)
    -- exclude: occupant object to ignore (the one currently departing).
    -- muc-occupant-left fires before Prosody removes the occupant from
    -- _occupants, so we must subtract the departing participant manually.
    local n = 0
    if room._occupants then
        for _, occ in pairs(room._occupants) do
            if occ ~= exclude and is_real(occ) then n = n + 1 end
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
    -- sudo is required: prosody runs as the prosody user and cannot talk to
    -- the system D-Bus directly. /etc/sudoers.d/jitsi-recorder-prosody grants
    -- NOPASSWD permission for exactly these two commands.
    local cmd = "sudo /usr/bin/systemctl --no-block " .. action .. " jitsi-recorder@" .. unit .. ".service"
    module:log("info", "%s", cmd)
    local ok = os.execute(cmd)
    if not ok then
        module:log("error", "command failed (exit non-zero): %s", cmd)
    end
end

module:hook("muc-occupant-joined", function (event)
    local room = event.room
    if not is_target(room) then return end
    local n = count_real(room)
    if n >= min_occupants and not triggered[room.jid] then
        triggered[room.jid] = true
        -- Use restart rather than start: if a previous gst-meet instance is still
        -- running or deactivating (stop/start race between back-to-back meetings),
        -- restart atomically kills it before launching the new one. This guarantees
        -- a fresh GStreamer pipeline and a fresh output file for every meeting.
        -- On an already-inactive unit, restart is identical to start.
        trigger("restart", room_local(room))
    end
end)

module:hook("muc-occupant-left", function (event)
    local room = event.room
    if not is_target(room) then return end

    -- Exclude the departing occupant: Prosody fires this event before removing
    -- them from _occupants in some versions. Without this exclusion count_real
    -- would return 1 when the last real participant leaves, and the stop would
    -- never fire.
    local n = count_real(room, event.occupant)

    -- Diagnostic dump: log every occupant still considered present, so we can
    -- see exactly what's keeping count_real above zero if the stop misfires.
    if n > 0 then
        local lines = {}
        for occ_jid, occ in pairs(room._occupants or {}) do
            table.insert(lines, string.format(
                "%s [bare=%s nick=%s real=%s departing=%s]",
                tostring(occ_jid),
                tostring(occ and occ.bare_jid),
                tostring(occ and occ.nick),
                tostring(is_real(occ)),
                tostring(occ == event.occupant)))
        end
        module:log("info", "muc-occupant-left: room=%s remaining_real=%d occupants={%s}",
            room_local(room), n, table.concat(lines, " | "))
    else
        module:log("info", "muc-occupant-left: room=%s remaining_real=0, issuing stop",
            room_local(room))
    end

    if n == 0 then
        -- Drop the `triggered` precondition: systemctl stop on an already-
        -- inactive unit is a harmless no-op, and removing the gate means we
        -- recover even if the module was reloaded mid-recording (which would
        -- have wiped the `triggered` table).
        triggered[room.jid] = nil
        trigger("stop", room_local(room))
    end
end)

module:log("info", "loaded; target_room=%s min_occupants=%d",
    target_room == "" and "<unset>" or target_room, min_occupants)
