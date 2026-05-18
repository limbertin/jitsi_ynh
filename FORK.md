# Essential Energy fork of `jitsi_ynh`

Internal notes for this fork. Upstream `README.md` is auto-generated and gets
overwritten by `readme_generator` on every release — keep fork-specific docs
here instead.

## Branding

Custom assets live in `conf/branding/`. Two different policies:

### `watermark.svg` — overlay

Overwrites `$install_dir/jitsi-meet-web/images/watermark.svg` on every install,
upgrade, and restore. Safe because the watermark slot has a stable shape across
Jitsi releases.

### `all.css` — park-alongside (manual merge + automated sync-back)

Upstream rebuilds `css/all.css` with each Jitsi release; class names and CSS
variables shift, so blindly overwriting it risks silently breaking layouts.
Instead, `_apply_branding` lays out three files per upgrade:

```
$install_dir/jitsi-meet-web/css/
├── all.css                  ← fresh upstream (live, served by nginx)
├── all.css.upstream-prev    ← upstream from the PREVIOUS release (for 3-way diff)
└── all.css-custom           ← our PREVIOUS merged baseline, never served
```

`all.css.upstream-prev` is stashed in `/etc/$app/branding/` between upgrades
so it survives `_setup_sources`'s `ynh_safe_rm` of the meet-web tree.

**Semantic note:** `conf/branding/all.css` in this repo represents the **last
fully-merged baseline**, NOT "just the custom delta". That loop-stable
semantic is what makes `tools/sync-branding-from-live.sh` work (see below).

**After each upgrade, branding CSS rules are temporarily inactive** until you
SSH in and merge. The full ritual is two phases:

```bash
# Phase A — on the VPS, hand-merge into the live file:
cd /var/www/jitsi/jitsi-meet-web/css
diff -u all.css.upstream-prev all.css        # what upstream changed this release
diff -u all.css.upstream-prev all.css-custom # what we kept from last release
sudo vim all.css                              # merge by hand
sudo systemctl reload nginx                   # optional, browsers will refetch

# Phase B — sync the merged result back into the repo, automatically:
cd ~/jitsi_ynh-wraper
./tools/sync-branding-from-live.sh
# (commits + pushes on its own; no prompts)
```

The helper script is idempotent — re-running it after no changes is a no-op.
It only stages `conf/branding/all.css`, so unrelated uncommitted work is
unaffected.

**Security note:** `all.css-custom` is technically reachable at
`https://<domain>/css/all.css-custom`. It's just CSS, not a credential leak,
but the file is visible. Move it out of the web root if that bothers you
(edit `_apply_branding` to write to `/etc/$app/branding/all.css-custom` instead).

### Updating either file

Replace the file in `conf/branding/`, commit, push, and run
`yunohost app upgrade jitsi -u <fork-url>`. For `watermark.svg` the change is
live immediately. For `all.css` you still need to do the manual merge step
above on the VPS.

## Auto-recording

Recording runs on the host as a `gst-meet`-based bot triggered by a Prosody
MUC hook for the configured room. Modes: `audio_only` / `smart_video`
(screen-share priority, dominant-speaker fallback) / `disabled`, exposed in
`config_panel.toml`.

### Phase 2 — recorder build pipeline (this commit)

`scripts/_recorder.sh` provides helpers that build `gst-meet` from a pinned
upstream commit during `scripts/install` and `scripts/upgrade`. Everything
the recorder needs lives under one prefix for trivial cleanup:

```
/opt/jitsi-recorder/
├── bin/gst-meet              ← the installed binary
├── rust/{cargo,rustup}/      ← isolated Rust toolchain (~1.5 GB)
├── src/                      ← pinned gst-meet checkout (target/ deleted post-build)
└── .commit                   ← SHA of the commit the binary was built from
```

**Memory safety.** Cargo's LLVM codegen phase peaks around 2–2.5 GB. If
`MemAvailable + SwapFree` is below 2.5 GB at build time, `_install_temp_swap`
creates a 4 GB swapfile at `/var/cache/jitsi-recorder.swap` and tears it down
when the build finishes (success or failure — there's an EXIT trap).

**Idempotency.** `_build_gst_meet` checks `/opt/jitsi-recorder/.commit`
against the pinned SHA and skips the build entirely if they match. Most
upgrades will add zero recorder time; only commit bumps trigger a rebuild.

**Build time:** 25–40 minutes on arm64 with `-j1`. The install/upgrade
script runs Jitsi service startup *before* the build, so the meeting server
is up and serving while the recorder builds in the background.

**Failure handling.** If the build fails, the install/upgrade script logs a
warning and continues — Jitsi itself remains fully functional, just without
the recorder. The admin can retry manually:

```bash
sudo bash /var/www/jitsi/../settings/scripts/_recorder.sh build
# or equivalently from the fork checkout:
sudo bash /path/to/jitsi_ynh/scripts/_recorder.sh build
```

The full build log is at `/var/log/jitsi-recorder/build.log`.

### Bumping the pinned `gst-meet` commit

Edit `GST_MEET_COMMIT` at the top of `scripts/_recorder.sh`, push, run
`yunohost app upgrade jitsi`. The idempotency check will see the mismatch
and rebuild. Run a smoke test afterwards:

```bash
sudo bash /path/to/jitsi_ynh/scripts/_recorder.sh smoke
```

### Phase 3a — audio-only recording wrapper (this commit)

`conf/recorder-pipeline.sh` is the shell-level entry point that the systemd
unit (Phase 4) will exec. It takes `<room> <output-file> [<mode>]`, picks a
GStreamer pipeline based on `<mode>`, and invokes `gst-meet` with the
arguments that match this YNH-flavored Jitsi setup.

**YNH Jitsi auth/routing quirks the wrapper handles by default:**

| Argument | Default | Why |
|---|---|---|
| `--xmpp-domain` | `guest.${XMPP_HOST}` | Main vhost uses internal_hashed; only `guest.*` accepts anonymous SASL. The web client uses guest too. |
| `--muc-domain` | `conference.${XMPP_HOST}` | MUC component address — does NOT inherit from xmpp-domain. |
| `--focus-jid` | `focus.${XMPP_HOST}` | The client_proxy *component* address from prosody.cfg.lua. Sending to `focus@auth.*` (user JID) silently fails. |

**Modes:**
- `audio_only` (default) — `audiomixer ! audioconvert ! opusenc ! webmmux ! filesink`. ~80 MB RSS during a call.
- `smart_video` — placeholder, falls back to `audio_only` with a warning. Will activate after Phase 3b lands.
- `disabled` — exit 0 without recording.

A low-memory safety net forces `audio_only` if `MemAvailable` at start is
below `LOW_MEM_KB` (default 256 MB), regardless of requested mode.

The wrapper uses `exec` so SIGTERM from systemd reaches `gst-meet` directly,
giving it a chance to flush the webmmux and close the file cleanly.

### Prerequisite: prosody mod_websocket

`gst-meet` only speaks WebSocket; it doesn't support BOSH. This fork's
`conf/prosody.cfg.lua` enables `mod_websocket` on the main VirtualHost (the
upstream YNH template only enables `mod_bosh`, which is why the web client
silently falls back to long-polling). This change is benign for non-recorder
clients — modern web clients prefer WebSocket when available.

### KNOWN ISSUE: JVB health checks (separate from this fork)

On the box where this was developed, jicofo logs **"Health check timed out
for Bridge..."** repeatedly (32 occurrences observed pre-development). When
this is happening, jicofo replies `service-unavailable` to conference-
allocation IQs, including the recorder's. Symptoms in `gst-meet` logs:

```
INFO  Logged in anonymously
ERROR error=focus IQ failed
ERROR fatal (in read loop): focus IQ failed
```

This is **not** a recorder bug; it affects any client trying to allocate a
new conference. Two- person meetings may still work because Jitsi falls back
to P2P. To debug, check `/var/log/jitsi/jitsi-videobridge.log` and the JVB
↔ prosody secret in `/etc/jitsi/videobridge/sip-communicator.properties`.
Out of scope for this fork.

### Phase 4 — Prosody trigger + systemd template + retention cron

* `conf/mod_auto_record.lua` — Prosody MUC plugin hooked on `muc-occupant-
  joined` and `-left`. Counts "real" participants (excludes focus, jvb, the
  recorder bot itself) and runs `systemctl --no-block start|stop
  jitsi-recorder@<room>.service`. Room name is sanitized to `[A-Za-z0-9_-]+`
  before going to `os.execute`.
* `conf/jitsi-recorder@.service` — systemd template (`%i = room name`).
  EnvironmentFile `/etc/jitsi-recorder/config`. Composes output path inline
  with `date -u`. `MemoryMax=400M`, `CPUQuota=120%` to fence the bot from
  OOM-ing the box. SIGTERM-on-stop with 20s grace so webmmux can flush.
* `conf/jitsi-recorder-retention.cron` — daily cleanup. Defensive against
  `RETENTION_DAYS=0`/non-numeric values.
* `conf/jitsi-recorder.config` — defaults. `_install_recorder_config`
  preserves admin edits — only deploys defaults when the file is absent.

The plugin is dropped into `/var/lib/jitsi-recorder/prosody-plugins/`, which
the fork adds as a second `plugin_paths` entry so the module survives
`_setup_sources`'s `ynh_safe_rm` of the meet-web tree.

### Phase 5 — config_panel knobs

`[main.autorecord]` section in `config_panel.toml` exposes:

| Setting | Type | Default | Persisted to |
|---|---|---|---|
| `recording_mode` | select (audio_only / smart_video / disabled) | `audio_only` | `RECORDING_MODE=` in `/etc/jitsi-recorder/config` |
| `retention_days` | number | `365` | `RETENTION_DAYS=` |
| `low_mem_kb` | number | `256000` | `LOW_MEM_KB=` |

Changes take effect on the **next** recorder start — no service restart
needed, because the systemd unit re-reads `/etc/jitsi-recorder/config` on
each instance launch.

**What's deliberately NOT in the config panel:** the target room name. It's
set in `conf/prosody.cfg.lua` as `auto_record_room = "equipe"`. Changing it
requires editing that template + `yunohost app upgrade` to redeploy the
prosody config + restart prosody. If you need to change it, do that
manually; making it a panel toggle would silently fail until the upgrade.

### Phase 3b (deferred indefinitely)

Smart-video Rust patch on `gst-meet/src/main.rs` (screen-share priority,
dominant-speaker fallback). Tracked in task #6 but not scheduled. Until
landed, `smart_video` mode in `recording_mode` falls back to `audio_only`
with a warning in `/var/log/jitsi-recorder/runtime.log`.
