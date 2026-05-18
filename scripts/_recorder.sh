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

_remove_recorder() {
    _log "removing $RECORDER_PREFIX"
    rm -rf -- "$RECORDER_PREFIX"
    _remove_temp_swap
}

# ---- direct-invocation dispatcher ------------------------------------------

# If this file is being EXECUTED (not sourced), accept a subcommand.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        build)    _build_gst_meet ;;
        pipeline) _install_pipeline_wrapper ;;
        smoke)    _smoke_test_gst_meet ;;
        remove)   _remove_recorder ;;
        *)        echo "usage: $0 {build|pipeline|smoke|remove}" >&2; exit 2 ;;
    esac
fi
