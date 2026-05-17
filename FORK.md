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

### Phases 3–5 (not yet implemented)

- Phase 3: Rust patch to `gst-meet`'s `examples/record.rs` adding the
  screen-share-priority → dominant-speaker fallback state machine.
- Phase 4: Prosody `mod_auto_record.lua` + `jitsi-recorder@.service`
  systemd template + retention cron.
- Phase 5: `config_panel.toml` `[main.autorecord]` section exposing mode,
  room name, retention, and the low-memory fallback threshold.
