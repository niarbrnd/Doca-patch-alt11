#!/usr/bin/env python3
"""
install_kernel_headers.py — скачивает и устанавливает заголовки ядра
точно совпадающие с текущей версией ядра ALT Linux.

Решает проблему когда в репозитории доступна только последняя версия
kernel-headers-modules, а на машине стоит более старое ядро.

Алгоритм:
  1. Читает uname -r -> например 6.12.34-6.12-alt1
  2. Разбирает: flavour=6.12, ver=6.12.34, rel=alt1
  3. Ищет задачу сборки на packages.altlinux.org
  4. Скачивает kernel-headers и kernel-headers-modules из архива задачи
  5. Устанавливает через rpm2cpio (без регистрации в RPM-базе, без конфликтов)
  6. Создаёт симлинк /lib/modules/<uname-r>/build -> /usr/src/linux-<ver>-<flavour>-<rel>

Использование:
  sudo python3 install_kernel_headers.py [--kernel 6.12.34-6.12-alt1] [--dry-run]
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path
from html.parser import HTMLParser


# ─── ALT Linux packages API ────────────────────────────────────────────────

TASKS_INDEX_URL = (
    "https://packages.altlinux.org/ru/p11/srpms/kernel-image-{flavour}"
    "/tasks/pkg_index/?task_repo=p11"
)
TASK_BUILD_URL = "https://git.altlinux.org/tasks/{task_id}/build/{subtask}/x86_64/rpms/"


class LinkParser(HTMLParser):
    """Собирает все href со страницы."""
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            for name, val in attrs:
                if name == "href" and val:
                    self.links.append(val)


def fetch(url: str, desc: str = "") -> str:
    """Скачивает URL, возвращает текст."""
    if desc:
        print(f"  Запрос: {desc}")
    req = urllib.request.Request(url, headers={"User-Agent": "install_kernel_headers/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", errors="replace")


def find_task_for_version(flavour: str, full_ver: str) -> tuple[str, str]:
    """
    Возвращает (task_id, subtask_id) для конкретной версии ядра.
    full_ver: например '6.12.34-alt1'

    Страница packages.altlinux.org содержит строки вида:
      tasks/archive/done/_NNN/387626/gears/100/git>gear: kernel-image.git=kernel-image-6.12-6.12.34-alt1
    task_id=387626, subtask=100 (соответствует build/100/x86_64/rpms/)
    """
    url = TASKS_INDEX_URL.format(flavour=flavour)
    html = fetch(url, f"задачи сборки kernel-image-{flavour}")

    # Ищем паттерн: tasks/.../TASKID/gears/SUBTASK/...kernel-image-FLAVOUR-FULLVER
    ver_escaped = re.escape(f"kernel-image-{flavour}-{full_ver}")
    pattern = re.compile(
        r"tasks/(?:archive/done/_\d+/)?(\d+)/gears/(\d+)/[^>]*>[^<]*"
        + ver_escaped,
        re.IGNORECASE,
    )
    m = pattern.search(html)
    if m:
        task_id, subtask = m.group(1), m.group(2)
        print(f"  Найдена задача #{task_id} (subtask {subtask}) для версии {full_ver}")
        return task_id, subtask

    # Запасной вариант: ищем task_id рядом с full_ver в любом порядке
    ver_short = re.escape(full_ver)
    for pat in [
        r"tasks/(?:archive/done/_\d+/)?(\d+)/gears/(\d+)/" + r".*?" + ver_short,
        ver_short + r".*?tasks/(?:archive/done/_\d+/)?(\d+)/gears/(\d+)/",
    ]:
        m = re.search(pat, html, re.DOTALL)
        if m:
            task_id, subtask = m.group(1), m.group(2)
            print(f"  Найдена задача #{task_id} (subtask {subtask}) для версии {full_ver}")
            return task_id, subtask

    raise RuntimeError(
        f"Задача сборки для версии {full_ver} не найдена.\n"
        f"Проверьте вручную: {url}"
    )


def find_subtask(task_id: str, flavour: str) -> str:
    """Находит номер подзадачи с нужными RPM-файлами."""
    task_url = f"https://git.altlinux.org/tasks/{task_id}/"
    try:
        html = fetch(task_url, f"структура задачи #{task_id}")
    except Exception:
        return "100"  # fallback

    parser = LinkParser()
    parser.feed(html)

    # Ищем ссылки вида build/NNN/x86_64/
    candidates = []
    for link in parser.links:
        m = re.search(r"build/(\d+)/x86_64", link)
        if m:
            candidates.append(m.group(1))

    if candidates:
        return candidates[0]
    return "100"


def list_rpms_in_task(task_id: str, subtask: str) -> list[str]:
    """Возвращает список имён RPM-файлов в директории задачи."""
    url = TASK_BUILD_URL.format(task_id=task_id, subtask=subtask)
    html = fetch(url, "список RPM в задаче")

    parser = LinkParser()
    parser.feed(html)

    rpms = [
        link.split("/")[-1]
        for link in parser.links
        if link.endswith(".rpm") and not "debuginfo" in link
    ]
    return rpms, url


def download_file(url: str, dest: Path, label: str) -> None:
    """Скачивает файл с прогрессом."""
    print(f"  Скачиваю {label} ...", end="", flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": "install_kernel_headers/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        total = int(r.headers.get("Content-Length", 0))
        downloaded = 0
        chunk = 65536
        with open(dest, "wb") as f:
            while True:
                data = r.read(chunk)
                if not data:
                    break
                f.write(data)
                downloaded += len(data)
                if total:
                    pct = downloaded * 100 // total
                    print(f"\r  Скачиваю {label} ... {pct}%  ({downloaded//(1024*1024)} МБ)", end="", flush=True)
    print(f"\r  Скачан {label}: {downloaded//(1024*1024)} МБ        ")


def extract_rpm(rpm_path: Path, dest_root: Path, dry_run: bool) -> None:
    """Извлекает RPM через rpm2cpio без регистрации в RPM-базе."""
    print(f"  Распаковываю {rpm_path.name} -> {dest_root}")
    if dry_run:
        return
    dest_root.mkdir(parents=True, exist_ok=True)
    cmd = f"rpm2cpio '{rpm_path}' | cpio -idm --quiet"
    result = subprocess.run(cmd, shell=True, cwd=dest_root)
    if result.returncode != 0:
        raise RuntimeError(f"Ошибка распаковки {rpm_path.name}")


def find_src_dir(ver: str, flavour: str, rel: str) -> Path | None:
    """Ищет директорию с заголовками в /usr/src/."""
    candidates = [
        Path(f"/usr/src/linux-{ver}-{flavour}-{rel}"),
        Path(f"/usr/src/linux-{ver}-{flavour}"),
        Path(f"/usr/src/linux-{ver}"),
    ]
    for c in candidates:
        if c.exists():
            return c
    # Поиск по маске
    for p in Path("/usr/src").glob(f"linux-{ver}*"):
        if p.is_dir():
            return p
    return None


def ensure_build_symlink(kernel_release: str, src_dir: Path, dry_run: bool) -> None:
    """Создаёт /lib/modules/<release>/build -> src_dir."""
    build_link = Path(f"/lib/modules/{kernel_release}/build")
    if build_link.exists() or build_link.is_symlink():
        target = build_link.resolve() if build_link.exists() else Path(os.readlink(build_link))
        print(f"  Симлинк уже существует: {build_link} -> {target}")
        return
    print(f"  Создаю симлинк: {build_link} -> {src_dir}")
    if not dry_run:
        build_link.parent.mkdir(parents=True, exist_ok=True)
        build_link.symlink_to(src_dir)


# ─── Разбор версии ядра ────────────────────────────────────────────────────

def parse_kernel_release(release: str) -> tuple[str, str, str, str]:
    """
    Разбирает строку uname -r.
    Примеры:
      6.12.34-6.12-alt1  -> ver=6.12.34  flavour=6.12  rel=alt1  full_ver=6.12.34-alt1
      6.12.68-6.12-alt1  -> ver=6.12.68  flavour=6.12  rel=alt1
    """
    m = re.fullmatch(r"(\d+\.\d+\.\d+)-(\d+\.\d+)-(alt\d+)", release)
    if not m:
        raise ValueError(
            f"Неожиданный формат версии ядра: {release!r}\n"
            f"Ожидается: 6.12.34-6.12-alt1"
        )
    ver, flavour, rel = m.group(1), m.group(2), m.group(3)
    full_ver = f"{ver}-{rel}"  # например 6.12.34-alt1
    return ver, flavour, rel, full_ver


# ─── Главная функция ───────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Устанавливает kernel-headers точной версии ядра ALT Linux"
    )
    ap.add_argument(
        "--kernel", default=None,
        help="Версия ядра (uname -r). По умолчанию — текущее ядро."
    )
    ap.add_argument(
        "--dry-run", action="store_true",
        help="Показать что будет сделано, не изменяя систему."
    )
    ap.add_argument(
        "--extract-to", default="/",
        help="Куда распаковывать RPM (по умолчанию /). Для тестов: /tmp/test-root."
    )
    args = ap.parse_args()

    if os.geteuid() != 0 and not args.dry_run and args.extract_to == "/":
        print("ОШИБКА: запустите от root (или используйте --dry-run / --extract-to /tmp/...)")
        sys.exit(1)

    # 1. Определяем версию ядра
    if args.kernel:
        kernel_release = args.kernel
    else:
        kernel_release = subprocess.check_output(["uname", "-r"]).decode().strip()

    print(f"\n=== Установка заголовков ядра ===")
    print(f"Ядро: {kernel_release}")

    try:
        ver, flavour, rel, full_ver = parse_kernel_release(kernel_release)
    except ValueError as e:
        print(f"ОШИБКА: {e}")
        sys.exit(1)

    print(f"  Версия:  {ver}")
    print(f"  Flavour: {flavour}")
    print(f"  Release: {rel}")

    # 2. Проверяем — не установлены ли уже нужные заголовки
    src_dir = find_src_dir(ver, flavour, rel)
    if src_dir and (src_dir / "Makefile").exists():
        print(f"\nЗаголовки уже установлены: {src_dir}")
        ensure_build_symlink(kernel_release, src_dir, args.dry_run)
        print("Ничего не нужно делать.")
        return

    # 3. Ищем задачу сборки
    print(f"\n--- Поиск задачи сборки на packages.altlinux.org ---")
    try:
        task_id, subtask = find_task_for_version(flavour, full_ver)
    except RuntimeError as e:
        print(f"ОШИБКА: {e}")
        sys.exit(1)

    # 4. Получаем список RPM в задаче
    print(f"\n--- Список пакетов в задаче #{task_id}/build/{subtask} ---")
    try:
        rpms, base_url = list_rpms_in_task(task_id, subtask)
    except Exception as e:
        print(f"ОШИБКА при получении списка RPM: {e}")
        sys.exit(1)

    print(f"  Найдено RPM: {len(rpms)}")

    # 5. Отбираем нужные пакеты
    wanted_prefixes = [
        f"kernel-headers-modules-{flavour}-",
        f"kernel-headers-{flavour}-",
    ]
    to_download = []
    for rpm in rpms:
        for prefix in wanted_prefixes:
            if rpm.startswith(prefix) and "debuginfo" not in rpm:
                to_download.append(rpm)
                break

    if not to_download:
        print(f"ОШИБКА: не найдены пакеты kernel-headers* в задаче #{task_id}")
        print(f"Доступные RPM: {rpms}")
        sys.exit(1)

    print(f"  Будут скачаны:")
    for r in to_download:
        print(f"    {r}")

    if args.dry_run:
        print(f"\n[dry-run] Пропускаю скачивание и установку.")
        print(f"[dry-run] Источник: {base_url}")
        return

    # 6. Скачиваем во временную директорию
    with tempfile.TemporaryDirectory(prefix="khdrs_") as tmpdir:
        tmp = Path(tmpdir)
        downloaded = []
        for rpm_name in to_download:
            url = base_url + rpm_name
            dest = tmp / rpm_name
            try:
                download_file(url, dest, rpm_name)
                downloaded.append(dest)
            except Exception as e:
                print(f"ОШИБКА при скачивании {rpm_name}: {e}")
                sys.exit(1)

        # 7. Распаковываем
        print(f"\n--- Распаковка ---")
        extract_root = Path(args.extract_to)
        for rpm_path in downloaded:
            extract_rpm(rpm_path, extract_root, args.dry_run)

    # 8. Проверяем что распаковалось
    src_dir = find_src_dir(ver, flavour, rel)
    if src_dir is None:
        print("ПРЕДУПРЕЖДЕНИЕ: директория /usr/src/linux-<ver>* не найдена после установки")
        print("Возможно, пакет распаковывает в нестандартный путь.")
    else:
        print(f"  Заголовки установлены в: {src_dir}")

    # 9. Создаём симлинк /lib/modules/<release>/build
    if src_dir:
        ensure_build_symlink(kernel_release, src_dir, args.dry_run)

    print(f"\n=== Готово ===")
    print(f"Проверка:")
    print(f"  ls /lib/modules/{kernel_release}/build")
    print(f"  ls /usr/src/linux-{ver}-{flavour}/Makefile")


if __name__ == "__main__":
    main()
