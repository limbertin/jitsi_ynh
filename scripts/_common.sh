#!/bin/bash

#=================================================
# COMMON VARIABLES AND CUSTOM HELPERS
#=================================================

_setup_sources() {
    # Download, check integrity, uncompress and patch the source from app.src
    declare -A packages=(
        [jitsi-jicofo]="jicofo"
        [jitsi-meet-prosody]="jitsi-meet/prosody-plugins"
        [jitsi-meet-web]="jitsi-meet"
        [jitsi-videobridge]="jitsi-videobridge"
    )

    for package in "${!packages[@]}"; do
        ynh_safe_rm "$install_dir/${package}"
        ynh_setup_source --dest_dir="$install_dir/temp" --source_id="$package"
        pushd "$install_dir/temp"
            ar x "$package.deb" data.tar.xz
            tar xf data.tar.xz
        popd

        mv "$install_dir/temp/usr/share/${packages[$package]}/" "$install_dir/$package/"
        ynh_safe_rm "$install_dir/temp"
    done
}

_apply_branding() {
    # Apply fork-specific assets onto the freshly extracted jitsi-meet-web tree.
    # Must run AFTER _setup_sources (install, upgrade) or AFTER ynh_restore "$install_dir"
    # (restore), because both repopulate $install_dir/jitsi-meet-web/ from upstream.
    #
    # Two policies, picked per file based on upstream churn risk:
    #
    #   watermark.svg → OVERLAY. The slot is stable across Jitsi releases; safe to overwrite.
    #
    #   all.css → PARK-ALONGSIDE. Upstream rebuilds this file with each release; class names
    #             and variables shift. We do NOT overwrite. Instead:
    #               - the freshly extracted upstream all.css is preserved as the live file
    #               - our customized version is placed next to it as all.css-custom
    #               - the *previous* upstream all.css (if any survived from before this
    #                 upgrade) is saved as all.css.upstream-prev so the admin can do a
    #                 3-way merge (custom + previous-upstream + new-upstream).
    #             After upgrade, the admin SSHes in, diffs the three files, and hand-merges
    #             the desired rules into all.css. Until that merge runs, the site serves the
    #             new upstream CSS — branding CSS rules are temporarily inactive.
    local target_root="$install_dir/jitsi-meet-web"
    local src_dir="../conf/branding"

    # Defensive: branding/ ships in the fork. In restore scripts pwd is .../settings/scripts
    # so the relative path resolves to .../settings/conf/branding (correct after ynh_restore).
    if [[ ! -d "$src_dir" ]]; then
        # Fall back to the absolute path used during install/upgrade (pwd = .../scripts).
        src_dir="$YNH_APP_BASEDIR/conf/branding"
    fi

    if [[ ! -d "$target_root/images" ]] || [[ ! -d "$target_root/css" ]]; then
        ynh_print_warn "jitsi-meet-web layout unexpected: $target_root missing images/ or css/ — skipping branding"
        return 0
    fi

    # 1. Watermark: overlay.
    install -m 0644 -o "$app" -g "$app" "$src_dir/watermark.svg" "$target_root/images/watermark.svg"

    # 2. CSS: park-alongside, with 3-way-merge breadcrumb.
    #    Note: _setup_sources runs `ynh_safe_rm "$install_dir/jitsi-meet-web"` before re-extracting,
    #    so all.css.upstream-prev from the previous run is also gone by the time we get here.
    #    We stash a copy in /etc/$app/branding/ across upgrades to survive that wipe.
    local stash_dir="/etc/$app/branding"
    mkdir -p "$stash_dir"
    chown "$app:$app" "$stash_dir"
    chmod 0750       "$stash_dir"

    # If we have a previous-upstream stash from the last upgrade, surface it for diffing.
    if [[ -f "$stash_dir/all.css.upstream-prev" ]]; then
        install -m 0640 -o "$app" -g "$app" "$stash_dir/all.css.upstream-prev" "$target_root/css/all.css.upstream-prev"
    fi

    # Stash the now-current upstream as the "previous" for the NEXT upgrade.
    install -m 0640 -o "$app" -g "$app" "$target_root/css/all.css" "$stash_dir/all.css.upstream-prev"

    # Park our customized version next to upstream for the admin to merge by hand.
    install -m 0644 -o "$app" -g "$app" "$src_dir/all.css" "$target_root/css/all.css-custom"
}

ynh_jniwrapper_armhf () {
    # set openjdk-8 as default
    # update-alternatives --set java /usr/lib/jvm/java-8-openjdk-armhf/jre/bin/java
    tempdir="$(mktemp -d)"

    # prepare jniwrapper compilation
    export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-armhf

    declare -A packages_arm
    packages_arm[jitsi-sctp]="jitsi-sctp"
    packages_arm[usrsctp]="jitsi-sctp/usrsctp/usrsctp"

    for package_arm in "${!packages_arm[@]}"; do
        ynh_setup_source --dest_dir="$tempdir/${packages_arm[$package_arm]}" --source_id=$package_arm
    done

    # needed to make compile works
    if [ ! -d "$tempdir/jitsi-sctp/jniwrapper/native/src/main/resources/lib/linux-arm/" ]; then
        mkdir -p $tempdir/jitsi-sctp/jniwrapper/native/src/main/resources/lib/linux-arm/
    fi

    pushd "$tempdir/jitsi-sctp"
        mvn package -DbuildSctp -DbuildNativeWrapper -DdeployNewJnilib -DskipTests
        mvn package
    popd

    # rm official jniwrapper to copy
    original_jniwrapper=$(ls $install_dir/jitsi-videobridge/lib/jniwrapper-native-*.jar)
    ynh_safe_rm "$original_jniwrapper"

    mv "$tempdir/jitsi-sctp/jniwrapper/native/target/jniwrapper-native-1.0-SNAPSHOT.jar" "$install_dir/jitsi-videobridge/lib/"

    chmod 640 "$install_dir/jitsi-videobridge/lib/jniwrapper-native-1.0-SNAPSHOT.jar"
    chown -R $app:$app "$install_dir/jitsi-videobridge/lib/jniwrapper-native-1.0-SNAPSHOT.jar"

    ynh_safe_rm "$tempdir"
}
