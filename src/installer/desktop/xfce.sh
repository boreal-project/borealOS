#!/bin/bash
XFCE_NAME="XFCE"
XFCE_START="startxfce4"
XFCE_PKGS="xfce4 xfce4-goodies gvfs gvfs-backends tumbler tumbler-plugins-extra xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin xfce4-power-manager xfce4-power-manager-plugins pavucontrol"
XFCE_EXTRA_PKGS="fonts-ibm-plex papirus-icon-theme adwaita-icon-theme"
XFCE_DM_PKGS="lightdm lightdm-gtk-greeter xcompmgr"
XFCE_DM_SERVICE="lightdm"
XFCE_REQUIRED_BINS="startxfce4 xfwm4 xfce4-panel xfdesktop"
XFCE_LOGO_SIZES="16 24 32 48 64 96 128"

xfce_stage_user_config() {
    local root="$1" rice="$2"
    local dest="$root/etc/skel/.config"
    local item

    mkdir -p "$dest/xfce4" "$dest/gtk-3.0"
    for item in desktop panel xfconf xfce4-screenshooter; do
        [ -e "$rice/xfce4/$item" ] || die "Missing XFCE rice entry: $rice/xfce4/$item"
        cp -a "$rice/xfce4/$item" "$dest/xfce4/"
    done
    cp "$rice/xfce4/gtk-3.0/gtk.css" "$dest/gtk-3.0/gtk.css"
}

xfce_stage_theme() {
    local root="$1" rice="$2"

    [ -d "$rice/theme/BorealOS-Dark" ] || die "Missing theme: $rice/theme/BorealOS-Dark"
    mkdir -p "$root/usr/share/themes"
    cp -a "$rice/theme/BorealOS-Dark" "$root/usr/share/themes/"
}

xfce_stage_icons() {
    local root="$1" logo="$2"
    local size dir

    for size in $XFCE_LOGO_SIZES; do
        dir="$root/usr/share/icons/hicolor/${size}x${size}/apps"
        mkdir -p "$dir"
        convert "$logo" -resize "${size}x${size}" -background none "$dir/xfce4-logo.png" \
            || die "Failed to render ${size}px XFCE logo"
        cp "$dir/xfce4-logo.png" "$dir/org.xfce.panel.png"
        cp "$dir/xfce4-logo.png" "$dir/xfce-logo.png"
    done
}

xfce_stage_defaults() {
    local root="$1"

    mkdir -p "$root/etc/xdg/xfce4"
    printf 'TerminalEmulator=kitty\nFileManager=Thunar\n' > "$root/etc/xdg/xfce4/helpers.rc"
    printf '[Default Applications]\ninode/directory=thunar.desktop\n' > "$root/etc/xdg/mimeapps.list"
}

xfce_stage_session() {
    local root="$1" rice="$2"

    install -Dm755 "$rice/xfce4/session/boreal-xfce-wallpaper" \
        "$root/usr/local/bin/boreal-xfce-wallpaper"
    install -Dm644 "$rice/xfce4/session/boreal-xfce-wallpaper.desktop" \
        "$root/etc/xdg/autostart/boreal-xfce-wallpaper.desktop"
}

xfce_stage_greeter() {
    local root="$1" rice="$2"

    mkdir -p "$root/etc/lightdm"
    cp -a "$rice/lightdm/lightdm.conf.d" "$rice/lightdm/lightdm-gtk-greeter.conf.d" "$root/etc/lightdm/"
    install -Dm755 "$rice/lightdm/boreal-greeter-compositor" \
        "$root/usr/local/bin/boreal-greeter-compositor"
}

xfce_stage_wallpaper() {
    local root="$1" wallpaper="$2"
    local dir file

    mkdir -p "$root/usr/share/xfce4/backdrops"
    cp "$wallpaper" "$root/usr/share/xfce4/backdrops/BorealOS.png"
    for dir in usr/share/backgrounds usr/share/wallpapers usr/share/xfce4/backdrops \
               usr/share/images/desktop-base; do
        [ -d "$root/$dir" ] || continue
        while IFS= read -r -d '' file; do
            [ "$(basename "$file")" = "BorealOS.png" ] && continue
            cp "$wallpaper" "$file"
        done < <(find "$root/$dir" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0)
    done
}

xfce_stage() {
    local root="$1" rice="$2" logo="$3" wallpaper="$4"

    xfce_stage_user_config "$root" "$rice"
    xfce_stage_theme "$root" "$rice"
    xfce_stage_icons "$root" "$logo"
    xfce_stage_defaults "$root"
    xfce_stage_session "$root" "$rice"
    xfce_stage_greeter "$root" "$rice"
    xfce_stage_wallpaper "$root" "$wallpaper"
}

xfce_verify() {
    local root="$1"
    local bin

    for bin in $XFCE_REQUIRED_BINS; do
        [ -x "$root/usr/bin/$bin" ] || die "$bin missing from image, refusing to ship a broken XFCE ISO"
    done
    [ -d "$root/usr/share/themes/BorealOS-Dark" ] || die "BorealOS-Dark theme missing from image"
    [ -f "$root/etc/lightdm/lightdm-gtk-greeter.conf.d/50-boreal.conf" ] || die "greeter config missing from image"
}
