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

### `all.css` — park-alongside (manual merge)

Upstream rebuilds `css/all.css` with each Jitsi release; class names and CSS
variables shift, so blindly overwriting it risks silently breaking layouts.
Instead, `_apply_branding` lays out three files per upgrade:

```
$install_dir/jitsi-meet-web/css/
├── all.css                  ← fresh upstream (live, served by nginx)
├── all.css.upstream-prev    ← upstream from the PREVIOUS release (for 3-way diff)
└── all.css-custom           ← OUR customized version, never served
```

`all.css.upstream-prev` is stashed in `/etc/$app/branding/` between upgrades
so it survives `_setup_sources`'s `ynh_safe_rm` of the meet-web tree.

**After each upgrade, branding CSS rules are temporarily inactive** until you
SSH in and merge. Workflow:

```bash
cd /var/www/jitsi/jitsi-meet-web/css
diff -u all.css.upstream-prev all.css       # what upstream changed this release
diff -u all.css.upstream-prev all.css-custom # what we changed vs. previous upstream
# Hand-merge desired rules from all.css-custom into all.css.
# Optionally update conf/branding/all.css in the fork to match the merged result
# so future upgrades start from the right baseline.
sudo systemctl reload nginx                  # not strictly needed, browsers will refetch
```

**Security note:** `all.css-custom` is technically reachable at
`https://<domain>/css/all.css-custom`. It's just CSS, not a credential leak,
but the file is visible. Move it out of the web root if that bothers you
(edit `_apply_branding` to write to `/etc/$app/branding/all.css-custom` instead).

### Updating either file

Replace the file in `conf/branding/`, commit, push, and run
`yunohost app upgrade jitsi -u <fork-url>`. For `watermark.svg` the change is
live immediately. For `all.css` you still need to do the manual merge step
above on the VPS.

## Auto-recording (planned — phases 2–5)

See `Tasks` in the project tracker. Recording runs on the host as a
`gst-meet`-based bot triggered by a Prosody MUC hook for the configured room.
Modes: `audio_only` / `smart_video` (screen-share priority, dominant-speaker
fallback) / `disabled`, exposed in `config_panel.toml`.
