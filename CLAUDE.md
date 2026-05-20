# jitsi_ynh-wraper — Claude Code context

Essential Energy fork of [YunoHost-Apps/jitsi_ynh](https://github.com/YunoHost-Apps/jitsi_ynh).
Adds an auto-recording pipeline on top of the stock Jitsi Meet YunoHost package.

## Architecture

```
Browser ──HTTPS──► Nginx ──► Jitsi Meet (web UI, /etc/jitsi/meet/)
                             │
                   Prosody (XMPP) ← conference MUC component
                             │  mod_auto_record (conf/mod_auto_record.lua)
                             │        │  fires systemctl restart/stop
                             ▼        ▼
                   Jicofo ──► jitsi-recorder@<room>.service (systemd template)
                                       │
                             /opt/jitsi-recorder/recorder-pipeline.sh
                                       │
                             gst-meet (Rust/GStreamer bot)
                                       │
                             /home/yunohost.app/jitsi/recordings/<room>-<ts>.webm
```

## Key files

| File | Purpose |
|---|---|
| `conf/mod_auto_record.lua` | Prosody module: watches MUC occupancy, fires systemctl |
| `conf/jitsi-recorder@.service` | systemd template unit for the recorder bot |
| `conf/recorder-pipeline.sh` | Wrapper: invokes gst-meet with the right GStreamer pipeline |
| `conf/jitsi-recorder.config` | Admin-editable config (RECORDINGS_DIR, RECORDING_MODE, etc.) |
| `conf/prosody.cfg.lua` | Prosody config template — loads mod_auto_record on the MUC component |
| `conf/jitsi-jicofo-jicofo.conf` | Jicofo HOCON config — authentication, bridge brewery |
| `scripts/_recorder.sh` | Build/install/remove helpers sourced by install, upgrade, remove |
| `scripts/install` | YunoHost install script |
| `scripts/upgrade` | YunoHost upgrade script |
| `scripts/config` | config_panel handler (reads/writes /etc/jitsi-recorder/config) |

## Phases (what's been built)

- **Phase 3a** — audio-only recording pipeline wrapper + prosody mod_websocket
- **Phase 4** — Prosody trigger (`mod_auto_record`) + systemd template + retention cron
- **Phase 5** — config_panel knobs (recording_mode, retention_days, low_mem_kb)
- **Phase 6** — recorder authenticates via a YunoHost LDAP user (`recorder` user, main vhost)

## Auto-record flow

1. Human joins `equipe@conference.<domain>` → `muc-occupant-joined` fires
2. `count_real` excludes focus, jvb, recorder bot; once ≥ `auto_record_min_occupants` real users are present → `systemctl --no-block restart jitsi-recorder@equipe.service`
3. systemd unit starts `recorder-pipeline.sh equipe <output.webm> audio_only`
4. `recorder-pipeline.sh` calls `gst-meet --nick=recorder ...` which joins the room via WebSocket/XMPP and captures audio
5. Last human leaves → `muc-occupant-left` fires → `count_real` (excluding the departing occupant) hits 0 → `systemctl --no-block stop jitsi-recorder@equipe.service`
6. gst-meet receives SIGTERM, flushes the webmmux trailer (TimeoutStopSec=20), exits cleanly

## Runtime paths

| Path | Contents |
|---|---|
| `/etc/jitsi-recorder/config` | Admin-readable settings (mode 0644) |
| `/etc/jitsi-recorder/credentials` | XMPP password (mode 0600, root:root) |
| `/etc/sudoers.d/jitsi-recorder-prosody` | NOPASSWD rule for prosody → systemctl |
| `/opt/jitsi-recorder/bin/gst-meet` | Compiled recorder binary |
| `/opt/jitsi-recorder/recorder-pipeline.sh` | Pipeline wrapper |
| `/var/log/jitsi-recorder/runtime.log` | Combined recorder log |
| `/var/log/jitsi-recorder/build.log` | gst-meet build log |
| `/home/yunohost.app/jitsi/recordings/` | Default output directory |
| `/etc/cron.daily/jitsi-recorder-retention` | Retention cleanup cron |

## Known gotchas

- **`muc-occupant-left` fires before Prosody removes the occupant from `_occupants`** on this Prosody version. `count_real` must pass `event.occupant` as `exclude` or the last-participant stop never fires.
- **`occupant.nick` on this server is a full MUC JID** (`room@muc/resource`), not a bare nickname. The recorder bot must be detected by `jid.split(occupant.bare_jid)` node part (`"recorder"`), not by `occupant.nick == "recorder"`.
- **Use `restart` not `start`** when triggering the recorder. `start` is a no-op if the unit is still deactivating from the previous meeting — `restart` atomically replaces it and guarantees a fresh GStreamer pipeline and output file.
- **Sudoers must include `restart`** in addition to start/stop. The rule lives at `/etc/sudoers.d/jitsi-recorder-prosody`; `_install_sudoers_rule` in `_recorder.sh` deploys it.
- **gst-meet build is slow** (~30-40 min on arm64). `_build_gst_meet` is idempotent — it skips the build if the installed binary matches the pinned commit SHA stored in `/opt/jitsi-recorder/.commit`.

## Pending / future work

- **Multi-room support**: `mod_auto_record` currently watches a single room (`auto_record_room`). Could be extended to a list or wildcard.
- **Video recording mode**: `recorder-pipeline.sh` supports `video` mode but it's untested end-to-end. Needs pipeline validation and MemoryMax tuning in the service unit.
- **Recording notifications**: No in-meeting notification to participants that they're being recorded. Could be added via Jitsi's `startRecording` IQ or a lobby message.
- **S3 / remote storage**: Recordings accumulate locally. An optional post-processing hook to upload to S3/Nextcloud would be useful.
- **Jicofo single-participant timeout**: Jicofo stays in the room indefinitely after humans leave (no `single-participant-timeout` configured). This is harmless (the stop fires on the last human departure), but configuring a short timeout would be cleaner.
- **config_panel: auto_record_room**: The target room is currently hardcoded at install time in `prosody.cfg.lua`. Exposing it in config_panel would let admins change it without editing the prosody config manually.

## Deployment notes

To redeploy auto-record components after editing (without a full reinstall):

```bash
cd /root/jitsi_ynh-wraper/scripts
sudo bash _recorder.sh auto-record   # reinstalls prosody module, systemd unit, sudoers, cron
sudo prosodyctl reload               # hot-reloads mod_auto_record
```

To rebuild gst-meet after a commit pin bump:

```bash
sudo bash /root/jitsi_ynh-wraper/scripts/_recorder.sh build
```
