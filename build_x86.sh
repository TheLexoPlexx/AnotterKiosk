#!/bin/bash

set -x -e

# *sigh*, some docker containers don't seem to have sbin in their PATH
export PATH=$PATH:/usr/sbin

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
BUILD_DIR="${SCRIPT_DIR}/work/root/"

# cleanup any previous build attempts
umount -fl "${BUILD_DIR}" || true
rm -rf "${BUILD_DIR}" || true
mkdir -p "${BUILD_DIR}"
rm x86kiosk.img || true

truncate -s 10G x86kiosk.img

PARTLAYOUT=$(cat <<-END
label: gpt
label-id: 3BC7D7CD-4BF8-4E92-AAEB-2ACD5F8D05AA
device: x86kiosk.img
unit: sectors
first-lba: 34
last-lba: 20971486
sector-size: 512

x86kiosk.img1 : start=        2048, size=     2095105, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=9C99F1BB-11A8-4BB5-82C2-555D7A38F85C, name="EFI system partition"
x86kiosk.img2 : start=     2099200, size=    18870272, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=93A9AB2C-BC29-4C6C-B6DD-1B4EDDED9A1E, name="Linux filesystem"
x86kiosk.img3 : start=          34, size=        2014, type=21686148-6449-6E6F-744E-656564454649, uuid=5862A4C7-7D99-4670-9806-05C027A3B3D7, name="BIOS boot partition"
END
)
echo "${PARTLAYOUT}" | sfdisk x86kiosk.img

# Ensure loop device nodes exist when running inside a container
if [ ! -e /dev/loop-control ]; then
	sudo mknod -m 0660 /dev/loop-control c 10 237 || true
fi
for i in $(seq 0 15); do
	if [ ! -b "/dev/loop${i}" ]; then
		sudo mknod -m 0660 "/dev/loop${i}" b 7 "${i}" || true
	fi
done

# Setup loop device for x86 image (with partition scanning)
ld=$(sudo losetup -P --show -f x86kiosk.img)
sudo partprobe "${ld}" 2>/dev/null || true
for part in 1 2 3; do
	pdev="${ld}p${part}"
	sysdev="/sys/class/block/$(basename "${ld}")p${part}/dev"
	if [ ! -b "${pdev}" ] && [ -f "${sysdev}" ]; then
		IFS=: read -r maj min < "${sysdev}"
		sudo mknod -m 0660 "${pdev}" b "${maj}" "${min}"
	fi
done

# Create filesystems
sudo mkfs.ext4 "${ld}p2"
sudo mkfs.fat -F 32 "${ld}p1"

# Mount partitions
sudo mount "${ld}p2" "${BUILD_DIR}"
sudo mkdir -p "${BUILD_DIR}/boot/firmware"
sudo mount "${ld}p1" "${BUILD_DIR}/boot/firmware"

# Debootstrap debian
sudo debootstrap --include=linux-image-amd64,grub-efi,sudo,ca-certificates --arch amd64 trixie "${BUILD_DIR}" http://deb.debian.org/debian/

# Copy the skeleton files
sudo rsync -a "${SCRIPT_DIR}/x86_skeleton/." "${BUILD_DIR}"
sudo rsync -a "${SCRIPT_DIR}/kiosk_skeleton/." "${BUILD_DIR}/kiosk_skeleton"

# Inject internal Root CA into system trust store and Chromium NSS skeleton if present
if [ -f "${SCRIPT_DIR}/.ci/registry-ca.crt" ]; then
	sudo mkdir -p "${BUILD_DIR}/kiosk_skeleton/usr/local/share/ca-certificates"
	sudo cp "${SCRIPT_DIR}/.ci/registry-ca.crt" "${BUILD_DIR}/kiosk_skeleton/usr/local/share/ca-certificates/eisenmann-intec.crt"
	sudo mkdir -p "${BUILD_DIR}/kiosk_skeleton/etc/skel/.pki/ca-certificates"
	sudo cp "${SCRIPT_DIR}/.ci/registry-ca.crt" "${BUILD_DIR}/kiosk_skeleton/etc/skel/.pki/ca-certificates/eisenmann-intec.crt"
fi

# Create fstab (use blkid so UUID detection works without udevd inside containers)
fat_uuid=$(sudo blkid -s UUID -o value "${ld}p1")
ext_uuid=$(sudo blkid -s UUID -o value "${ld}p2")

echo "UUID=${fat_uuid}  /boot/firmware  vfat    ro,defaults          0       2" | sudo tee "${BUILD_DIR}/etc/fstab"
echo "UUID=${ext_uuid}  /               ext4    ro,defaults,noatime  0       1" | sudo tee -a "${BUILD_DIR}/etc/fstab"

# Include git repo version info
git config --global --add safe.directory "${SCRIPT_DIR}" 2>/dev/null || true
echo -n "AnotterKiosk x86 version: " > "${BUILD_DIR}/version-info"
git describe --abbrev=4 --dirty --always --tags >> "${BUILD_DIR}/version-info"

# Mount system partitions (from the build host)
sudo mount proc -t proc -o nosuid,noexec,nodev "${BUILD_DIR}/proc/"
sudo mount sys -t sysfs -o nosuid,noexec,nodev,ro "${BUILD_DIR}/sys/"
if ! sudo mount devpts -t devtmpfs -o mode=0755,nosuid "${BUILD_DIR}/dev/" 2>/dev/null; then
	sudo mount --bind /dev "${BUILD_DIR}/dev/"
fi
# Ensure loop device and partition nodes exist inside chroot /dev for grub-install
if [ ! -b "${BUILD_DIR}${ld}" ] && [ -f "/sys/class/block/$(basename "${ld}")/dev" ]; then
	IFS=: read -r maj min < "/sys/class/block/$(basename "${ld}")/dev"
	sudo mknod -m 0660 "${BUILD_DIR}${ld}" b "${maj}" "${min}" || true
fi
for part in 1 2 3; do
	pdev="${ld}p${part}"
	sysdev="/sys/class/block/$(basename "${ld}")p${part}/dev"
	if [ ! -b "${BUILD_DIR}${pdev}" ] && [ -f "${sysdev}" ]; then
		IFS=: read -r maj min < "${sysdev}"
		sudo mknod -m 0660 "${BUILD_DIR}${pdev}" b "${maj}" "${min}" || true
	fi
done
sudo mkdir -p "${BUILD_DIR}/dev/pts"
sudo mount devpts -t devpts -o mode=0620,gid=5,nosuid,noexec "${BUILD_DIR}/dev/pts" || true

# and then actually install everything.
sudo chroot "${BUILD_DIR}" env LOOP_DEV="${ld}" /setup.sh
sudo chroot "${BUILD_DIR}" /kiosk_skeleton/build.sh

sudo rm -r "${BUILD_DIR}/kiosk_skeleton"

# Inject CI secrets and variables into /boot/firmware/kioskbrowser.ini and authorized_keys without echoing secrets
{ set +x; } 2>/dev/null
sudo WIFI_PASSWORD="${WIFI_PASSWORD:-}" \
     WIFI_SSID="${WIFI_SSID:-}" \
     SSH_AUTHORIZED_KEYS="${SSH_AUTHORIZED_KEYS:-}" \
     WACOM_URL="${WACOM_URL:-}" \
     TV_URL="${TV_URL:-}" \
     KIOSK_HOSTNAME="${KIOSK_HOSTNAME:-}" \
     BUILD_DIR="${BUILD_DIR}" \
     python3 -c '
import os, pathlib

fw = pathlib.Path(os.environ["BUILD_DIR"]) / "boot" / "firmware"
ini_path = fw / "kioskbrowser.ini"
lines = ini_path.read_text(encoding="utf-8").splitlines()

def set_ini_value(lines: list[str], section: str, key: str, val: str) -> list[str]:
    escaped = val.replace("\\", "\\\\").replace("\"", "\\\"")
    in_section = False
    replaced = False
    out = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_section and not replaced:
                out.append(f"{key}=\"{escaped}\"")
                replaced = True
            in_section = (stripped[1:-1].strip() == section)
            out.append(line)
            continue
        if in_section and not replaced and not stripped.startswith(";"):
            k = stripped.split("=", 1)[0].strip() if "=" in stripped else ""
            if k == key:
                out.append(f"{key}=\"{escaped}\"")
                replaced = True
                continue
        out.append(line)
    if in_section and not replaced:
        out.append(f"{key}=\"{escaped}\"")
    return out

if os.environ.get("WIFI_SSID"):
    lines = set_ini_value(lines, "wifi", "ssid", os.environ["WIFI_SSID"])
if os.environ.get("WIFI_PASSWORD"):
    lines = set_ini_value(lines, "wifi", "psk", os.environ["WIFI_PASSWORD"])
if os.environ.get("WACOM_URL"):
    lines = set_ini_value(lines, "browser", "wacom_url", os.environ["WACOM_URL"])
if os.environ.get("TV_URL"):
    lines = set_ini_value(lines, "browser", "tv_url", os.environ["TV_URL"])
if os.environ.get("KIOSK_HOSTNAME"):
    lines = set_ini_value(lines, "general", "hostname", os.environ["KIOSK_HOSTNAME"])

ini_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

auth_keys = os.environ.get("SSH_AUTHORIZED_KEYS", "").strip()
if auth_keys:
    (fw / "authorized_keys").write_text(auth_keys + "\n", encoding="utf-8")
'
set -x

cp "${BUILD_DIR}/version-info" version-info

# trim all filesystems
sudo fstrim -a

# fill unused space on /boot with 0x00 
# (FAT32, so zerofree doesn't work, we'll do it manually)
sudo dd if=/dev/zero of="${BUILD_DIR}/boot/firmware/zerofree" bs=1M || true
sudo rm "${BUILD_DIR}/boot/firmware/zerofree" || true

sudo umount -fl "${BUILD_DIR}/dev/pts" || true
sudo umount -fl "${BUILD_DIR}/proc" || true
sudo umount -fl "${BUILD_DIR}/sys" || true
sudo umount -fl "${BUILD_DIR}/dev" || true

sudo umount "${BUILD_DIR}/dev/pts" || true
sudo umount "${BUILD_DIR}/proc" || true
sudo umount "${BUILD_DIR}/sys" || true
sudo umount "${BUILD_DIR}/dev" || true

sudo umount "${BUILD_DIR}/boot/firmware" || true
sudo umount "${BUILD_DIR}" || true

# set all empty blocks on ext4 to 0x00 (for better compression)
sudo zerofree "${ld}p2"

sudo losetup -D "${ld}"

tag=$(git describe --abbrev=4 --dirty --always --tags)
mv x86kiosk.img anotterkiosk-${tag}-x86.img
xz -T0 anotterkiosk-${tag}-x86.img