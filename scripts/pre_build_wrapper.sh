#!/bin/bash
# =============================================================================
# DKMS PRE_BUILD wrapper for mlnx-ofa_kernel on ALT Linux
# =============================================================================
# Called by DKMS instead of ./configure directly.
#
# Problem solved:
#   The mlnx-ofa_kernel build always includes --with-mlxfw-mod by default.
#   On kernels where CONFIG_MLXFW=y (mlxfw built-in to vmlinux), building an
#   external mlxfw.ko causes a "symbol exported twice" error during modpost.
#
# Solution:
#   Detect CONFIG_MLXFW=y in the target kernel's autoconf.h and pass
#   --without-mlxfw-mod to configure when mlxfw is already built-in.
#
# Usage (from dkms.conf PRE_BUILD):
#   PRE_BUILD='./ofed_scripts/pre_build_wrapper.sh $kernel_source_dir \
#              --default --build-dummy-mods --with-njobs=$parallel_jobs'
# =============================================================================

KERNEL_SOURCE_DIR="$1"
shift  # remaining args passed to configure

EXTRA_FLAGS=""

# Check if CONFIG_MLXFW is built-in (=y) to the target kernel.
# When built-in, autoconf.h contains: #define CONFIG_MLXFW 1
# When module (=m), it contains: #define CONFIG_MLXFW_MODULE 1
# When absent (=n), it contains neither.
AUTOCONF="$KERNEL_SOURCE_DIR/include/generated/autoconf.h"
if grep -q "^#define CONFIG_MLXFW 1" "$AUTOCONF" 2>/dev/null; then
    echo "[pre_build_wrapper] CONFIG_MLXFW=y in kernel — disabling external mlxfw build"
    EXTRA_FLAGS="--without-mlxfw-mod"
fi

exec ./configure --kernel-sources="$KERNEL_SOURCE_DIR" "$@" $EXTRA_FLAGS
