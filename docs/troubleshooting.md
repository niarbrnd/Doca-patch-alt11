# Troubleshooting Guide

## DKMS Build Failures

### Error: `passing argument 1 of 'tls_offload_rx_resync_async_request_end' from incompatible pointer type`

**File**: `ktls_rx.c`
**Cause**: TLS offload API changed in kernel 6.12.68. The MLNX OFED backport
patch 0141 uses the old `struct sock *` API, but kernel ≥ 6.12.68 requires
`struct tls_offload_resync_async *`.

**Fix**: Apply the patched `patches/0141-backport-tls-api-fix.patch`:
```bash
cp patches/0141-backport-tls-api-fix.patch \
  /usr/src/mlnx-ofa_kernel-25.10/backports/0141-BACKPORT-drivers-net-ethernet-mellanox-mlx5-core-en_.patch
```
Also ensure the source `ktls_rx.c` is in pre-backport state (plain `priv_rx->sk` calls).
See `docs/technical-notes.md` §3 for details.

---

### Error: `'mlxfw_firmware_flash' exported twice. Previous export was in vmlinux`

**Cause**: `CONFIG_MLXFW=y` in the kernel (built-in). Cannot build external `mlxfw.ko`.

**Fix**: Add `pre_build_wrapper.sh` to the MLNX OFED build:
```bash
cp scripts/pre_build_wrapper.sh \
  /usr/src/mlnx-ofa_kernel-25.10/ofed_scripts/pre_build_wrapper.sh
chmod +x /usr/src/mlnx-ofa_kernel-25.10/ofed_scripts/pre_build_wrapper.sh
```
Edit `/usr/src/mlnx-ofa_kernel-25.10/dkms.conf`, change `PRE_BUILD=` line to:
```
PRE_BUILD='./ofed_scripts/pre_build_wrapper.sh $kernel_source_dir --default --build-dummy-mods --with-njobs=$parallel_jobs'
```

---

### Error: `configure: error: C preprocessor "/lib/cpp" fails sanity check`

**Affects**: `knem`, `xpmem`
**Cause**: No `/lib/cpp` or `/usr/bin/cpp` on ALT Linux (only `cpp-13` is installed).

**Fix**:
```bash
ln -sf /usr/bin/cpp-13 /usr/bin/cpp
ln -sf /usr/bin/cpp-13 /lib/cpp
```

---

### Error: `fatal error: linux/limits.h: No such file or directory`

**Affects**: `knem`
**Cause**: UAPI kernel headers installed to versioned path, not standard `/usr/include/linux/`.

**Fix**:
```bash
HDIR=$(ls -d /usr/include/linux-*/include 2>/dev/null | sort -V | tail -1)
ln -sf "$HDIR/linux"       /usr/include/linux
ln -sf "$HDIR/asm"         /usr/include/asm
ln -sf "$HDIR/asm-generic" /usr/include/asm-generic
```

---

### Error: `Error! Could not find module source directory`

**Cause**: DKMS expects directory `/usr/src/<name>-<version>/` but the
extracted RPM created a directory with a different name.

**Fix**: Check `PACKAGE_NAME` and `PACKAGE_VERSION` in the module's `dkms.conf`,
then create/copy to the expected directory:
```bash
grep "^PACKAGE" /usr/src/kernel-mft-4.34.1/dkms.conf
# PACKAGE_NAME=kernel-mft-dkms  PACKAGE_VERSION=4.34.1
cp -r /usr/src/kernel-mft-4.34.1 /usr/src/kernel-mft-dkms-4.34.1
dkms add -m kernel-mft-dkms -v 4.34.1
```

---

### Error: `gcc-13: fatal error: cannot execute 'cc1'`

**Cause**: `gcc13` installed but `cpp13` (which provides `cc1`) is missing.

**Fix**:
```bash
wget -O /tmp/cpp13.rpm \
  "https://git.altlinux.org/tasks/340115/build/400/x86_64/rpms/cpp13-13.2.1-alt3.x86_64.rpm"
rpm -ivh --nodeps /tmp/cpp13.rpm
```

---

### Error: `libdoca_common.so: undefined symbol: __cxa_call_terminate@CXXABI_1.3.15`

**Cause**: `libstdc++.so.6` is too old (GCC 13 provides max CXXABI_1.3.14).

**Fix**: Upgrade to GCC 14's libstdc++:
```bash
wget -O /tmp/libstdcxx14.rpm \
  "https://git.altlinux.org/tasks/398037/build/200/x86_64/rpms/libstdc++6-14.3.1-alt2.x86_64.rpm"
rpm -Uvh --nodeps /tmp/libstdcxx14.rpm
ldconfig
```
Verify: `strings /usr/lib64/libstdc++.so.6 | grep CXXABI_1.3.15`

---

---

### Error: `nvme-core: 'nvme_wq' exported twice. Previous export was in vmlinux` (mlnx-nvme)

**Affects**: kernel 6.12.34-6.12-alt1 (and any kernel with `CONFIG_NVME_CORE=y`)

**Cause**: nvme-core is compiled statically into the kernel (`CONFIG_NVME_CORE=y`).
mlnx-nvme tries to build a replacement `nvme-core.ko`, but MODPOST detects
duplicate symbol exports and fails:

```
ERROR: modpost: host/nvme-core: 'nvme_wq' exported twice. Previous export was in vmlinux
ERROR: modpost: host/nvme-core: 'nvme_reset_wq' exported twice. Previous export was in vmlinux
... (many more symbols)
```

**Why it worked on 6.12.68**: On that kernel `CONFIG_NVME_CORE=m` — nvme-core
is a loadable module, so mlnx-nvme can replace it without conflicts.

**Fix**: Skip mlnx-nvme for kernels where `CONFIG_NVME_CORE=y`. The kernel's
built-in `nvme-rdma.ko` handles NVMe over RDMA:

```bash
# Check before building
grep CONFIG_NVME_CORE /lib/modules/$(uname -r)/build/include/generated/autoconf.h
# → #define CONFIG_NVME_CORE 1   means skip mlnx-nvme
# → #define CONFIG_NVME_CORE_MODULE 1   means build is OK

# The install.sh script detects this automatically and skips mlnx-nvme
```

**Impact**: Mellanox-specific NVMe stack optimizations are unavailable.
Standard kernel `nvme-rdma` + `mlx5_ib` provides full NVMe over RDMA
functionality for ConnectX and BlueField devices.

---

## apt is Broken After Installation

**Symptom**: `apt-get install <anything>` fails with dependency resolution errors.

**Cause**: RHEL10 packages installed via `rpm --nodeps` inject entries into ALT's
RPM database with RHEL-style dependency names (`pkgconfig(libibverbs)`, etc.) that
ALT's `apt` cannot resolve. This affects ALL `apt` operations system-wide.

**Workaround**: Bypass `apt` for DOCA-related dependencies:
```bash
# Download packages directly
wget -O /tmp/package.rpm "https://git.altlinux.org/tasks/.../package.rpm"
rpm -ivh --nodeps /tmp/package.rpm
```

**Permanent fix**: To restore `apt`, remove the offending RHEL packages from
the RPM database (carefully — do not remove DOCA SDK packages needed for runtime).

---

## Kernel Module Issues After Reboot

### Modules not loading

```bash
# Check DKMS status
dkms status

# Manually load core module
modprobe mlx5_core

# Check for errors
dmesg | grep -i "mlx5\|ib_core\|rdma"
```

### Wrong kernel version

Ensure you booted into the kernel for which DKMS modules were built:
```bash
uname -r          # Should match the DKMS build kernel
dkms status       # Shows kernel version next to each module
```

### Module signing errors

The build warning `Binary sign-file not found, modules won't be signed` is
expected when kernel module signing is not configured. Unsigned modules load
fine on kernels without `MODULES_LOCKDOWN`.

---

## Verifying Installation

```bash
# 1. Check DOCA SDK loads
ldconfig -p | grep libdoca_common
ldd /opt/mellanox/doca/lib64/libdoca_common.so | grep "not found"

# 2. Check OFED userspace
/opt/doca/usr/bin/ibstat 2>/dev/null || echo "No IB hardware detected (expected before device attachment)"

# 3. Check DKMS modules
dkms status | grep installed

# 4. After attaching Mellanox device:
ibstat
ibv_devinfo
/opt/mellanox/doca/tools/doca_caps
```
