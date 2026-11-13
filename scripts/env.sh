#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DEVICE="${1:?Usage: env.sh <device>}"
DEVICE_JSON="devices/${DEVICE}.json"

[ -f "$DEVICE_JSON" ] || die "No device config found at $DEVICE_JSON"

KERNEL_REPO=$(read_field kernel_repo)
KERNEL_BRANCH=$(read_field kernel_branch)
KERNEL_ARCH=$(read_field arch)
CLANG_TYPE=$(read_field clang_type)
CLANG_VERSION=$(read_field clang_version)

# "neutron" (default) is the custom kernel-oriented LLVM build from
# Neutron-Toolchains, identified by a pinned catalogue build tag.
# "aosp" is a googlesource prebuilt, identified by its release branch.
CLANG_TYPE="${CLANG_TYPE:-neutron}"

[ -n "$KERNEL_ARCH" ] || die "No arch set in $DEVICE_JSON for device '$DEVICE'"
if [ "$KERNEL_ARCH" != "arm64" ]; then
    die "env.sh only supports arch=arm64 — device '$DEVICE' declares arch='$KERNEL_ARCH'."
fi

[ -n "$CLANG_VERSION" ] || die "No clang_version set in $DEVICE_JSON for device '$DEVICE'"

# glibc version on the build host — Neutron Clang binaries are dynamically
# linked against the glibc of the machine that produced them, so an older host
# cannot run them at all.
host_glibc=$(ldd --version 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+$' || true)

# glibc_older <host> <required> → true when the host glibc is too old
glibc_older() {
    local h_major="${1%%.*}" h_minor="${1#*.}"
    local r_major="${2%%.*}" r_minor="${2#*.}"
    (( h_major < r_major || (h_major == r_major && h_minor < r_minor) ))
}

case "$CLANG_TYPE" in
neutron)
    CLANG_TAG=$(read_field clang_tag)
    CLANG_SHA256=$(read_field clang_sha256)

    [ -n "$CLANG_TAG" ] || die "No clang_tag set in $DEVICE_JSON for device '$DEVICE' — pin the Neutron Clang build (e.g. 06092026)."
    [ -n "$CLANG_SHA256" ] || die "No clang_sha256 set in $DEVICE_JSON for device '$DEVICE' — pin the release tarball checksum."

    command -v zstd >/dev/null 2>&1 || die "zstd is required to unpack the Neutron Clang tarball — install the zstd package."
    command -v tar >/dev/null 2>&1 || die "tar is required to unpack the Neutron Clang tarball."

    log "Device: $DEVICE"
    log "Kernel: $KERNEL_REPO ($KERNEL_BRANCH)"
    log "Clang:  Neutron Clang ${CLANG_VERSION} (build ${CLANG_TAG})"

    CLANG_DIR="$(pwd)/toolchain/neutron-clang-${CLANG_TAG}"

    # The catalogue entry is the source of truth for what a tag contains. It is
    # checked on every run, cached toolchain or not: confirm the pinned tag
    # really is the requested clang major version, that the published tarball
    # still matches the checksum we pinned, and that this host can run it.
    INFO_FILE="/tmp/neutron-${CLANG_TAG}-info.txt"
    retry_fetch "https://raw.githubusercontent.com/Neutron-Toolchains/clang-build-catalogue/main/${CLANG_TAG}-info.txt" "$INFO_FILE"

    CATALOGUE_VER=$(grep -A1 '^\[clang-ver\]' "$INFO_FILE" | tail -n1)
    CATALOGUE_SHA=$(grep -A1 '^\[shasum\]' "$INFO_FILE" | tail -n1)
    CATALOGUE_GLIBC=$(grep -A1 '^\[host-glibc\]' "$INFO_FILE" | tail -n1)

    [ -n "$CATALOGUE_VER" ] || die "Could not read clang-ver from the catalogue info for build ${CLANG_TAG}."
    [ "${CATALOGUE_VER%%.*}" = "$CLANG_VERSION" ] || \
        die "Neutron Clang build ${CLANG_TAG} is clang ${CATALOGUE_VER}, but $DEVICE_JSON asks for clang ${CLANG_VERSION}. Pick a build tag whose clang major matches."

    if [ -n "$CATALOGUE_SHA" ] && [ "$CATALOGUE_SHA" != "$CLANG_SHA256" ]; then
        die "Neutron Clang build ${CLANG_TAG} checksum changed (pinned ${CLANG_SHA256}, catalogue ${CATALOGUE_SHA}). Re-pin clang_sha256 in $DEVICE_JSON only after verifying the rebuild."
    fi

    if [ -n "$host_glibc" ] && [ -n "$CATALOGUE_GLIBC" ] && glibc_older "$host_glibc" "$CATALOGUE_GLIBC"; then
        warn "Host glibc is ${host_glibc}, but Neutron Clang ${CLANG_TAG} needs at least ${CATALOGUE_GLIBC}."
        warn "Its binaries will fail to load on this machine — build on a host that ships glibc ${CATALOGUE_GLIBC} or newer."
    fi

    if [ -d "$CLANG_DIR/bin" ]; then
        log "Using cached toolchain at $CLANG_DIR (restored from CI cache or already present)"
    else
        log "Fetching Neutron Clang ${CLANG_TAG} (clang ${CATALOGUE_VER})..."
        CLANG_TARBALL="/tmp/neutron-clang-${CLANG_TAG}.tar.zst"
        retry_fetch "https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/${CLANG_TAG}/neutron-clang-${CLANG_TAG}.tar.zst" "$CLANG_TARBALL"

        echo "${CLANG_SHA256}  ${CLANG_TARBALL}" | sha256sum -c - >/dev/null || \
            die "Checksum mismatch for Neutron Clang ${CLANG_TAG} tarball — refusing to use it."

        mkdir -p "$CLANG_DIR"
        tar -I zstd -xf "$CLANG_TARBALL" -C "$CLANG_DIR"
        rm -f "$CLANG_TARBALL"

        [ -d "$CLANG_DIR/bin" ] || die "Extracted archive but $CLANG_DIR/bin is missing — archive layout may differ from expected."
    fi

    log "Toolchain glibc requirement: ${CATALOGUE_GLIBC:-unknown}, host: ${host_glibc:-unknown}"
    ;;
aosp)
    CLANG_BRANCH=$(read_field clang_branch)

    if [ -z "$CLANG_BRANCH" ]; then
        warn "No clang_branch set in $DEVICE_JSON for device '$DEVICE'"
        warn "This must match the exact googlesource release branch this clang_version was published under"
        die "(e.g. android16-qpr2-release for r563880c) — verify against https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 first, do not guess it."
    fi

    log "Device: $DEVICE"
    log "Kernel: $KERNEL_REPO ($KERNEL_BRANCH)"
    log "Clang:  clang-$CLANG_VERSION"

    CLANG_DIR="$(pwd)/toolchain/clang-${CLANG_VERSION}"

    if [ -d "$CLANG_DIR/bin" ]; then
        log "Using cached toolchain at $CLANG_DIR (restored from CI cache or already present)"
    else
        log "Fetching clang-${CLANG_VERSION} from googlesource (archive)..."
        mkdir -p "$CLANG_DIR"
        ARCHIVE_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/${CLANG_BRANCH}/clang-${CLANG_VERSION}.tar.gz"

        # retry_fetch (common.sh): survives transient network blips
        retry_fetch "$ARCHIVE_URL" "/tmp/clang-${CLANG_VERSION}.tar.gz"

        tar -xzf "/tmp/clang-${CLANG_VERSION}.tar.gz" -C "$CLANG_DIR"
        rm -f "/tmp/clang-${CLANG_VERSION}.tar.gz"

        [ -d "$CLANG_DIR/bin" ] || die "Extracted archive but $CLANG_DIR/bin is missing — archive layout may differ from expected."
    fi
    ;;
*)
    die "Unknown clang_type '$CLANG_TYPE' in $DEVICE_JSON — expected 'neutron' or 'aosp'."
    ;;
esac

export PATH="${CLANG_DIR}/bin:${PATH}"

# CRITICAL: this kernel's top-level Makefile assigns CC/LD/AR/etc
export LLVM=1
export LLVM_IAS=1

export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

log "Toolchain ready: $(clang --version | head -1)"
