#!/bin/bash
#
# Build, install, and clean up gst-meet for the auto-recorder feature.
#
# This file is sourced by scripts/install, scripts/upgrade, and scripts/remove
# to get the helpers below. It can also be invoked directly for testing:
#
#   sudo bash scripts/_recorder.sh build      # build + install gst-meet
#   sudo bash scripts/_recorder.sh smoke      # smoke-test the installed binary
#   sudo bash scripts/_recorder.sh remove     # uninstall everything
#
# Layout (everything under one prefix for easy cleanup):
#   /opt/jitsi-recorder/
#     ├── bin/gst-meet              installed binary
#     ├── rust/{cargo,rustup}/      isolated Rust toolchain
#     ├── src/                      pinned gst-meet checkout
#     └── .commit                   SHA the installed binary was built from
#
# Memory safety: cargo's LLVM codegen phase peaks around 2-2.5 GB. On boxes
# where MemAvailable+SwapFree falls below the safety threshold, _install_temp_swap
# creates a temporary swapfile that _remove_temp_swap tears down post-build.
# On boxes with enough headroom (>= ~2.5 GB available), no swap is created.

set -euo pipefail

# ---- pinned constants -------------------------------------------------------

# Pinned to avstack/gst-meet @ 2024-10-10 (most recent commit on main as of
# fork inception). Pin lets us rebuild deterministically; bump deliberately.
GST_MEET_COMMIT="${GST_MEET_COMMIT:-2947267f8d2ca780b010cd4f4c38e0f41cda0009}"
GST_MEET_REPO="${GST_MEET_REPO:-https://github.com/avstack/gst-meet.git}"

RECORDER_PREFIX="${RECORDER_PREFIX:-/opt/jitsi-recorder}"
RECORDER_BIN="$RECORDER_PREFIX/bin/gst-meet"
RECORDER_SRC="$RECORDER_PREFIX/src"
RECORDER_RUST_HOME="$RECORDER_PREFIX/rust"
RECORDER_COMMIT_FILE="$RECORDER_PREFIX/.commit"

SWAP_FILE="${SWAP_FILE:-/var/cache/jitsi-recorder.swap}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-4096}"
# If MemAvailable + SwapFree >= this many KB, skip creating temp swap.
SWAP_SKIP_THRESHOLD_KB="${SWAP_SKIP_THRESHOLD_KB:-2621440}"  # 2.5 GB

# ---- auto-record (Phase 4) paths ------------------------------------------
RECORDER_CONFIG_DIR="${RECORDER_CONFIG_DIR:-/etc/jitsi-recorder}"
RECORDER_CONFIG="$RECORDER_CONFIG_DIR/config"
RECORDER_CREDENTIALS="$RECORDER_CONFIG_DIR/credentials"
RECORDER_RECORDINGS_DIR_DEFAULT="/home/yunohost.app/jitsi/recordings"
RECORDER_PLUGIN_DIR="/var/lib/jitsi-recorder/prosody-plugins"
RECORDER_LOG_DIR="/var/log/jitsi-recorder"
RECORDER_SYSTEMD_UNIT="/etc/systemd/system/jitsi-recorder@.service"
RECORDER_CRON="/etc/cron.daily/jitsi-recorder-retention"

# ---- helpers ----------------------------------------------------------------

_log() { echo "[recorder] $*"; }

_meminfo_kb() {
    awk -v key="$1:" '$1==key {print $2; exit}' /proc/meminfo
}

_install_temp_swap() {
    local mem_kb swap_kb total_kb
    mem_kb=$(_meminfo_kb MemAvailable)
    swap_kb=$(_meminfo_kb SwapFree)
    total_kb=$(( mem_kb + swap_kb ))
    if (( total_kb >= SWAP_SKIP_THRESHOLD_KB )); then
        _log "MemAvailable+SwapFree=$(( total_kb / 1024 ))MB >= threshold, no temp swap needed"
        return 0
    fi
    if [[ -e "$SWAP_FILE" ]]; then
        _log "temp swap already exists at $SWAP_FILE — leaving alone"
        return 0
    fi
    _log "creating ${SWAP_SIZE_MB}MB temp swap at $SWAP_FILE"
    fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE"
    chmod 0600 "$SWAP_FILE"
    mkswap -q "$SWAP_FILE"
    swapon "$SWAP_FILE"
}

_remove_temp_swap() {
    if [[ -e "$SWAP_FILE" ]]; then
        _log "removing temp swap $SWAP_FILE"
        swapoff "$SWAP_FILE" || true
        rm -f -- "$SWAP_FILE"
    fi
}

_install_rustup() {
    if [[ -x "$RECORDER_RUST_HOME/cargo/bin/cargo" ]]; then
        _log "rustup toolchain already present"
        return 0
    fi
    _log "installing isolated rustup toolchain into $RECORDER_RUST_HOME"
    mkdir -p "$RECORDER_RUST_HOME"
    RUSTUP_HOME="$RECORDER_RUST_HOME/rustup" \
    CARGO_HOME="$RECORDER_RUST_HOME/cargo" \
        bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path --default-toolchain stable --profile minimal'
}

_clone_gst_meet() {
    if [[ -d "$RECORDER_SRC/.git" ]]; then
        _log "updating existing gst-meet checkout"
        git -C "$RECORDER_SRC" fetch --quiet origin
    else
        _log "cloning gst-meet"
        mkdir -p "$RECORDER_SRC"
        git clone --quiet "$GST_MEET_REPO" "$RECORDER_SRC"
    fi
    git -C "$RECORDER_SRC" checkout --quiet "$GST_MEET_COMMIT"
}

_build_gst_meet() {
    # Idempotent: skip the whole dance if the installed binary already matches
    # the pinned commit. Drops 30+ minutes off most upgrade runs.
    if [[ -x "$RECORDER_BIN" ]] \
            && [[ "$(cat "$RECORDER_COMMIT_FILE" 2>/dev/null)" == "$GST_MEET_COMMIT" ]]; then
        _log "gst-meet already built at $GST_MEET_COMMIT, skipping rebuild"
        return 0
    fi

    _install_temp_swap
    # Ensure swap is torn down even if any later step fails.
    trap '_remove_temp_swap' EXIT

    _install_rustup
    _clone_gst_meet

    export RUSTUP_HOME="$RECORDER_RUST_HOME/rustup"
    export CARGO_HOME="$RECORDER_RUST_HOME/cargo"
    export PATH="$CARGO_HOME/bin:$PATH"

    _log "building gst-meet (cargo --release -j1) — expect 25-40 min on arm64"
    (cd "$RECORDER_SRC" && cargo build --release -j1 --bin gst-meet)

    install -m 0755 -D "$RECORDER_SRC/target/release/gst-meet" "$RECORDER_BIN"
    echo "$GST_MEET_COMMIT" > "$RECORDER_COMMIT_FILE"

    # Drop ~1.2 GB of compiled artifacts; we have the binary now.
    rm -rf "$RECORDER_SRC/target"
    _log "installed gst-meet to $RECORDER_BIN"

    trap - EXIT
    _remove_temp_swap
}

_smoke_test_gst_meet() {
    if [[ ! -x "$RECORDER_BIN" ]]; then
        _log "ERROR: $RECORDER_BIN missing"
        return 1
    fi
    _log "smoke test: $RECORDER_BIN --help"
    "$RECORDER_BIN" --help > /dev/null
    _log "smoke test passed"
}

_install_pipeline_wrapper() {
    # The wrapper script ships in conf/recorder-pipeline.sh in the fork and is
    # installed alongside the binary. Idempotent — install(1) overwrites if changed.
    local src_dir="../conf"
    [[ -d "$src_dir" ]] || src_dir="${YNH_APP_BASEDIR:-.}/conf"
    if [[ ! -f "$src_dir/recorder-pipeline.sh" ]]; then
        _log "WARN: $src_dir/recorder-pipeline.sh not found, skipping pipeline wrapper install"
        return 0
    fi
    install -m 0755 -D "$src_dir/recorder-pipeline.sh" "$RECORDER_PREFIX/recorder-pipeline.sh"
    _log "installed pipeline wrapper to $RECORDER_PREFIX/recorder-pipeline.sh"
}

# ---- Phase 4: auto-record install helpers ---------------------------------

_install_prosody_module() {
    local src_dir="../conf"
    [[ -d "$src_dir" ]] || src_dir="${YNH_APP_BASEDIR:-.}/conf"
    install -m 0644 -D "$src_dir/mod_auto_record.lua" "$RECORDER_PLUGIN_DIR/mod_auto_record.lua"
    _log "installed prosody mod_auto_record.lua into $RECORDER_PLUGIN_DIR"
}

_install_systemd_template() {
    local src_dir="../conf"
    [[ -d "$src_dir" ]] || src_dir="${YNH_APP_BASEDIR:-.}/conf"
    install -m 0644 "$src_dir/jitsi-recorder@.service" "$RECORDER_SYSTEMD_UNIT"
    systemctl daemon-reload
    _log "installed $RECORDER_SYSTEMD_UNIT"
}

_install_recorder_config() {
    # Preserves admin edits: only deploys the default if the file doesn't exist.
    # Phase 5 will overwrite this file on config_panel changes.
    local src_dir="../conf"
    [[ -d "$src_dir" ]] || src_dir="${YNH_APP_BASEDIR:-.}/conf"
    mkdir -p "$RECORDER_CONFIG_DIR"
    if [[ -f "$RECORDER_CONFIG" ]]; then
        _log "$RECORDER_CONFIG already exists, preserving admin's values"
    else
        install -m 0644 "$src_dir/jitsi-recorder.config" "$RECORDER_CONFIG"
        _log "installed default $RECORDER_CONFIG"
    fi
}

_install_retention_cron() {
    local src_dir="../conf"
    [[ -d "$src_dir" ]] || src_dir="${YNH_APP_BASEDIR:-.}/conf"
    install -m 0755 "$src_dir/jitsi-recorder-retention.cron" "$RECORDER_CRON"
    _log "installed retention cron at $RECORDER_CRON"
}

_setup_recordings_dir() {
    # Honor admin's RECORDINGS_DIR setting if /etc/jitsi-recorder/config has it.
    local dir="$RECORDER_RECORDINGS_DIR_DEFAULT"
    if [[ -r "$RECORDER_CONFIG" ]]; then
        local cfg_dir
        cfg_dir=$(awk -F= '/^RECORDINGS_DIR=/ {print $2; exit}' "$RECORDER_CONFIG" | tr -d '"' | tr -d "'")
        [[ -n "$cfg_dir" ]] && dir="$cfg_dir"
    fi
    mkdir -p "$dir" "$RECORDER_LOG_DIR"
    chmod 0755 "$dir" "$RECORDER_LOG_DIR"
    _log "ensured $dir and $RECORDER_LOG_DIR exist"
}

_write_recorder_credentials() {
    # Writes /etc/jitsi-recorder/credentials sourced by the systemd unit.
    # Args: <recorder_user> <recorder_vhost> <recorder_password>
    #
    # The file is mode 0600 root-only — distinct from /etc/jitsi-recorder/config
    # (world-readable, managed by config_panel) so the secret can never leak
    # via the YNH web UI binding.
    local user="$1" vhost="$2" password="$3"
    mkdir -p "$RECORDER_CONFIG_DIR"
    umask 0177
    cat > "$RECORDER_CREDENTIALS" <<EOF
# /etc/jitsi-recorder/credentials
# Auto-generated by scripts/install. Mode 0600 root:root. DO NOT commit.
XMPP_USERNAME=$user
XMPP_AUTH_DOMAIN=$vhost
XMPP_PASSWORD=$password
EOF
    chmod 0600 "$RECORDER_CREDENTIALS"
    chown root:root "$RECORDER_CREDENTIALS"
    _log "wrote $RECORDER_CREDENTIALS (mode 0600 root:root)"
}

_install_auto_record() {
    # Top-level entry point called from scripts/install + scripts/upgrade.
    _install_prosody_module
    _install_systemd_template
    _install_recorder_config
    _install_retention_cron
    _setup_recordings_dir
}

_remove_auto_record() {
    # Stop any running recorder instances before yanking the unit file.
    local units
    units=$(systemctl list-units --no-legend --no-pager 'jitsi-recorder@*.service' 2>/dev/null | awk '{print $1}' || true)
    for unit in $units; do
        _log "stopping $unit"
        systemctl stop "$unit" || true
    done
    rm -f -- "$RECORDER_SYSTEMD_UNIT" "$RECORDER_CRON"
    rm -rf -- "$RECORDER_PLUGIN_DIR" "$RECORDER_CONFIG_DIR"
    systemctl daemon-reload || true
    _log "auto-record components removed (credentials at $RECORDER_CREDENTIALS deleted with $RECORDER_CONFIG_DIR)"
}

_remove_recorder() {
    _log "removing $RECORDER_PREFIX"
    rm -rf -- "$RECORDER_PREFIX"
    _remove_temp_swap
}

# ---- direct-invocation dispatcher ------------------------------------------

# If this file is being EXECUTED (not sourced), accept a subcommand.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        build)        _build_gst_meet ;;
        pipeline)     _install_pipeline_wrapper ;;
        auto-record)  _install_auto_record ;;
        smoke)        _smoke_test_gst_meet ;;
        remove)       _remove_recorder ; _remove_auto_record ;;
        *)            echo "usage: $0 {build|pipeline|auto-record|smoke|remove}" >&2; exit 2 ;;
    esac
fi
