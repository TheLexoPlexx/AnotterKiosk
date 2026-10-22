#!/usr/bin/env python3
"""Preserve an existing kiosk FAT32 partition across a whole-disk flash."""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime


IDENTITY_FIELDS = ("name", "size", "model", "serial", "wwn", "maj:min")


def run(*command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(
            f"{shlex.join(command)} failed (exit {result.returncode}): "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    return result.stdout


def descendants(node):
    yield node
    for child in node.get("children", []):
        yield from descendants(child)


def inspect_disk(device, expected):
    snapshot = json.loads(run(
        "lsblk", "--json", "--bytes", "--paths", "--output",
        "NAME,SIZE,TYPE,FSTYPE,MODEL,SERIAL,WWN,MAJ:MIN,RO,MOUNTPOINTS", device,
    ))
    disks = [node for node in snapshot["blockdevices"] if node["name"] == device]
    if len(disks) != 1:
        raise RuntimeError(f"Cannot identify target disk {device}")
    disk = disks[0]
    identity = {key: disk.get(key) for key in IDENTITY_FIELDS}
    if disk["type"] != "disk" or disk["ro"] or identity != expected:
        raise RuntimeError(f"Target identity or write eligibility changed: {device}")
    for node in descendants(disk):
        if any(node.get("mountpoints") or []) or node["type"] not in {"disk", "part"}:
            raise RuntimeError(f"Target is mounted or has active mappings: {node['name']}")
    return [node["name"] for node in descendants(disk)
            if node["type"] == "part" and node.get("fstype") == "vfat"]


@contextmanager
def mounted(partition, writable=False):
    directory = Path(tempfile.mkdtemp(prefix="anotterkiosk-mount-"))
    options = ",".join([
        "rw" if writable else "ro", "nosuid", "nodev", "noexec",
        f"uid={os.getuid()}", f"gid={os.getgid()}", "dmask=0077", "fmask=0177",
    ])
    try:
        run("sudo", "mount", "--types", "vfat", "--options", options,
            "--source", partition, "--target", str(directory))
    except Exception:
        directory.rmdir()
        raise
    try:
        yield directory
    finally:
        # Never recursively delete a mountpoint: a failed unmount must leave it intact.
        run("sudo", "umount", "--", str(directory))
        directory.rmdir()


def manifest(directory):
    files = {}
    directories = []
    for parent, names, filenames in os.walk(directory, followlinks=False, onerror=raise_error):
        for name in sorted(names + filenames):
            path = Path(parent) / name
            relative = path.relative_to(directory).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                directories.append(relative)
            elif stat.S_ISREG(mode):
                with path.open("rb") as stream:
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                files[relative] = {"sha256": digest, "size": path.stat().st_size}
            else:
                raise RuntimeError(f"Unsupported file type in configuration partition: {relative}")
    return {"files": files, "directories": sorted(directories)}


def raise_error(error):
    raise error


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sync_directory(directory):
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def durable_tree(directory):
    for parent, _, files in os.walk(directory, topdown=False, onerror=raise_error):
        for name in files:
            with (Path(parent) / name).open("rb") as stream:
                os.fsync(stream.fileno())
        sync_directory(parent)


def backup(device, expected):
    partitions = inspect_disk(device, expected)
    found = None
    for partition in partitions:
        with mounted(partition) as source:
            if not (source / "kioskbrowser.ini").is_file():
                continue
            if found:
                raise RuntimeError("Multiple kiosk configuration partitions found; refusing to erase")
            state_root = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
            root = state_root / "anotterkiosk/backups"
            root.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now().astimezone().strftime("%Y-%m-%d_%H-%M-%S%z")
            destination = Path(tempfile.mkdtemp(prefix=f"updated-{timestamp}-", dir=root))
            print(f"Backing up entire {partition} to {destination}", file=sys.stderr)
            before = manifest(source)
            shutil.copytree(source, destination / "boot", copy_function=shutil.copy2)
            if manifest(destination / "boot") != before or manifest(source) != before:
                raise RuntimeError(f"Backup verification failed; nothing may be erased. Copy: {destination}")
            write_json(destination / "manifest.json", before)
            write_json(destination / "identity.json", expected)
            write_json(destination / "backup.json", {"partition": partition, "created_at": timestamp})
            durable_tree(destination)
            # Persist newly created ancestor entries before permitting a destructive write.
            for parent in (root, *root.parents):
                sync_directory(parent)
            found = destination
    if found:
        print(f"Verified backup retained at {found}", file=sys.stderr)
        print(found)
    else:
        print("No kioskbrowser.ini found on the target's FAT32 partitions; no kiosk backup needed.", file=sys.stderr)


def comparison(old, new):
    old_files, new_files = old["files"], new["files"]
    report = [
        "Old FAT32 partition compared with the freshly flashed image.",
        "New defaults remain active; old files are archived under boot/.",
        "Only paths and SHA-256 hashes are reported, never file contents.", "",
    ]
    changes = []
    for path in sorted(old_files.keys() | new_files.keys()):
        old_file, new_file = old_files.get(path), new_files.get(path)
        if old_file == new_file:
            continue
        state = "CHANGED" if old_file and new_file else "OLD ONLY" if old_file else "NEW ONLY"
        changes.append(f"{state}: {path}")
        if old_file:
            changes.append(f"  old SHA-256: {old_file['sha256']}")
        if new_file:
            changes.append(f"  new SHA-256: {new_file['sha256']}")
    for path in sorted(set(old["directories"]) ^ set(new["directories"])):
        state = "OLD DIRECTORY" if path in old["directories"] else "NEW DIRECTORY"
        changes.append(f"{state}: {path}")
    report.extend(changes or ["All files and directories are identical."])
    return "\n".join(report) + "\n"


def archive(device, directory):
    expected = json.loads((directory / "identity.json").read_text())
    old = json.loads((directory / "manifest.json").read_text())
    if manifest(directory / "boot") != old:
        raise RuntimeError(f"Local backup is incomplete or changed: {directory}")
    inspect_disk(device, expected)
    run("sudo", "blockdev", "--rereadpt", device)
    run("udevadm", "settle")
    partitions = inspect_disk(device, expected)
    if len(partitions) != 1:
        raise RuntimeError("Expected exactly one new FAT32 partition; local backup retained")
    with mounted(partitions[0], writable=True) as target:
        if not (target / "kioskbrowser.ini").is_file():
            raise RuntimeError("New FAT32 partition lacks kioskbrowser.ini; local backup retained")
        new = manifest(target)
        report = comparison(old, new)
        (directory / "comparison.txt").write_text(report)
        write_json(directory / "new-image-manifest.json", new)
        durable_tree(directory)
        destination = target / directory.name
        if destination.exists():
            raise RuntimeError(f"Archive already exists; refusing to overwrite {directory.name}")
        space = os.statvfs(target)
        unit = space.f_frsize
        # Include per-file allocation and directory entries, rather than just byte totals.
        required = sum(((entry["size"] + unit - 1) // unit) * unit for entry in old["files"].values())
        required += sum(((path.stat().st_size + unit - 1) // unit) * unit
                        for path in directory.iterdir() if path.is_file())
        required += (len(old["directories"]) + len(old["files"]) + 3) * unit
        available = space.f_bavail * unit
        if required > available:
            raise RuntimeError(f"New FAT32 partition needs about {required} bytes for the archive but has {available}; backup retained at {directory}")
        shutil.copytree(directory, destination, copy_function=shutil.copy2)
        if manifest(destination / "boot") != old:
            raise RuntimeError(f"On-device archive verification failed; local backup retained at {directory}")
        for path in directory.iterdir():
            if path.is_file() and not file_equal(path, destination / path.name):
                raise RuntimeError(f"Archive metadata verification failed for {path.name}")
        # Successful unmount below flushes FAT data and metadata before reporting success.
    print(f"Old files archived on {partitions[0]} in /{directory.name}/boot/", file=sys.stderr)
    print(f"Comparison report: /{directory.name}/comparison.txt", file=sys.stderr)
    print(f"Local backup retained at {directory}. New defaults remain active.", file=sys.stderr)


def file_equal(left, right):
    with left.open("rb") as old, right.open("rb") as new:
        return hashlib.file_digest(old, "sha256").digest() == hashlib.file_digest(new, "sha256").digest()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("backup", help="Back up a kiosk before flashing; print its local backup path")
    prepare.add_argument("--device", required=True)
    prepare.add_argument("--identity", required=True, help="Expected disk identity as JSON")
    restore = commands.add_parser("archive", help="Archive a retained backup on the newly flashed FAT32 partition")
    restore.add_argument("--device", required=True)
    restore.add_argument("--backup", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "backup":
            backup(args.device, json.loads(args.identity))
        else:
            archive(args.device, args.backup)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Preservation failed during {args.command}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
