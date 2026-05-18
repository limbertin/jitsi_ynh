#!/usr/bin/env bash
#
# gst-meet wrapper that joins a room and writes a recording.
#
# Installed to /opt/jitsi-recorder/recorder-pipeline.sh by scripts/install.
# Invoked by the jitsi-recorder@<room>.service systemd unit (Phase 4).
#
# Usage:   recorder-pipeline.sh <room> <output-file> [<mode>]
# Modes:   audio_only (default)      mix all participants' audio to one Opus track
#          smart_video               PLACEHOLDER — Phase 3b will land the screen-share
#                                    -priority/dominant-speaker-fallback pipeline. For
#                                    now this falls back to audio_only with a warning.
#          disabled                  exit 0 immediately, no recording
#
# Environment overrides:
#   XMPP_HOST       default: meet.essentialenergy.com.br
#   GST_MEET_BIN    default: /opt/jitsi-recorder/bin/gst-meet
#   LOW_MEM_KB      default: 256000 (256 MB)    force audio_only below this MemAvailable
#   XMPP_GUEST      default: guest.${XMPP_HOST}
#                   On YNH Jitsi, anonymous auth lives on this vhost; main vhost
#                   requires internal_hashed (used by jicofo/jvb only).
#   MUC_DOMAIN      default: conference.${XMPP_HOST}
#   FOCUS_JID       default: focus.${XMPP_HOST}  (the client_proxy COMPONENT address,
#                   NOT focus@auth.* which is the user JID). YNH Jitsi routes through
#                   the component proxy declared in prosody.cfg.lua.

set -euo pipefail

ROOM="${1:?room name required as arg 1}"
OUT="${2:?output file path required as arg 2}"
MODE="${3:-audio_only}"

XMPP_HOST="${XMPP_HOST:-meet.essentialenergy.com.br}"
XMPP_GUEST="${XMPP_GUEST:-guest.${XMPP_HOST}}"
MUC_DOMAIN="${MUC_DOMAIN:-conference.${XMPP_HOST}}"
FOCUS_JID="${FOCUS_JID:-focus.${XMPP_HOST}}"
GST_MEET_BIN="${GST_MEET_BIN:-/opt/jitsi-recorder/bin/gst-meet}"
LOW_MEM_KB="${LOW_MEM_KB:-256000}"

log() { echo "[recorder $$] $*"; }

if [[ ! -x "$GST_MEET_BIN" ]]; then
    log "ERROR: gst-meet binary missing at $GST_MEET_BIN"
    exit 1
fi

# Pre-create the output directory (gst-meet's filesink won't).
mkdir -p -- "$(dirname -- "$OUT")"

# Low-memory safety net: if MemAvailable is below threshold at start, force
# audio_only regardless of requested mode. Cheap insurance against OOM mid-call.
mem_avail_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
if (( mem_avail_kb < LOW_MEM_KB )) && [[ "$MODE" != "audio_only" && "$MODE" != "disabled" ]]; then
    log "WARN: MemAvailable=${mem_avail_kb}KB < ${LOW_MEM_KB}KB, forcing audio_only"
    MODE="audio_only"
fi

case "$MODE" in
    disabled)
        log "mode=disabled, exiting without recording"
        exit 0
        ;;
    smart_video)
        log "WARN: smart_video mode not yet implemented (Phase 3b), falling back to audio_only"
        MODE="audio_only"
        ;;
    audio_only)
        : # nothing to do, drop through
        ;;
    *)
        log "ERROR: unknown mode '$MODE'"
        exit 2
        ;;
esac

# Audio-only pipeline: gst-meet auto-links every remote participant's audio to
# the element named "audio". audiomixer combines them; opusenc + webmmux produces
# a streamable .webm with a single Opus track. Suffix .webm regardless of $OUT to
# avoid surprising consumers; .mkv would also work but webm is what Jitsi's own
# local recording produces, so downstream tooling is more likely to handle it.
PIPELINE="audiomixer name=audio ! audioconvert ! audioresample ! opusenc ! webmmux ! filesink location=${OUT}"

log "joining room=$ROOM as nick=recorder, writing to $OUT"
log "pipeline: $PIPELINE"

# exec replaces the bash process so systemd's TERM signal reaches gst-meet directly,
# letting it close the file cleanly when the room empties or the unit stops.
exec "$GST_MEET_BIN" \
    --web-socket-url="wss://${XMPP_HOST}/xmpp-websocket" \
    --xmpp-domain="$XMPP_GUEST" \
    --muc-domain="$MUC_DOMAIN" \
    --focus-jid="$FOCUS_JID" \
    --room-name="$ROOM" \
    --nick=recorder \
    --recv-pipeline="$PIPELINE"
