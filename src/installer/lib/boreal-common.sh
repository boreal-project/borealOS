#!/bin/bash
# Shared BorealOS installer helpers: version, release channel, apt sources, branding.

BOREAL_VERSION="0.0.2"
BOREAL_HOME_URL="https://boreal-project.github.io"

BOREAL_BASE="${BOREAL_BASE:-debian}"          # debian | devuan
BOREAL_CHANNEL="${BOREAL_CHANNEL:-stable}"    # stable | testing | unstable
BOREAL_MIRROR="${BOREAL_MIRROR:-}"            # empty = base default
BOREAL_SECURITY_MIRROR="${BOREAL_SECURITY_MIRROR:-}"
BOREAL_COMPONENTS="${BOREAL_COMPONENTS:-main contrib non-free non-free-firmware}"

boreal_suite() {
    case "$BOREAL_BASE:$BOREAL_CHANNEL" in
        debian:stable)   echo trixie ;;
        debian:testing)  echo forky ;;
        debian:unstable) echo sid ;;
        devuan:stable)   echo excalibur ;;
        devuan:testing)  echo freia ;;
        devuan:unstable) echo ceres ;;
        *) return 1 ;;
    esac
}

boreal_default_mirror() {
    case "$BOREAL_BASE" in
        debian) echo "http://deb.debian.org/debian" ;;
        devuan) echo "http://deb.devuan.org/merged" ;;
        *) return 1 ;;
    esac
}

boreal_default_security_mirror() {
    case "$BOREAL_BASE" in
        debian) echo "http://deb.debian.org/debian-security" ;;
        devuan) echo "http://deb.devuan.org/merged" ;;
        *) return 1 ;;
    esac
}

boreal_valid_mirror() {
    [[ "$1" =~ ^https?://[A-Za-z0-9._~:/%-]+$ ]]
}

# Prints sources.list lines for the chosen base/channel/mirror.
boreal_sources_list() {
    local suite mirror sec
    suite="$(boreal_suite)" || return 1
    mirror="${BOREAL_MIRROR:-$(boreal_default_mirror)}"
    mirror="${mirror%/}"
    sec="${BOREAL_SECURITY_MIRROR:-$(boreal_default_security_mirror)}"
    sec="${sec%/}"

    echo "deb $mirror $suite $BOREAL_COMPONENTS"
    # Only stable has -updates/-security pockets.
    if [ "$BOREAL_CHANNEL" = "stable" ]; then
        echo "deb $mirror ${suite}-updates $BOREAL_COMPONENTS"
        echo "deb $sec ${suite}-security $BOREAL_COMPONENTS"
    fi
}

# Backports suite for newer kernels; stable only, from the chosen mirror.
boreal_backports_suite() {
    [ "$BOREAL_CHANNEL" = "stable" ] && echo "$(boreal_suite)-backports"
    return 0
}

boreal_backports_list() {
    local bp mirror
    bp="$(boreal_backports_suite)"
    mirror="${BOREAL_MIRROR:-$(boreal_default_mirror)}"
    [ -n "$bp" ] && echo "deb ${mirror%/} $bp main"
    return 0
}

boreal_id_like() {
    case "$BOREAL_BASE" in
        devuan) echo "devuan debian" ;;
        *) echo "debian" ;;
    esac
}

# boreal_write_branding <root>: os-release, lsb-release, issue files under <root>.
boreal_write_branding() {
    local root="${1:-}"
    mkdir -p "$root/etc"
    [ -L "$root/etc/os-release" ] && rm -f "$root/etc/os-release"
    cat > "$root/etc/os-release" <<OS
NAME="BorealOS"
PRETTY_NAME="BorealOS ${BOREAL_VERSION}"
ID=borealos
ID_LIKE="$(boreal_id_like)"
VERSION="${BOREAL_VERSION}"
VERSION_ID="${BOREAL_VERSION}"
HOME_URL="${BOREAL_HOME_URL}"
OS
    cat > "$root/etc/lsb-release" <<LSB
DISTRIB_ID=BorealOS
DISTRIB_RELEASE=${BOREAL_VERSION}
DISTRIB_CODENAME=boreal
DISTRIB_DESCRIPTION="BorealOS ${BOREAL_VERSION}"
LSB
    echo "BorealOS"                > "$root/etc/issue"
    echo "BorealOS ${BOREAL_VERSION}" > "$root/etc/issue.net"
    echo "BorealOS"                > "$root/etc/debian_version"
}
