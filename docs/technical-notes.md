# Technical Notes: DOCA 3.2.1 on ALT Linux 11

## Overview

This document explains the technical decisions and compatibility fixes required
to install NVIDIA DOCA 3.2.1 (RHEL 10 RPM packages) on ALT Linux 11 (Nimbostratus),
kernel 6.12.x.

---

## 1. Installation Strategy: Parallel Install

DOCA 3.2.1 RPMs target RHEL 10.1 and assume an RPM-based system with `dnf`.
ALT Linux uses its own `apt-get` over RPM. Direct installation fails due to
unresolved dependencies referencing RHEL-specific package names
(`pkgconfig(libibverbs)`, `/usr/bin/python3.12`, etc.).

### Solution: Two-track approach

```
Track A: OFED userspace (conflicts with ALT system packages)
  → rpm2cpio extraction into /opt/doca/
  → ALT system libibverbs-53.0-alt1 remains untouched
  → coexist via separate LD_LIBRARY_PATH

Track B: DOCA SDK (natively installs to /opt/mellanox/doca/)
  → rpm --nodeps --nosignature (bypass dependency check)
  → no conflicts with ALT system packages
  → SDK uses its own /opt/mellanox/doca/lib64/
```

### Why rpm --nodeps works for DOCA SDK

The DOCA SDK packages are designed to be self-contained and install exclusively
into `/opt/mellanox/doca/`. Their RPM dependencies are declared against RHEL
package names, but the actual `.so` files they need are either:
- Already present in the extracted OFED userspace (`/opt/doca/usr/lib64/`)
- Present in ALT system libraries
- Included in other DOCA SDK packages

### The apt breakage problem

Installing RHEL10 packages via `rpm --nodeps` injects them into ALT's RPM database
with dependency metadata that ALT's `apt` cannot resolve. This causes `apt` to
refuse ALL operations (not just DOCA-related ones).

**Workaround**: Use `wget` + `rpm -ivh --nodeps` directly for any packages needed
during the installation process, completely bypassing `apt`.

---

## 2. CXXABI_1.3.15 Requirement

### Problem

`libdoca_common.so.3.2.1025` requires `__cxa_call_terminate@CXXABI_1.3.15`.
This symbol is only available in GCC 14's `libstdc++.so.6`.

```bash
$ nm -D /opt/mellanox/doca/lib64/libdoca_common.so.3.2.1025 | grep CXXABI
         U __cxa_call_terminate@CXXABI_1.3.15
```

**CXXABI version table**:

| GCC version | CXXABI version | libstdc++6 ALT package |
|-------------|----------------|------------------------|
| GCC 12      | CXXABI_1.3.13  | libstdc++6-12.x.x      |
| GCC 13      | CXXABI_1.3.14  | libstdc++6-13.2.1-alt3 |
| **GCC 14**  | **CXXABI_1.3.15** | **libstdc++6-14.x.x** |

ALT p11 (stable) only goes up to GCC 13. GCC 14 is available in ALT Sisyphus.

### Solution

Download `libstdc++6-14.3.1-alt2.x86_64.rpm` from ALT Sisyphus build task
and upgrade the system libstdc++6:

```bash
rpm -Uvh --nodeps libstdc++6-14.3.1-alt2.x86_64.rpm
```

The new libstdc++ is ABI-compatible: it provides all CXXABI versions from 1.3.0
through 1.3.15, so existing applications using GCC 13 continue to work.

**Source**: ALT Sisyphus task #398037, build 200, x86_64

---

## 3. TLS API Change in Kernel 6.12.68 (Backport Patch Fix)

### Background

MLNX OFED uses a backport system: the driver source in
`/usr/src/mlnx-ofa_kernel-25.10/` contains the "original" MLNX code,
and patches in `backports/` adapt it to various kernel versions at build time.

Patch `0141-BACKPORT-...-ktls_rx.c` handles TLS offload receive resync
for the `mlx5e` driver.

### The API change

In kernel 6.12.68, `tls_offload_rx_resync_async_request_start/end` changed
their first argument:

| Kernel version | Signature |
|---|---|
| < 6.12.68 | `(struct sock *sk, ...)` |
| ≥ 6.12.68 | `(struct tls_offload_resync_async *resync_async, ...)` |

The original backport patch (written for older kernels) wraps these calls in
`#ifdef HAVE_TLS_OFFLOAD_RX_RESYNC_ASYNC_REQUEST_START` but does not handle
the new struct-based API — it still passes `struct sock *sk`.

### The build error

```
ktls_rx.c:466:56: error: passing argument 1 of
  'tls_offload_rx_resync_async_request_end'
  from incompatible pointer type
note: expected 'struct tls_offload_resync_async *' but argument is of type
  'struct sock *'
```

### The fix

The MLNX OFED build system detects whether `struct tls_offload_resync_async`
exists via `autoconf` check `HAVE_TLS_OFFLOAD_RESYNC_ASYNC_STRUCT`:

```c
// compat/config/rdma.m4
MLNX_RDMA_TEST_CASE(HAVE_TLS_OFFLOAD_RESYNC_ASYNC_STRUCT,
    [net/tls.h has struct tls_offload_resync_async is defined], [
    #include <net/tls.h>
],[
    struct tls_offload_resync_async x;
    return 0;
])
```

We modified patch 0141 to add `#ifdef HAVE_TLS_OFFLOAD_RESYNC_ASYNC_STRUCT`
guards inside the existing `HAVE_TLS_OFFLOAD_RX_RESYNC_ASYNC_REQUEST_START`
blocks:

```c
// For mlx5e_ktls_handle_get_psv_completion():
#ifdef HAVE_TLS_OFFLOAD_RX_RESYNC_ASYNC_REQUEST_START
    hw_seq = MLX5_GET(tls_progress_params, ctx, hw_resync_tcp_sn);
#ifdef HAVE_TLS_OFFLOAD_RESYNC_ASYNC_STRUCT
    {
        struct tls_context *tls_ctx = tls_get_ctx(priv_rx->sk);
        tls_offload_rx_resync_async_request_end(
            tls_offload_ctx_rx(tls_ctx)->resync_async,
            cpu_to_be32(hw_seq));
    }
#else
    tls_offload_rx_resync_async_request_end(priv_rx->sk, cpu_to_be32(hw_seq));
#endif
    priv_rx->rq_stats->tls_resync_req_end++;
#else
    tls_offload_rx_force_resync_request(priv_rx->sk);
#endif
```

### Why patch the backport file, not the source file

DKMS builds use the flow:
1. `rm -rf build/` — build directory is wiped on each build
2. `cp -a source/ build/` — fresh copy from `/usr/src/mlnx-ofa_kernel-25.10/`
3. `./configure` → `ofed_patch.sh` → applies all `backports/*.patch` files
4. `make` — compilation

Editing the source file directly is overwritten in step 3 when the backport
patch is re-applied. The correct fix is in the backport patch file itself.

**Important**: The source file (`ktls_rx.c` in `/usr/src/`) must remain in
the **pre-backport** state (plain `priv_rx->sk` calls) for the patch to apply
cleanly. The patch handles the version detection.

---

## 4. mlxfw Symbol Conflict

### Problem

`CONFIG_MLXFW=y` in the ALT Linux 6.12.68 kernel means `mlxfw_firmware_flash`
is exported from `vmlinux` (built-in). When MLNX OFED tries to build and
register an external `mlxfw.ko` that also exports this symbol:

```
ERROR: modpost: .../mlxfw/mlxfw: 'mlxfw_firmware_flash' exported twice.
Previous export was in vmlinux
```

### Detection

```bash
grep "CONFIG_MLXFW" /usr/src/linux-6.12.68-6.12-alt1/include/generated/autoconf.h
# → #define CONFIG_MLXFW 1     (built-in = y)
```

vs. module case: `#define CONFIG_MLXFW_MODULE 1`

### Solution: pre_build_wrapper.sh

```bash
# Replaces the plain ./configure call in dkms.conf PRE_BUILD.
# Detects CONFIG_MLXFW=y and adds --without-mlxfw-mod:
if grep -q "^#define CONFIG_MLXFW 1" "$AUTOCONF"; then
    EXTRA_FLAGS="--without-mlxfw-mod"
fi
exec ./configure --kernel-sources="$KERNEL_SOURCE_DIR" "$@" $EXTRA_FLAGS
```

This suppresses building `mlxfw.ko` when it's already in the kernel.
The `mlx5_core` driver can use the built-in `mlxfw` symbols from `vmlinux`.

Additionally, the `mlxfw` entry in `mlnx_ofed_module_disabled()` in `dkms.conf`
prevents DKMS from trying to install a non-existent `mlxfw.ko`:

```bash
mlxfw) grep -q "^#define CONFIG_MLXFW 1" \
    "$kernel_source_dir/include/generated/autoconf.h" 2>/dev/null;;
```

---

## 5. C Preprocessor (cpp) Symlink

### Problem

`knem` and `xpmem` use GNU Autoconf-based `./configure` scripts that test for
`/lib/cpp` (the C preprocessor). On ALT Linux, only `cpp-13` is installed
(at `/usr/bin/cpp-13`) — no generic `/usr/bin/cpp` or `/lib/cpp` symlink exists.

```
configure: error: C preprocessor "/lib/cpp" fails sanity check
```

### Solution

```bash
ln -sf /usr/bin/cpp-13 /usr/bin/cpp
ln -sf /usr/bin/cpp-13 /lib/cpp
```

---

## 6. UAPI Kernel Headers Location

### Problem

`knem`'s `./configure` tests `#include <limits.h>` which triggers an include
chain: `limits.h` → `bits/posix1_lim.h` → `bits/local_lim.h` → `linux/limits.h`.

On ALT Linux, the `kernel-headers-6.12-6.12.68-alt1` package installs UAPI
headers into a versioned directory:

```
/usr/include/linux-6.12.68-6.12/include/linux/
/usr/include/linux-6.12.68-6.12/include/asm/
/usr/include/linux-6.12.68-6.12/include/asm-generic/
```

But the standard `/usr/include/linux/` path does not exist.

### Solution

```bash
HDIR=/usr/include/linux-6.12.68-6.12/include
ln -sf "$HDIR/linux"       /usr/include/linux
ln -sf "$HDIR/asm"         /usr/include/asm
ln -sf "$HDIR/asm-generic" /usr/include/asm-generic
```

---

## 7. DKMS Module Name Mapping

Some MLNX modules have `PACKAGE_NAME` in `dkms.conf` that differs from the
source directory name. DKMS requires `<name>-<version>` as the directory name:

| Source extracted to         | PACKAGE_NAME in dkms.conf | PACKAGE_VERSION | Required dir         |
|-----------------------------|---------------------------|-----------------|----------------------|
| `/usr/src/kernel-mft-4.34.1/` | `kernel-mft-dkms`       | `4.34.1`        | `kernel-mft-dkms-4.34.1/` |
| `/usr/src/mlnx-nvme-25.10/`   | `mlnx-nvme`             | `4.0`           | `mlnx-nvme-4.0/`    |
| `/usr/src/mlnx-nfsrdma-25.10/`| `mlnx-nfsrdma`          | `3.4`           | `mlnx-nfsrdma-3.4/` |

**Fix**: Copy the source directory to the DKMS-expected path before `dkms add`.

---

## 8. mlnx-nvme and CONFIG_NVME_CORE=y

### Problem

`mlnx-nvme` provides a Mellanox-patched NVMe stack including `nvme-core.ko`,
`nvme-rdma.ko`, `nvme-fc.ko` and others. Its `host/Makefile` builds nvme-core
conditionally:

```makefile
obj-$(CONFIG_NVME_CORE) += nvme-core.o
```

When the target kernel has `CONFIG_NVME_CORE=y` (built-in), this becomes
`obj-y`, and the build produces object files that reference symbols already
exported from `vmlinux`. MODPOST fails during the build:

```
ERROR: modpost: host/nvme-core: 'nvme_wq' exported twice. Previous export was in vmlinux
ERROR: modpost: host/nvme-core: 'nvme_reset_wq' exported twice.
(20+ duplicate symbols)
```

### Kernel comparison

| Kernel | CONFIG_NVME_CORE | Result |
|--------|-----------------|--------|
| 6.12.34-6.12-alt1 | `=y` (built into vmlinux) | modpost error, skip mlnx-nvme |
| 6.12.41-6.12-alt1 | `=y` (built into vmlinux) | modpost error, skip mlnx-nvme |
| 6.12.42-6.12-alt1 | `=y` (built into vmlinux) | modpost error, skip mlnx-nvme |
| **6.12.45-6.12-alt1** | **`=m` (loadable module)** | **mlnx-nvme builds and installs** |
| 6.12.51..6.12.59-6.12-alt1 | `=m` | mlnx-nvme builds and installs |
| 6.12.68-6.12-alt1 | `=m` (loadable module) | mlnx-nvme builds and installs |

**The transition from `=y` to `=m` occurred between 6.12.42 and 6.12.45.**

### Detection

```bash
grep CONFIG_NVME_CORE /lib/modules/$(uname -r)/build/include/generated/autoconf.h
```

- `#define CONFIG_NVME_CORE 1` → built-in (`=y`), skip mlnx-nvme
- `#define CONFIG_NVME_CORE_MODULE 1` → module (`=m`), mlnx-nvme can be built
- line absent → CONFIG_NVME_CORE not set, mlnx-nvme may still build (treat as module case)

Verified ALT Linux p11 kernel config history (checked via `kernel-headers-modules` RPMs from build task archives):

| Kernel version | CONFIG_NVME_CORE | mlnx-nvme |
|----------------|-----------------|-----------|
| 6.12.34-alt1 | `=y` | ❌ skip |
| 6.12.41-alt1 | `=y` | ❌ skip |
| 6.12.42-alt1 | `=y` | ❌ skip |
| **6.12.45-alt1** | **`=m`** | **✅ build** |
| 6.12.51-alt1 | `=m` | ✅ build |
| 6.12.55-alt1 | `=m` | ✅ build |
| 6.12.57-alt1 | `=m` | ✅ build |
| 6.12.59-alt1 | `=m` | ✅ build |
| 6.12.68-alt1 | `=m` | ✅ build |

### Impact and mitigation

The kernel's own `nvme-rdma.ko` (which uses the built-in nvme-core) provides
full NVMe over Fabrics over RDMA. With `mlx5_ib` loaded, ConnectX and BlueField
devices work normally for NVMe-oF workloads. Only Mellanox-specific performance
optimizations in the patched nvme stack are unavailable.

### install.sh behavior

`install.sh` automatically detects `CONFIG_NVME_CORE=y` in the target kernel
and skips the mlnx-nvme build with an explanatory warning. No manual
intervention is needed.

---

## 9. Library Search Path

After installation, the library search order is:

```
/etc/ld.so.conf.d/doca-ofed.conf:
    /opt/doca/usr/lib64    ← MLNX OFED userspace (libibverbs, libmlx5, ...)

/etc/ld.so.conf.d/doca-runtime.conf:
    /opt/mellanox/doca/lib64  ← DOCA SDK (libdoca_common, libdoca_flow, ...)
```

The system ALT packages (`/usr/lib64/libibverbs.so.1` from `libibverbs-53.0-alt1`)
remain available for system applications. DOCA applications using
`/opt/doca/usr/lib64/` get the MLNX OFED 25.10 version.
