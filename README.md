# DOCA 3.2.1 для ALT Linux 11

Скрипты и патчи для установки **NVIDIA DOCA 3.2.1** (OFED 25.10) на
**ALT Linux 11 Nimbostratus** (ядро 6.12.x).

DOCA распространяется в виде бинарных RPM-пакетов для RHEL 10.1.
Этот репозиторий содержит инструменты для их адаптации к ALT Linux.

---

## Что устанавливается

| Компонент | Версия | Путь установки |
|-----------|--------|----------------|
| DOCA SDK (libdoca_common, libdoca_flow, ...) | 3.2.1025 | `/opt/mellanox/doca/` |
| OFED userspace (libibverbs, librdmacm, UCX, OpenMPI, ...) | 25.10 | `/opt/doca/` |
| mlnx-ofa_kernel (mlx5_core, mlx5_ib, ib_ipoib, ...) | 25.10 | DKMS |
| iser, isert, srp, knem, xpmem, virtiofs | 25.10 | DKMS |
| kernel-mft (MFT firmware tools kernel part) | 4.34.1 | DKMS |
| mlnx-nvme, mlnx-nfsrdma | 25.10 | DKMS |

## Требования

| Требование | Значение |
|---|---|
| Дистрибутив | ALT Linux 11 Nimbostratus (Virtualization / Server) |
| Ядро | 6.12.x (рекомендуется 6.12.68-6.12-alt1) |
| Архитектура | x86_64 |
| Права | root |
| Интернет | Нужен для загрузки gcc13, libstdc++6-14, dkms, kernel-headers |
| Пакеты DOCA | `/usr/share/doca-host-3.2.1/repo/Packages/` (177 RPM-файлов) |

> **Примечание**: системные пакеты ALT (`libibverbs-53.0-alt1` и др.)
> не затрагиваются — установка выполняется параллельно в `/opt/doca/`.

---

## Быстрый старт

```bash
# 1. Клонировать репозиторий
git clone https://github.com/YOUR_USERNAME/doca-alt-linux.git
cd doca-alt-linux

# 2. Запустить установку (все фазы)
sudo ./install.sh

# 3. После завершения — перезагрузиться в новое ядро
sudo reboot

# 4. Проверить результат
dkms status
source /etc/profile.d/doca-env.sh
ibv_devinfo    # после подключения устройства Mellanox
```

### Режим dry-run (проверка без изменений)

```bash
sudo ./install.sh --dry-run
```

### Отдельные фазы

```bash
sudo ./install.sh phase0   # Установка зависимостей (gcc13, dkms, headers)
sudo ./install.sh phase1   # OFED userspace → /opt/doca/
sudo ./install.sh phase2   # DOCA SDK → /opt/mellanox/doca/
sudo ./install.sh phase3   # ldconfig + /etc/profile.d/doca-env.sh
sudo ./install.sh phase4   # DKMS: сборка и установка модулей ядра
```

### Нестандартный путь к пакетам

```bash
sudo ./install.sh --repo /path/to/doca/Packages --kernel 6.12.68-6.12-alt1
```

---

## Структура репозитория

```
doca-alt-linux/
├── install.sh                         # Главный скрипт установки
├── README.md                          # Этот файл
│
├── patches/
│   └── 0141-backport-tls-api-fix.patch  # Исправление API TLS для ядра 6.12.68+
│                                         # (tls_offload_rx_resync_async_request_*
│                                         #  изменился с struct sock* на
│                                         #  struct tls_offload_resync_async*)
│
├── scripts/
│   └── pre_build_wrapper.sh           # Обёртка для DKMS PRE_BUILD:
│                                      #  отключает mlxfw когда CONFIG_MLXFW=y
│
└── docs/
    ├── technical-notes.md             # Технические подробности всех исправлений
    └── troubleshooting.md             # Решение типичных проблем
```

---

## Технические проблемы и решения

### Проблема 1: apt заблокирован RHEL10-пакетами

После установки пакетов DOCA SDK через `rpm --nodeps` в RPM-базу попадают
записи с RHEL-зависимостями (`pkgconfig(libibverbs)`, `/usr/bin/python3.12`),
которые ALT-овский `apt` не понимает и блокирует все операции.

**Решение**: загружать нужные пакеты через `wget` + `rpm -ivh --nodeps`,
минуя `apt`.

### Проблема 2: CXXABI_1.3.15 отсутствует

`libdoca_common.so.3.2.1025` требует `__cxa_call_terminate@CXXABI_1.3.15`
(GCC 14). ALT p11 максимум имеет GCC 13 (CXXABI_1.3.14).

**Решение**: установить `libstdc++6-14.3.1-alt2` из ALT Sisyphus.

### Проблема 3: Изменение API TLS в ядре 6.12.68

Функции `tls_offload_rx_resync_async_request_start/end` в ядре 6.12.68
изменили сигнатуру: первый аргумент `struct sock *sk` заменён на
`struct tls_offload_resync_async *resync_async`.

Backport-патч MLNX OFED 0141 не учитывает это изменение.

**Решение**: патч `patches/0141-backport-tls-api-fix.patch` добавляет
`#ifdef HAVE_TLS_OFFLOAD_RESYNC_ASYNC_STRUCT` внутрь существующих guards.

### Проблема 4: mlxfw встроен в ядро (CONFIG_MLXFW=y)

В ядре 6.12.68 `mlxfw_firmware_flash` экспортируется из `vmlinux`.
Сборка внешнего `mlxfw.ko` даёт ошибку modpost.

**Решение**: `scripts/pre_build_wrapper.sh` определяет `CONFIG_MLXFW=y`
и передаёт `--without-mlxfw-mod` в `./configure`.

Подробнее: [docs/technical-notes.md](docs/technical-notes.md)

---

## Проверка установки

```bash
# Библиотеки DOCA SDK
ldconfig -p | grep -c libdoca          # должно быть > 20

# Переменные окружения
source /etc/profile.d/doca-env.sh
pkg-config --modversion doca-common    # 3.2.1025

# DKMS модули
dkms status

# После подключения Mellanox-устройства (PCIe passthrough)
ibstat
ibv_devinfo
/opt/mellanox/doca/tools/doca_caps
```

---

## Совместимость

| ALT Linux | Ядро | Статус |
|-----------|------|--------|
| 11 Nimbostratus (PVE) | 6.12.68-6.12-alt1 | ✅ Проверено |
| 11 Nimbostratus (Server) | 6.12.x | 🔶 Ожидается рабочим |
| 10.x | 5.x / 6.x | ❌ Не тестировалось |

### Поддерживаемые устройства (через DOCA)

- Mellanox ConnectX-5 / ConnectX-6 / ConnectX-7
- Mellanox BlueField-2 / BlueField-3
- (любые устройства, поддерживаемые MLNX OFED 25.10)

---

## Лицензия

Скрипты установки: MIT License.
Патч `0141-backport-tls-api-fix.patch` является производным от
MLNX OFED (GPL-2.0 OR Linux-OpenIB).
Пакеты DOCA: NVIDIA End User License Agreement.
