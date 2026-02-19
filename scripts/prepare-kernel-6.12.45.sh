#!/bin/bash
# =============================================================================
# prepare-kernel-6.12.45.sh — подготовка системы для перехода на ядро 6.12.45
# =============================================================================
#
# Что делает скрипт:
#   1. Скачивает пакеты ядра 6.12.45 из архива сборки ALT Linux
#      (задача 394137, https://git.altlinux.org/tasks/394137/build/100/x86_64/rpms/)
#   2. Устанавливает ядро (rpm --oldpackage) и DRM-модули
#   3. Распаковывает kernel-headers и kernel-headers-modules (через rpm2cpio)
#   4. Создаёт symlink /lib/modules/6.12.45-6.12-alt1/build
#   5. Обновляет UAPI symlinks (/usr/include/linux → 6.12.45)
#   6. Собирает все DKMS-модули MLNX OFED для ядра 6.12.45
#      (включая mlnx-nvme — CONFIG_NVME_CORE=m в этом ядре)
#
# Примечания:
#   - kernel-modules-xtables-addons и kernel-modules-zfs для 6.12.45
#     в репозитории ALT p11 отсутствуют (есть только для 6.12.34 и 6.12.68)
#   - CONFIG_MLXFW=y → pre_build_wrapper.sh подавляет сборку внешнего mlxfw.ko
#   - CONFIG_TLS не установлен → патч TLS backport 0141 не требуется
#   - Скрипт идемпотентен: повторный запуск пропускает выполненные шаги
#
# Использование:
#   sudo ./scripts/prepare-kernel-6.12.45.sh [--dry-run] [--no-download]
#   sudo ./scripts/prepare-kernel-6.12.45.sh --skip-dkms   (только ядро/headers)
#   sudo ./scripts/prepare-kernel-6.12.45.sh --dkms-only   (только DKMS)
#
# =============================================================================

set -euo pipefail

# ─── Константы ────────────────────────────────────────────────────────────────
KVER="6.12.45-6.12-alt1"          # полная версия для DKMS
KVER_SHORT="6.12.45"               # только номер версии
KFLAVOUR="6.12"                    # серия ядра ALT

# Задача сборки ALT Linux для ядра 6.12.45
TASK_ID="394137"
SUBTASK="100"
TASK_BASE="https://git.altlinux.org/tasks/${TASK_ID}/build/${SUBTASK}/x86_64/rpms"

# Пакеты для скачивания
declare -A PKGS=(
    ["kernel-image"]="kernel-image-${KFLAVOUR}-${KVER_SHORT}-alt1.x86_64.rpm"
    ["kernel-headers"]="kernel-headers-${KFLAVOUR}-${KVER_SHORT}-alt1.x86_64.rpm"
    ["kernel-headers-modules"]="kernel-headers-modules-${KFLAVOUR}-${KVER_SHORT}-alt1.x86_64.rpm"
    ["kernel-modules-drm"]="kernel-modules-drm-${KFLAVOUR}-${KVER_SHORT}-alt1.x86_64.rpm"
)

DOWNLOAD_DIR="/var/cache/doca/kernel-${KVER_SHORT}"

# ─── Цвета и логирование ──────────────────────────────────────────────────────
RED='\033[0;31m'; YLW='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLU}[K645]${NC} $*"; }
ok()   { echo -e "${GRN}[ OK ]${NC} $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }
run()  { $DRY_RUN && echo "  [DRY] $*" || "$@"; }

step() {
    echo ""
    echo -e "${BLU}────────────────────────────────────────────────────${NC}"
    echo -e "${BLU} $*${NC}"
    echo -e "${BLU}────────────────────────────────────────────────────${NC}"
}

# ─── Аргументы ────────────────────────────────────────────────────────────────
DRY_RUN=false
NO_DOWNLOAD=false
SKIP_DKMS=false
DKMS_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=true ;;
        --no-download) NO_DOWNLOAD=true ;;
        --skip-dkms)   SKIP_DKMS=true ;;
        --dkms-only)   DKMS_ONLY=true ;;
        -h|--help)
            sed -n '2,35p' "$0"
            exit 0
            ;;
        *) die "Неизвестный аргумент: $arg. Используйте --help." ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Запускайте от root"

# ─── Баннер ───────────────────────────────────────────────────────────────────
print_banner() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║     Подготовка к переходу на ядро 6.12.45-6.12-alt1             ║"
    echo "║     DOCA 3.2.1 / MLNX OFED 25.10 / ALT Linux 11               ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Текущее ядро:  $(uname -r)"
    echo "  Цель:          $KVER"
    echo "  Архив пакетов: $TASK_BASE"
    echo "  Кэш RPM:       $DOWNLOAD_DIR"
    echo "  Режим:         $(${DRY_RUN} && echo DRY-RUN || echo РЕАЛЬНЫЙ)"
    echo ""
}

# =============================================================================
# ШАГ 1: Скачивание пакетов
# =============================================================================
step_download() {
    step "ШАГ 1: Скачивание пакетов ядра 6.12.45"
    mkdir -p "$DOWNLOAD_DIR"

    local all_ok=true
    for key in kernel-image kernel-headers kernel-headers-modules kernel-modules-drm; do
        local fname="${PKGS[$key]}"
        local dest="$DOWNLOAD_DIR/$fname"
        local url="$TASK_BASE/$fname"

        if [[ -f "$dest" ]]; then
            ok "Уже скачан: $fname ($(du -sh "$dest" | cut -f1))"
            continue
        fi

        if $NO_DOWNLOAD; then
            warn "Пропуск скачивания (--no-download): $fname"
            all_ok=false
            continue
        fi

        log "Скачиваю: $fname"
        if $DRY_RUN; then
            echo "  [DRY] wget -O $dest $url"
        else
            if wget -q --show-progress -O "$dest" "$url" 2>&1; then
                ok "Скачан: $fname ($(du -sh "$dest" | cut -f1))"
            else
                rm -f "$dest"
                err "Ошибка скачивания: $url"
                all_ok=false
            fi
        fi
    done

    $all_ok || warn "Некоторые пакеты не скачаны — продолжаю с тем что есть"
}

# =============================================================================
# ШАГ 2: Установка ядра и DRM-модулей
# =============================================================================
step_install_kernel() {
    step "ШАГ 2: Установка ядра и DRM-модулей"

    # ── 2a. Ядро ──────────────────────────────────────────────────────────────
    local img_rpm="$DOWNLOAD_DIR/${PKGS[kernel-image]}"
    if rpm -q "kernel-image-${KFLAVOUR}-${KVER_SHORT}-alt1" &>/dev/null; then
        ok "Ядро уже установлено: kernel-image-${KFLAVOUR}-${KVER_SHORT}-alt1"
    elif [[ -f "$img_rpm" ]]; then
        log "Устанавливаю ядро: ${PKGS[kernel-image]}"
        # --oldpackage нужен т.к. в системе может быть более новое ядро (6.12.68)
        run rpm -ivh --nodeps --nosignature --oldpackage "$img_rpm" 2>&1 | \
            grep -v "^$" || true
        ok "Ядро установлено"
    else
        warn "Файл не найден: $img_rpm — пропускаю установку ядра"
    fi

    # ── 2b. DRM-модули ────────────────────────────────────────────────────────
    local drm_rpm="$DOWNLOAD_DIR/${PKGS[kernel-modules-drm]}"
    if rpm -q "kernel-modules-drm-${KFLAVOUR}-${KVER_SHORT}-alt1" &>/dev/null; then
        ok "DRM-модули уже установлены"
    elif [[ -f "$drm_rpm" ]]; then
        log "Устанавливаю DRM-модули: ${PKGS[kernel-modules-drm]}"
        run rpm -ivh --nodeps --nosignature --oldpackage "$drm_rpm" 2>&1 | \
            grep -v "^$" || true
        ok "DRM-модули установлены"
    else
        warn "Файл не найден: $drm_rpm — пропускаю DRM-модули"
    fi
}

# =============================================================================
# ШАГ 3: Установка kernel-headers (через rpm2cpio)
# =============================================================================
step_install_headers() {
    step "ШАГ 3: Распаковка kernel-headers"

    # Ожидаемая директория после распаковки
    local src_dir="/usr/src/linux-${KVER_SHORT}-${KFLAVOUR}"
    local src_dir_full="/usr/src/linux-${KVER_SHORT}-${KFLAVOUR}-alt1"

    if [[ -f "${src_dir}/Makefile" ]] || [[ -f "${src_dir_full}/Makefile" ]]; then
        ok "kernel-headers уже распакованы: ${src_dir}"
    else
        for key in kernel-headers kernel-headers-modules; do
            local rpm_file="$DOWNLOAD_DIR/${PKGS[$key]}"
            if [[ -f "$rpm_file" ]]; then
                log "Распаковываю: ${PKGS[$key]}"
                if $DRY_RUN; then
                    echo "  [DRY] rpm2cpio $rpm_file | cpio -idm --quiet (в /)"
                else
                    (cd / && rpm2cpio "$rpm_file" | cpio -idm --quiet 2>/dev/null)
                    ok "Распакован: ${PKGS[$key]}"
                fi
            else
                warn "Файл не найден: $rpm_file — пропускаю"
            fi
        done
    fi

    # ── 3a. Symlink /lib/modules/<kver>/build ─────────────────────────────────
    local build_link="/lib/modules/${KVER}/build"
    local actual_src=""

    # Определяем реальную директорию headers
    for d in "/usr/src/linux-${KVER_SHORT}-${KFLAVOUR}-alt1" \
              "/usr/src/linux-${KVER_SHORT}-${KFLAVOUR}"; do
        [[ -d "$d" ]] && { actual_src="$d"; break; }
    done

    if [[ -z "$actual_src" ]]; then
        warn "Директория /usr/src/linux-${KVER_SHORT}* не найдена — headers не установлены?"
    elif [[ -L "$build_link" ]] || [[ -d "$build_link" ]]; then
        local cur_target
        cur_target=$(readlink -f "$build_link" 2>/dev/null || echo "?")
        ok "Build symlink уже существует: $build_link → $cur_target"
    else
        log "Создаю build symlink: $build_link → $actual_src"
        run mkdir -p "/lib/modules/${KVER}"
        run ln -sf "$actual_src" "$build_link"
        ok "Создан: $build_link → $actual_src"
    fi

    # ── 3b. Проверка autoconf.h ────────────────────────────────────────────────
    local autoconf="$build_link/include/generated/autoconf.h"
    if $DRY_RUN; then
        echo "  [DRY] проверка autoconf.h"
    elif [[ -f "$autoconf" ]]; then
        local nvme_cfg
        nvme_cfg=$(grep "CONFIG_NVME_CORE" "$autoconf" 2>/dev/null | head -1 || echo "не найден")
        local mlxfw_cfg
        mlxfw_cfg=$(grep "CONFIG_MLXFW" "$autoconf" 2>/dev/null | head -1 || echo "не найден")
        ok "autoconf.h найден ($(grep -c CONFIG_ "$autoconf") параметров)"
        log "  CONFIG_NVME_CORE:  $nvme_cfg"
        log "  CONFIG_MLXFW:      $mlxfw_cfg"
    else
        warn "autoconf.h не найден в $autoconf — DKMS сборка может не работать"
    fi
}

# =============================================================================
# ШАГ 4: Обновление UAPI symlinks (/usr/include/linux → 6.12.45)
# =============================================================================
step_uapi_symlinks() {
    step "ШАГ 4: Обновление UAPI symlinks (/usr/include/linux)"

    local uapi_dir="/usr/include/linux-${KVER_SHORT}-${KFLAVOUR}/include"

    if [[ ! -d "$uapi_dir" ]]; then
        warn "UAPI директория не найдена: $uapi_dir (headers не установлены?)"
        return
    fi

    for subdir in linux asm asm-generic; do
        local link="/usr/include/$subdir"
        local target="$uapi_dir/$subdir"
        if [[ ! -d "$target" ]]; then
            warn "Нет $target — пропускаю symlink $link"
            continue
        fi
        local cur_target
        cur_target=$(readlink "$link" 2>/dev/null || echo "")
        if [[ "$cur_target" == "$target" ]]; then
            ok "/usr/include/$subdir → уже указывает на 6.12.45"
        else
            log "Обновляю: /usr/include/$subdir → $target"
            run ln -sfn "$target" "$link"
            ok "/usr/include/$subdir → $target"
        fi
    done
}

# =============================================================================
# ШАГ 5: Сборка DKMS-модулей для 6.12.45
# =============================================================================

# Строит и устанавливает один DKMS-модуль
_dkms_build_install() {
    local name="$1" ver="$2"
    local log_file="/tmp/dkms-${name}-${KVER_SHORT}.log"

    # Проверяем не установлен ли уже
    if dkms status -m "$name" -v "$ver" -k "$KVER" 2>/dev/null | grep -q "installed"; then
        ok "  $name/$ver — уже установлен для $KVER"
        return 0
    fi

    # Проверяем что источник есть
    if ! dkms status -m "$name" -v "$ver" 2>/dev/null | grep -q "$name"; then
        if [[ -d "/usr/src/${name}-${ver}" ]]; then
            log "  Регистрирую: $name/$ver"
            $DRY_RUN || dkms add -m "$name" -v "$ver" &>/dev/null || true
        else
            warn "  $name/$ver — источник /usr/src/${name}-${ver} не найден, пропускаю"
            return 1
        fi
    fi

    # Build
    log "  Сборка: $name/$ver для $KVER ..."
    if $DRY_RUN; then
        echo "    [DRY] dkms build -m $name -v $ver -k $KVER"
        echo "    [DRY] dkms install -m $name -v $ver -k $KVER"
        return 0
    fi

    if dkms build -m "$name" -v "$ver" -k "$KVER" > "$log_file" 2>&1; then
        ok "  $name/$ver — сборка OK"
    else
        err "  $name/$ver — ОШИБКА сборки!"
        err "  Лог: $log_file"
        # Выводим последние строки с ошибками
        grep -i "error:" "$log_file" 2>/dev/null | tail -5 | while read -r line; do
            err "    $line"
        done
        return 1
    fi

    # Install
    if dkms install -m "$name" -v "$ver" -k "$KVER" >> "$log_file" 2>&1; then
        ok "  $name/$ver — установлен"
    else
        err "  $name/$ver — ОШИБКА установки! Лог: $log_file"
        return 1
    fi
}

step_dkms() {
    step "ШАГ 5: Сборка DKMS-модулей для $KVER"

    # Проверяем что headers доступны
    local autoconf="/lib/modules/${KVER}/build/include/generated/autoconf.h"
    if ! $DRY_RUN && [[ ! -f "$autoconf" ]]; then
        die "Kernel headers не найдены ($autoconf). Сначала выполните ШАГи 3-4."
    fi

    # Проверяем CONFIG_NVME_CORE для 6.12.45 (ожидаем =m)
    local build_nvme=true
    if ! $DRY_RUN; then
        if grep -q "^#define CONFIG_NVME_CORE 1" "$autoconf" 2>/dev/null; then
            warn "CONFIG_NVME_CORE=y — mlnx-nvme пропускается"
            build_nvme=false
        else
            log "CONFIG_NVME_CORE=m — mlnx-nvme будет собран"
        fi
    fi

    local ok_count=0 fail_count=0

    # Основные модули MLNX OFED
    local -a MODULES=(
        "mlnx-ofa_kernel:25.10"
        "iser:25.10"
        "isert:25.10"
        "srp:25.10"
        "virtiofs:25.10"
        "knem:1.1.4.90mlnx4"
        "xpmem:2510.0.16"
    )

    # Переименованные модули (PACKAGE_NAME != имя директории в /usr/src)
    # Для них /usr/src/<name>-<ver>/ уже должна существовать
    local -a RENAMED_MODULES=(
        "kernel-mft-dkms:4.34.1"
        "mlnx-nfsrdma:3.4"
    )

    # mlnx-nvme: собираем только если CONFIG_NVME_CORE=m
    if $build_nvme; then
        RENAMED_MODULES+=("mlnx-nvme:4.0")
    fi

    # Строим все модули
    for entry in "${MODULES[@]}" "${RENAMED_MODULES[@]}"; do
        local name="${entry%%:*}"
        local ver="${entry#*:}"
        if _dkms_build_install "$name" "$ver"; then
            (( ok_count++ )) || true
        else
            (( fail_count++ )) || true
        fi
    done

    echo ""
    if [[ $fail_count -eq 0 ]]; then
        ok "DKMS: все модули собраны и установлены ($ok_count / $((ok_count + fail_count)))"
    else
        warn "DKMS: $ok_count OK, $fail_count с ошибками"
    fi
}

# =============================================================================
# ИТОГ
# =============================================================================
print_summary() {
    echo ""
    echo "══════════════════════════════════════════════════════════════════"
    ok "Подготовка к ядру 6.12.45 завершена"
    echo ""
    echo "  Статус DKMS:"
    dkms status 2>/dev/null | grep "$KVER" | sed 's/^/    /' || echo "    (dkms status недоступен)"
    echo ""
    echo "  Следующие шаги:"
    echo "    1. Перезагрузитесь в ядро 6.12.45:"
    echo "       reboot"
    echo "       (выберите '6.12.45' в меню GRUB)"
    echo ""
    echo "    2. После загрузки проверьте:"
    echo "       uname -r                    # должно быть 6.12.45-6.12-alt1"
    echo "       dkms status                 # все модули installed"
    echo "       modprobe mlx5_core          # загрузка драйвера"
    echo "       dmesg | grep mlx5           # проверка в логе ядра"
    echo ""
    echo "  Примечания:"
    echo "    - kernel-modules-xtables-addons и kernel-modules-zfs"
    echo "      для ядра 6.12.45 в репозитории ALT p11 отсутствуют."
    echo "      Доступны версии для 6.12.34 и 6.12.68."
    echo "      Совместимость с 6.12.45 не гарантирована."
    echo "══════════════════════════════════════════════════════════════════"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    print_banner
    $DRY_RUN && warn "DRY RUN — изменения в систему не вносятся"

    if $DKMS_ONLY; then
        step_dkms
    else
        step_download
        step_install_kernel
        step_install_headers
        step_uapi_symlinks
        $SKIP_DKMS || step_dkms
    fi

    print_summary
}

main
