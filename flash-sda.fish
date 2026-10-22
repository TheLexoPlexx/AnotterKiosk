#!/usr/bin/env fish

function fail
    printf 'Error: %s\n' "$argv" >&2
    exit 1
end

set -l download_only false
set -l wait_for_release false
for arg in $argv
    switch "$arg"
        case --help -h
            printf 'Usage: fish %s [--download-only] [--wait]\n\n' (status filename)
            printf 'Verify git state, fetch and SHA-256-check the latest x86 image for main, then select a disk to erase.\n'
            printf '  --download-only  Download and verify the release image into cache without flashing.\n'
            printf '  --wait           Wait for a release matching current main (60s interval, 60 retries / 60m timeout).\n\n'
            printf 'Images are cached under $XDG_CACHE_HOME/anotterkiosk (default: ~/.cache/anotterkiosk).\n'
            printf 'Mounted disks, active swap, read-only disks and active device mappings are excluded.\n'
            printf 'Existing kiosk FAT32 files are backed up locally and archived under updated-<timestamp>/ after flashing.\n'
            printf 'New image defaults remain active; local backups are retained under $XDG_STATE_HOME/anotterkiosk/backups.\n'
            exit 0
        case --download-only
            set download_only true
        case --wait
            set wait_for_release true
        case '*'
            fail 'Unknown arguments. Use --help.'
    end
end

for dependency in git curl jq sha256sum xz lsblk mktemp cp mv rm mkdir seq sleep
    command -q $dependency; or fail "Required command not found: $dependency"
end

function fetch
    curl --fail --location --show-error --proto '=https' --proto-redir '=https' $argv
end

function matches_sha256 --argument-names image expected
    test -f "$image"; or return 1
    set -l digest (sha256sum -- "$image"); or return 1
    set -l fields (string split ' ' -- "$digest")
    test "$fields[1]" = "$expected"
end

function release_commit_sha --argument-names api release
    set -l target (printf '%s' "$release" | jq -er '.target_commitish // empty' 2>/dev/null | string lower)
    if string match --quiet --regex '^[0-9a-f]{7,40}$' -- "$target"
        printf '%s\n' "$target"
        return 0
    end
    set -l tag_name (printf '%s' "$release" | jq -er '.tag_name // empty' 2>/dev/null)
    if test -n "$tag_name"
        set -l tag_json (fetch --silent "$api/tags/$tag_name" 2>/dev/null); or return 1
        set -l tag_sha (printf '%s' "$tag_json" | jq -er '.commit.sha // .id // empty' 2>/dev/null | string lower)
        if string match --quiet --regex '^[0-9a-f]{7,40}$' -- "$tag_sha"
            printf '%s\n' "$tag_sha"
            return 0
        end
    end
    return 1
end

function release_matches_commit --argument-names release_sha target_sha
    test -n "$release_sha" -a -n "$target_sha"; or return 1
    string match --quiet "$release_sha*" -- "$target_sha"
    or string match --quiet "$target_sha*" -- "$release_sha"
end

function release_has_required_assets --argument-names release
    printf '%s' "$release" | jq -e '
        ([.assets[]? | select(.name | test("^anotterkiosk-[A-Za-z0-9._-]+-x86[.]img[.]xz$"))] | length == 1) as $has_img
        | ([.assets[]? | select(.name | test("^anotterkiosk-[A-Za-z0-9._-]+-x86[.]img[.]xz$"))][0].name // "") as $img_name
        | $has_img and ([.assets[]? | select(.name == ($img_name + ".sha256"))] | length == 1)
    ' >/dev/null 2>&1
end

set -l repo_dir (path dirname (status filename))
git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; or fail "Not a git repository: $repo_dir"
set -l dirty_status (git -C "$repo_dir" status --porcelain)
if test -n "$dirty_status"
    printf 'Warning: Git working tree is dirty; uncommitted changes are not pushed.\n' >&2
else
    set -l upstream '@{u}'
    if not git -C "$repo_dir" rev-parse --verify "$upstream" >/dev/null 2>&1
        set upstream origin/main
    end
    set -l unpushed (git -C "$repo_dir" rev-list --count "$upstream..HEAD" 2>/dev/null)
    if test $status -ne 0; or test "$unpushed" -gt 0
        printf 'Git working tree is clean with unpushed commits; pushing…\n'
        git -C "$repo_dir" push; or fail 'Could not push commits to remote.'
    else
        printf 'Git working tree is clean and pushed.\n'
    end
end

set -l main_sha (git -C "$repo_dir" rev-parse refs/heads/main 2>/dev/null; or git -C "$repo_dir" rev-parse HEAD); or fail 'Could not determine current main commit.'
set main_sha (string lower -- "$main_sha")
set -l main_short (string sub --length 7 -- "$main_sha")

set -l api https://git.services.eisenmann-intec.local/api/v1/repos/alex/AnotterKiosk
printf 'Checking latest AnotterKiosk release (expecting main %s)…\n' "$main_short"
set -l release (fetch --silent "$api/releases/latest" 2>/dev/null)
set -l release_sha ''
if test -n "$release"
    set release_sha (release_commit_sha "$api" "$release")
end

if not begin
        release_matches_commit "$release_sha" "$main_sha"
        and release_has_required_assets "$release"
    end
    if test "$wait_for_release" != true
        test -n "$release"; or fail 'Could not fetch latest release metadata.'
        set -l release_short (string sub --length 7 -- "$release_sha")
        test -n "$release_short"; or set release_short unknown
        if not release_matches_commit "$release_sha" "$main_sha"
            fail "Latest release ($release_short) does not stem from current main ($main_short). Use --wait to wait for a new release."
        end
        fail "Latest release ($main_short) is missing required x86 image assets. Use --wait to wait for the release upload."
    end

    set -l release_ready false
    for retry in (seq 60)
        if release_matches_commit "$release_sha" "$main_sha"
            printf 'Release for %s found, waiting for assets to finish uploading (60s, retry %d/60)…\n' "$main_short" "$retry"
        else
            set -l release_short (string sub --length 7 -- "$release_sha")
            test -n "$release_short"; or set release_short none
            printf 'Latest release (%s) does not stem from current main (%s); waiting 60s (retry %d/60)…\n' "$release_short" "$main_short" "$retry"
        end
        sleep 60
        set release (fetch --silent "$api/releases/latest" 2>/dev/null)
        set release_sha ''
        if test -n "$release"
            set release_sha (release_commit_sha "$api" "$release")
        end
        if release_matches_commit "$release_sha" "$main_sha"; and release_has_required_assets "$release"
            set release_ready true
            break
        end
    end
    test "$release_ready" = true; or fail "Timed out after 60 minutes (60 retries) waiting for a release from current main ($main_short)."
end
printf 'Latest release matches current main (%s).\n' "$main_short"
set -l image_asset (printf '%s' "$release" | jq -ce '
    [.assets[] | select(.name | test("^anotterkiosk-[A-Za-z0-9._-]+-x86[.]img[.]xz$"))]
    | if length == 1 then .[0] else error("Expected exactly one x86 image asset") end
'); or fail 'Latest release does not contain exactly one supported x86 image.'
set -l image_name (printf '%s' "$image_asset" | jq -er '.name'); or fail 'Missing image name.'
set -l image_url (printf '%s' "$image_asset" | jq -er '.browser_download_url'); or fail 'Missing image download URL.'
set -l checksum_url (printf '%s' "$release" | jq -er --arg name "$image_name.sha256" '
    [.assets[] | select(.name == $name)]
    | if length == 1 then .[0].browser_download_url else error("Missing or ambiguous SHA-256 asset") end
'); or fail 'Latest release must supply a matching .sha256 asset.'
set -l checksum (fetch --silent "$checksum_url"); or fail 'Could not download SHA-256 checksum.'
set -l expected_hash (printf '%s' "$checksum" | jq -Rser --arg name "$image_name" '
    capture("^(?<sha>[0-9a-fA-F]{64}) [ *](?<name>[^\\r\\n]+)\\r?\\n?$")
    | select(.name == $name) | .sha | ascii_downcase
'); or fail 'Invalid SHA-256 checksum or mismatched image filename.'

set -l cache_root "$HOME/.cache"
if set -q XDG_CACHE_HOME; and test -n "$XDG_CACHE_HOME"
    set cache_root "$XDG_CACHE_HOME"
end
set -l cache_dir "$cache_root/anotterkiosk/$expected_hash"
mkdir -p -- "$cache_dir"; or fail "Could not create cache: $cache_dir"
set -l image "$cache_dir/$image_name"
set -l staging (mktemp -d "$cache_dir/.download.XXXXXXXXXX"); or fail 'Could not create download staging directory.'
function cleanup --on-event fish_exit --inherit-variable staging
    rm -rf -- "$staging"
end

if matches_sha256 "$image" "$expected_hash"
    printf 'Using verified cached image: %s\n' "$image"
else
    set -l imported false
    # Reuse the manually downloaded image from the original flashing workflow.
    for existing in (path dirname (status filename))/"$image_name" "$HOME/Downloads/$image_name"
        if matches_sha256 "$existing" "$expected_hash"
            printf 'Caching existing verified image: %s\n' "$existing"
            cp --reflink=auto -- "$existing" "$staging/$image_name"; or fail 'Could not cache existing image.'
            set imported true
            break
        end
    end
    if test "$imported" = false
        printf 'Downloading %s…\n' "$image_name"
        fetch --progress-bar --output "$staging/$image_name" "$image_url"; or fail 'Image download failed; cached images were left intact.'
    end
    matches_sha256 "$staging/$image_name" "$expected_hash"; or fail 'Image SHA-256 mismatch. Refusing to flash or cache it.'
    mv -f -- "$staging/$image_name" "$image"; or fail 'Could not save verified image in cache.'
end
printf '%s\n' "$checksum" >"$cache_dir/$image_name.sha256"; or fail 'Could not save checksum.'
printf 'Checking compressed image integrity…\n'
xz --test -- "$image"; or fail 'Compressed image integrity check failed.'
printf 'SHA-256 verified: %s\n' "$expected_hash"
if test "$download_only" = true
    printf 'Image ready: %s\n' "$image"
    exit 0
end

command -q sudo; or fail 'Required command not found: sudo'
for dependency in python3 mount umount blockdev udevadm
    command -q $dependency; or fail "Required preservation command not found: $dependency"
end
set -l preserve_helper (path dirname (status filename))/flash-preserve.py
test -f "$preserve_helper"; or fail "Missing preservation helper: $preserve_helper"
isatty stdin; or fail 'Disk selection requires an interactive terminal. Use --download-only to only cache the image.'
set -l image_details (xz --robot --list -- "$image"); or fail 'Could not read uncompressed image size.'
set -l image_bytes (printf '%s\n' $image_details | jq -Rer 'select(startswith("totals\t")) | split("\t")[4] | tonumber'); or fail 'Could not determine image size.'

function disk_snapshot
    lsblk --json --bytes --paths --output NAME,SIZE,TYPE,MODEL,SERIAL,WWN,MAJ:MIN,RO,MOUNTPOINTS
end

function eligible_disks --argument-names snapshot required_bytes
    printf '%s' "$snapshot" | jq -ce --argjson required "$required_bytes" '
        [.blockdevices[]
        | select(.type == "disk" and .ro == false and .size >= $required)
        | select(.name | startswith("/dev/zram") | not)
        | select([recurse(.children[]?) | .mountpoints[]? | select(. != null and . != "")] | length == 0)
        | select([recurse(.children[]?) | select(.type != "disk" and .type != "part")] | length == 0)]
    '
end

set -l snapshot (disk_snapshot); or fail 'Could not inspect block devices.'
set -l candidates (eligible_disks "$snapshot" "$image_bytes"); or fail 'Could not determine safe target disks.'
set -l devices (printf '%s' "$candidates" | jq -r '.[].name')
printf '\nCurrent block devices:\n'
lsblk --paths --output NAME,SIZE,MODEL,TYPE,MOUNTPOINTS; or fail 'Could not display block devices.'
if test (count $devices) -eq 0
    fail 'No eligible disks. Unmount target partitions first; disks must be writable, large enough, and have no active mappings or swap.'
end
printf '\nSelectable disks (ALL DATA on the selected disk will be destroyed):\n'
for index in (seq (count $devices))
    set -l description (printf '%s' "$candidates" | jq -r --argjson index (math "$index - 1") '
        .[$index] | "\(.name)  \(.size / 1073741824 * 10 | floor / 10) GiB  \(.model // "")  serial=\(.serial // "unknown")"
    ')
    printf '  %s) %s\n' "$index" "$description"
end
read --prompt-str 'Select disk number (or q to cancel): ' choice; or fail 'Disk selection cancelled.'
if test "$choice" = q
    exit 0
end
string match --quiet --regex '^[0-9]+$' -- "$choice"; or fail 'Enter a disk number from the list.'
test "$choice" -ge 1; and test "$choice" -le (count $devices); or fail 'Disk number is out of range.'
set -l device "$devices[$choice]"
set -l identity_filter '{name, size, model, serial, wwn, "maj:min": .["maj:min"]}'
set -l identity (printf '%s' "$candidates" | jq -c --arg device "$device" ".[] | select(.name == \$device) | $identity_filter"); or fail 'Could not record target identity.'
printf '\nImage: %s\nTarget: %s\nThis permanently erases the entire disk.\n' "$image_name" "$device"
read --prompt-str "Type ERASE $device to proceed: " confirmation; or fail 'Erase confirmation cancelled.'
if test "$confirmation" != "ERASE $device"
    printf 'Cancelled. Nothing written.\n'
    exit 0
end
sudo -v; or fail 'Could not obtain sudo authorization.'
set -l backup_dir (python3 "$preserve_helper" backup --device "$device" --identity "$identity"); or fail 'Kiosk backup failed. Nothing written.'
if test -n "$backup_dir"
    printf 'A verified local backup is safe at: %s\n' "$backup_dir"
    printf 'After flashing it will be archived on the new FAT32 partition; new defaults will stay active.\n'
end

# Recheck after the user prompt: removable devices and automount state can change.
set snapshot (disk_snapshot); or fail 'Could not recheck block devices.'
set candidates (eligible_disks "$snapshot" "$image_bytes"); or fail 'Could not recheck target eligibility.'
set -l current_identity (printf '%s' "$candidates" | jq -ec --arg device "$device" ".[] | select(.name == \$device) | $identity_filter"); or fail 'Target disappeared, is mounted, or is no longer eligible. Nothing written.'
test "$identity" = "$current_identity"; or fail 'Target disk identity changed. Nothing written.'
test -b "$device"; or fail 'Target is not a block device. Nothing written.'
printf '\nWriting %s to %s…\n' "$image_name" "$device"
xz -dc -- "$image" | sudo dd of="$device" bs=4M status=progress conv=fsync,nocreat
set -l pipeline_status $pipestatus
if test "$pipeline_status[1]" -ne 0
    fail "Image decompression failed (exit $pipeline_status[1]); the target may be only partially written."
end
if test "$pipeline_status[2]" -ne 0
    fail "Disk write failed (exit $pipeline_status[2]); the target may be only partially written."
end
# Ensure partition 1 has the standard EFI System Partition GUID and relocate backup GPT to end of disk
sudo sfdisk --part-type "$device" 1 C12A7328-F81F-11D2-BA4B-00A0C93EC93B >/dev/null 2>&1; or true
sudo sfdisk --relocate gpt-bak-std "$device" >/dev/null 2>&1; or true
sudo partprobe "$device" >/dev/null 2>&1; or true
sudo udevadm settle
if test -n "$backup_dir"
    python3 "$preserve_helper" archive --device "$device" --backup "$backup_dir"
    if test $status -ne 0
        printf 'Image was flashed, but on-device archival failed. Your old files remain at:\n%s\n' "$backup_dir" >&2
        printf 'After resolving the error, retry archival without reflashing:\n' >&2
        printf 'python3 %s archive --device %s --backup %s\n' (string escape -- "$preserve_helper") (string escape -- "$device") (string escape -- "$backup_dir") >&2
        exit 1
    end
end
printf '\nDone. Image written and flushed to %s. Cached image retained at:\n%s\n' "$device" "$image"
