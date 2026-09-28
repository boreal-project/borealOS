#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$SCRIPT_DIR/iso-work"
OUTPUT="$SCRIPT_DIR/borealOS.iso"
ROOTFS_TAR="$SCRIPT_DIR/borealOS-rootfs.tar.gz"
RSYNC_EXCLUDES="$SCRIPT_DIR/rsync-exclude.list"
INSTALLER_SH="$SCRIPT_DIR/installer.sh"
RICE_DIR="$SCRIPT_DIR/../rice"
WALLPAPER_DEFAULT="$SCRIPT_DIR/background_main.png"
WALLPAPER_ALT="$SCRIPT_DIR/background_one.png"
WALLPAPER_MAIN="$RICE_DIR/default-wallpaper.jpg"
WALLPAPER_BG2="$SCRIPT_DIR/background_2.png"
WALLPAPER_GRUB="$SCRIPT_DIR/background_grub.png"
LOGO="$SCRIPT_DIR/logo.png"
GHOST_LOGO="$SCRIPT_DIR/borealos-ghost-logo.png"
BANNER="$SCRIPT_DIR/borealOS-text-and-logo-transparent.png"

RED='\033[0;31m'; GRN='\033[0;32m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
die()  { echo -e "${RED}ERROR: $1${RST}" >&2; exit 1; }
ok()   { echo -e "${GRN}$1${RST}"; }
warn() { echo -e "${RED}WARN: $1${RST}"; }

source "$SCRIPT_DIR/desktop/xfce.sh"

# ── Guarantee no display manager autostarts in the LIVE env ────────────────
# The live boot must land on the tty1 menu (/etc/profile.d/boreal-live.sh),
# never on a greeter. Package postinsts can (re)register a DM through any of
# three mechanisms, so we sweep all of them last, right before packing the
# squashfs, and fail the build if anything is left. The DM *package* stays
# installed; installer.sh enables it on the target.
enforce_no_live_dm() {
    local root="$1" dm f init_target left
    echo "==> Verifying no display manager autostarts in the live env..."

    for dm in lightdm sddm gdm gdm3 xdm wdm slim nodm; do
        # OpenRC runlevel links + SysV rc?.d links
        while IFS= read -r -d '' f; do
            warn "DM autostart found, removing: ${f#"$root"}"
            rm -f "$f"
        done < <(find "$root/etc/runlevels" "$root"/etc/rc[0-6S].d \
                    -name "*${dm}*" \( -type l -o -type f \) -print0 2>/dev/null)
    done

    # systemd: only matters if a package swapped /sbin/init, but if it did,
    # this is the link that would start the greeter regardless of runlevels.
    find "$root/etc/systemd/system" -name 'display-manager.service' \
        \( -type l -o -type f \) -print -delete 2>/dev/null | sed "s|^$root|  removed: |"
    rm -f "$root/etc/X11/default-display-manager"

    # /sbin/init must still be OpenRC/sysvinit. Plain readlink on purpose:
    # readlink -f would resolve absolute links against the HOST filesystem.
    init_target="$(readlink "$root/sbin/init" 2>/dev/null || true)"
    case "$init_target" in
        *systemd*) die "/sbin/init -> $init_target: a package pulled in systemd-sysv and replaced the OpenRC/sysvinit init. The live env would boot systemd and start the DM." ;;
    esac

    left="$(find "$root/etc/runlevels" "$root"/etc/rc[0-6S].d \
                \( -name '*lightdm*' -o -name '*sddm*' -o -name '*gdm*' -o -name '*xdm*' \
                   -o -name '*wdm*' -o -name '*slim*' -o -name '*nodm*' \) \
                \( -type l -o -type f \) 2>/dev/null || true)"
    [ -z "$left" ] || die "Display manager still enabled in live env: $left"
    ok "No display manager autostart in the live env."
}

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

cleanup_mounts() {
    for m in dev proc sys; do
        mountpoint -q "$WORK/squashfs-root/$m" 2>/dev/null && umount -l "$WORK/squashfs-root/$m" 2>/dev/null || true
    done
}
trap cleanup_mounts EXIT
cleanup_mounts

for f in "$ROOTFS_TAR" "$RSYNC_EXCLUDES" "$INSTALLER_SH" "$WALLPAPER_MAIN" "$WALLPAPER_DEFAULT" "$WALLPAPER_BG2" "$LOGO" "$BANNER"; do
    [ -f "$f" ] || die "Missing: $f"
done
[ -f "$WALLPAPER_GRUB" ] || warn "Missing $WALLPAPER_GRUB - GRUB will fall back to $WALLPAPER_DEFAULT."
[ "$EUID" -eq 0 ] || die "Run as root."

command -v xorriso       >/dev/null || apt-get install -y xorriso        || die "Failed to install xorriso"
command -v convert       >/dev/null || apt-get install -y imagemagick    || die "Failed to install imagemagick"
dpkg -s grub-efi-amd64-bin >/dev/null 2>&1 || apt-get install -y grub-efi-amd64-bin || die "Failed to install grub-efi-amd64-bin"
dpkg -s grub-pc-bin        >/dev/null 2>&1 || apt-get install -y grub-pc-bin        || die "Failed to install grub-pc-bin"
dpkg -s mtools             >/dev/null 2>&1 || apt-get install -y mtools             || die "Failed to install mtools"
command -v grub-mkrescue >/dev/null || apt-get install -y grub2-common || die "Failed to install grub2-common"
command -v mksquashfs    >/dev/null || apt-get install -y squashfs-tools  || die "Failed to install squashfs-tools"

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
        1) DE_PKGS="kde-plasma-desktop"; DE_EXTRA_PKGS=""; DM_PKGS="sddm"; DM_SERVICE="sddm"; DE_NAME="KDE Plasma"; DE_START="startplasma-x11"; break ;;
        2) DE_PKGS="$XFCE_PKGS"; DE_EXTRA_PKGS="$XFCE_EXTRA_PKGS"; DM_PKGS="$XFCE_DM_PKGS"; DM_SERVICE="$XFCE_DM_SERVICE"; DE_NAME="$XFCE_NAME"; DE_START="$XFCE_START"; break ;;
        3) DE_PKGS="foot"; DE_EXTRA_PKGS=""; DM_PKGS=""; DM_SERVICE=""; DE_NAME="Niri"; DE_START="niri-session"; break ;;
        4) DE_PKGS=""; DE_EXTRA_PKGS=""; DM_PKGS=""; DM_SERVICE=""; DE_NAME="None"; DE_START=""; break ;;
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
echo "$DE_NAME"      > "$WORK/squashfs-root/opt/borealOS/de"
echo "$DM_SERVICE"   > "$WORK/squashfs-root/opt/borealOS/dm"
cp "$RSYNC_EXCLUDES"   "$WORK/squashfs-root/opt/borealOS/rsync-exclude.list"
echo "$DE_START"     > "$WORK/squashfs-root/opt/borealOS/de-start"
echo "$SHELL_BIN"    > "$WORK/squashfs-root/opt/borealOS/shell"
{
    echo "built: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
    echo "build-iso.sh sha256: $(sha256sum "$0" 2>/dev/null | cut -d' ' -f1)"
    [ -f "$SCRIPT_DIR/gui-installer/boreal-installer.c" ] && echo "boreal-installer.c sha256: $(sha256sum "$SCRIPT_DIR/gui-installer/boreal-installer.c" 2>/dev/null | cut -d' ' -f1)"
} > "$WORK/squashfs-root/opt/borealOS/build-info" 2>/dev/null || true

echo "==> Setting up BorealOS artwork..."
mkdir -p "$WORK/squashfs-root/usr/share/boreal-artwork"
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

cp "$WP_MAIN" "$WORK/squashfs-root/opt/borealOS/default-wallpaper.png"

echo "==> Writing xorg config..."
mkdir -p "$WORK/squashfs-root/etc/X11/xorg.conf.d"

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

cat > "$WORK/squashfs-root/etc/X11/xorg.conf.d/10-boreal-video.conf" <<'XORGVIDEO'
Section "Device"
    Identifier "BorealOS Video"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection
XORGVIDEO

mkdir -p "$WORK/squashfs-root/usr/share/X11/xorg.conf.d"
cat > "$WORK/squashfs-root/usr/share/X11/xorg.conf.d/99-boreal-novm.conf" <<'XORGNVM'
Section "Module"
    Disable "vmware"
EndSection
XORGNVM

rm -f "$WORK/squashfs-root/etc/X11/xorg.conf"

mkdir -p "$WORK/squashfs-root/etc/udev/rules.d"
cat > "$WORK/squashfs-root/etc/udev/rules.d/99-boreal-input.rules" <<'UDVRULES'
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
if [ "$DE_NAME" = "KDE Plasma" ]; then
    install -Dm644 "$RICE_DIR/sddm/borealos.conf" "$WORK/squashfs-root/etc/sddm.conf.d/borealos.conf"
fi

install -Dm644 "$RICE_DIR/system/boreal-path.sh" "$WORK/squashfs-root/etc/profile.d/boreal-path.sh"

mkdir -p "$WORK/squashfs-root/usr/share/pixmaps"
cp "$LOGO" "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo.png"
cp "${GHOST_LOGO}" "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo-ghost.png" 2>/dev/null \
    || cp "$LOGO" "$WORK/squashfs-root/usr/share/pixmaps/boreal-logo-ghost.png"

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

if [ -d "$RICE_DIR/kitty" ]; then
    mkdir -p "$WORK/squashfs-root/root/.config/kitty"
    cp -r "$RICE_DIR/kitty/." "$WORK/squashfs-root/root/.config/kitty/"
    echo "  kitty rice copied to live root"
fi

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
[ "$(tty)" = "/dev/tty1" ] || return 0
[ "$(id -u)" = "0" ]       || return 0
grep -q "boot=live" /proc/cmdline 2>/dev/null || return 0

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

cat > "$WORK/squashfs-root/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
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

mkdir -p /etc/X11
cat > /etc/X11/Xwrapper.config <<'XWRAP'
allowed_users=anybody
needs_root_rights=yes
XWRAP

for pkg in virtualbox-guest-x11 virtualbox-guest-utils xf86-video-vmware; do
    apt-get install -y "$pkg" 2>/dev/null || echo "SKIP: $pkg"
done
fi

# Install the user's chosen DE
if [ -n "$DE_PKGS" ]; then
    apt-get install -y $DE_PKGS || { echo "FATAL: DE package install failed ($DE_PKGS), see error above"; exit 1; }
    if [ -n "$DM_PKGS" ]; then
        apt-get install -y $DM_PKGS || { echo "FATAL: DM package install failed ($DM_PKGS), see error above"; exit 1; }
    fi
    if [ -n "$DE_EXTRA_PKGS" ]; then
        apt-get install -y $DE_EXTRA_PKGS || echo "WARN: theming packages failed ($DE_EXTRA_PKGS) - desktop will use default theme/icons/fonts"
    fi
    apt-get install -y hicolor-icon-theme shared-mime-info || true
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
    fi
fi

if [ "$DE_NAME" != "None" ]; then
    apt-get install -y --no-install-recommends gcc make pkg-config libgtk-3-dev libgtk-3-0 \
        || echo "WARN: GTK3 build deps failed"
fi

mkdir -p /opt/borealOS/debs

echo 'root:borealOS' | /usr/sbin/chpasswd

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

CHROOT

umount "$WORK/squashfs-root/sys" "$WORK/squashfs-root/proc" "$WORK/squashfs-root/dev"
ok "==> Packages installed."

if [ "$DE_NAME" = "$XFCE_NAME" ]; then
    echo "==> Staging XFCE desktop..."
    xfce_stage "$WORK/squashfs-root" "$RICE_DIR" "$LOGO" "$WP_MAIN"
    ok "XFCE staged."
fi

echo "==> Creating GRUB theme..."
GRUB_THEME_DIR="$WORK/squashfs-root/usr/share/grub/themes/boreal"
mkdir -p "$GRUB_THEME_DIR"

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

GRUB_BG_SRC="$WALLPAPER_GRUB"
[ -f "$GRUB_BG_SRC" ] || GRUB_BG_SRC="$WALLPAPER_DEFAULT"
convert "$GRUB_BG_SRC" -resize 1024x768^ -gravity center -extent 1024x768 \
    -depth 8 -define png:color-type=2 -interlace none \
    "$GRUB_THEME_DIR/background.png" 2>/dev/null || \
    cp "$GRUB_BG_SRC" "$GRUB_THEME_DIR/background.png"
convert "$GRUB_THEME_DIR/background.png" -fill black -colorize 20% \
    -depth 8 -define png:color-type=2 -interlace none \
    "$GRUB_THEME_DIR/background.png" 2>/dev/null || true
convert "$BANNER" -trim -resize 400x -background none \
    -depth 8 -define png:color-type=6 -interlace none \
    "$GRUB_THEME_DIR/title.png" 2>/dev/null || \
    cp "$BANNER" "$GRUB_THEME_DIR/title.png"

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

for _pass in 1 2; do
    for _bp in gcc gcc-12 gcc-13 gcc-14 cpp cpp-12 cpp-13 cpp-14 make \
               libgtk-3-dev libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev \
               libatk1.0-dev libglib2.0-dev pkg-config; do
        dpkg --purge "\$_bp" 2>/dev/null || true
    done
done
GUIBUILD
ok "boreal-installer built."

fi

echo "==> Finalizing system..."
rm -rf "$WORK/squashfs-root/usr/share/images/desktop-base" 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/images/vendor-logos" 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/backgrounds" -maxdepth 2 -name "*debian*" -delete 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/pixmaps" -name "*debian*" -delete 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/icons" -name "*debian*" -delete 2>/dev/null || true
find "$WORK/squashfs-root/boot/grub" -name "*debian*" -delete 2>/dev/null || true

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

echo "==> Slimming down image (apt cache, docs, locales) - keeping man pages and per-package copyright files..."
chroot "$WORK/squashfs-root" apt-get clean 2>/dev/null || true
rm -rf "$WORK/squashfs-root/var/lib/apt/lists/"* 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/doc" -mindepth 1 -not -name copyright -not -type d -delete 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/doc" -mindepth 1 -type d -empty -delete 2>/dev/null || true
rm -rf "$WORK/squashfs-root/usr/share/lintian/"* 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/locale" -mindepth 1 -maxdepth 1 -type d -not -name 'en*' -exec rm -rf {} + 2>/dev/null || true
find "$WORK/squashfs-root/usr/share/locale-langpack" -mindepth 1 -maxdepth 1 -type d -not -name 'en*' -exec rm -rf {} + 2>/dev/null || true
find "$WORK/squashfs-root/var/log" -type f -delete 2>/dev/null || true
find "$WORK/squashfs-root/var/cache" -maxdepth 1 -type d -not -name apt -exec rm -rf {} + 2>/dev/null || true

enforce_no_live_dm "$WORK/squashfs-root"

echo "==> Building SquashFS..."
if [ "$DE_NAME" = "$XFCE_NAME" ]; then
    xfce_verify "$WORK/squashfs-root"
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
