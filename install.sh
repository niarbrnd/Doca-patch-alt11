#!/bin/bash
# =============================================================================
# DOCA 3.2.1 Installation Script for ALT Linux 11 (Nimbostratus)
# =============================================================================
# Installs NVIDIA DOCA 3.2.1 from pre-built RHEL 10 RPMs onto ALT Linux 11
# (kernel 6.12.x). Uses a parallel install strategy:
#
#   OFED userspace   → extracted via rpm2cpio → /opt/doca/
#   DOCA SDK         → installed via rpm --nodeps → /opt/mellanox/doca/
#   Kernel modules   → built via DKMS for the running kernel
#
# Usage:
#   ./install.sh [OPTIONS] [PHASE]
#
# Phases:  phase0 | phase1 | phase2 | phase3 | phase4 | all (default)
#          phase0  = system prerequisites (gcc, dkms, headers, symlinks)
#          phase1  = OFED userspace extraction
#          phase2  = DOCA SDK installation
#          phase3  = ldconfig + environment setup
#          phase4  = DKMS kernel modules build & install
#
# Options:
#   --repo DIR      Path to DOCA RPM packages directory
#                   (default: /usr/share/doca-host-3.2.1/repo/Packages)
#   --kernel VER    Target kernel version for DKMS
#                   (default: running kernel from uname -r)
#   --no-download   Skip downloading missing packages from internet
#   --dry-run       Show what would be done without executing
#   -h, --help      Show this help
# =============================================================================

set -euo pipefail

# ─── Configurable defaults ────────────────────────────────────────────────────
DOCA_PKGDIR="${DOCA_PKGDIR:-/usr/share/doca-host-3.2.1/repo/Packages}"
OFED_PREFIX="/opt/doca"
TARGET_KERNEL="${TARGET_KERNEL:-$(uname -r)}"
DOWNLOAD_PKGS=true
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ALT Sisyphus task URLs for packages unavailable in p11
# (verified build tasks as of Feb 2026)
GCC13_URL_BASE="https://git.altlinux.org/tasks/340115/build/400/x86_64/rpms"
LIBSTDCXX14_URL="https://git.altlinux.org/tasks/398037/build/200/x86_64/rpms/libstdc++6-14.3.1-alt2.x86_64.rpm"
DKMS_URL="https://git.altlinux.org/tasks/363381/build/3200/x86_64/rpms/dkms-3.1.1-alt3.noarch.rpm"
KERNEL_TASK_URL="https://git.altlinux.org/tasks/406728/build/100/x86_64/rpms"

# ─── Colors & logging ─────────────────────────────────────────────────────────
RED='\033[0;31m'; YLW='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLU}[DOCA]${NC} $*"; }
ok()   { echo -e "${GRN}[OK]${NC}   $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*" >&2; }
die()  { err "$*"; exit 1; }
run()  { $DRY_RUN && echo "  [DRY] $*" || "$@"; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
PHASE="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)       DOCA_PKGDIR="$2"; shift 2 ;;
        --kernel)     TARGET_KERNEL="$2"; shift 2 ;;
        --no-download) DOWNLOAD_PKGS=false; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    sed -n '2,35p' "$0"; exit 0 ;;
        phase[0-4]|all) PHASE="$1"; shift ;;
        *) die "Unknown argument: $1. Use --help for usage." ;;
    esac
done

# ─── Guards ───────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This script must be run as root"

check_alt_linux() {
    if ! grep -qi "alt" /etc/os-release 2>/dev/null; then
        warn "Not detected as ALT Linux — continuing anyway"
    fi
}

check_pkgdir() {
    [[ -d "$DOCA_PKGDIR" ]] || die "DOCA package directory not found: $DOCA_PKGDIR"
    local count
    count=$(ls "$DOCA_PKGDIR"/*.rpm 2>/dev/null | wc -l)
    [[ $count -gt 50 ]] || die "Expected 100+ RPM packages in $DOCA_PKGDIR, found $count"
    ok "Found $count RPM packages in $DOCA_PKGDIR"
}

# ─── Download helper ──────────────────────────────────────────────────────────
download_rpm() {
    local url="$1" dest_dir="${2:-/tmp/doca-deps}"
    local fname; fname=$(basename "$url")
    mkdir -p "$dest_dir"
    if [[ -f "$dest_dir/$fname" ]]; then
        ok "Already downloaded: $fname"
        return 0
    fi
    if ! $DOWNLOAD_PKGS; then
        warn "Download skipped (--no-download): $fname"
        return 1
    fi
    log "Downloading: $fname"
    if ! wget -q --show-progress -O "$dest_dir/$fname" "$url"; then
        err "Failed to download: $url"
        rm -f "$dest_dir/$fname"
        return 1
    fi
    ok "Downloaded: $fname"
}

install_rpm_nodeps() {
    local pkg="$1"
    log "  Installing (--nodeps): $(basename "$pkg")"
    run rpm -ivh --nodeps --nosignature "$pkg" 2>&1 | grep -v "^$" || true
}

# =============================================================================
# PHASE 0: System Prerequisites
# =============================================================================
phase0_prerequisites() {
    log "=== PHASE 0: System Prerequisites ==="
    local tmpdir=/tmp/doca-deps
    mkdir -p "$tmpdir"

    # ── 0a. gcc-13 and development tools ──────────────────────────────────────
    log "-- 0a. Checking GCC 13 toolchain"
    if ! command -v gcc-13 &>/dev/null; then
        log "  gcc-13 not found — downloading from ALT repository"
        for pkg in gcc13-13.2.1-alt3.x86_64.rpm gcc13-c++-13.2.1-alt3.x86_64.rpm \
                   cpp13-13.2.1-alt3.x86_64.rpm; do
            download_rpm "$GCC13_URL_BASE/$pkg" "$tmpdir" && \
                install_rpm_nodeps "$tmpdir/$pkg" || warn "Failed to install $pkg"
        done
        # Dependencies for gcc13
        for pkg in glibc-devel libmpc3 libmpfr6; do
            if ! rpm -q "$pkg" &>/dev/null; then
                warn "  $pkg missing — attempting download"
                # Try to get from the same task
                download_rpm "$GCC13_URL_BASE/${pkg}-*.x86_64.rpm" "$tmpdir" 2>/dev/null && \
                    install_rpm_nodeps "$tmpdir/${pkg}"*.rpm 2>/dev/null || \
                    warn "  $pkg not installed — DKMS build may fail"
            fi
        done
    else
        ok "gcc-13 already present"
    fi

    # ── 0b. libstdc++6-14 from ALT Sisyphus (provides CXXABI_1.3.15) ──────────
    log "-- 0b. Checking libstdc++6 version (need CXXABI >= 1.3.15 for DOCA SDK)"
    if ! strings /usr/lib64/libstdc++.so.6 2>/dev/null | grep -q "CXXABI_1.3.15"; then
        log "  CXXABI_1.3.15 not found — downloading libstdc++6-14 from Sisyphus"
        download_rpm "$LIBSTDCXX14_URL" "$tmpdir" && \
            run rpm -Uvh --nodeps --nosignature "$tmpdir/libstdc++6-14"*.rpm || \
            warn "  Could not upgrade libstdc++6 — DOCA runtime may fail to load"
    else
        ok "CXXABI_1.3.15 already available"
    fi

    # ── 0c. DKMS (ALT native, not RHEL) ───────────────────────────────────────
    log "-- 0c. Checking DKMS"
    if ! rpm -q dkms &>/dev/null || rpm -q dkms | grep -q "el10"; then
        log "  RHEL dkms detected or dkms missing — installing ALT native dkms"
        # Remove RHEL dkms if present
        rpm -e --nodeps dkms 2>/dev/null || true
        download_rpm "$DKMS_URL" "$tmpdir" && \
            install_rpm_nodeps "$tmpdir/dkms-3.1.1-alt3.noarch.rpm" || \
            die "Cannot install DKMS — kernel module build will fail"
    else
        ok "DKMS already present: $(rpm -q dkms)"
    fi

    # ── 0d. Kernel headers for TARGET_KERNEL ──────────────────────────────────
    log "-- 0d. Checking kernel headers for $TARGET_KERNEL"
    local kver_short; kver_short=$(echo "$TARGET_KERNEL" | grep -oP '^\d+\.\d+')
    local hdr_pkg="kernel-headers-modules-${kver_short}"

    if [[ ! -d "/usr/src/linux-headers-${TARGET_KERNEL}" ]] && \
       [[ ! -d "/usr/src/linux-${TARGET_KERNEL}" ]]; then
        log "  Kernel headers not found — downloading for $TARGET_KERNEL"
        for pkg in "kernel-headers-modules-${kver_short}" \
                   "kernel-headers-${kver_short}" \
                   "kernel-image-${kver_short}"; do
            download_rpm "${KERNEL_TASK_URL}/${pkg}-${TARGET_KERNEL%-*}-alt1.x86_64.rpm" \
                         "$tmpdir" 2>/dev/null && \
                install_rpm_nodeps "$tmpdir/${pkg}"*.rpm 2>/dev/null || true
        done
    else
        ok "Kernel headers present for $TARGET_KERNEL"
    fi

    # Verify kernel build dir
    if [[ ! -d "/lib/modules/$TARGET_KERNEL/build" ]]; then
        warn "Kernel build directory missing: /lib/modules/$TARGET_KERNEL/build"
        warn "DKMS build will likely fail. Reboot into $TARGET_KERNEL first."
    fi

    # ── 0e. cpp preprocessor symlink ──────────────────────────────────────────
    log "-- 0e. Checking cpp preprocessor symlink"
    if [[ ! -x /usr/bin/cpp ]]; then
        if [[ -x /usr/bin/cpp-13 ]]; then
            run ln -sf /usr/bin/cpp-13 /usr/bin/cpp
            run ln -sf /usr/bin/cpp-13 /lib/cpp
            ok "Created /usr/bin/cpp → cpp-13"
        else
            warn "cpp-13 not found — knem/xpmem build may fail"
        fi
    else
        ok "cpp symlink present: $(readlink -f /usr/bin/cpp)"
    fi

    # ── 0f. UAPI kernel headers symlinks ──────────────────────────────────────
    log "-- 0f. Checking UAPI kernel headers in /usr/include/"
    local uapi_base
    uapi_base=$(ls -d /usr/include/linux-${kver_short}*/include 2>/dev/null | sort -V | tail -1)

    if [[ -n "$uapi_base" ]] && [[ ! -d /usr/include/linux ]]; then
        run ln -sf "$uapi_base/linux"       /usr/include/linux
        run ln -sf "$uapi_base/asm"         /usr/include/asm
        run ln -sf "$uapi_base/asm-generic" /usr/include/asm-generic
        ok "Created UAPI header symlinks → $uapi_base"
    elif [[ -d /usr/include/linux ]]; then
        ok "UAPI headers already in /usr/include/linux/"
    else
        warn "UAPI headers not found — knem configure may fail"
    fi

    ok "Phase 0 complete"
}

# =============================================================================
# PHASE 1: OFED Userspace (via rpm2cpio → /opt/doca/)
# =============================================================================
phase1_ofed_userspace() {
    log "=== PHASE 1: OFED userspace → $OFED_PREFIX ==="
    run mkdir -p "$OFED_PREFIX"

    # Packages that conflict with ALT Linux system packages.
    # Extracted in parallel to /opt/doca/ to avoid overwriting ALT's libibverbs.
    local OFED_PKGS=(
        rdma-core-2510.0.11-1.el10.x86_64.rpm
        rdma-core-devel-2510.0.11-1.el10.x86_64.rpm
        libibverbs-2510.0.11-1.el10.x86_64.rpm
        libibverbs-utils-2510.0.11-1.el10.x86_64.rpm
        libibumad-2510.0.11-1.el10.x86_64.rpm
        librdmacm-2510.0.11-1.el10.x86_64.rpm
        librdmacm-utils-2510.0.11-1.el10.x86_64.rpm
        python3-pyverbs-2510.0.11-1.el10.x86_64.rpm
        ibacm-2510.0.11-1.el10.x86_64.rpm
        srp_daemon-2510.0.11-1.el10.x86_64.rpm
        libxpmem-2510.0.16-1.el10.x86_64.rpm
        libxpmem-devel-2510.0.16-1.el10.x86_64.rpm
        xpmem-2510.0.16-1.el10.x86_64.rpm
        knem-1.1.4.90mlnx4-OFED.25.10.1.2.2.1.el10.x86_64.rpm
        ibarr-2510.0.0-1.el10.x86_64.rpm
        ibdump-6.0.0-2.el10.x86_64.rpm
        ibsim-0.12.1-3.el10.x86_64.rpm
        ibutils2-2.1.1-0.22400.MLNX20251030.g8c84ecb57.2510122.x86_64.rpm
        infiniband-diags-2510.0.11-1.el10.x86_64.rpm
        infiniband-diags-compat-2510.0.11-1.el10.x86_64.rpm
        opensm-5.25.1.MLNX20251030.e3791a47-0.1.2510122.x86_64.rpm
        opensm-libs-5.25.1.MLNX20251030.e3791a47-0.1.2510122.x86_64.rpm
        opensm-devel-5.25.1.MLNX20251030.e3791a47-0.1.2510122.x86_64.rpm
        opensm-static-5.25.1.MLNX20251030.e3791a47-0.1.2510122.x86_64.rpm
        mft-4.34.1-10.x86_64.rpm
        mft-mlx5-4.34.1-10.x86_64.rpm
        mft-nvredfish-4.34.1-10.x86_64.rpm
        mlnx-tools-2510.0.16-1.x86_64.rpm
        mlnx-fw-updater-25.10-1.7.1.0.x86_64.rpm
        mlnxofed-docs-25.10-1.7.1.0.noarch.rpm
        mlx-steering-dump-1.0.0-0.2510122.x86_64.rpm
        perftest-25.10.0-0.134.g8aff167.x86_64.rpm
        sockperf-3.1-1.el10.x86_64.rpm
        rshim-2.5.7-0.g0339e66.x86_64.rpm
        libvfio-mlx5-1.1.01-1.x86_64.rpm
        ngauge-1.0.3-1.x86_64.rpm
        ofed-scripts-25.10-OFED.25.10.1.7.x86_64.rpm
        openmpi-4.1.9a1-1.20251022.ad48c462ff.2510122.x86_64.rpm
        ucx-1.20.0-1.20251022.03898fede.2510122.x86_64.rpm
        ucx-cma-1.20.0-1.20251022.03898fede.2510122.x86_64.rpm
        ucx-ib-1.20.0-1.20251022.03898fede.2510122.x86_64.rpm
        ucx-ib-mlx5-1.20.0-1.20251022.03898fede.2510122.x86_64.rpm
        ucx-rdmacm-1.20.0-1.20251022.03898fede.2510122.x86_64.rpm
        ucx-knem-1.20.0-1.20251022.03898fede.2510122.x86_64.rpm
        ucx-xpmem-1.20.0-1.20251022.03898fede.2510122.x86_64.rpm
        ucx-devel-1.20.0-1.20251022.03898fede.2510122.x86_64.rpm
        ucx-static-1.20.0-1.20251022.03898fede.2510122.x86_64.rpm
        clusterkit-1.15.472-1.20251022.023d2d0.2510122.x86_64.rpm
        openvswitch-3.2.1005-1.2510171.x86_64.rpm
        openvswitch-devel-3.2.1005-1.2510171.x86_64.rpm
        openvswitch-ipsec-3.2.1005-1.2510171.x86_64.rpm
        openvswitch-test-3.2.1005-1.2510171.noarch.rpm
        openvswitch-selinux-policy-3.2.1005-1.2510171.noarch.rpm
        network-scripts-openvswitch-3.2.1005-1.2510171.x86_64.rpm
        python3-openvswitch-3.2.1005-1.2510171.noarch.rpm
        python3-doca-openvswitch-3.2.1005-1.el10.noarch.rpm
        doca-openvswitch-3.2.1005-1.el10.x86_64.rpm
        doca-openvswitch-devel-3.2.1005-1.el10.x86_64.rpm
        doca-openvswitch-ipsec-3.2.1005-1.el10.x86_64.rpm
        doca-openvswitch-test-3.2.1005-1.el10.noarch.rpm
        doca-openvswitch-selinux-policy-3.2.1005-1.el10.noarch.rpm
        doca-perftest-2.4.9-1.el10.x86_64.rpm
        sharp-3.13.12-1.2510122.x86_64.rpm
        nvhws-25.10.14-1.el10.x86_64.rpm
        nvhws-devel-25.10.14-1.el10.x86_64.rpm
        nvhws-sim-25.10.14-1.el10.x86_64.rpm
        nvhws-sim-devel-25.10.14-1.el10.x86_64.rpm
        collectx_1.23.5-39472961-rhel10.1-x86_64-clxapi.rpm
        collectx_1.23.5-39472961-rhel10.1-x86_64-clxapidev.rpm
    )

    local ok_count=0 fail_count=0
    for pkg in "${OFED_PKGS[@]}"; do
        local path="$DOCA_PKGDIR/$pkg"
        if [[ ! -f "$path" ]]; then
            warn "Not found (skipping): $pkg"
            ((fail_count++)) || true
            continue
        fi
        log "  Extracting: $pkg"
        if $DRY_RUN; then
            echo "  [DRY] rpm2cpio $path | cpio -idm (in $OFED_PREFIX)"
        else
            rpm2cpio "$path" | (cd "$OFED_PREFIX" && cpio -idm 2>/dev/null) && \
                ((ok_count++)) || { warn "  Extract failed: $pkg"; ((fail_count++)) || true; }
        fi
    done
    ok "Phase 1 complete: extracted=$ok_count, skipped/failed=$fail_count"
}

# =============================================================================
# PHASE 2: DOCA SDK (via rpm --nodeps → /opt/mellanox/doca/)
# =============================================================================
phase2_doca_sdk() {
    log "=== PHASE 2: DOCA SDK → /opt/mellanox/doca/ ==="
    rpm --import "$DOCA_PKGDIR/../RPM-GPG-KEY-doca" 2>/dev/null || true

    local SDK_PKGS=(
        doca-extra-0.1.9.0.0.0-1.el10.noarch.rpm
        doca-sdk-common-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-common-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-argp-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-argp-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-aes-gcm-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-aes-gcm-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-apsh-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-apsh-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-comch-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-comch-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-compress-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-compress-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-devemu-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-devemu-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-dma-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-dma-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-dpa-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-dpa-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-dpdk-bridge-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-dpdk-bridge-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-erasure-coding-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-erasure-coding-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-eth-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-eth-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-flow-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-flow-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-flow-trace-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-gpunetio-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-gpunetio-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-mgmt-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-mgmt-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-pcc-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-pcc-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-rdma-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-rdma-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-sha-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-sha-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-sta-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-sta-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-telemetry-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-telemetry-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-telemetry-exporter-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-telemetry-exporter-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-urom-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-urom-devel-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-verbs-3.2.1025-1.el10.x86_64.rpm
        doca-sdk-verbs-devel-3.2.1025-1.el10.x86_64.rpm
        doca-apsh-config-3.2.1025-1.el10.x86_64.rpm
        doca-bench-3.2.1025-1.el10.x86_64.rpm
        doca-bench-extension-3.2.1025-1.el10.x86_64.rpm
        doca-caps-3.2.1025-1.el10.x86_64.rpm
        doca-comm-channel-admin-3.2.1025-1.el10.x86_64.rpm
        doca-dms-3.2.1025-1.el10.x86_64.rpm
        doca-flow-tune-3.2.1025-1.el10.x86_64.rpm
        doca-pcc-counters-3.2.1025-1.el10.x86_64.rpm
        doca-samples-3.2.1025-1.el10.x86_64.rpm
        doca-socket-relay-3.2.1025-1.el10.x86_64.rpm
        doca-spcx-cc-3.2.1025-1.el10.x86_64.rpm
        doca-telemetry-utils-3.2.1025-1.el10.x86_64.rpm
        doca-sosreport-4.9.0-1.el10.noarch.rpm
        dpacc-2.0.1.84-1.el10.x86_64.rpm
        dpacc-extract-2.0.1.84-1.el10.x86_64.rpm
        dpa-gdbserver-25.10.3060-1.el10.x86_64.rpm
        dpa-resource-mgmt-25.10.0161-5.el10.x86_64.rpm
        dpa-stats-25.10.0161-0.el10.x86_64.rpm
        flexio-sdk-25.10.3060-0.el10.x86_64.rpm
        flexio-samples-25.10.3060-1.el10.noarch.rpm
        mlnx-dpdk-22.11.0-2510.2.1.2510170.x86_64.rpm
        mlnx-dpdk-devel-22.11.0-2510.2.1.2510170.x86_64.rpm
        mlnx-ethtool-2510.0.0-1.el10.x86_64.rpm
        mlnx-iproute2-2510.0.10-2.x86_64.rpm
    )

    local paths=()
    local missing=0
    for pkg in "${SDK_PKGS[@]}"; do
        local path="$DOCA_PKGDIR/$pkg"
        if [[ -f "$path" ]]; then
            paths+=("$path")
        else
            warn "Not found (skipping): $pkg"
            ((missing++)) || true
        fi
    done

    log "  Installing ${#paths[@]} DOCA SDK packages (missing: $missing)"
    if [[ ${#paths[@]} -gt 0 ]] && ! $DRY_RUN; then
        rpm -ivh --nodeps --nosignature "${paths[@]}" 2>&1 | grep -v "^$" || true
    elif $DRY_RUN; then
        echo "  [DRY] rpm -ivh --nodeps --nosignature <${#paths[@]} packages>"
    fi
    ok "Phase 2 complete"
}

# =============================================================================
# PHASE 3: ldconfig + Environment
# =============================================================================
phase3_configure() {
    log "=== PHASE 3: ldconfig + environment ==="

    if ! $DRY_RUN; then
        # OFED libraries in /opt/doca
        cat > /etc/ld.so.conf.d/doca-ofed.conf << 'EOF'
# DOCA OFED userspace libraries (rdma-core, libibverbs, libmlx5, ...)
/opt/doca/usr/lib64
/opt/doca/usr/lib
EOF

        # DOCA SDK libraries
        cat > /etc/ld.so.conf.d/doca-runtime.conf << 'EOF'
# DOCA SDK runtime libraries
/opt/mellanox/doca/lib64
EOF
        ldconfig
        log "  ldconfig updated ($(ldconfig -p | wc -l) entries)"

        # Environment for all users
        cat > /etc/profile.d/doca-env.sh << 'ENVEOF'
# DOCA 3.2.1 environment (SDK + OFED userspace)
export PATH="${PATH}:/opt/mellanox/doca/tools:/opt/doca/usr/bin:/opt/doca/usr/sbin"
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}:/opt/mellanox/doca/lib64/pkgconfig:/opt/doca/usr/lib64/pkgconfig:/opt/doca/usr/share/pkgconfig"
export CPATH="${CPATH:-}:/opt/mellanox/doca/include:/opt/doca/usr/include"
export MANPATH="${MANPATH:-}:/opt/doca/usr/share/man"
ENVEOF
        chmod 644 /etc/profile.d/doca-env.sh
    else
        echo "  [DRY] Would write /etc/ld.so.conf.d/doca-{ofed,runtime}.conf"
        echo "  [DRY] Would write /etc/profile.d/doca-env.sh"
        echo "  [DRY] Would run ldconfig"
    fi
    ok "Phase 3 complete"
}

# =============================================================================
# PHASE 4: DKMS Kernel Modules
# =============================================================================
phase4_dkms() {
    log "=== PHASE 4: DKMS kernel modules for $TARGET_KERNEL ==="

    # ── 4a. Extract DKMS sources ───────────────────────────────────────────────
    log "-- 4a. Extracting DKMS module sources to /usr/src/"
    local DKMS_SRC_PKGS=(
        mlnx-ofa_kernel-source-25.10-OFED.25.10.1.7.1.1.el10.x86_64.rpm
        mlnx-ofa_kernel-dkms-25.10-OFED.25.10.1.7.1.1.el10.x86_64.rpm
        mlnx-ofa_kernel-25.10-OFED.25.10.1.7.1.1.el10.x86_64.rpm
        kernel-mft-dkms-4.34.1-10.x86_64.rpm
        iser-dkms-25.10-OFED.25.10.1.7.1.1.el10.x86_64.rpm
        isert-dkms-25.10-OFED.25.10.1.7.1.1.el10.x86_64.rpm
        srp-dkms-25.10-OFED.25.10.1.7.1.1.el10.x86_64.rpm
        mlnx-nvme-dkms-25.10-OFED.25.10.1.7.1.1.el10.x86_64.rpm
        mlnx-nfsrdma-dkms-25.10-OFED.25.10.1.7.1.1.el10.x86_64.rpm
        knem-dkms-1.1.4.90mlnx4-OFED.25.10.1.2.2.1.el10.x86_64.rpm
        xpmem-dkms-2510.0.16-1.el10.x86_64.rpm
        virtiofs-dkms-25.10-OFED.25.10.1.7.1.1.el10.x86_64.rpm
    )

    for pkg in "${DKMS_SRC_PKGS[@]}"; do
        local path="$DOCA_PKGDIR/$pkg"
        [[ -f "$path" ]] || { warn "Not found: $pkg"; continue; }
        log "  Extracting: $pkg"
        $DRY_RUN || rpm2cpio "$path" | (cd / && cpio -idm 2>/dev/null) || true
    done

    # ── 4b. Apply kernel compatibility patches ─────────────────────────────────
    log "-- 4b. Applying kernel compatibility patches"
    _apply_mlnx_ofa_patches
    _patch_dkms_conf

    # ── 4c. Register, build and install all modules ────────────────────────────
    log "-- 4c. Building DKMS modules for kernel $TARGET_KERNEL"
    _dkms_build_all

    ok "Phase 4 complete"
}

# ─── Patch: mlnx-ofa_kernel backport 0141 (TLS API change in 6.12.68+) ───────
_apply_mlnx_ofa_patches() {
    local src_dir="/usr/src/mlnx-ofa_kernel-25.10"
    [[ -d "$src_dir" ]] || { warn "mlnx-ofa_kernel source not found, skipping patches"; return; }

    local patch_src="$SCRIPT_DIR/patches/0141-backport-tls-api-fix.patch"
    local patch_dst="$src_dir/backports/0141-BACKPORT-drivers-net-ethernet-mellanox-mlx5-core-en_.patch"

    if [[ -f "$patch_src" ]]; then
        log "  Applying TLS API backport fix (0141)"
        $DRY_RUN || /bin/cp "$patch_src" "$patch_dst"
    else
        warn "  Patch file not found: $patch_src"
        warn "  The backport patch in $patch_dst may need manual fixing"
        warn "  See docs/technical-notes.md for details"
    fi

    # Restore ktls_rx.c to pre-backport state (the patch handles everything)
    local ktls="$src_dir/drivers/net/ethernet/mellanox/mlx5/core/en_accel/ktls_rx.c"
    if [[ -f "$ktls" ]] && grep -q "HAVE_TLS_OFFLOAD_RESYNC_ASYNC_STRUCT" "$ktls"; then
        log "  Reverting manual ktls_rx.c edits (patch handles this now)"
        if ! $DRY_RUN; then
            # Remove the manually added #ifdef HAVE_TLS_OFFLOAD_RESYNC_ASYNC_STRUCT blocks
            sed -i \
                '/^#ifdef HAVE_TLS_OFFLOAD_RESYNC_ASYNC_STRUCT/{
                    N; N; N; N; N; N
                    /tls_offload_rx_resync_async_request_end(tls_offload_ctx_rx/d
                }' "$ktls" 2>/dev/null || true
        fi
    fi
}

# ─── Patch: dkms.conf fixes ────────────────────────────────────────────────────
_patch_dkms_conf() {
    local dkms_conf="/usr/src/mlnx-ofa_kernel-25.10/dkms.conf"
    [[ -f "$dkms_conf" ]] || return

    # Install pre_build_wrapper.sh
    local wrapper_src="$SCRIPT_DIR/scripts/pre_build_wrapper.sh"
    local wrapper_dst="/usr/src/mlnx-ofa_kernel-25.10/ofed_scripts/pre_build_wrapper.sh"

    if [[ -f "$wrapper_src" ]] && ! $DRY_RUN; then
        /bin/cp "$wrapper_src" "$wrapper_dst"
        chmod +x "$wrapper_dst"
        log "  Installed pre_build_wrapper.sh"
    fi

    # Patch PRE_BUILD to use wrapper
    if ! grep -q "pre_build_wrapper.sh" "$dkms_conf" && ! $DRY_RUN; then
        sed -i "s|^PRE_BUILD=.*|PRE_BUILD='./ofed_scripts/pre_build_wrapper.sh \$kernel_source_dir --default --build-dummy-mods --with-njobs=\$parallel_jobs'|" \
            "$dkms_conf"
        log "  Patched PRE_BUILD in dkms.conf"
    fi

    # Add mlxfw to the disabled module list (CONFIG_MLXFW=y in kernel 6.12+)
    if ! grep -q "mlxfw)" "$dkms_conf" && ! $DRY_RUN; then
        sed -i "/fwctl) mlnx_ofed_is_conf_set CONFIG_FWCTL;;/a\\
\\tmlxfw) grep -q \"^#define CONFIG_MLXFW 1\" \"\$kernel_source_dir/include/generated/autoconf.h\" 2>/dev/null;;" \
            "$dkms_conf"
        log "  Added mlxfw to disabled module list in dkms.conf"
    fi
}

# ─── DKMS: register, build, install ───────────────────────────────────────────
_dkms_build_all() {
    # Module name → DKMS package name / version mapping
    # Format: "src_dir_name:dkms_name:dkms_version"
    declare -A DKMS_MODS=(
        ["mlnx-ofa_kernel-25.10"]="mlnx-ofa_kernel:25.10"
        ["iser-25.10"]="iser:25.10"
        ["isert-25.10"]="isert:25.10"
        ["srp-25.10"]="srp:25.10"
        ["virtiofs-25.10"]="virtiofs:25.10"
        ["knem-1.1.4.90mlnx4"]="knem:1.1.4.90mlnx4"
        ["xpmem-2510.0.16"]="xpmem:2510.0.16"
    )
    # Modules with non-obvious naming (PACKAGE_NAME differs from dir name)
    declare -A DKMS_RENAMED=(
        ["kernel-mft-4.34.1"]="kernel-mft-dkms-4.34.1:kernel-mft-dkms:4.34.1"
        ["mlnx-nvme-25.10"]="mlnx-nvme-4.0:mlnx-nvme:4.0"
        ["mlnx-nfsrdma-25.10"]="mlnx-nfsrdma-3.4:mlnx-nfsrdma:3.4"
    )

    # Handle renamed modules (copy to DKMS-expected path)
    for orig_dir in "${!DKMS_RENAMED[@]}"; do
        local spec="${DKMS_RENAMED[$orig_dir]}"
        local new_dir="${spec%%:*}"; spec="${spec#*:}"
        local dkms_name="${spec%%:*}"; local dkms_ver="${spec#*:}"

        if [[ -d "/usr/src/$orig_dir" ]] && [[ ! -d "/usr/src/$new_dir" ]]; then
            log "  Copying /usr/src/$orig_dir → /usr/src/$new_dir"
            $DRY_RUN || /bin/cp -r "/usr/src/$orig_dir" "/usr/src/$new_dir"
        fi

        _dkms_register_build_install "$dkms_name" "$dkms_ver"
    done

    # Standard modules
    for src_dir in "${!DKMS_MODS[@]}"; do
        local spec="${DKMS_MODS[$src_dir]}"
        local dkms_name="${spec%%:*}"; local dkms_ver="${spec#*:}"
        _dkms_register_build_install "$dkms_name" "$dkms_ver"
    done
}

_dkms_register_build_install() {
    local name="$1" ver="$2"
    local src_dir="/usr/src/${name}-${ver}"

    # For modules with different src dir naming
    [[ -d "$src_dir" ]] || {
        warn "DKMS source not found: $src_dir — skipping $name/$ver"
        return
    }

    # Register
    if ! dkms status -m "$name" -v "$ver" 2>/dev/null | grep -q "$name"; then
        log "  Registering: $name/$ver"
        $DRY_RUN || dkms add -m "$name" -v "$ver" 2>&1 | grep -v "^$" || true
    fi

    # Build
    log "  Building: $name/$ver for $TARGET_KERNEL"
    if ! $DRY_RUN; then
        if ! dkms build -m "$name" -v "$ver" -k "$TARGET_KERNEL" 2>&1 | \
                grep -v "^$" | grep -v "Cleaning build" | grep -v "make.*clean"; then
            warn "Build failed for $name/$ver — check /var/lib/dkms/$name/$ver/build/make.log"
            return
        fi
    else
        echo "  [DRY] dkms build -m $name -v $ver -k $TARGET_KERNEL"
    fi

    # Install
    log "  Installing: $name/$ver"
    $DRY_RUN || dkms install -m "$name" -v "$ver" -k "$TARGET_KERNEL" 2>&1 | \
        grep -E "Installing|done|Error" || true
}

# =============================================================================
# MAIN
# =============================================================================
print_banner() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║       DOCA 3.2.1 Installer for ALT Linux 11 (Nimbostratus)      ║"
    echo "║       OFED 25.10 / mlnx-ofa_kernel 25.10 / DOCA SDK 3.2.1025   ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Host:    $(uname -n)"
    echo "  Kernel:  $(uname -r)  →  target: $TARGET_KERNEL"
    echo "  Arch:    $(uname -m)"
    echo "  PKGDIR:  $DOCA_PKGDIR"
    echo "  Phase:   $PHASE"
    echo "  DryRun:  $DRY_RUN"
    echo ""
}

main() {
    check_alt_linux
    print_banner

    $DRY_RUN && warn "DRY RUN mode — no changes will be made"
    check_pkgdir

    case "$PHASE" in
        phase0) phase0_prerequisites ;;
        phase1) phase1_ofed_userspace ;;
        phase2) phase2_doca_sdk ;;
        phase3) phase3_configure ;;
        phase4) phase4_dkms ;;
        all)
            phase0_prerequisites
            phase1_ofed_userspace
            phase2_doca_sdk
            phase3_configure
            phase4_dkms
            ;;
    esac

    echo ""
    echo "══════════════════════════════════════════════════════════════════"
    ok "Installation complete!"
    echo ""
    echo "  Next steps:"
    echo "  1. Source environment: source /etc/profile.d/doca-env.sh"
    if [[ "$(uname -r)" != "$TARGET_KERNEL" ]]; then
        echo "  2. REBOOT into kernel $TARGET_KERNEL for modules to activate"
        echo "     (current: $(uname -r))"
    fi
    echo "  3. Verify: dkms status"
    echo "  4. After connecting Mellanox hardware:"
    echo "     ibstat   # InfiniBand port status"
    echo "     ibv_devinfo   # RDMA device info"
    echo "══════════════════════════════════════════════════════════════════"
}

main
