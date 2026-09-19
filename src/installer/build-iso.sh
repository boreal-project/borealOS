#!/bin/bash
set -e

# Always resolve paths relative to the script's own directory,
# not cwd. Prevents stale iso-work folders from accumulating when run as
# e.g. "sudo bash src/installer/build-iso.sh" from the repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$SCRIPT_DIR/iso-work"
OUTPUT="$SCRIPT_DIR/borealOS.iso"
ROOTFS_TAR="$SCRIPT_DIR/borealOS-rootfs.tar.gz"
INSTALLER_SH="$SCRIPT_DIR/installer.sh"
RICE_DIR="$SCRIPT_DIR/../rice"
WALLPAPER_DEFAULT="$SCRIPT_DIR/background_main.png"
WALLPAPER_ALT="$SCRIPT_DIR/background_one.png"
# default-wallpaper.jpg's exact location wasn't fully certain, so this
# checks the plausible spots instead of a single hardcoded guess - and
# reports exactly which one it found further down, so a wrong guess is
# loud instead of silently shipping a build without the real wallpaper.
WALLPAPER_MAIN=""
for _candidate in \
    "$RICE_DIR/default-wallpaper.jpg" \
    "$SCRIPT_DIR/../src/rice/default-wallpaper.jpg" \
    "$SCRIPT_DIR/rice/default-wallpaper.jpg" \
    "$SCRIPT_DIR/../default-wallpaper.jpg" \
    "$SCRIPT_DIR/default-wallpaper.jpg"; do
    if [ -f "$_candidate" ]; then
        WALLPAPER_MAIN="$_candidate"
        break
    fi
done
[ -n "$WALLPAPER_MAIN" ] || WALLPAPER_MAIN="$RICE_DIR/default-wallpaper.jpg"
WALLPAPER_BG2="$SCRIPT_DIR/background_2.png"
WALLPAPER_GRUB="$SCRIPT_DIR/background_grub.png"
LOGO="$SCRIPT_DIR/logo.png"
GHOST_LOGO="$SCRIPT_DIR/borealos-ghost-logo.png"
BANNER="$SCRIPT_DIR/borealOS-text-and-logo-transparent.png"
BRANDING_ZIP="$SCRIPT_DIR/borealOS-branding.zip"

RED='\033[0;31m'; GRN='\033[0;32m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
die()  { echo -e "${RED}ERROR: $1${RST}" >&2; exit 1; }
ok()   { echo -e "${GRN}$1${RST}"; }
warn() { echo -e "${RED}WARN: $1${RST}"; }

# Self-check: a backtick (or bare $()) anywhere inside an UNQUOTED heredoc in
# this file - including inside a "#" comment - gets executed for real by
# THIS script's own shell at heredoc-construction time, on the real host,
# before the text ever reaches a chroot. This has caused a real
# `apt-get autoremove --purge` to run on the host and corrupt a chroot
# script with its spliced-in output. Refuse to run if this pattern
# reappears, instead of silently repeating that bug.
_self_check_heredocs() {
    python3 - "$1" << 'SELFCHECK'
import re, sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
i = 0
bad = []
while i < len(lines):
    m = re.search(r"<<-?\s*(['\"]?)(\w+)\1\s*(?:\|\|.*)?$", lines[i])
    if m and m.group(1) == '':
        tag = m.group(2)
        j = i + 1
        while j < len(lines) and lines[j].rstrip('\n') != tag:
            if '`' in lines[j]:
                bad.append((j + 1, lines[j].rstrip()))
            j += 1
    i += 1
if bad:
    print("SELF-CHECK FAILED: backtick(s) inside an unquoted heredoc:")
    for ln, txt in bad:
        print(f"  line {ln}: {txt}")
    sys.exit(1)
sys.exit(0)
SELFCHECK
}
_self_check_heredocs "${BASH_SOURCE[0]}" || die "This script contains a backtick inside an unquoted heredoc (see above) - this WILL execute on your host instead of staying inert. Fix it before running."

# /dev, /proc, /sys get bind-mounted into $WORK/squashfs-root for chroot use
# further down. If the script dies (or is Ctrl-C'd) anywhere after that and
# before the matching umount, those bind mounts are left dangling on disk.
# The *next* run's `rm -rf "$WORK"` then tries to unlink files through a
# live /proc mount and fails with "Operation not permitted" (procfs/sysfs
# refuse most unlinks regardless of permissions) - it looks like a
# permissions bug but it's actually just leftover mounts from the crash.
# This trap makes sure they're always cleaned up, on success OR failure.
cleanup_mounts() {
    for m in dev proc sys; do
        mountpoint -q "$WORK/squashfs-root/$m" 2>/dev/null && umount -l "$WORK/squashfs-root/$m" 2>/dev/null || true
    done
}
trap cleanup_mounts EXIT

# Defensive: also clean up anything left mounted by a previous run that
# crashed before this trap existed, or that was killed with SIGKILL (which
# no trap can catch).
cleanup_mounts

for f in "$ROOTFS_TAR" "$INSTALLER_SH" "$WALLPAPER_DEFAULT" "$WALLPAPER_BG2" "$LOGO" "$BANNER"; do
    [ -f "$f" ] || die "Missing: $f"
done
if [ -f "$WALLPAPER_MAIN" ]; then
    echo "==> Using $WALLPAPER_MAIN as the primary desktop wallpaper."
else
    die "Could not find default-wallpaper.jpg in any of the checked locations (tried: $RICE_DIR/default-wallpaper.jpg, $SCRIPT_DIR/../src/rice/default-wallpaper.jpg, $SCRIPT_DIR/rice/default-wallpaper.jpg, $SCRIPT_DIR/../default-wallpaper.jpg, $SCRIPT_DIR/default-wallpaper.jpg). Tell me its real path and I'll fix the lookup instead of guessing again."
fi
[ -f "$WALLPAPER_GRUB" ] || warn "Missing $WALLPAPER_GRUB - GRUB will fall back to $WALLPAPER_DEFAULT."
[ "$EUID" -eq 0 ] || die "Run as root."

command -v xorriso       >/dev/null || apt-get install -y xorriso        || die "Failed to install xorriso"
command -v convert       >/dev/null || apt-get install -y imagemagick    || die "Failed to install imagemagick"
dpkg -s grub-efi-amd64-bin >/dev/null 2>&1 || apt-get install -y grub-efi-amd64-bin || die "Failed to install grub-efi-amd64-bin"
dpkg -s grub-pc-bin        >/dev/null 2>&1 || apt-get install -y grub-pc-bin        || die "Failed to install grub-pc-bin"
dpkg -s mtools             >/dev/null 2>&1 || apt-get install -y mtools             || die "Failed to install mtools"
command -v grub-mkrescue >/dev/null || apt-get install -y grub2-common || die "Failed to install grub2-common"
command -v mksquashfs    >/dev/null || apt-get install -y squashfs-tools  || die "Failed to install squashfs-tools"
command -v unzip         >/dev/null || apt-get install -y unzip           || die "Failed to install unzip"

EFI_PLATFORM_DIR="$(find /usr/lib/grub -maxdepth 1 -type d -name 'x86_64-efi' 2>/dev/null | head -1)"
[ -n "$EFI_PLATFORM_DIR" ] || die "grub x86_64-efi platform directory not found - grub-efi-amd64-bin did not install correctly, EFI ISO cannot be built"

echo ""
echo -e "${BLD}Select DE/WM to include in ISO:${RST}"
echo "  1) KDE Plasma"
echo "  2) XFCE"
echo "  3) Niri (Wayland, built from source)"
echo "  4) None (TTY only)"
while true; do
    echo -ne "${CYN}Choice${RST}: "
    read -r de_choice
    case "$de_choice" in
        1) DE_PKGS="kde-plasma-desktop"; DM_PKGS="sddm"; DE_NAME="KDE Plasma"; DE_START="startplasma-x11"; break ;;
        2) DE_PKGS="xfce4 xfce4-goodies gvfs gvfs-backends tumbler tumbler-plugins-extra xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin xfce4-power-manager xfce4-power-manager-plugins pavucontrol"; DE_EXTRA_PKGS="fonts-ibm-plex papirus-icon-theme adwaita-icon-theme"; DM_PKGS="lightdm lightdm-gtk-greeter xcompmgr"; DE_NAME="XFCE"; DE_START="startxfce4"; break ;;
        3) DE_PKGS="foot"; DM_PKGS=""; DE_NAME="Niri"; DE_START="niri-session"; break ;;
        4) DE_PKGS=""; DM_PKGS=""; DE_NAME="None"; DE_START=""; break ;;
        *) echo -e "${RED}Invalid.${RST}" ;;
    esac
done

echo ""
echo -e "${BLD}Select kernel:${RST}"
echo "  1) linux-image-amd64 from trixie-backports (current, 7.0.x)"
echo "  2) linux-image-6.18-amd64 from trixie-backports (LTS 6.18.x)"
while true; do
    echo -ne "${CYN}Choice${RST}: "
    read -r kern_choice
    case "$kern_choice" in
        1) KERNEL_PKG="linux-image-amd64"; KERNEL_NAME="7.0 current (trixie-backports)"; break ;;
        2) KERNEL_PKG="linux-image-6.18-amd64"; KERNEL_NAME="6.18 LTS (trixie-backports)"; break ;;
        *) echo -e "${RED}Invalid.${RST}" ;;
    esac
done

echo ""
echo -e "${BLD}Select shell to include:${RST}"
echo "  1) bash"
echo "  2) fish"
echo "  3) sh (already present)"
while true; do
    echo -ne "${CYN}Choice${RST}: "
    read -r sh_choice
    case "$sh_choice" in
        1) SHELL_PKG="bash"; SHELL_BIN="/bin/bash"; SHELL_NAME="bash"; break ;;
        2) SHELL_PKG="fish"; SHELL_BIN="/usr/bin/fish"; SHELL_NAME="fish"; break ;;
        3) SHELL_PKG=""; SHELL_BIN="/bin/sh"; SHELL_NAME="sh"; break ;;
        *) echo -e "${RED}Invalid.${RST}" ;;
    esac
done

echo ""
echo -e "${BLD}Building ISO: DE=${DE_NAME}, Shell=${SHELL_NAME}${RST}"
echo ""

echo "==> Cleaning work directory..."
rm -rf "$WORK"
mkdir -p "$WORK"/{iso/{boot/grub,live},squashfs-root}

echo "==> Extracting rootfs..."
tar -xzf "$ROOTFS_TAR" -C "$WORK/squashfs-root" || die "Failed to extract rootfs"

echo "==> Injecting installer and assets..."
mkdir -p "$WORK/squashfs-root/opt/borealOS"
cp "$ROOTFS_TAR"        "$WORK/squashfs-root/opt/borealOS/rootfs.tar.gz" || die "Failed to copy rootfs"
cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/opt/borealOS/background_main.png"
cp "$WALLPAPER_BG2"     "$WORK/squashfs-root/opt/borealOS/background_2.png"
cp "$WALLPAPER_ALT"     "$WORK/squashfs-root/opt/borealOS/background_one.png"
[ -f "$WALLPAPER_GRUB" ] && cp "$WALLPAPER_GRUB" "$WORK/squashfs-root/opt/borealOS/background_grub.png"
cp "$LOGO"              "$WORK/squashfs-root/opt/borealOS/logo.png"
[ -f "$GHOST_LOGO" ] && cp "$GHOST_LOGO" "$WORK/squashfs-root/opt/borealOS/logo-ghost.png"
cp "$BANNER"            "$WORK/squashfs-root/opt/borealOS/banner.png"
cp "$INSTALLER_SH"      "$WORK/squashfs-root/usr/local/bin/borealOS-install"
chmod +x                "$WORK/squashfs-root/usr/local/bin/borealOS-install"
echo "$DE_NAME"   > "$WORK/squashfs-root/opt/borealOS/de"
mkdir -p "$WORK/squashfs-root/opt/borealOS/lightdm"
if [ -d "$RICE_DIR/lightdm" ]; then
    cp -r "$RICE_DIR/lightdm/." "$WORK/squashfs-root/opt/borealOS/lightdm/"
    ok "Copied lightdm rice configs"
else
    warn "No rice/lightdm/ found - using defaults"
fi

# Compositor for the greeter's X session (see 01_debian.conf's
# display-setup-script). Without this, the greeter's rounded/transparent
# corners render as solid black — GTK's border-radius clips paint inside a
# still-square X11 window, it doesn't punch a real hole without a compositor.
mkdir -p "$WORK/squashfs-root/usr/local/bin"
cat > "$WORK/squashfs-root/usr/local/bin/boreal-greeter-compositor" <<'GREETERCOMP'
#!/bin/sh
# Runs as root via lightdm's display-setup-script, on the greeter's own X
# display, before the greeter connects. xcompmgr is a deliberately minimal
# choice here (no config file, no window-manager duties, single purpose:
# real ARGB compositing) since the greeter has no WM of its own to host one.
command -v xcompmgr >/dev/null 2>&1 || exit 0
DISPLAY="${DISPLAY:-:0}" xcompmgr -a -n &
GREETERCOMP
chmod 755 "$WORK/squashfs-root/usr/local/bin/boreal-greeter-compositor"

echo "$DE_START"  > "$WORK/squashfs-root/opt/borealOS/de-start"
echo "$SHELL_BIN" > "$WORK/squashfs-root/opt/borealOS/shell"
# So it's possible to tell, from a booted ISO, exactly which build-iso.sh run
# produced it (and which boreal-installer.c it compiled) - useful for
# confirming you're not testing a stale ISO after a fix. Logged by the
# installer at startup.
{
    echo "built: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
    echo "build-iso.sh sha256: $(sha256sum "$0" 2>/dev/null | cut -d' ' -f1)"
    [ -f "$SCRIPT_DIR/gui-installer/boreal-installer.c" ] && echo "boreal-installer.c sha256: $(sha256sum "$SCRIPT_DIR/gui-installer/boreal-installer.c" 2>/dev/null | cut -d' ' -f1)"
} > "$WORK/squashfs-root/opt/borealOS/build-info" 2>/dev/null || true

echo "==> Setting up BorealOS artwork..."
mkdir -p "$WORK/squashfs-root/usr/share/boreal-artwork"
# WALLPAPER_MAIN (rice/default-wallpaper.jpg) is the primary wallpaper for
# the installed system + live XFCE session + lightdm greeter background.
# It ships at a much higher resolution than any real display needs (source
# is 9504x6336 - a print/poster-sized master, not a screen asset), so it's
# downscaled once here to a sane desktop-wallpaper ceiling instead of
# copying that multi-megabyte file to every destination below verbatim.
WP_MAIN="${WALLPAPER_MAIN:-$WALLPAPER_DEFAULT}"
WP_MAIN_SCALED="$WORK/wallpaper-default-scaled.png"
if convert "$WP_MAIN" -resize '3840x2160>' "$WP_MAIN_SCALED" 2>/dev/null; then
    WP_MAIN="$WP_MAIN_SCALED"
else
    warn "Could not downscale $WALLPAPER_MAIN with imagemagick - shipping it at native resolution."
fi
cp "$WP_MAIN"           "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-default.png"
cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-waves.png"
cp "$WALLPAPER_ALT"     "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-alt.png"
cp "$LOGO"              "$WORK/squashfs-root/usr/share/boreal-artwork/logo.png"
[ -f "$GHOST_LOGO" ] && cp "$GHOST_LOGO" "$WORK/squashfs-root/usr/share/boreal-artwork/logo-ghost.png"
cp "$BANNER"            "$WORK/squashfs-root/usr/share/boreal-artwork/banner.png"
chmod 755 "$WORK/squashfs-root/usr/share/boreal-artwork"
chmod 644 "$WORK/squashfs-root/usr/share/boreal-artwork/"*.png

# Both installers (installer.sh and boreal-installer.c) re-copy artwork
# from /opt/borealOS/ into the target's /usr/share/boreal-artwork/ during
# install, as a repair step in case an earlier install stage clobbered
# something - that step was copying from background_main.png/background_2.png
# (whatever the OLD default wallpaper source used to be, before
# WALLPAPER_MAIN was switched to the rice's default-wallpaper.jpg), because
# the actual correctly-scaled wallpaper was never staged into /opt/borealOS
# under any name for it to copy FROM. That's the real reason the desktop
# wallpaper never reflected any wallpaper-logic fix on an installed
# system, on EITHER installer, regardless of how correct the xfconf-side
# fix was - the installer was overwriting the right file with a
# completely different, wrong one immediately after. Staging the same
# already-scaled WP_MAIN here under a stable name gives both installers a
# correct source to copy from.
cp "$WP_MAIN" "$WORK/squashfs-root/opt/borealOS/default-wallpaper.png"


echo "==> Writing xorg config..."
mkdir -p "$WORK/squashfs-root/etc/X11/xorg.conf.d"

# Input config: let libinput handle all devices via udev (modern approach).
cat > "$WORK/squashfs-root/etc/X11/xorg.conf.d/00-boreal-input.conf" <<'XORGCONF'
Section "InputClass"
    Identifier "libinput pointer"
    MatchIsPointer "on"
    Driver "libinput"
    Option "NaturalScrolling" "false"
EndSection

Section "InputClass"
    Identifier "libinput keyboard"
    MatchIsKeyboard "on"
    Driver "libinput"
    Option "XkbLayout" "us"
EndSection
XORGCONF

# Video config: use fbdev as primary driver.
# - modesetting requires /dev/dri/card0 (KMS) — not always present in VMs → "no screens found"
# - vmware_drv segfaults in some VMware guest configs
# - fbdev works on any framebuffer device (/dev/fb0) including VMware, VirtualBox, QEMU, bare metal
# - vesa is the absolute last resort (no KMS, no fb required)
cat > "$WORK/squashfs-root/etc/X11/xorg.conf.d/10-boreal-video.conf" <<'XORGVIDEO'
Section "Device"
    Identifier "BorealOS Video"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection
XORGVIDEO

# Blacklist vmware_drv via Xorg so it is never auto-loaded by the server
mkdir -p "$WORK/squashfs-root/usr/share/X11/xorg.conf.d"
cat > "$WORK/squashfs-root/usr/share/X11/xorg.conf.d/99-boreal-novm.conf" <<'XORGNVM'
Section "Module"
    Disable "vmware"
EndSection
XORGNVM

# Also make the start-graphical script try fbdev → vesa → modesetting in order
# by passing -config to Xorg so we always get a screen even on unusual hardware

rm -f "$WORK/squashfs-root/etc/X11/xorg.conf"

# udev rule: make all input devices readable by everyone in the live env.
# Normally input group handles this but in a minimal live env the group
# membership doesn't take effect until next login — chmod is instant.
mkdir -p "$WORK/squashfs-root/etc/udev/rules.d"
cat > "$WORK/squashfs-root/etc/udev/rules.d/99-boreal-input.rules" <<'UDVRULES'
# BorealOS live: make input devices world-accessible so X11 libinput works
# without needing proper group membership in the live session.
KERNEL=="event*", SUBSYSTEM=="input", MODE="0666"
KERNEL=="mice",   SUBSYSTEM=="input", MODE="0666"
KERNEL=="mouse*", SUBSYSTEM=="input", MODE="0666"
UDVRULES

echo "==> Copying rice configs to skel..."
SKEL="$WORK/squashfs-root/etc/skel"
copy_rice() {
    local src="$RICE_DIR/$1" dst="$SKEL/$2"
    mkdir -p "$(dirname "$dst")"
    [ -f "$src" ] && cp "$src" "$dst" && echo "  copied: $2" || warn "  missing: $1"
}
if [ "$DE_NAME" != "None" ]; then
    copy_rice "fastfetch/config.jsonc" ".config/fastfetch/config.jsonc"
    copy_rice "kitty/kitty.conf"       ".config/kitty/kitty.conf"
    copy_rice "kitty/dark.conf"        ".config/kitty/dark.conf"
    copy_rice "kitty/light.conf"       ".config/kitty/light.conf"
fi
if [ "$DE_NAME" = "Niri" ]; then
    copy_rice "niri/config.kdl"        ".config/niri/config.kdl"
fi

if [ "$DE_NAME" = "XFCE" ]; then
echo "==> Copying XFCE rice configs..."
XFCE_RICE="$RICE_DIR/xfce4"

xfce_copy_to() {
    local DEST="$1"

    # desktop/ → .config/xfce4/desktop/
    if [ -d "$XFCE_RICE/desktop" ]; then
        mkdir -p "$DEST/.config/xfce4/desktop"
        cp -r "$XFCE_RICE/desktop/." "$DEST/.config/xfce4/desktop/"
        echo "  xfce rice: desktop → .config/xfce4/desktop"
    fi

    # panel/ → .config/xfce4/panel/
    if [ -d "$XFCE_RICE/panel" ]; then
        mkdir -p "$DEST/.config/xfce4/panel"
        cp -r "$XFCE_RICE/panel/." "$DEST/.config/xfce4/panel/"
        echo "  xfce rice: panel → .config/xfce4/panel"
    fi

    # xfce4-screenshooter/ → .config/xfce4-screenshooter/
    if [ -d "$XFCE_RICE/xfce4-screenshooter" ]; then
        mkdir -p "$DEST/.config/xfce4-screenshooter"
        cp -r "$XFCE_RICE/xfce4-screenshooter/." "$DEST/.config/xfce4-screenshooter/"
        echo "  xfce rice: xfce4-screenshooter → .config/xfce4-screenshooter"
    fi

    # xfconf/ → .config/xfce4/xfconf/
    # This is the XFCE settings store — most important for theming/panel layout
    if [ -d "$XFCE_RICE/xfconf" ]; then
        mkdir -p "$DEST/.config/xfce4/xfconf"
        cp -r "$XFCE_RICE/xfconf/." "$DEST/.config/xfce4/xfconf/"
        echo "  xfce rice: xfconf → .config/xfce4/xfconf"
    fi

    # gtk-3.0/gtk.css → .config/gtk-3.0/gtk.css
    # Per-user override that rounds the floating panel (xfce4-panel has no
    # native corner-radius/margin property, so this is done in CSS instead).
    if [ -f "$XFCE_RICE/gtk-3.0/gtk.css" ]; then
        mkdir -p "$DEST/.config/gtk-3.0"
        cp "$XFCE_RICE/gtk-3.0/gtk.css" "$DEST/.config/gtk-3.0/gtk.css"
        echo "  xfce rice: gtk.css → .config/gtk-3.0/gtk.css"
    fi
}

# 1. Apply to /etc/skel so every new user on the installed system gets the rice
xfce_copy_to "$SKEL"
ok "XFCE rice applied to skel."

# 2. Install the bundled BorealOS-Dark theme (gtk-2.0/gtk-3.0/xfwm4) system-wide.
# This is shipped in the repo (src/rice/theme/) rather than pulled from apt,
# so it doesn't depend on a specific Debian package existing/being current.
if [ -d "$RICE_DIR/theme/BorealOS-Dark" ]; then
    mkdir -p "$WORK/squashfs-root/usr/share/themes"
    cp -r "$RICE_DIR/theme/BorealOS-Dark" "$WORK/squashfs-root/usr/share/themes/BorealOS-Dark"
    ok "BorealOS-Dark theme installed to /usr/share/themes."
else
    warn "No rice/theme/BorealOS-Dark found - xfwm4/xsettings will reference a theme that doesn't exist, falling back to system default at runtime."
fi
fi

echo "==> Applying BorealOS XFCE branding..."
# Copy logo to pixmaps
mkdir -p "$WORK/squashfs-root/usr/share/pixmaps"
cp "$LOGO" "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo.png"
if [ -f "$GHOST_LOGO" ]; then
    cp "$GHOST_LOGO" "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo-ghost.png"
else
    cp "$LOGO" "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo-ghost.png"
fi
convert "$LOGO" -resize 24x24 -background none     "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo-24.png" 2>/dev/null || true
convert "$LOGO" -resize 48x48 -background none     "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo-48.png" 2>/dev/null || true

# Replace the xfce4 logo used by the apps-menu panel button with our logo.
# xfce4-panel's applicationsmenu plugin uses "org.xfce.panel" or "xfce4-logo" icon.
# We overwrite those in hicolor so our logo appears without any xfconf needed.
for size in 16 24 32 48 64 96 128; do
    dir="$WORK/squashfs-root/usr/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$dir"
    convert "$LOGO" -resize ${size}x${size} -background none         "$dir/xfce4-logo.png" 2>/dev/null || true
    cp "$dir/xfce4-logo.png" "$dir/org.xfce.panel.png" 2>/dev/null || true
    cp "$dir/xfce4-logo.png" "$dir/xfce-logo.png" 2>/dev/null || true
done

mkdir -p "$WORK/squashfs-root/usr/local/bin"
cat > "$WORK/squashfs-root/usr/local/bin/boreal-apply-theme.sh" <<'THEMESCRIPT'
#!/bin/sh
# Run-once guard: this used to run at every single login via autostart,
# reapplying theme/wallpaper/panel settings every time even though
# nothing about them changes after the first run. That's not just
# wasteful - it's what silently kept re-forcing xfwm4's compositor back
# on after the static config disabled it, undoing that fix at every
# session start. First login per user only, from here on: a marker file
# in that user's own config dir. Delete the marker to force a reapply
# (useful for testing/development) - nothing else needs to change to do
# that, no toggle or flag required.
MARKER="$HOME/.config/.boreal-theme-applied"
[ -f "$MARKER" ] && exit 0
mkdir -p "$HOME/.config"

# Wait for xfconfd itself (not just "some channel has some property"),
# and separately wait for xfdesktop to actually be running before writing
# to its channel. xfwm4's channel already has properties from packaging,
# so polling it proves nothing about whether xfdesktop/xfce4-desktop is
# up yet — that was the actual reason wallpaper writes used to silently
# no-op: they landed on a channel nothing was listening on.
set_prop() {
    xfconf-query -c "$1" -p "$2" -n -t "$3" -s "$4" 2>/dev/null \
        || xfconf-query -c "$1" -p "$2" -t "$3" -s "$4" 2>/dev/null
}

wait_for() {
    # $1 = command to check readiness of (pgrep name), $2 = seconds to wait
    i=0
    while [ "$i" -lt "$2" ]; do
        pgrep -x "$1" >/dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

command -v xfconf-query >/dev/null 2>&1 || exit 0
wait_for xfconfd 15 || exit 0

set_prop xsettings /Net/ThemeName string BorealOS-Dark
set_prop xsettings /Net/IconThemeName string Papirus-Dark
set_prop xsettings /Net/DoubleClickTime int 400
set_prop xsettings /Gtk/CursorThemeName string Adwaita
set_prop xsettings /Gtk/CursorThemeSize int 24
set_prop xsettings /Gtk/FontName string "IBM Plex Sans 10"
set_prop xsettings /Gtk/MonospaceFontName string "IBM Plex Mono 10"

set_prop xfwm4 /general/theme string BorealOS-Dark
set_prop xfwm4 /general/title_font string "IBM Plex Sans Bold 9"
set_prop xfwm4 /general/double_click_action string maximize
set_prop xfwm4 /general/click_to_focus bool true
# use_compositing is deliberately NOT set here (and left at false, from
# the static xfwm4.xml). It used to be force-set to true right here, on
# every login - which silently re-enabled xfwm4's own built-in compositor
# after the static config had disabled it, undoing that fix at every
# single session start and racing/conflicting with the xcompmgr autostart
# entry that's supposed to be the ONLY compositor. That's the actual
# reason xcompmgr showed up as running (pgrep) but never successfully
# registered as the compositing manager (xprop -root _NET_WM_CM_S0 came
# back "not found") - xfwm4 was still fighting it for the role.
# vblank_mode defaults to "xpresent" or "glx" depending on build, both of
# which silently do nothing on drivers that lack the Present/GLX extension
# (common in plain VM framebuffer drivers with no 3D acceleration) -
# xfwm4's compositor then just never actually composites, so
# use_compositing=true alone doesn't guarantee it's working. "off" is the
# one mode that doesn't depend on either extension and is the standard
# recommendation for exactly this failure mode. Kept here as a defensive
# no-op in case xfwm4's own compositor is ever intentionally re-enabled
# later, even though nothing currently turns it back on.
set_prop xfwm4 /general/vblank_mode string off
set_prop xfwm4 /general/frame_opacity int 100
set_prop xfwm4 /general/show_frame_shadow bool true

set_prop xfce4-session /general/SaveOnExit bool false
set_prop xfce4-session /general/LockScreen string xflock4
set_prop xfce4-session /shutdown/ShowOnLogout bool true

# --- Wallpaper -----------------------------------------------------------
# Deliberately minimal: only set which image is displayed, nothing about
# the "Folder:" picker's browsing location. That folder property is a
# separate, cosmetic setting read by xfce4-desktop-settings' own picker
# widget (a GtkFileChooserButton-style control with its own internal
# "current folder" state) - writing it externally via xfconf-query changes
# the label the picker shows, but doesn't go through the normal widget
# code path that actually initializes that control's backing folder
# reference, which is what produced "Unable to load Images from folder
# '(null)'" when the picker was then browsed. last-image (the property
# that actually controls what's displayed) has no such entanglement and
# doesn't need a folder to be set anywhere for it to work. Leaving the
# folder alone lets XFCE's own default apply there instead, so the picker
# just works normally, and this only touches what's actually displayed.
#
# Same reasoning as the wallpaper rewrite above: wait for xfdesktop to
# create its own real backdrop entries, then adjust what's already there.
WALLPAPER=/usr/share/boreal-artwork/wallpaper-default.png
if [ -f "$WALLPAPER" ]; then
    MONITORS=""
    for i in $(seq 1 20); do
        MONITORS=$(xfconf-query -c xfce4-desktop -p /backdrop/screen0 -l 2>/dev/null \
            | grep -oE '/backdrop/screen0/[^/]+' | sed 's#.*/##' | sort -u)
        [ -n "$MONITORS" ] && break
        sleep 1
    done
    if [ -n "$MONITORS" ]; then
        for mon in $MONITORS; do
            set_prop xfce4-desktop "/backdrop/screen0/${mon}/workspace0/last-image" string "$WALLPAPER"
            set_prop xfce4-desktop "/backdrop/screen0/${mon}/workspace0/image-style" int 5
            set_prop xfce4-desktop "/backdrop/screen0/${mon}/last-single-image" string "$WALLPAPER"
            set_prop xfce4-desktop "/backdrop/screen0/${mon}/image-show" bool true
        done
        command -v xfdesktop >/dev/null 2>&1 && xfdesktop --reload 2>/dev/null || true
    fi
fi

EXISTING_TYPES=$(for id in $(xfconf-query -c xfce4-panel -p /plugins -l 2>/dev/null | grep -oE 'plugin-[0-9]+'); do
    xfconf-query -c xfce4-panel -p "/plugins/$id" 2>/dev/null
done)
echo "$EXISTING_TYPES" | grep -qE '^(whiskermenu|applicationsmenu)$' || xfce4-panel --add=whiskermenu 2>/dev/null
echo "$EXISTING_TYPES" | grep -q '^pulseaudio$'                     || xfce4-panel --add=pulseaudio 2>/dev/null
echo "$EXISTING_TYPES" | grep -q '^power-manager-plugin$'           || xfce4-panel --add=power-manager-plugin 2>/dev/null

IDS=$(xfconf-query -c xfce4-panel -p /plugins -l 2>/dev/null | grep -oE 'plugin-[0-9]+' | sort -u)
for id in $IDS; do
    val=$(xfconf-query -c xfce4-panel -p "/plugins/$id" 2>/dev/null)
    if [ "$val" = "applicationsmenu" ] || [ "$val" = "whiskermenu" ]; then
        set_prop xfce4-panel "/plugins/${id}/button-icon" string /usr/share/pixmaps/boreal-logo-ghost.png
    fi
done

# Everything above completed without exiting early, so mark this user as
# done - next login's autostart run hits the guard at the top and exits
# immediately instead of redoing any of this.
touch "$MARKER"
THEMESCRIPT
chmod 755 "$WORK/squashfs-root/usr/local/bin/boreal-apply-theme.sh"

mkdir -p "$WORK/squashfs-root/root/.config/autostart" "$WORK/squashfs-root/etc/skel/.config/autostart"
cat > "$WORK/squashfs-root/etc/skel/.config/autostart/boreal-apply-theme.desktop" <<'THEMEAUTOSTART'
[Desktop Entry]
Type=Application
Name=BorealOS Theme
Exec=/usr/local/bin/boreal-apply-theme.sh
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
StartupNotify=false
THEMEAUTOSTART
cp "$WORK/squashfs-root/etc/skel/.config/autostart/boreal-apply-theme.desktop" \
   "$WORK/squashfs-root/root/.config/autostart/boreal-apply-theme.desktop"

# xcompmgr for the XFCE session itself, not just the greeter. xfwm4 ships
# its own built-in compositor (toggled via use_compositing), but that's a
# completely different code path from the xcompmgr already used for
# lightdm's greeter via display-setup-script - and only the greeter's
# xcompmgr has actually been confirmed working. use_compositing is now set
# to false in xfwm4.xml so its own compositor doesn't run alongside this
# one (two compositors fighting over the same display is a real, separate
# problem to avoid), and this autostart entry gives the XFCE session the
# exact same compositor setup already proven to work for the greeter,
# instead of a second, unconfirmed one.
cat > "$WORK/squashfs-root/etc/skel/.config/autostart/boreal-compositor.desktop" <<'COMPAUTOSTART'
[Desktop Entry]
Type=Application
Name=BorealOS Compositor
Exec=xcompmgr -a -n
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
StartupNotify=false
COMPAUTOSTART
cp "$WORK/squashfs-root/etc/skel/.config/autostart/boreal-compositor.desktop" \
   "$WORK/squashfs-root/root/.config/autostart/boreal-compositor.desktop"

# TTY install wrapper — runs the terminal installer
cat > "$WORK/squashfs-root/usr/local/bin/boreal-tty-install" <<'TTYINSTALL'
#!/bin/bash
if command -v borealOS-install >/dev/null 2>&1; then
    borealOS-install
else
    echo "ERROR: borealOS-install not found"
    read -r
fi
TTYINSTALL
chmod +x "$WORK/squashfs-root/usr/local/bin/boreal-tty-install"

# Terminal launcher: tries kitty (with rice config) → xfce4-terminal → xterm
# Terminal launcher helper, used by tty install command if run manually
cat > "$WORK/squashfs-root/usr/local/bin/boreal-open-terminal" <<'TERMLAUNCH'
#!/bin/bash
# Usage: boreal-open-terminal <command>
CMD="$1"
KITTY_CONF=/root/.config/kitty/kitty.conf
if command -v kitty >/dev/null 2>&1; then
    if [ -f "$KITTY_CONF" ]; then
        kitty --config "$KITTY_CONF" bash -c "$CMD; bash"
    else
        kitty bash -c "$CMD; bash"
    fi
elif command -v xfce4-terminal >/dev/null 2>&1; then
    xfce4-terminal --hold -e "bash -c '$CMD; bash'"
else
    xterm -hold -e "bash -c '$CMD; bash'"
fi
TERMLAUNCH
chmod +x "$WORK/squashfs-root/usr/local/bin/boreal-open-terminal"

# Copy kitty rice configs to live root so the TTY install terminal looks riced
if [ -d "$RICE_DIR/kitty" ]; then
    mkdir -p "$WORK/squashfs-root/root/.config/kitty"
    cp -r "$RICE_DIR/kitty/." "$WORK/squashfs-root/root/.config/kitty/"
    echo "  kitty rice copied to live root"
fi

# Create a .desktop for the installer launcher on the panel
mkdir -p "$WORK/squashfs-root/usr/share/applications"
cat > "$WORK/squashfs-root/usr/share/applications/boreal-installer.desktop" <<'DESKTOP'
[Desktop Entry]
Name=BorealOS Installer
Comment=Install BorealOS
Exec=/usr/local/bin/boreal-installer
Icon=/usr/share/pixmaps/boreal-logo.png
StartupWMClass=boreal-installer
Type=Application
Categories=System;
DESKTOP
ok "BorealOS XFCE branding applied."

echo "==> Applying branding..."
cat > "$WORK/squashfs-root/etc/os-release" <<OS
NAME="BorealOS"
PRETTY_NAME="BorealOS 0.0.2"
ID=borealos
ID_LIKE=
VERSION="0.0.2"
VERSION_ID="0.0.2"
HOME_URL="https://borealos.org"
OS
cat > "$WORK/squashfs-root/etc/lsb-release" <<LSB
DISTRIB_ID=BorealOS
DISTRIB_RELEASE=0.0.2
DISTRIB_CODENAME=boreal
DISTRIB_DESCRIPTION="BorealOS 0.0.2"
LSB
echo "BorealOS"      > "$WORK/squashfs-root/etc/issue"
echo "BorealOS 0.0.2"  > "$WORK/squashfs-root/etc/issue.net"
echo "BorealOS"      > "$WORK/squashfs-root/etc/debian_version"
echo "borealOS-live" > "$WORK/squashfs-root/etc/hostname"

echo "==> Writing live TTY menu..."
cat > "$WORK/squashfs-root/etc/profile.d/boreal-live.sh" <<'LIVEMENU'
#!/bin/bash
[ "$(tty)" = "/dev/tty1" ] || exit 0
[ "$(id -u)" = "0" ]       || exit 0
grep -q "boot=live" /proc/cmdline 2>/dev/null || exit 0

DE=$(cat /opt/borealOS/de 2>/dev/null || echo "None")
DE_START=$(cat /opt/borealOS/de-start 2>/dev/null || echo "")

while true; do
    clear
    printf '\033[0;36m\033[1m'
    cat <<'BANNER'
  ____                       _  ___  ____
 | __ )  ___  _ __ ___  __ _| |/ _ \/ ___|
 |  _ \ / _ \| '__/ _ \/ _` | | | | \___ \
 | |_) | (_) | | |  __/ (_| | | |_| |___) |
 |____/ \___/|_|  \___|\__,_|_|\___/|____/
BANNER
    printf '\033[0m'
    echo ""
    echo "  BorealOS 0.0.2 Live  |  DE: $DE"
    echo ""
    echo "  1) Graphical Install"
    echo "  2) Terminal Installer"
    echo "  3) Shell"
    echo ""
    echo -n "  Choice: "
    read -r choice
    case "$choice" in
        1)
            if [ ! -x /usr/local/bin/boreal-installer ]; then
                echo "Graphical installer not found in this ISO."
                sleep 2
            else
                clear
                /usr/local/bin/boreal-start-graphical
                break
            fi
            ;;
        2)
            clear
            borealOS-install
            break
            ;;
        3)
            clear
            break
            ;;
    esac
done
LIVEMENU
chmod +x "$WORK/squashfs-root/etc/profile.d/boreal-live.sh"

cat > "$WORK/squashfs-root/usr/local/bin/boreal-start-graphical" <<'GRAPHICAL'
#!/bin/bash
# Runs the BorealOS graphical installer directly on a bare X server.
# No window manager, no desktop session - just our installer as the sole
# X client, drawn fullscreen. The user's chosen DE is installed separately
# onto the target disk by the installer itself; this session only hosts
# the installer program.

if [ ! -x /usr/local/bin/boreal-installer ]; then
    echo "ERROR: boreal-installer not found. Rebuild the ISO."
    echo "Press Enter to return."
    read -r; exit 0
fi

echo "Starting BorealOS graphical installer..."

echo "==> Pre-flight checks..."
XORG_BIN=""
for p in /usr/lib/xorg/Xorg /usr/bin/Xorg /usr/bin/X; do
    [ -x "$p" ] && XORG_BIN="$p" && break
done
if [ -z "$XORG_BIN" ]; then
    echo "ERROR: Xorg binary not found. Check that xserver-xorg-core is installed."
    echo "Press Enter to return."; read -r; exit 1
fi
echo "  Xorg: $XORG_BIN"
command -v xinit >/dev/null || { echo "ERROR: xinit not found"; read -r; exit 1; }
echo "  xinit: OK"

VT=7
for v in 7 8 2 3 4 5 6; do
    fgconsole 2>/dev/null | grep -q "^${v}$" || { VT=$v; break; }
done
echo "  Using VT: $VT"

mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

cat > /root/.xinitrc <<'XINITRC'
#!/bin/bash
export DISPLAY=:0
eval "$(dbus-launch --sh-syntax --exit-with-session 2>/dev/null)" || true
xsetroot -cursor_name left_ptr 2>/dev/null || true
exec /usr/local/bin/boreal-installer
XINITRC
chmod +x /root/.xinitrc

if ! pgrep -x udevd >/dev/null 2>&1 && ! pgrep -x systemd-udevd >/dev/null 2>&1; then
    echo "==> Starting udev..."
    if [ -x /sbin/udevd ]; then
        /sbin/udevd --daemon
    elif [ -x /usr/sbin/udevd ]; then
        /usr/sbin/udevd --daemon
    elif [ -x /lib/systemd/systemd-udevd ]; then
        /lib/systemd/systemd-udevd --daemon
    fi
    sleep 1
fi

udevadm trigger --action=add --subsystem-match=input 2>/dev/null || true
udevadm settle --timeout=3 2>/dev/null || true
chmod a+rw /dev/input/event* /dev/input/mice /dev/input/mouse* 2>/dev/null || true
usermod -aG input,plugdev root 2>/dev/null || true

echo "  Input devices: $(ls /dev/input/event* 2>/dev/null | wc -l) event nodes found"

echo "==> Starting X on display :0 VT${VT}..."
xinit /root/.xinitrc -- "$XORG_BIN" :0 vt${VT} -nolisten tcp     > /tmp/xorg.log 2>&1
XRET=$?
if [ "$XRET" -ne 0 ] && grep -q "no screens found" /tmp/xorg.log 2>/dev/null; then
    echo "fbdev failed — retrying with vesa driver..."
    cat > /etc/X11/xorg.conf.d/10-boreal-video.conf <<VESACFG
Section "Device"
    Identifier "BorealOS Video Vesa"
    Driver "vesa"
EndSection
VESACFG
    xinit /root/.xinitrc -- "$XORG_BIN" :0 vt${VT} -nolisten tcp         > /tmp/xorg.log 2>&1
    XRET=$?
fi
echo ""
if [ "$XRET" -ne 0 ]; then
    echo "X server exited with code $XRET."
fi
echo "--- Xorg log (last 30 lines) ---"
tail -30 /tmp/xorg.log
echo "--- boreal-installer log ---"
cat /tmp/boreal-installer.log 2>/dev/null | tail -20 || true
echo ""
echo "Press Enter to return to the menu."
read -r
GRAPHICAL
chmod +x "$WORK/squashfs-root/usr/local/bin/boreal-start-graphical"

echo "==> Installing packages..."
mount --bind /dev  "$WORK/squashfs-root/dev"
mount --bind /proc "$WORK/squashfs-root/proc"
mount --bind /sys  "$WORK/squashfs-root/sys"
cp /etc/resolv.conf "$WORK/squashfs-root/etc/resolv.conf"

# policy-rc.d: tells dpkg/invoke-rc.d to refuse ALL service start/restart
# actions during the chroot install. This is the standard Debian mechanism —
# without it, any package whose postinst calls `service X start` or
# `invoke-rc.d X start` will actually try to start the service inside the
# chroot, and for DMs that means registering runlevel symlinks.
cat > "$WORK/squashfs-root/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
# Deny all service actions during chroot build
exit 101
POLICY
chmod +x "$WORK/squashfs-root/usr/sbin/policy-rc.d"

chroot "$WORK/squashfs-root" /bin/bash <<CHROOT || die "Package installation failed"
set -e
export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/70boreal-noninteractive <<'APTCONF'
DPkg::Options {
   "--force-confdef";
   "--force-confold";
}
APTCONF
echo "deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware" > /etc/apt/sources.list
PYVER=\$(ls /usr/lib/ | grep -oP '^python3\.[0-9]+\$' | sort -V | tail -1)
if [ -n "\$PYVER" ]; then
    mkdir -p /usr/share/python3
    if [ ! -s /usr/share/python3/debian_defaults ]; then
        cat > /usr/share/python3/debian_defaults <<PYDEFAULTS
[DEFAULT]
default-version = \${PYVER}
supported-versions = \${PYVER}
unsupported-versions =
requested-versions = \${PYVER#python}
PYDEFAULTS
    fi
fi
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall python3-minimal || true
dpkg --configure -a || true
apt-get update -qq

echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list
apt-get update -qq

apt-get install -y --no-install-recommends -t trixie-backports ${KERNEL_PKG}

apt-get install -y --no-install-recommends \
    grub-efi-amd64 grub-efi-amd64-bin grub-pc-bin grub-common \
    efibootmgr \
    live-boot live-boot-initramfs-tools \
    openrc \
    network-manager ifupdown dhcpcd5 \
    parted dosfstools e2fsprogs \
    cryptsetup cryptsetup-initramfs lvm2 \
    btrfs-progs xfsprogs \
    passwd sudo \
    bash bash-completion \
    iproute2 iputils-ping net-tools \
    curl wget nano less \
    tzdata locales console-setup \
    openssl libdevmapper1.02.1 libefivar1 libefiboot1 \
    os-prober python3 rsync \
    fonts-dejavu-core \
    wpasupplicant \
    elogind libpam-elogind polkitd pkexec \
    chrony \
    $SHELL_PKG

if [ "$DE_NAME" != "None" ]; then
apt-get install -y --no-install-recommends \
    xserver-xorg xserver-xorg-core xserver-xorg-legacy \
    xserver-xorg-input-all \
    xserver-xorg-input-libinput \
    xserver-xorg-input-evdev \
    xserver-xorg-input-mouse \
    xserver-xorg-input-kbd \
    xserver-xorg-video-all xserver-xorg-video-vesa xserver-xorg-video-fbdev \
    xinit xauth x11-xserver-utils x11-utils xterm xwayland \
    libinput-tools \
    libgl1-mesa-dri libgl1 mesa-utils \
    dbus dbus-bin dbus-x11 at-spi2-core \
    adwaita-icon-theme gnome-themes-extra \
    libinput10 libinput-dev \
    udev

# This live/installed environment has no systemd-logind/elogind seat manager,
# so Xorg needs the classic setuid wrapper to be allowed to open /dev/tty*
# and the DRM/input devices for a non-root user (otherwise: "parse_vt_settings:
# Cannot open /dev/tty0 (Permission denied)" when running startx/startxfce4).
mkdir -p /etc/X11
cat > /etc/X11/Xwrapper.config <<'XWRAP'
allowed_users=anybody
needs_root_rights=yes
XWRAP
for xorgbin in /usr/lib/xorg/Xorg /usr/lib/xorg/Xorg.wrap; do
    [ -f "$xorgbin" ] && chmod u+s "$xorgbin"
done

for pkg in virtualbox-guest-x11 virtualbox-guest-utils xf86-video-vmware; do
    apt-get install -y "$pkg" 2>/dev/null || echo "SKIP: $pkg"
done
fi

# Install the user's chosen DE
if [ -n "$DE_PKGS" ]; then
    # --no-install-recommends dropped here on purpose: Debian's xfce4/
    # xfce4-goodies metapackages list a lot of genuinely load-bearing
    # things as Recommends rather than hard Depends (additional icon
    # theme coverage, thumbnailers, xfce4-terminal, etc.) - stripping
    # those is exactly what produced icons that are missing or fall back
    # to a generic filler glyph. The narrower --no-install-recommends
    # calls elsewhere in this script (kernel, kitty, the niri/GUI-installer
    # build toolchain) are deliberately minimal and unrelated to desktop
    # completeness, so those are left as-is.
    apt-get install -y $DE_PKGS || { echo "FATAL: DE package install failed ($DE_PKGS), see error above"; exit 1; }
    if [ -n "$DM_PKGS" ]; then
        apt-get install -y $DM_PKGS || { echo "FATAL: DM package install failed ($DM_PKGS), see error above"; exit 1; }
    fi
    if [ -n "$DE_EXTRA_PKGS" ]; then
        apt-get install -y $DE_EXTRA_PKGS || echo "WARN: theming packages failed ($DE_EXTRA_PKGS) - desktop will use default theme/icons/fonts"
    fi
    # hicolor-icon-theme is the fallback every other icon theme inherits
    # from - without it, any icon missing from Papirus itself (not just
    # ones recommends would have pulled in) has nothing to fall back to
    # and shows as a blank/generic glyph instead.
    apt-get install -y hicolor-icon-theme shared-mime-info || true
    # Explicitly pin everything DE/DM-related as manually installed, so the
    # later "apt-get autoremove --purge" (after build deps are removed) can
    # never cascade-remove a DE package regardless of how apt resolved deps.
    #
    # IMPORTANT: comments inside this unquoted CHROOT heredoc are not
    # inert - the outer shell (running build-iso.sh on the real host,
    # before this text ever reaches the chroot) performs real backtick/$()
    # command substitution even inside "#" comments. A backtick here once
    # caused a real "apt-get autoremove --purge" to run on the host, with
    # its output spliced into the script, which the chroot then tried to
    # execute as a command. Never put backticks or bare $() in a comment
    # anywhere in this heredoc.
    set +e
    for _pkg in $DE_PKGS $DM_PKGS $DE_EXTRA_PKGS; do
        apt-mark manual "$_pkg" >/dev/null
    done
    set -e
fi

if [ "$DE_NAME" != "None" ]; then
    apt-get install -y --no-install-recommends fastfetch || echo "FAILED: fastfetch install, see error above"
    apt-get install -y --no-install-recommends kitty || { echo "FATAL: kitty install failed, see error above"; exit 1; }
    command -v kitty >/dev/null 2>&1 || { echo "FATAL: kitty binary missing after install"; exit 1; }

    # Real browser instead of a placeholder/broken launcher.
    apt-get install -y firefox-esr || echo "WARN: firefox-esr install failed - no browser will be available"

    if command -v kitty >/dev/null 2>&1; then
        update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/bin/kitty 50 2>/dev/null || true
        update-alternatives --set x-terminal-emulator /usr/bin/kitty 2>/dev/null || true
        mkdir -p /etc/xdg/xfce4
        cat > /etc/xdg/xfce4/helpers.rc <<HELPERSRC
TerminalEmulator=kitty
HELPERSRC
    fi
fi

if [ "$DE_NAME" != "None" ]; then
    apt-get install -y --no-install-recommends gcc make pkg-config libgtk-3-dev libgtk-3-0 \
        || echo "WARN: GTK3 build deps failed"
fi

# lightdm is now installed normally above (with $DE_PKGS), so it gets
# properly configured with full dependency resolution and rides along
# to the target via the rsync copy of the live system - no more fragile
# separate offline-cache/dpkg-i dance for the DM itself.
mkdir -p /opt/borealOS/debs

echo 'root:borealOS' | /usr/sbin/chpasswd

# ── Disable (not uninstall) any display manager in the live env ────────────
# lightdm's own postinst auto-enables it via rc-update, which would make the
# live boot media show a login screen instead of going straight to the
# installer. We want the package itself to stay installed (so it rsyncs
# onto the target intact), just not auto-started here in the live env -
# the installer re-enables it for the target specifically later.
echo "==> Disabling (not removing) any display manager for the live boot..."
for dm in lightdm sddm gdm gdm3 xdm wdm slim nodm; do
    rc-update del ${dm} default 2>/dev/null || true
    rc-update del ${dm} boot 2>/dev/null || true
    rm -f /etc/runlevels/default/${dm} \
          /etc/runlevels/boot/${dm} \
          /etc/runlevels/sysinit/${dm} 2>/dev/null || true
    find /etc/rc*.d -name "*${dm}*" -delete 2>/dev/null || true
done

# Remove the file that tells Xorg/PAM which DM to use
rm -f /etc/X11/default-display-manager 2>/dev/null || true

rm -f /etc/machine-id /var/lib/dbus/machine-id
dbus-uuidgen --ensure=/etc/machine-id
mkdir -p /var/lib/dbus
ln -sf /etc/machine-id /var/lib/dbus/machine-id

echo "==> Configuring UTC hwclock + chrony..."
cat > /etc/adjtime <<'ADJTIME'
0.0 0 0.0
0
UTC
ADJTIME
hwclock --systohc --utc 2>/dev/null || true
cat >> /etc/chrony/chrony.conf <<'CHRONYCONF'

makestep 1.0 3
CHRONYCONF
rc-update add chronyd default 2>/dev/null || rc-update add chrony default 2>/dev/null || true
rc-update add hwclock boot 2>/dev/null || true

pam-auth-update --enable elogind 2>/dev/null || true
rc-update add elogind boot 2>/dev/null || rc-update add elogind default 2>/dev/null || true
rc-update add dbus boot 2>/dev/null || rc-update add dbus default 2>/dev/null || true

mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-boreal-power.rules <<'POLKITRULES'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.login1.power-off" ||
         action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
         action.id == "org.freedesktop.login1.reboot" ||
         action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
         action.id == "org.freedesktop.login1.suspend" ||
         action.id == "org.freedesktop.login1.suspend-multiple-sessions" ||
         action.id == "org.freedesktop.login1.hibernate" ||
         action.id == "org.freedesktop.login1.hibernate-multiple-sessions") &&
        subject.local && subject.active) {
        return polkit.Result.YES;
    }
});
POLKITRULES

if [ "$DE_NAME" = "XFCE" ]; then
    echo "==> Verifying XFCE survived package install/cleanup..."
    command -v startxfce4 >/dev/null 2>&1 || { echo "FATAL: startxfce4 missing after package install - XFCE did not actually get installed, or something removed it. Aborting build instead of shipping a broken ISO."; exit 1; }
    command -v xfwm4 >/dev/null 2>&1     || { echo "FATAL: xfwm4 missing after package install."; exit 1; }
    command -v xfce4-panel >/dev/null 2>&1 || { echo "FATAL: xfce4-panel missing after package install."; exit 1; }
    echo "OK: startxfce4, xfwm4, xfce4-panel all present."
fi
CHROOT

umount "$WORK/squashfs-root/sys" "$WORK/squashfs-root/proc" "$WORK/squashfs-root/dev"
ok "==> Packages installed."

echo "==> Creating GRUB theme..."
GRUB_THEME_DIR="$WORK/squashfs-root/usr/share/grub/themes/boreal"
mkdir -p "$GRUB_THEME_DIR"

# --- Fonts: GRUB needs real .pf2 bitmap fonts, it can't just read a font
# name out of theme.txt and go find a system font like every other app.
# The previous theme referenced "DejaVu Sans Bold 16" etc but never
# generated or loaded any matching .pf2 - GRUB silently falls back to its
# tiny built-in font whenever that happens, which is the actual reason the
# boot menu looked plain.
#
# This now runs AFTER package install (moved from earlier in the script) and
# reads the TTF straight out of squashfs-root's already-installed
# fonts-ibm-plex (DE_EXTRA_PKGS, confirmed installed above), instead of a
# separate `apt-get download fonts-ibm-plex` on the *build host's own* apt
# sources. That separate download was the actual bug: fonts-ibm-plex is a
# Debian contrib-section package, and if the build host isn't running the
# exact right Debian release/config (e.g. it's Ubuntu, or contrib isn't
# enabled), the download just fails silently and this whole feature no-ops
# with a generic warning that doesn't say why. Reading it out of the chroot
# removes that dependency on the host's own package availability entirely -
# if it's not there, the earlier apt-mark/apt-get install step for
# DE_EXTRA_PKGS would already have failed loudly.
GRUB_FONT_OK=false
if command -v grub-mkfont >/dev/null 2>&1; then
    REGULAR_TTF=$(find "$WORK/squashfs-root/usr/share/fonts" -iname "IBMPlexSans-Regular.*tf" 2>/dev/null | head -1)
    BOLD_TTF=$(find "$WORK/squashfs-root/usr/share/fonts" -iname "IBMPlexSans-Bold.*tf" 2>/dev/null | head -1)
    if [ -n "$REGULAR_TTF" ] && [ -n "$BOLD_TTF" ]; then
        grub-mkfont --output="$GRUB_THEME_DIR/plex_regular_16.pf2" --size=16 \
            --name="Boreal Plex Regular 16" "$REGULAR_TTF" 2>/dev/null &&
        grub-mkfont --output="$GRUB_THEME_DIR/plex_bold_16.pf2" --size=16 \
            --name="Boreal Plex Bold 16" "$BOLD_TTF" 2>/dev/null &&
        grub-mkfont --output="$GRUB_THEME_DIR/plex_regular_13.pf2" --size=13 \
            --name="Boreal Plex Regular 13" "$REGULAR_TTF" 2>/dev/null &&
        GRUB_FONT_OK=true
    else
        warn "IBMPlexSans-Regular/Bold not found under squashfs-root/usr/share/fonts - fonts-ibm-plex may not have installed correctly (check the DE_EXTRA_PKGS install output above)."
    fi
else
    warn "grub-mkfont not found on build host (install grub2-common / grub-common)."
fi
if [ "$GRUB_FONT_OK" = true ]; then
    ok "GRUB fonts generated from IBM Plex Sans (source: $REGULAR_TTF)."
else
    warn "Could not generate IBM Plex Sans .pf2 fonts for GRUB - boot menu will use GRUB's built-in font instead."
fi

# Use the dedicated GRUB background (thin-line pine/aurora artwork, already
# dark) instead of the desktop wallpaper - GRUB has no compositor and no UI
# chrome to separate text from a busy image, so a background made for this
# specifically reads better than reusing the desktop one. Falls back to the
# desktop wallpaper if it's missing rather than failing the whole build.
#
# Resized to match the ACTUAL gfxmode (1024x768) directly, not a fixed
# 1920x1080 intermediate - the source art is 1280x720 (16:9) while
# 1024x768 is 4:3, so generating at 1920x1080 first and letting GRUB
# stretch that down to 1024x768 at boot meant two lossy resizes plus a
# real aspect-ratio distortion (a 16:9 image squashed into a 4:3 canvas).
# That combination was the actual "low quality" - not a compression/
# quality-setting issue. -resize WxH^ + -gravity center -extent WxH crops
# to fill 1024x768 without distorting the image at all.
GRUB_BG_SRC="$WALLPAPER_GRUB"
[ -f "$GRUB_BG_SRC" ] || GRUB_BG_SRC="$WALLPAPER_DEFAULT"
convert "$GRUB_BG_SRC" -resize 1024x768^ -gravity center -extent 1024x768 \
    -depth 8 -define png:color-type=2 -interlace none \
    "$GRUB_THEME_DIR/background.png" 2>/dev/null || \
    cp "$GRUB_BG_SRC" "$GRUB_THEME_DIR/background.png"
# Darken slightly so light-on-dark text/menu stays readable regardless of
# which background image is in use, same principle as the panel's
# translucent fill - matches the rest of the OS instead of relying on the
# image's own contrast being good enough everywhere.
convert "$GRUB_THEME_DIR/background.png" -fill black -colorize 20% \
    -depth 8 -define png:color-type=2 -interlace none \
    "$GRUB_THEME_DIR/background.png" 2>/dev/null || true
convert "$BANNER" -trim -resize 400x -background none \
    -depth 8 -define png:color-type=6 -interlace none \
    "$GRUB_THEME_DIR/title.png" 2>/dev/null || \
    cp "$BANNER" "$GRUB_THEME_DIR/title.png"

# --- Selection highlight: a smaller, translucent pill (was a solid 560x54
# block at full opacity, oversized against the now-smaller menu items and
# not the same "glass" language as the panel/dialogs elsewhere in the OS).
# Kept in the same accent blue (#1a5fb4) as kitty/GTK theme/xfwm4, but as a
# semi-transparent fill with a soft light border instead of solid color, to
# match the translucent-panel look used everywhere else.
#
# -depth 8 -define png:color-type=6 -interlace none: GRUB's own PNG loader
# only understands 8-bit-per-channel, non-interlaced RGBA. ImageMagick's
# default output for a synthetic xc:none canvas came out 16-bit here, which
# GRUB's loader doesn't handle correctly - it was the actual cause of the
# stray red pixels at the pill's rounded corners (misread channel/bit-depth
# data at the anti-aliased edge), not a drawing mistake in the shape itself.
convert -size 440x40 xc:none -depth 8 \
    -fill "rgba(26,95,180,0.55)"   -draw "roundrectangle 0,0,439,39,12,12" \
    -fill none -stroke "rgba(255,255,255,0.18)" -strokewidth 1 \
        -draw "roundrectangle 0.5,0.5,438.5,38.5,12,12" \
    -depth 8 -define png:color-type=6 -interlace none \
    "$GRUB_THEME_DIR/select_c.png" 2>/dev/null || true

TITLE_H=$(identify -format "%h" "$GRUB_THEME_DIR/title.png" 2>/dev/null || echo 164)

if [ "$GRUB_FONT_OK" = true ]; then
    MSG_FONT="Boreal Plex Regular 13"
    ITEM_FONT="Boreal Plex Bold 16"
    HINT_FONT="Boreal Plex Regular 13"
    # (plex_bold_16.pf2 generated above matches ITEM_FONT here)
else
    MSG_FONT="DejaVu Sans Regular 13"
    ITEM_FONT="DejaVu Sans Bold 14"
    HINT_FONT="DejaVu Sans Regular 12"
fi

cat > "$GRUB_THEME_DIR/theme.txt" <<THEME
desktop-image: "background.png"
desktop-color: "#0b0e14"
title-text: ""
message-font: "${MSG_FONT}"
message-color: "#eaf2ff"
message-bg-color: "#0b0e14"
terminal-box: "terminal_*.png"
terminal-font: "${MSG_FONT}"
terminal-width: "80%"
terminal-height: "70%"
terminal-left: "10%"
terminal-top: "15%"

+ image {
    top = 5%
    left = 50%-200
    width = 400
    height = ${TITLE_H}
    file = "title.png"
}

+ boot_menu {
    top = 45%
    left = 50%-220
    width = 440
    height = 32%
    item_font = "${ITEM_FONT}"
    item_color = "#c7d6ec"
    selected_item_color = "#ffffff"
    item_height = 40
    item_padding = 12
    item_spacing = 8
    icon_width = 0
    icon_height = 0
    scrollbar = false
THEME
if [ -f "$GRUB_THEME_DIR/select_c.png" ]; then
    cat >> "$GRUB_THEME_DIR/theme.txt" <<THEME
    selected_item_pixmap_style = "select_*.png"
THEME
fi
cat >> "$GRUB_THEME_DIR/theme.txt" <<THEME
}

+ progress_bar {
    id = "__timeout__"
    top = 84%
    left = 50%-200
    width = 400
    height = 6
    font = "${HINT_FONT}"
    text_color = "#eaf2ff"
    fg_color = "#3e8fe0"
    bg_color = "#1c2330"
    border_color = "#00000000"
    show_text = false
}

+ label {
    top = 91%
    left = 0
    width = 100%
    align = "center"
    font = "${HINT_FONT}"
    color = "#7d90ac"
    text = "↑↓ navigate    ⏎ boot    e edit    c console"
}
THEME
ok "GRUB theme generated (IBM Plex Sans, BorealOS-Dark palette, real selection highlight)."

find "$WORK/squashfs-root/usr/share/backgrounds" "$WORK/squashfs-root/usr/share/wallpapers" \
     "$WORK/squashfs-root/usr/share/xfce4/backdrops" "$WORK/squashfs-root/usr/share/images/desktop-base" \
     -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) \
     -exec cp "$WORK/squashfs-root/usr/share/boreal-artwork/wallpaper-default.png" {} \; 2>/dev/null || true

# Bundle any custom .deb packages for fully offline install on the target.
# Drop them in <repo>/packages/ (i.e. ../../packages relative to this
# script) and they're copied alongside the DM debs, so the installer's
# offline dpkg -i step on the target picks them up automatically.
CUSTOM_PKG_DIR="$SCRIPT_DIR/../../packages"
if [ -d "$CUSTOM_PKG_DIR" ]; then
    count=$(find "$CUSTOM_PKG_DIR" -maxdepth 1 -name '*.deb' | wc -l)
    if [ "$count" -gt 0 ]; then
        echo "==> Bundling $count custom package(s) from $CUSTOM_PKG_DIR"
        mkdir -p "$WORK/squashfs-root/opt/borealOS/debs"
        cp "$CUSTOM_PKG_DIR"/*.deb "$WORK/squashfs-root/opt/borealOS/debs/"
    fi
fi

if [ "$DE_NAME" != "None" ]; then
echo "==> Building and installing BorealOS graphical installer..."
GUI_SRC="$SCRIPT_DIR/gui-installer"
if [ ! -f "$GUI_SRC/boreal-installer.c" ]; then
    die "Missing $GUI_SRC/boreal-installer.c - graphical installer source not found"
fi
mkdir -p "$WORK/squashfs-root/usr/share/boreal-installer"
cp "$GUI_SRC/boreal-installer.c" "$WORK/squashfs-root/tmp/boreal-installer.c"
cp "$GUI_SRC/style.css" "$WORK/squashfs-root/usr/share/boreal-installer/style.css"

chroot "$WORK/squashfs-root" /bin/bash <<GUIBUILD || die "boreal-installer build failed"
set -e
export DEBIAN_FRONTEND=noninteractive
gcc \$(pkg-config --cflags gtk+-3.0) -O2 -o /usr/local/bin/boreal-installer /tmp/boreal-installer.c \$(pkg-config --libs gtk+-3.0) -lpthread
chmod +x /usr/local/bin/boreal-installer
rm -f /tmp/boreal-installer.c

# --- Safe build-dep cleanup -------------------------------------------------
# THIS is what ate xfce4-panel/xfdesktop4/xfce4-settings/xfce4-appfinder
# last build. apt-mark manual (done earlier for $DE_PKGS/$DM_PKGS/
# $DE_EXTRA_PKGS) only protects a package from apt-get autoremove's orphan
# sweep - it does NOT stop a plain "apt-get remove <pkg>" from cascade-
# removing anything that still depends on <pkg>, manual or not, and it does
# NOT stop autoremove from dropping a sub-component that was only ever
# pulled in *automatically* as a dependency of a manually-marked
# metapackage. xfce4-panel, xfdesktop4, xfce4-settings, xfce4-appfinder and
# libxfce4ui-utils are exactly that: auto-installed dependencies of the
# manually-pinned "xfce4"/"xfce4-goodies" packages, so "apt-get remove
# --purge <dev pkgs>" followed by "apt-get autoremove --purge" was free to
# cascade straight through them.
#
# dpkg --purge has no dependency-solver cascade: it purges exactly the
# named package and refuses (harmlessly swallowed by || true) if anything
# still depends on it. Since gcc/cpp/make/pkg-config and these -dev headers
# are pure build tooling that nothing in a normal desktop runtime depends
# on, this removes exactly what we want and nothing else - it cannot reach
# over and remove xfce4-panel or any other DE package no matter what apt's
# dependency graph looks like. Two passes because dpkg still enforces
# ordering (e.g. libgtk-3-dev has to go before libglib2.0-dev can be
# purged) and this avoids having to hand-sort that order ourselves.
# Deliberately NOT calling apt-get autoremove here at all - it's the other
# half of what broke last time, and it buys negligible size (a handful of
# already-tiny leaf packages, not the multi-hundred-MB toolchain).
for _pass in 1 2; do
    for _bp in gcc gcc-12 gcc-13 gcc-14 cpp cpp-12 cpp-13 cpp-14 make \
               libgtk-3-dev libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev \
               libatk1.0-dev libglib2.0-dev pkg-config; do
        dpkg --purge "\$_bp" 2>/dev/null || true
    done
done
GUIBUILD
ok "boreal-installer built."

if [ -n "$DE_START" ]; then
    echo "==> Re-verifying $DE_NAME right after the boreal-installer build/purge step (narrows down where a future regression would come from, instead of only finding out at the final check right before mksquashfs)..."
    [ -x "$WORK/squashfs-root/usr/bin/$DE_START" ] || [ -x "$WORK/squashfs-root/usr/local/bin/$DE_START" ] || \
        die "FATAL: $DE_START missing from squashfs-root immediately after the GUIBUILD dpkg --purge step - inspect that step, not the slimming step further down."
    ok "OK: $DE_START present right after GUIBUILD."
fi
fi

echo "==> Finalizing system..."
find "$WORK/squashfs-root/usr/share" \
    \( -name "*debian*" -not -path "*/dpkg/*" -not -path "*/apt/*" \
       -not -path "*/plymouth/themes/debian-logo*" \) \
    -delete 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/images/desktop-base" 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/images/vendor-logos" 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/backgrounds" -maxdepth 2 -name "*debian*" -delete 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/pixmaps" -name "*debian*" -delete 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/icons" -name "*debian*" -delete 2>/dev/null || true
find "$WORK/squashfs-root/boot/grub" -name "*debian*" -delete 2>/dev/null || true

# live-boot depends on plymouth (needed only for the live/boot squashfs
# session itself), so it can't be excluded from install in the first place.
# But once we're done needing it, uninstall it PROPERLY via dpkg instead of
# just deleting its files - deleting files while leaving the package
# registered in dpkg's database is what used to cause a broken initramfs
# hook (dpkg still thinks the files exist, references a now-missing PNG,
# and update-initramfs chokes on it). --force-depends is needed because
# live-boot formally depends on it; that's fine, live-boot itself doesn't
# need it anymore once the live session is up and installation is possible.
chroot "$WORK/squashfs-root" dpkg -r --force-depends \
    plymouth plymouth-themes libplymouth5 \
    plymouth-label plymouth-theme-debian-logo plymouth-theme-debian-spinner \
    2>/dev/null || true
find "$WORK/squashfs-root/etc/initramfs-tools" -iname "*plymouth*" -delete 2>/dev/null || true

if [ "$DE_NAME" = "Niri" ]; then
    echo "==> Building niri from source (10-20 minutes)..."
    mount --bind /dev  "$WORK/squashfs-root/dev"
    mount --bind /proc "$WORK/squashfs-root/proc"
    mount --bind /sys  "$WORK/squashfs-root/sys"
    cp /etc/resolv.conf "$WORK/squashfs-root/etc/resolv.conf"
    chroot "$WORK/squashfs-root" /bin/bash <<NIRICHROOT || die "niri build failed"
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends \
    build-essential git cmake pkg-config meson ninja-build \
    curl clang libclang-dev \
    libwayland-dev libxkbcommon-dev libxkbcommon-x11-dev \
    libxcb1-dev libxcb-xkb-dev libxcb-composite0-dev libxcb-present-dev libxcb-xfixes0-dev \
    libinput-dev libseat-dev libpam0g-dev \
    libdrm-dev libpixman-1-dev libgbm-dev \
    libudev-dev libdbus-1-dev libsystemd-dev \
    libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev libglib2.0-dev \
    libffi-dev libexpat1-dev libcap-dev libxrandr-dev \
    libpipewire-0.3-dev libspa-0.2-dev \
    xwayland wayland-protocols

# Debian stable's apt rustc/cargo are frequently older than niri's MSRV, which
# is the usual reason this build silently fails. Install rust via rustup
# instead so we always get a current stable toolchain.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
source "$HOME/.cargo/env"

for optpkg in libwayland-egl1 libegl-dev libegl1-mesa-dev libgles-dev libgles2-mesa-dev \
    libgtk-3-dev libpulse-dev libpcre2-dev wayland-utils swaybg waybar wlr-randr grim slurp; do
    apt-get install -y --no-install-recommends "$optpkg" 2>/dev/null || echo "SKIP: $optpkg"
done

LATEST_TAG=$(git ls-remote --tags https://github.com/YaLTeR/niri.git 2>/dev/null | \
    grep -oP 'refs/tags/v[0-9.]+$' | sort -V | tail -1 | sed 's|refs/tags/||')
echo "Cloning niri $LATEST_TAG..."
cd /tmp && git clone --depth 1 --branch "$LATEST_TAG" https://github.com/YaLTeR/niri.git niri-src
cd niri-src && cargo build --release
install -Dm755 target/release/niri /usr/local/bin/niri
if [ -f resources/niri-session ]; then
    install -Dm755 resources/niri-session /usr/local/bin/niri-session
else
    printf '#!/bin/sh\nexport XDG_SESSION_TYPE=wayland\nexport XDG_CURRENT_DESKTOP=niri\nexec niri --session\n' > /usr/local/bin/niri-session
    chmod +x /usr/local/bin/niri-session
fi
mkdir -p /usr/local/share/wayland-sessions
cat > /usr/local/share/wayland-sessions/niri.desktop <<DESK
[Desktop Entry]
Name=Niri
Comment=A scrollable-tiling Wayland compositor
Exec=niri-session
Type=Application
DesktopNames=niri
DESK
cd / && rm -rf /tmp/niri-src
rustup self uninstall -y 2>/dev/null || rm -rf "$HOME/.cargo" "$HOME/.rustup"

# --- Safe build-dep cleanup --------------------------------------------
# See the comment on the equivalent step in the boreal-installer GUIBUILD
# block above: apt-mark manual does not stop a plain "apt-get remove"
# cascade, and does not stop autoremove from sweeping an auto-installed
# runtime sub-component of a manually-pinned package. The niri build pulls
# in a much larger, more tangled set of -dev packages than the installer
# build does, so purging them one-by-one with dpkg (as we do above) isn't
# practical here - instead we ask autoremove to simulate first (-s, no
# changes made) and abort loudly if the simulated plan would touch
# anything the Niri session needs at runtime, before ever running it for
# real.
apt-get remove -y --purge cmake meson ninja-build build-essential libclang-dev clang 2>/dev/null || true
SIM=\$(apt-get autoremove -y --purge -s 2>/dev/null || true)
if echo "\$SIM" | grep -E "^(Remv|Purg) (xwayland|libwayland-client0|libwayland-server0|libwayland-egl1|libwayland-cursor0|libxkbcommon0|libxkbcommon-x11-0|libseat1|libinput10|libdrm2|libgbm1|libpixman-1-0|libpipewire-0.3-0)" >/dev/null 2>&1; then
    echo "\$SIM" | grep -E "^(Remv|Purg)"
    echo "FATAL: simulated autoremove would strip a niri-session runtime dependency (see Remv/Purg lines above) - aborting before running it for real. Add whatever's missing here to the removal manually instead, or extend the protect-list above." >&2
    exit 1
fi
apt-get autoremove -y --purge 2>/dev/null || true
NIRICHROOT
    umount "$WORK/squashfs-root/sys" "$WORK/squashfs-root/proc" "$WORK/squashfs-root/dev"
    ok "niri built."
    [ -x "$WORK/squashfs-root/usr/local/bin/niri" ] || die "FATAL: /usr/local/bin/niri missing from squashfs-root right after the niri build/purge step."
    [ -x "$WORK/squashfs-root/usr/local/bin/niri-session" ] || die "FATAL: /usr/local/bin/niri-session missing from squashfs-root right after the niri build/purge step."
    ok "OK: niri and niri-session present right after the niri build/purge step."
fi

echo "==> Enabling udev in OpenRC for live env..."
ln -sf /etc/init.d/udev "$WORK/squashfs-root/etc/runlevels/sysinit/udev" 2>/dev/null || true
ln -sf /etc/init.d/udev-trigger "$WORK/squashfs-root/etc/runlevels/sysinit/udev-trigger" 2>/dev/null || true

echo "==> Setting up auto-login for live env..."
tar -xOf "$ROOTFS_TAR" ./etc/inittab > "$WORK/squashfs-root/etc/inittab" 2>/dev/null || true
sed -i 's|^\(1:[0-9]*:respawn:.*getty\)|\1 --autologin root|' "$WORK/squashfs-root/etc/inittab"
if ! grep -q "autologin" "$WORK/squashfs-root/etc/inittab"; then
    sed -i '/^1:/d' "$WORK/squashfs-root/etc/inittab"
    echo "1:2345:respawn:/sbin/agetty --autologin root --noclear 38400 tty1" >> "$WORK/squashfs-root/etc/inittab"
fi

echo "==> Forcing BorealOS wallpaper over any package-installed defaults..."
mkdir -p "$WORK/squashfs-root/usr/share/xfce4/backdrops"
cp "$WP_MAIN" "$WORK/squashfs-root/usr/share/xfce4/backdrops/BorealOS.png"
find "$WORK/squashfs-root/usr/share/xfce4/backdrops"     -not -name "BorealOS.png" -type f -delete 2>/dev/null || true

for dir in \
    "$WORK/squashfs-root/usr/share/backgrounds" \
    "$WORK/squashfs-root/usr/share/wallpapers" \
    "$WORK/squashfs-root/usr/share/pixmaps/backgrounds"; do
    [ -d "$dir" ] || continue
    find "$dir" -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \) -print0 2>/dev/null | \
        while IFS= read -r -d '' f; do cp "$WP_MAIN" "$f" 2>/dev/null || true; done
done
mkdir -p "$WORK/squashfs-root/usr/share/backgrounds/xfce"
cp "$WP_MAIN" "$WORK/squashfs-root/usr/share/backgrounds/xfce/xfce-shapes.png" 2>/dev/null || true
cp "$WP_MAIN" "$WORK/squashfs-root/usr/share/backgrounds/xfce/xfce-verticals.png" 2>/dev/null || true
cp "$WP_MAIN" "$WORK/squashfs-root/usr/share/backgrounds/xfce/xfce-stripes.png" 2>/dev/null || true

echo "==> Slimming down image (apt cache, docs, locales) - keeping man pages and per-package copyright files..."
chroot "$WORK/squashfs-root" apt-get clean 2>/dev/null || true
rm -rf "$WORK/squashfs-root/var/lib/apt/lists/"* 2>/dev/null || true
# /usr/share/man is intentionally left alone now - man pages are kept.
# /usr/share/doc/<pkg>/copyright is Debian Policy-required (it's the actual
# license text for that package) so it's kept too; everything else under
# doc/ (changelogs, examples, READMEs) is still trimmed for size.
find "$WORK/squashfs-root/usr/share/doc" -mindepth 1 -not -name copyright -not -type d -delete 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/doc" -mindepth 1 -type d -empty -delete 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/lintian/"* 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/locale" -mindepth 1 -maxdepth 1 -type d -not -name 'en*' -exec rm -rf {} + 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/locale-langpack" -mindepth 1 -maxdepth 1 -type d -not -name 'en*' -exec rm -rf {} + 2>/dev/null || true
find "$WORK/squashfs-root/var/log" -type f -delete 2>/dev/null || true
find "$WORK/squashfs-root/var/cache" -maxdepth 1 -type d -not -name apt -exec rm -rf {} + 2>/dev/null || true

echo "==> Building SquashFS..."
if [ "$DE_NAME" = "XFCE" ]; then
    echo "==> Final XFCE check before squashfs (catches anything GUIBUILD's autoremove or the slimming step above may have stripped since the first check)..."
    for bin in startxfce4 xfwm4 xfce4-panel xfdesktop; do
        [ -x "$WORK/squashfs-root/usr/bin/$bin" ] || die "FINAL CHECK FAILED: $bin missing from squashfs-root right before mksquashfs. Something between package install and here removed it (likely the GUIBUILD gcc/dev-package purge+autoremove, or the doc/locale slimming step) despite apt-mark manual pinning. Refusing to ship a broken ISO - inspect what changed in that range."
    done
    ok "Final check passed: startxfce4, xfwm4, xfce4-panel, xfdesktop all present in squashfs-root."
fi
mksquashfs "$WORK/squashfs-root" "$WORK/iso/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 19 -noappend -xattrs -quiet || die "mksquashfs failed"

echo "==> Copying kernel and initrd..."
VMLINUZ=$(ls "$WORK/squashfs-root/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
INITRD=$(ls  "$WORK/squashfs-root/boot/initrd.img-"* 2>/dev/null | sort -V | tail -1)
[ -f "$VMLINUZ" ] || die "No kernel found."
[ -f "$INITRD"  ] || die "No initrd found."
cp "$VMLINUZ" "$WORK/iso/boot/vmlinuz"
cp "$INITRD"  "$WORK/iso/boot/initrd.img"

echo "==> Writing GRUB config..."
mkdir -p "$WORK/iso/boot/grub/themes/boreal"
cp -r "$WORK/squashfs-root/usr/share/grub/themes/boreal/." "$WORK/iso/boot/grub/themes/boreal/"

cat > "$WORK/iso/boot/grub/grub.cfg" <<'GRUB'
insmod all_video
insmod gfxterm
insmod png
insmod font
# Fixed target resolution, not "auto" - the theme's boot_menu geometry mixes
# percentage positions with fixed-pixel elements (logo/banner width, item
# height), so it was designed assuming one specific canvas size, and this
# is the resolution that value was actually confirmed working at (both
# here and in the post-install grub.cfg, which now matches this exactly -
# that mismatch, not this number itself, was the actual cause of GRUB
# looking different/smaller after install). The ",auto" suffix is kept
# only as a fallback for hardware that can't do 1024x768, not as the
# primary target - background/pill images are generated larger and GRUB
# scales them to whatever's actually active, so they don't need to match
# this number.
set gfxmode=1024x768,auto
set gfxpayload=keep
terminal_output gfxterm
if loadfont /boot/grub/themes/boreal/plex_regular_16.pf2; then
    loadfont /boot/grub/themes/boreal/plex_bold_16.pf2
    loadfont /boot/grub/themes/boreal/plex_regular_13.pf2
fi
set timeout_style=menu
set timeout=10
set default=0
set theme=/boot/grub/themes/boreal/theme.txt

menuentry "BorealOS 0.0.2 Live" {
    linux /boot/vmlinuz boot=live quiet
    initrd /boot/initrd.img
}

menuentry "BorealOS 0.0.2 Live (safe mode)" {
    linux /boot/vmlinuz boot=live nomodeset
    initrd /boot/initrd.img
}
GRUB

echo "==> Building ISO..."
GRUB_MKRESCUE_LOG="$WORK/grub-mkrescue.log"
grub-mkrescue -o "$OUTPUT" "$WORK/iso" \
    --modules="normal iso9660 linux ext2 fat search search_label part_gpt part_msdos all_video gfxterm png" \
    2>&1 | tee "$GRUB_MKRESCUE_LOG"
[ ${PIPESTATUS[0]} -eq 0 ] || die "grub-mkrescue failed (see $GRUB_MKRESCUE_LOG)"
if grep -qi "No EFI boot images\|efi.img.*not found\|cannot find efi" "$GRUB_MKRESCUE_LOG"; then
    die "grub-mkrescue built a BIOS-only ISO (no EFI El Torito image) - see $GRUB_MKRESCUE_LOG. Re-check grub-efi-amd64-bin installation."
fi

if command -v xorriso >/dev/null 2>&1; then
    xorriso -indev "$OUTPUT" -report_el_torito plain 2>/dev/null | grep -qi "El Torito boot img.*UEFI" \
        || warn "Could not confirm an EFI El Torito entry on $OUTPUT - verify UEFI boot manually before shipping this ISO."
fi

ok "==> Done: $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
