#!/bin/bash

RED='\033[0;31m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

EXTRA_USERS=()
EFI="" ROOT="" DISK="" BIOS=""
DE_CHOICE="" SHELL_BIN=""
NET_TYPE="" NET_IF="" NET_IP="" NET_GW="" NET_DNS=""
HOSTNAME="" LOCALE="" TIMEZONE=""
ROOT_PASS="" ROOT_UUID="" EFI_UUID=""

die() {
    echo -e "\n${RED}${BLD}FATAL: $1${RST}" >&2
    cleanup
    echo -e "${RED}Dropping to shell.${RST}"
    bash
    exit 1
}
step() { echo -e "\n${CYN}${BLD}=> $1${RST}"; }
ok()   { echo -e "${GRN}OK: $1${RST}"; }
warn() { echo -e "${RED}WARN: $1${RST}"; }

banner() {
    clear
    echo -e "${CYN}${BLD}"
    cat <<'ART'
  ____                       _  ___  ____
 | __ )  ___  _ __ ___  __ _| |/ _ \/ ___|
 |  _ \ / _ \| '__/ _ \/ _` | | | | \___ \
 | |_) | (_) | | |  __/ (_| | | |_| |___) |
 |____/ \___/|_|  \___|\__,_|_|\___/|____/
ART
    echo -e "${RST}"
}

ask() {
    local prompt="$1" var="$2" default="$3"
    while true; do
        echo -ne "${CYN}${prompt}${RST}"
        [ -n "$default" ] && echo -ne " [${default}]"
        echo -ne ": "
        read -r input
        input="${input:-$default}"
        [ -n "$input" ] && { printf -v "$var" '%s' "$input"; return; }
        echo -e "${RED}Cannot be empty.${RST}"
    done
}

ask_pass() {
    local prompt="$1" var="$2"
    while true; do
        echo -ne "${CYN}${prompt}${RST} (doesn't echo): "
        read -rs p1; echo
        echo -ne "${CYN}Confirm ${prompt}${RST} (doesn't echo): "
        read -rs p2; echo
        if [ -n "$p1" ] && [ "$p1" = "$p2" ]; then
            printf -v "$var" '%s' "$p1"; return
        fi
        echo -e "${RED}Passwords do not match or are empty.${RST}"
    done
}

menu() {
    local title="$1"; shift
    local options=("$@")
    echo -e "${BLD}${title}${RST}"
    for i in "${!options[@]}"; do echo "  $((i+1))) ${options[$i]}"; done
    while true; do
        echo -ne "${CYN}Choice${RST}: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            MENU_RESULT="${options[$((choice-1))]}"; return
        fi
        echo -e "${RED}Invalid.${RST}"
    done
}

confirm() {
    echo -ne "${CYN}$1 [Y/n]${RST}: "
    read -r ans
    [[ "$ans" =~ ^[Nn]$ ]] && return 1
    return 0
}

check_root() { [ "$EUID" -eq 0 ] || die "Must run as root."; }

check_assets() {
    [ -f /opt/borealOS/rootfs.tar.gz ]    || die "/opt/borealOS/rootfs.tar.gz missing."
    [ -f /opt/borealOS/background_2.png ] || die "Wallpaper missing."
    [ -f /opt/borealOS/de ]               || die "/opt/borealOS/de missing."
    [ -f /opt/borealOS/shell ]            || die "/opt/borealOS/shell missing."
    command -v rsync        >/dev/null     || die "rsync not in live env."
    command -v grub-install >/dev/null     || die "grub-install not in live env."
    DE_CHOICE=$(cat /opt/borealOS/de)
    SHELL_BIN=$(cat /opt/borealOS/shell)
}

select_disk() {
    banner
    echo -e "${BLD}Available disks:${RST}\n"
    lsblk -dpno NAME,SIZE,MODEL | grep -v "loop\|sr0"
    echo
    ask "Target disk (e.g. /dev/sda)" DISK
    [ -b "$DISK" ] || die "$DISK is not a block device."
    echo -e "\n${RED}${BLD}WARNING: All data on $DISK will be erased.${RST}"
    confirm "Continue?" || die "Aborted."
}

select_partitioning() {
    banner
    echo -e "${BLD}Partitioning${RST}"
    EFI_SIZE=512
    SWAP_SIZE=0
    if confirm "Advanced partitioning (custom EFI/swap size)?"; then
        while true; do
            ask "EFI size in MiB" EFI_SIZE
            [[ "$EFI_SIZE" =~ ^[0-9]+$ ]] && [ "$EFI_SIZE" -ge 100 ] && break
            echo -e "${RED}Enter a number >= 100.${RST}"
        done
        while true; do
            ask "Swap size in MiB (0 for none)" SWAP_SIZE
            [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]] && break
            echo -e "${RED}Enter a number >= 0.${RST}"
        done
    fi

    USE_LVM="n"
    USE_LUKS="n"
    LUKS_PASS=""
    if confirm "Use LVM?"; then USE_LVM="y"; fi
    if confirm "Encrypt root with LUKS?"; then
        USE_LUKS="y"
        while true; do
            echo -ne "${CYN}Encryption passphrase${RST}: "
            read -rs LUKS_PASS; echo
            echo -ne "${CYN}Confirm passphrase${RST}: "
            read -rs LUKS_PASS2; echo
            [ -n "$LUKS_PASS" ] && [ "$LUKS_PASS" = "$LUKS_PASS2" ] && break
            echo -e "${RED}Passphrases empty or don't match.${RST}"
        done
    fi
}

select_timezone() {
    banner
    echo -e "${BLD}Timezone${RST} - type to filter (e.g. Europe, Berlin)"
    echo
    echo -ne "${CYN}Filter${RST}: "
    read -r tz_filter
    mapfile -t tz_list < <(find /usr/share/zoneinfo -type f -o -type l 2>/dev/null | \
        sed 's|/usr/share/zoneinfo/||' | \
        grep -v "^posix\|^right\|\.tab$\|^leap\|\.list$\|^tzdata\|^iso3166" | \
        sort | grep -i "${tz_filter}")
    if [ ${#tz_list[@]} -eq 0 ]; then
        echo -e "${RED}No matches.${RST}"
        ask "Timezone" TIMEZONE "UTC"; return
    fi
    if [ ${#tz_list[@]} -gt 40 ]; then
        echo -e "${RED}${#tz_list[@]} results - refine filter.${RST}"
        select_timezone; return
    fi
    for i in "${!tz_list[@]}"; do echo "  $((i+1))) ${tz_list[$i]}"; done
    echo
    while true; do
        echo -ne "${CYN}Choice (0=manual)${RST}: "
        read -r c
        [ "$c" = "0" ] && { ask "Timezone" TIMEZONE "UTC"; return; }
        if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#tz_list[@]} )); then
            TIMEZONE="${tz_list[$((c-1))]}"; return
        fi
        echo -e "${RED}Invalid.${RST}"
    done
}

get_user_info() {
    banner
    ask "Hostname" HOSTNAME "borealOS"
    ask_pass "Root password" ROOT_PASS
    ask "Locale (e.g. en_US.UTF-8)" LOCALE "en_US.UTF-8"
    select_timezone
}

get_extra_users() {
    banner
    echo -e "${BLD}Extra user accounts${RST} - leave blank to stop"
    echo
    while true; do
        echo -ne "${CYN}Username (blank=done)${RST}: "
        read -r uname
        [ -z "$uname" ] && break
        ask_pass "Password for $uname" upass
        local usudo="y"
        echo -ne "${CYN}Give $uname sudo rights? [Y/n]${RST}: "
        read -r usudo
        [[ "$usudo" =~ ^[Nn]$ ]] && usudo="n" || usudo="y"
        EXTRA_USERS+=("${uname}|${upass}|${usudo}")
        ok "Added: $uname (sudo: $usudo)"
    done
}

configure_network() {
    banner
    menu "Network:" "DHCP (automatic)" "Static IP" "Skip"
    NET_TYPE="$MENU_RESULT"
    [ "$NET_TYPE" = "Skip" ] && return
    echo
    echo -e "${BLD}Interfaces:${RST}"
    ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print "  "$2}' | grep -v lo
    echo
    ask "Interface" NET_IF "eth0"
    if [ "$NET_TYPE" = "Static IP" ]; then
        ask "IP/prefix (e.g. 192.168.1.100/24)" NET_IP
        ask "Gateway" NET_GW
        ask "DNS" NET_DNS "1.1.1.1"
    fi
}

partition_disk() {
    step "Partitioning $DISK..."

    # Leftover state from a PREVIOUS install attempt on this exact disk is
    # the actual cause of both failures in the logs: "partition(s) ... been
    # written, but we have been unable to inform the kernel" on mklabel,
    # and "/dev/sda3 is apparently in use by the system" on mkfs.ext4.
    # This installer always uses the same fixed names (VG "borealvg", LUKS
    # mapping "borealcrypt"), so a prior run that got as far as vgcreate/
    # luksOpen leaves the kernel holding a live reference into this disk's
    # partitions - LVM's own udev/autoactivation rules on the live medium
    # can reattach that VG again on every subsequent boot purely from
    # on-disk signatures, well before this script ever runs, which is why
    # even a completely fresh boot's FIRST parted call already failed.
    # Previously this cleanup only ran in the EXIT trap (i.e. only after
    # THIS run finished/failed) - never before a run starts, and never a
    # full signature wipe. Doing it here, unconditionally, before mklabel,
    # closes that gap instead of relying on the user to reboot enough
    # times for it to eventually work.
    step "Clearing any leftover state on $DISK from a previous attempt..."
    for mnt in $(awk -v d="$DISK" '$1 ~ "^"d {print $2}' /proc/mounts | sort -r); do
        umount -l "$mnt" 2>/dev/null || true
    done
    for sw in $(awk -v d="$DISK" '$1 ~ "^"d {print $1}' /proc/swaps 2>/dev/null); do
        swapoff "$sw" 2>/dev/null || true
    done
    vgchange -an borealvg 2>/dev/null || true
    vgremove -f borealvg 2>/dev/null || true
    for pv in $(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' '); do
        case "$pv" in "$DISK"*) pvremove -ff -y "$pv" 2>/dev/null || true ;; esac
    done
    cryptsetup luksClose borealcrypt 2>/dev/null || true
    # Any other dm mapping still pointing at a partition of this disk
    # (e.g. from a crash mid-install rather than a clean prior run) -
    # dmsetup deps tells us what a mapping is built on, so this only
    # tears down mappings that actually sit on THIS disk, not unrelated
    # ones (like the live ISO's own overlay).
    for dm in $(dmsetup ls --target linear 2>/dev/null | awk '{print $1}'); do
        dmsetup deps -o devname "$dm" 2>/dev/null | grep -q "$(basename "$DISK")" \
            && dmsetup remove -f "$dm" 2>/dev/null || true
    done
    # Strip residual LVM/LUKS/filesystem signatures the kernel/udev can
    # otherwise still see even after parted writes a fresh partition
    # table - this is the actual fix for "unable to inform the kernel" /
    # "apparently in use", both of which are the kernel getting confused
    # by old magic bytes it can still find, not a real busy-device error.
    wipefs -af "$DISK" 2>/dev/null || true
    for p in "${DISK}"*[0-9]*; do
        [ -b "$p" ] && wipefs -af "$p" 2>/dev/null || true
    done
    partprobe "$DISK" 2>/dev/null
    udevadm settle 2>/dev/null || sleep 2

    EFI_END=$((2 + EFI_SIZE))
    SWAP_END=$((EFI_END + SWAP_SIZE))
    # mklabel/mkpart retried with a re-probe in between: the "unable to
    # inform the kernel of the change" parted warning is a udev/kernel
    # synchronization race, not necessarily a hard failure - retrying
    # after explicitly asking the kernel to re-read the table (rather
    # than a single blind attempt) resolves it far more often than not.
    attempt=1
    until parted -s "$DISK" mklabel gpt 2>&1; do
        [ "$attempt" -ge 3 ] && die "mklabel failed after $attempt attempts"
        warn "mklabel failed (attempt $attempt) - re-reading partition table and retrying..."
        partprobe "$DISK" 2>/dev/null
        udevadm settle 2>/dev/null || sleep 2
        attempt=$((attempt + 1))
    done
    parted -s "$DISK" mkpart bios_boot 1MiB 2MiB                || die "BIOS boot partition failed"
    parted -s "$DISK" set 1 bios_grub on                        || die "bios_grub flag failed"
    parted -s "$DISK" mkpart ESP fat32 2MiB "${EFI_END}MiB"     || die "EFI partition failed"
    parted -s "$DISK" set 2 esp on                              || die "esp flag failed"
    NEXT_PART=3
    if [ "$SWAP_SIZE" -gt 0 ]; then
        parted -s "$DISK" mkpart swap linux-swap "${EFI_END}MiB" "${SWAP_END}MiB" || die "swap partition failed"
        NEXT_PART=4
    fi
    ROOT_START=$([ "$SWAP_SIZE" -gt 0 ] && echo "${SWAP_END}MiB" || echo "${EFI_END}MiB")
    parted -s "$DISK" mkpart primary ext4 "$ROOT_START" 100%    || die "root partition failed"
    partprobe "$DISK" 2>/dev/null
    udevadm settle 2>/dev/null || sleep 2
    if [[ "$DISK" == *nvme* ]]; then
        SEP="p"
    else
        SEP=""
    fi
    BIOS="${DISK}${SEP}1"; EFI="${DISK}${SEP}2"
    if [ "$SWAP_SIZE" -gt 0 ]; then SWAP="${DISK}${SEP}3"; else SWAP=""; fi
    ROOT="${DISK}${SEP}${NEXT_PART}"
    # Wait for the device nodes to actually show up rather than a single
    # blind check - udev creating them can lag slightly behind partprobe
    # returning, especially right after the wipefs/mklabel churn above.
    for dev in "$BIOS" "$EFI" "$ROOT"; do
        i=0
        while [ ! -b "$dev" ] && [ "$i" -lt 10 ]; do
            sleep 1
            i=$((i + 1))
        done
    done
    [ -b "$BIOS" ] || die "BIOS partition $BIOS not found"
    [ -b "$EFI"  ] || die "EFI partition $EFI not found"
    [ -b "$ROOT" ] || die "Root partition $ROOT not found"
    mkfs.fat -F32 -n EFI "$EFI"      || die "mkfs.fat failed"
    if [ -n "$SWAP" ]; then
        mkswap -L borealswap "$SWAP" || die "mkswap failed"
    fi

    FINAL_ROOT="$ROOT"
    LUKS_UUID=""

    if [ "$USE_LUKS" = "y" ]; then
        step "Setting up LUKS encryption..."
        printf '%s' "$LUKS_PASS" > /tmp/borealkey
        chmod 600 /tmp/borealkey
        cryptsetup luksFormat --type luks2 -q "$ROOT" --key-file=/tmp/borealkey || { shred -u /tmp/borealkey; die "luksFormat failed"; }
        cryptsetup luksOpen "$ROOT" borealcrypt --key-file=/tmp/borealkey || { shred -u /tmp/borealkey; die "luksOpen failed"; }
        shred -u /tmp/borealkey
        FINAL_ROOT="/dev/mapper/borealcrypt"
        LUKS_UUID=$(cryptsetup luksUUID "$ROOT")
        [ -n "$LUKS_UUID" ] || die "Could not read LUKS UUID"
    fi

    if [ "$USE_LVM" = "y" ]; then
        step "Setting up LVM..."
        pvcreate -f "$FINAL_ROOT"          || die "pvcreate failed"
        vgcreate borealvg "$FINAL_ROOT"    || die "vgcreate failed"
        lvcreate -l 100%FREE -n root borealvg || die "lvcreate failed"
        FINAL_ROOT="/dev/borealvg/root"
        sleep 1
    fi

    mkfs.ext4 -F -L borealOS "$FINAL_ROOT" || die "mkfs.ext4 failed"
    sleep 1
    ROOT_UUID=$(blkid -s UUID -o value "$FINAL_ROOT") || die "blkid root failed"
    EFI_UUID=$(blkid -s UUID -o value "$EFI")   || die "blkid efi failed"
    [ -n "$ROOT_UUID" ] || die "Root UUID empty"
    [ -n "$EFI_UUID"  ] || die "EFI UUID empty"
    ok "Root UUID: $ROOT_UUID  EFI UUID: $EFI_UUID"
}

mount_target() {
    step "Mounting..."
    mount "$FINAL_ROOT" /mnt     || die "mount root failed"
    mkdir -p /mnt/boot/efi
    mount "$EFI" /mnt/boot/efi  || die "mount EFI failed"
    ok "Mounted."
}

rsync_system() {
    step "Copying live system to disk..."
    rsync -aAX \
        --exclude=/proc/* \
        --exclude=/sys/* \
        --exclude=/dev/* \
        --exclude=/run/* \
        --exclude=/tmp/* \
        --exclude=/mnt/* \
        --exclude=/media/* \
        --exclude=/live \
        --exclude=/boot/grub \
        --exclude=/boot/efi \
        --exclude=/opt/borealOS \
        --exclude=/usr/local/bin/borealOS-install \
        --exclude=/etc/profile.d/live-welcome.sh \
        / /mnt/ || die "rsync failed"
    mkdir -p /mnt/{proc,sys,dev,run,tmp,boot/grub,boot/efi}
    chmod 1777 /mnt/tmp
    ok "System copied."
}

install_bundled_packages() {
    step "Verifying display manager on target..."
    bind_mounts

    # DM_PKGS is already installed at ISO-build time (build-iso.sh, right
    # alongside DE_PKGS) and rides onto the target via the rsync copy in
    # copy_system - no separate install needed, and this installer is
    # offline by design, so it never touches the network here. Just verify
    # what should already be there actually is.
    local dm_to_check="${DM_PKGS:-lightdm lightdm-gtk-greeter}"
    local missing=""
    for pkg in $dm_to_check; do
        chroot /mnt dpkg -s "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
    done
    if [ -n "$missing" ]; then
        warn "DM package(s) missing on target:$missing - they should have been baked into the ISO by build-iso.sh. Target may boot to TTY."
    fi

    # Install any other cached debs (bundled drivers, etc.) - purely local
    # files, dpkg -i, no network involved.
    local deb_count
    deb_count=$(ls /opt/borealOS/debs/*.deb 2>/dev/null | wc -l)
    if [ "$deb_count" -gt 0 ]; then
        mkdir -p /mnt/tmp/debs
        cp /opt/borealOS/debs/*.deb /mnt/tmp/debs/
        chroot /mnt /bin/bash <<DPKG
dpkg -i --force-depends /tmp/debs/*.deb 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true
rm -rf /tmp/debs
DPKG
        ok "Bundled debs installed ($deb_count)."
    fi

    unbind_mounts
    ok "Display manager installed."
}

bind_mounts() {
    for d in dev proc sys run; do
        mount --bind /$d /mnt/$d || die "bind mount /$d failed"
    done
}

unbind_mounts() {
    for d in dev proc sys run; do
        umount -l /mnt/$d 2>/dev/null || true
    done
}

write_fstab() {
    step "Writing fstab..."
    cat > /mnt/etc/fstab <<FSTAB
UUID=${ROOT_UUID}  /         ext4  errors=remount-ro  0  1
UUID=${EFI_UUID}   /boot/efi vfat  umask=0077         0  2
FSTAB
    if [ -n "$SWAP" ]; then
        SWAP_UUID=$(blkid -s UUID -o value "$SWAP")
        if [ -n "$SWAP_UUID" ]; then
            echo "UUID=${SWAP_UUID}   none      swap  sw                 0  0" >> /mnt/etc/fstab
        fi
    fi
    if [ "$USE_LUKS" = "y" ]; then
        cat > /mnt/etc/crypttab <<CRYPTTAB
borealcrypt UUID=${LUKS_UUID} none luks,discard
CRYPTTAB
    fi
    ok "fstab written."
}

write_network() {
    # Only loopback in interfaces - dhcpcd handles ethernet automatically
    # (dhcpcd skips interfaces listed in /etc/network/interfaces as DHCP)
    cat > /mnt/etc/network/interfaces <<IFACES
auto lo
iface lo inet loopback
IFACES
    rm -rf /mnt/etc/network/interfaces.d/* 2>/dev/null || true

    [ "$NET_TYPE" = "Skip" ] && { ok "Network skipped."; return; }

    step "Writing network config..."
    mkdir -p /mnt/etc/rc2.d /mnt/etc/runlevels/default

    if [ "$NET_TYPE" = "DHCP (automatic)" ]; then
        # dhcpcd with no interface arg = configures ALL ethernet interfaces automatically
        cat > /mnt/etc/dhcpcd.conf <<DHCP
hostname
clientid
persistent
option rapid_commit
option domain_name_servers, domain_name, domain_search, routers
option ntp_servers
option interface_mtu
slaac private
static domain_name_servers=1.1.1.1 8.8.8.8
DHCP
        rm -f /mnt/etc/rc2.d/S*dhcpcd /mnt/etc/rc2.d/S*NetworkManager 2>/dev/null || true
        rm -f /mnt/etc/runlevels/default/dhcpcd /mnt/etc/runlevels/default/NetworkManager 2>/dev/null || true
        ln -sf ../init.d/dhcpcd /mnt/etc/rc2.d/S02dhcpcd
        ln -sf /etc/init.d/dhcpcd /mnt/etc/runlevels/default/dhcpcd 2>/dev/null || true
    else
        cat >> /mnt/etc/network/interfaces <<IFACES

auto ${NET_IF}
iface ${NET_IF} inet static
    address ${NET_IP}
    gateway ${NET_GW}
    dns-nameservers ${NET_DNS}
IFACES
    fi
    ok "Network config written."
}

configure_system() {
    step "Configuring system..."

    cat > /mnt/etc/apt/sources.list <<SOURCES
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
SOURCES
    rm -f /mnt/etc/apt/sources.list.d/*.list 2>/dev/null || true

    chroot /mnt /bin/bash <<CHROOT || die "System configuration failed"
set -e
export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/70boreal-noninteractive <<'APTCONF'
DPkg::Options {
   "--force-confdef";
   "--force-confold";
}
APTCONF
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
HOSTS
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
echo "${TIMEZONE}" > /etc/timezone
sed -i "s|^# *${LOCALE}|${LOCALE}|" /etc/locale.gen 2>/dev/null || true
grep -q "^${LOCALE}" /etc/locale.gen 2>/dev/null || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
cat > /etc/os-release <<OS
NAME="BorealOS"
PRETTY_NAME="BorealOS 0.0.2"
ID=borealos
ID_LIKE=
VERSION="0.0.2"
VERSION_ID="0.0.2"
HOME_URL="https://borealos.org"
OS
cat > /etc/lsb-release <<LSB
DISTRIB_ID=BorealOS
DISTRIB_RELEASE=0.0.2
DISTRIB_CODENAME=boreal
DISTRIB_DESCRIPTION="BorealOS 0.0.2"
LSB
echo "BorealOS"     > /etc/issue
echo "BorealOS 0.0.2" > /etc/issue.net
echo "BorealOS"     > /etc/debian_version

# chrony is already installed at ISO-build time (build-iso.sh) and rsynced
# over with everything else - this installer is offline by design, so it
# only verifies it's there rather than trying to (re-)install it, which
# would need network access it isn't supposed to depend on.
command -v chronyd >/dev/null 2>&1 || command -v chrony >/dev/null 2>&1 || warn "chrony missing - it should have been baked into the ISO by build-iso.sh"
cat > /etc/adjtime <<'ADJTIME'
0.0 0 0.0
0
UTC
ADJTIME
hwclock --systohc --utc 2>/dev/null || true
mkdir -p /etc/chrony
if [ -f /etc/chrony/chrony.conf ] && ! grep -q "^makestep" /etc/chrony/chrony.conf; then
    cat >> /etc/chrony/chrony.conf <<'CHRONYCONF'

makestep 1.0 3
CHRONYCONF
fi
rc-update add chronyd default 2>/dev/null || rc-update add chrony default 2>/dev/null || true
rc-update add hwclock boot 2>/dev/null || true

# Same story as chrony above - elogind/polkitd/pkexec are already baked
# into the ISO by build-iso.sh, so just verify rather than reach for the
# network.
command -v elogind >/dev/null 2>&1 || warn "elogind missing - it should have been baked into the ISO by build-iso.sh - shutdown/restart will stay greyed out"
command -v pkexec >/dev/null 2>&1 || warn "pkexec missing - it should have been baked into the ISO by build-iso.sh - shutdown/restart will stay greyed out"
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

    step "Finalizing system branding..."
    find /mnt/usr/share \
        \( -name "*debian*" -not -path "*/dpkg/*" -not -path "*/apt/*" -not -path "*/python3/*" \) \
        -delete 2>/dev/null || true
    rm -rf /mnt/usr/share/images/desktop-base 2>/dev/null || true
    rm -rf /mnt/usr/share/images/vendor-logos 2>/dev/null || true

    if [ ! -s /mnt/usr/share/python3/debian_defaults ]; then
        PYVER=$(ls /mnt/usr/lib/ | grep -oP '^python3\.[0-9]+$' | sort -V | tail -1)
        if [ -n "$PYVER" ]; then
            mkdir -p /mnt/usr/share/python3
            cat > /mnt/usr/share/python3/debian_defaults <<PYDEFAULTS
[DEFAULT]
default-version = ${PYVER}
supported-versions = ${PYVER}
unsupported-versions =
requested-versions = 3.${PYVER#python3.}
PYDEFAULTS
        fi
    fi

    step "Installing artwork..."
    mkdir -p /mnt/usr/share/boreal-artwork
    # /opt/borealOS/default-wallpaper.png is the already-scaled, correct
    # default wallpaper (see build-iso.sh's comment where it's staged
    # there). This used to copy from background_2.png - a completely
    # different, unrelated wallpaper - which is the actual reason the
    # desktop wallpaper never reflected any fix to the wallpaper-setting
    # logic further down this file: this repair step ran afterward and
    # overwrote the correct file with the wrong one every single install.
    cp /opt/borealOS/default-wallpaper.png /mnt/usr/share/boreal-artwork/wallpaper-default.png
    cp /opt/borealOS/background_one.png /mnt/usr/share/boreal-artwork/wallpaper-waves.png
    cp /opt/borealOS/logo.png           /mnt/usr/share/boreal-artwork/logo.png

    ok "System configured."
}

set_passwords() {
    step "Setting passwords..."
    printf 'root:%s\n' "$ROOT_PASS" | chroot /mnt /usr/sbin/chpasswd || die "root password failed"
    for entry in "${EXTRA_USERS[@]}"; do
        local uname="${entry%%|*}"
        local rest="${entry#*|}"
        local upass="${rest%%|*}"
        local usudo="${rest##*|}"
        local groups="audio,video,netdev"
        [ "$usudo" = "y" ] && groups="sudo,${groups}"
        chroot /mnt useradd -m -G "$groups" -s "$SHELL_BIN" "$uname" 2>/dev/null || \
        chroot /mnt useradd -m -G "audio,video" -s "$SHELL_BIN" "$uname" || \
        die "useradd failed for $uname"
        printf '%s:%s\n' "$uname" "$upass" | chroot /mnt /usr/sbin/chpasswd || die "password failed for $uname"
    done
    ok "Passwords set."
}

remove_live_boot() {
    step "Removing live-boot..."
    chroot /mnt dpkg -r --force-depends \
        live-boot live-boot-initramfs-tools \
        live-config live-config-systemd 2>/dev/null || true
    find /mnt/usr/share/initramfs-tools \
         /mnt/etc/initramfs-tools \
         /mnt/etc/grub.d \
         -name "*live*" -delete 2>/dev/null || true
    rm -rf /mnt/lib/live /mnt/usr/lib/live 2>/dev/null || true
    rm -f /mnt/etc/profile.d/boreal-live.sh 2>/dev/null || true
    rm -f /mnt/usr/local/bin/boreal-start-graphical 2>/dev/null || true

    # Remove the minimal XFCE installer host environment unless the user
    # actually chose XFCE as their DE. If they chose XFCE, the full
    # xfce4-goodies suite was installed on top — nothing to remove.
    if [ "$DE_CHOICE" != "XFCE" ]; then
        step "Removing XFCE installer host (not the chosen DE)..."
        chroot /mnt apt-get remove --purge -y \
            xfce4 xfce4-terminal xfwm4 xfdesktop4 xfconf \
            xfce4-session xfce4-panel thunar \
            2>/dev/null || true
        chroot /mnt apt-get autoremove --purge -y 2>/dev/null || true
        ok "XFCE installer host removed."
    else
        ok "XFCE is the chosen DE — keeping full install."
    fi

    # Clean up the live-only deb caches from the target system
    rm -rf /mnt/opt/borealOS/gui-debs 2>/dev/null || true
    rm -rf /mnt/opt/borealOS/debs 2>/dev/null || true

    # Plymouth is now properly uninstalled via dpkg at ISO build time (see
    # build-iso.sh), instead of just having its files deleted - which used
    # to leave dpkg's database inconsistent (package still "installed" with
    # missing files) and break update-initramfs on every install. That's
    # fixed at the source now, so it shouldn't be present here at all. This
    # is just a cheap sanity check, not a routine cleanup step.
    if chroot /mnt dpkg -l plymouth 2>/dev/null | grep -q "^ii"; then
        warn "plymouth is still installed on target - it should have been removed at ISO build time. Removing it now as a fallback."
        chroot /mnt dpkg -r --force-depends plymouth plymouth-themes libplymouth5 plymouth-label plymouth-theme-debian-logo plymouth-theme-debian-spinner 2>/dev/null || true
    fi

    step "Rebuilding initramfs..."
    chroot /mnt update-initramfs -u -k all 2>&1 || die "update-initramfs failed"
    ls /mnt/boot/initrd.img-* >/dev/null 2>&1 || die "No initrd after rebuild"
    ok "live-boot removed, initramfs rebuilt."

    step "Generating unique machine-id for this install..."
    rm -f /mnt/etc/machine-id /mnt/var/lib/dbus/machine-id
    chroot /mnt dbus-uuidgen --ensure=/etc/machine-id
    mkdir -p /mnt/var/lib/dbus
    ln -sf /etc/machine-id /mnt/var/lib/dbus/machine-id
}

restore_inittab() {
    step "Restoring inittab..."
    cat > /mnt/etc/inittab <<'INITTAB'
id:2:initdefault:
si::sysinit:/etc/init.d/rcS
~~:S:wait:/sbin/sulogin --force
l0:0:wait:/etc/init.d/rc 0
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l4:4:wait:/etc/init.d/rc 4
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6
z6:6:respawn:/sbin/sulogin --force
ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now
pf::powerwait:/etc/init.d/powerfail start
pn::powerfailnow:/etc/init.d/powerfail now
po::powerokwait:/etc/init.d/powerfail stop
1:2345:respawn:/sbin/getty --noclear 38400 tty1
2:23:respawn:/sbin/getty 38400 tty2
3:23:respawn:/sbin/getty 38400 tty3
INITTAB
    ok "inittab restored."
}

setup_de() {
    step "Configuring DE: $DE_CHOICE..."
    mkdir -p /mnt/etc/runlevels/default /mnt/etc/rc2.d

    case "$DE_CHOICE" in
        "KDE Plasma")
            ln -sf /etc/init.d/sddm /mnt/etc/runlevels/default/sddm 2>/dev/null || true
            ln -sf ../init.d/sddm /mnt/etc/rc2.d/S03sddm 2>/dev/null || true
            mkdir -p /mnt/etc/sddm.conf.d
            cat > /mnt/etc/sddm.conf.d/borealos.conf <<SDDM
[General]
DisplayServer=x11
[Theme]
Background=/usr/share/boreal-artwork/wallpaper-default.png
SDDM
            ;;
        "XFCE")
            ln -sf /etc/init.d/lightdm /mnt/etc/runlevels/default/lightdm 2>/dev/null || true
            ln -sf ../init.d/lightdm /mnt/etc/rc2.d/S03lightdm 2>/dev/null || true

            # This installer is offline by design - there is no package
            # mirror available at install time, so there is no way to
            # "fix" a missing desktop environment here. XFCE is supposed
            # to already be present (rsynced over from the live squashfs -
            # see build-iso.sh, which now hard-fails at ISO build time if
            # startxfce4/xfwm4/xfce4-panel aren't present, specifically so
            # this situation can't happen with a correctly built ISO).
            # If this check ever fires, the ISO itself was built wrong or
            # is stale - failing clearly here beats a silent broken desktop
            # or a self-heal that requires network and will never work.
            if ! chroot /mnt sh -c "command -v startxfce4" >/dev/null 2>&1; then
                die "startxfce4 is missing on target - XFCE was not present in the live image this ISO was built from. This installer is offline and cannot fix that here. Rebuild the ISO with build-iso.sh (it now refuses to complete if XFCE isn't actually present), then try installing again with a fresh ISO."
            fi
            ok "XFCE present on target."

            step "Installing XFCE theming and panel plugins..."
            # fonts-ibm-plex/papirus-icon-theme/adwaita-icon-theme/panel
            # plugins are already installed at ISO build time (DE_EXTRA_PKGS
            # in build-iso.sh) and ride along here via the rsync from the
            # live squashfs - no need to reinstall them, and this installer
            # is offline so an apt-get call here couldn't work anyway.
            if chroot /mnt sh -c "command -v xfce4-panel" >/dev/null 2>&1 && chroot /mnt dpkg -l fonts-ibm-plex 2>/dev/null | grep -q "^ii"; then
                ok "Theming packages present on target."
            else
                warn "Some theming packages may be missing from the live image - desktop will still work but fonts/icons may fall back to system defaults. Rebuild the ISO if this is unexpected."
            fi

            step "Installing BorealOS-Dark theme..."
            if [ -d /usr/share/themes/BorealOS-Dark ] && [ ! -d /mnt/usr/share/themes/BorealOS-Dark ]; then
                mkdir -p /mnt/usr/share/themes
                cp -r /usr/share/themes/BorealOS-Dark /mnt/usr/share/themes/BorealOS-Dark
            fi
            if [ -d /mnt/usr/share/themes/BorealOS-Dark ]; then
                ok "BorealOS-Dark theme present on target."
            else
                warn "BorealOS-Dark theme not found anywhere - xfwm4/xsettings will fall back to the system default theme at runtime."
            fi

            mkdir -p /mnt/etc/lightdm
            if ls /opt/borealOS/lightdm/* >/dev/null 2>&1; then
                cp -r /opt/borealOS/lightdm/. /mnt/etc/lightdm/
                ok "lightdm rice config applied."
            else
                cat > /mnt/etc/lightdm/lightdm-gtk-greeter.conf <<LDM
[greeter]
background=/usr/share/boreal-artwork/wallpaper-default.png
theme-name=BorealOS-Dark
icon-theme-name=Papirus-Dark
cursor-theme-name=Adwaita
font-name=IBM Plex Sans 10
hide-user-image=true
LDM
            fi
            mkdir -p /mnt/etc/lightdm/lightdm.conf.d
            cat > /mnt/etc/lightdm/lightdm.conf.d/60-boreal.conf <<LIGHTDMCONF
[LightDM]
logind-check-graphical=true

[Seat:*]
greeter-session=lightdm-gtk-greeter
display-setup-script=/usr/local/bin/boreal-greeter-compositor
LIGHTDMCONF

            step "Fixing default wallpaper..."
            find /mnt/usr/share/backgrounds /mnt/usr/share/wallpapers \
                 /mnt/usr/share/xfce4/backdrops /mnt/usr/share/images/desktop-base \
                 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) \
                 -exec cp /mnt/usr/share/boreal-artwork/wallpaper-default.png {} \; 2>/dev/null || true

            step "Verifying theme script and autostart came over from the live image..."
            # boreal-apply-theme.sh and its autostart .desktop entry are
            # NOT written here anymore - they used to be, as a heredoc
            # embedded directly in this script, kept manually in sync with
            # the actual live-squashfs copy build-iso.sh produces. That's
            # exactly the kind of duplication that's easy to forget to
            # update (it happened - a THIRD copy, hardcoded in the GUI
            # installer's C source, went stale for turns without anyone
            # noticing, silently overwriting the correct rsynced file on
            # every GUI install). rsync_system already copies the entire
            # live filesystem, including these two files at their real
            # paths - so they're already correct here, and this just
            # verifies that rather than re-writing a second copy that
            # could drift from the first again.
            [ -x /mnt/usr/local/bin/boreal-apply-theme.sh ] || \
                warn "boreal-apply-theme.sh missing/not executable on target after rsync - theme won't self-apply at login"
            [ -f /mnt/etc/skel/.config/autostart/boreal-apply-theme.desktop ] || \
                warn "boreal-apply-theme.desktop missing from target skel after rsync"

            mkdir -p /mnt/root/.config/autostart
            cp /mnt/etc/skel/.config/autostart/boreal-apply-theme.desktop /mnt/root/.config/autostart/
            # xcompmgr for the XFCE session itself - xfwm4's own built-in
            # compositor is a different, unconfirmed code path from the
            # xcompmgr already proven working for lightdm's greeter, so
            # the session gets that same proven setup instead.
            [ -f /mnt/etc/skel/.config/autostart/boreal-compositor.desktop ] && \
                cp /mnt/etc/skel/.config/autostart/boreal-compositor.desktop /mnt/root/.config/autostart/
            chroot /mnt chown -R root:root /root/.config 2>/dev/null || true
            for u in "${EXTRA_USERS[@]}"; do
                local uname="${u%%|*}"
                [ -d "/mnt/home/${uname}" ] || continue
                mkdir -p "/mnt/home/${uname}/.config/autostart"
                cp /mnt/etc/skel/.config/autostart/boreal-apply-theme.desktop "/mnt/home/${uname}/.config/autostart/"
                [ -f /mnt/etc/skel/.config/autostart/boreal-compositor.desktop ] && \
                    cp /mnt/etc/skel/.config/autostart/boreal-compositor.desktop "/mnt/home/${uname}/.config/autostart/"
                chroot /mnt chown -R "${uname}:${uname}" "/home/${uname}/.config" 2>/dev/null || true
            done
            ;;
        "Hyprland")
            mkdir -p /mnt/etc/hypr
            cat > /mnt/etc/hypr/hyprland.conf <<HYPR
\$mod = SUPER
monitor=,preferred,auto,1
exec-once = waybar
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(4dffd2ff)
    col.inactive_border = rgba(0d1b2aff)
}
decoration { rounding = 8 }
bind = \$mod, Return, exec, foot
bind = \$mod, D, exec, wofi --show run
bind = \$mod SHIFT, Q, killactive
bind = \$mod SHIFT, E, exit
bind = \$mod, left, movefocus, l
bind = \$mod, right, movefocus, r
bind = \$mod, up, movefocus, u
bind = \$mod, down, movefocus, d
HYPR
            for u in "${EXTRA_USERS[@]}"; do
                local uname="${u%%|*}"
                mkdir -p /mnt/home/${uname}/.config/hypr
                cp /mnt/etc/hypr/hyprland.conf /mnt/home/${uname}/.config/hypr/
                chroot /mnt chown -R ${uname}:${uname} /home/${uname}/.config
            done
            ;;
        "Niri")
            mkdir -p /mnt/etc/niri
            cat > /mnt/etc/niri/config.kdl <<NIRI
input {
    keyboard { xkb { layout "us" } }
    touchpad { tap }
}
layout {
    gaps 16
    border { width 2; active-color "#4dffd2"; inactive-color "#0d1b2a" }
    focus-ring { off }
}
binds {
    Mod+Return { spawn "foot"; }
    Mod+D { spawn "wofi" "--show" "run"; }
    Mod+Shift+Q { close-window; }
    Mod+Shift+E { quit; }
    Mod+Left  { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Up    { focus-window-up; }
    Mod+Down  { focus-window-down; }
}
NIRI
            for u in "${EXTRA_USERS[@]}"; do
                local uname="${u%%|*}"
                mkdir -p /mnt/home/${uname}/.config/niri
                cp /mnt/etc/niri/config.kdl /mnt/home/${uname}/.config/niri/
                chroot /mnt chown -R ${uname}:${uname} /home/${uname}/.config
            done
            ;;
    esac
    ok "DE configured."
}

install_grub() {
    step "Installing GRUB theme..."
    mkdir -p /mnt/boot/grub/themes/boreal
    if [ -d /usr/share/grub/themes/boreal ]; then
        cp -r /usr/share/grub/themes/boreal/. /mnt/boot/grub/themes/boreal/
    fi

    step "Installing GRUB..."
    rm -rf /mnt/boot/efi/EFI 2>/dev/null || true

    cat > /mnt/etc/default/grub <<GRUBDEF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=BorealOS
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
GRUB_GFXMODE=1024x768,auto
GRUBDEF
    if [ "$USE_LUKS" = "y" ]; then
        echo "GRUB_ENABLE_CRYPTODISK=y" >> /mnt/etc/default/grub
    fi

    GRUB_MODULES=""
    if [ "$USE_LUKS" = "y" ] && [ "$USE_LVM" = "y" ]; then
        GRUB_MODULES='--modules="cryptodisk luks2 luks lvm"'
    elif [ "$USE_LUKS" = "y" ]; then
        GRUB_MODULES='--modules="cryptodisk luks2 luks"'
    elif [ "$USE_LVM" = "y" ]; then
        GRUB_MODULES='--modules="lvm"'
    fi

    chroot /mnt bash -c "grub-install --target=i386-pc $GRUB_MODULES '$DISK'" \
        2>&1 || die "BIOS grub-install failed"

    chroot /mnt bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BorealOS --removable --recheck $GRUB_MODULES" \
        2>&1 || warn "EFI grub-install failed (ok if BIOS-only)"

    KVER=$(ls /mnt/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's|/mnt/boot/vmlinuz-||')
    [ -n "$KVER" ] || die "No kernel found in /mnt/boot"
    [ -f "/mnt/boot/initrd.img-${KVER}" ] || die "No initrd for kernel $KVER"

    UNLOCK=""
    if [ "$USE_LUKS" = "y" ]; then
        NODASH=$(echo "$LUKS_UUID" | tr -d '-')
        UNLOCK="insmod cryptodisk
insmod luks2
insmod luks
cryptomount -u ${NODASH}
"
        [ "$USE_LVM" = "y" ] && UNLOCK="${UNLOCK}insmod lvm
"
    elif [ "$USE_LVM" = "y" ]; then
        UNLOCK="insmod lvm
"
    fi

    mkdir -p /mnt/boot/efi/EFI/BOOT
    cat > /mnt/boot/efi/EFI/BOOT/grub.cfg <<EGCFG
${UNLOCK}search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
set prefix=(\$root)/boot/grub
configfile (\$root)/boot/grub/grub.cfg
EGCFG

    mkdir -p /mnt/boot/grub
    cat > /mnt/boot/grub/grub.cfg <<GCFG
insmod all_video
insmod gfxterm
insmod png
insmod font
set gfxmode=1024x768,auto
terminal_output gfxterm

set default=0
set timeout=5

if [ -f /boot/grub/themes/boreal/theme.txt ]; then
    if loadfont /boot/grub/themes/boreal/plex_regular_16.pf2; then
        loadfont /boot/grub/themes/boreal/plex_bold_16.pf2
        loadfont /boot/grub/themes/boreal/plex_regular_13.pf2
    fi
    set theme=/boot/grub/themes/boreal/theme.txt
else
    set menu_color_normal=cyan/black
    set menu_color_highlight=black/cyan
fi

menuentry "BorealOS 0.0.2" {
    ${UNLOCK}search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID} ro quiet
    initrd /boot/initrd.img-${KVER}
}
menuentry "BorealOS 0.0.2 (recovery)" {
    ${UNLOCK}search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID} ro single
    initrd /boot/initrd.img-${KVER}
}
GCFG

    ok "GRUB installed. Kernel: $KVER"
}

verify() {
    step "Verifying..."
    local fail=0
    [ -f /mnt/boot/grub/grub.cfg ]                 || { warn "grub.cfg missing";     fail=1; }
    [ -f /mnt/etc/fstab ]                          || { warn "fstab missing";         fail=1; }
    ls /mnt/boot/vmlinuz-* >/dev/null 2>&1         || { warn "No kernel";             fail=1; }
    ls /mnt/boot/initrd.img-* >/dev/null 2>&1      || { warn "No initrd";             fail=1; }
    grep -q "${ROOT_UUID}" /mnt/boot/grub/grub.cfg || { warn "UUID not in grub.cfg";  fail=1; }
    grep -q "${ROOT_UUID}" /mnt/etc/fstab          || { warn "UUID not in fstab";     fail=1; }
    grep -q "boot=live" /mnt/boot/grub/grub.cfg    && { warn "boot=live in grub.cfg!"; fail=1; }
    [ "$fail" = "1" ] && die "Verification failed."
    ok "All checks passed."
}

cleanup() {
    unbind_mounts 2>/dev/null || true
    umount /mnt/boot/efi 2>/dev/null || true
    umount /mnt 2>/dev/null || true
    [ -n "$SWAP" ] && swapoff "$SWAP" 2>/dev/null || true
    vgchange -an borealvg 2>/dev/null || true
    cryptsetup luksClose borealcrypt 2>/dev/null || true
}

finish() {
    banner
    ok "Installation complete."
    echo
    echo "  Disk:        $DISK"
    echo "  DE/WM:       $DE_CHOICE"
    echo "  Shell:       $SHELL_BIN"
    echo "  Host:        $HOSTNAME"
    echo "  Timezone:    $TIMEZONE"
    echo "  Network:     $NET_TYPE"
    echo "  Extra users: ${#EXTRA_USERS[@]}"
    echo
    menu "What now?" "Reboot" "Drop to shell"
    case "$MENU_RESULT" in
        "Reboot") reboot ;;
        "Drop to shell") echo -e "${CYN}Type 'reboot' when done.${RST}"; bash ;;
    esac
}

main() {
    check_root
    check_assets
    banner
    echo -e "${BLD}BorealOS Installer${RST}"
    echo -e "  DE: ${DE_CHOICE}  |  Shell: ${SHELL_BIN}"
    echo
    confirm "Begin?" || die "Aborted."

    select_disk
    select_partitioning
    get_user_info
    get_extra_users
    configure_network

    banner
    echo -e "${BLD}Summary:${RST}"
    echo "  Disk:         $DISK"
    echo "  Hostname:     $HOSTNAME"
    echo "  Timezone:     $TIMEZONE"
    echo "  DE/WM:        $DE_CHOICE"
    echo "  Shell:        $SHELL_BIN"
    echo "  Network:      $NET_TYPE"
    echo "  Extra users:  ${#EXTRA_USERS[@]}"
    echo
    confirm "Proceed?" || die "Aborted."

    partition_disk
    mount_target
    rsync_system
    install_bundled_packages
    write_fstab
    write_network
    bind_mounts
    configure_system
    set_passwords
    remove_live_boot
    restore_inittab
    setup_de
    install_grub
    unbind_mounts
    verify
    cleanup
    finish
}

trap 'unbind_mounts 2>/dev/null; umount /mnt/boot/efi 2>/dev/null; umount /mnt 2>/dev/null; vgchange -an borealvg 2>/dev/null; cryptsetup luksClose borealcrypt 2>/dev/null' EXIT
main
