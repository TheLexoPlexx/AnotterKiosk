#!/usr/bin/env bash
# Publish the built AnotterKiosk x86 image to Gitea Releases, keeping only the latest release.
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CA="${ROOT}/.ci/registry-ca.crt"
API="${GITEA_API_URL:-https://git.services.eisenmann-intec.local/api/v1}"
REPO="${GITEA_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
TOKEN="${GITEA_TOKEN:-}"

if [[ ! -f "${CA}" ]]; then
	echo "Missing CA bundle: ${CA} (run Install and Configure Certificates step first)" >&2
	exit 1
fi
if [[ -z "${TOKEN}" ]]; then
	echo "GITEA_TOKEN is empty; skipping Gitea release upload." >&2
	exit 0
fi
if [[ -z "${REPO}" ]]; then
	echo "GITEA_REPOSITORY or GITHUB_REPOSITORY is required." >&2
	exit 1
fi

shopt -s nullglob
IMAGES=("${ROOT}"/anotterkiosk-*-x86.img.xz)
if [[ ${#IMAGES[@]} -eq 0 ]]; then
	echo "No anotterkiosk-*-x86.img.xz found in ${ROOT}" >&2
	exit 1
fi

for img in "${IMAGES[@]}"; do
	(cd "$(dirname "${img}")" && sha256sum "$(basename "${img}")" > "$(basename "${img}").sha256")
done

if [[ "${GITHUB_REF:-}" == refs/tags/* ]]; then
	TAG="${GITHUB_REF#refs/tags/}"
elif [[ -n "${RELEASE_TAG:-}" ]]; then
	TAG="${RELEASE_TAG}"
else
	TAG="latest"
fi

TARGET_COMMITISH="${GITHUB_SHA:-main}"
SHORT_SHA="$(git -C "${ROOT}" rev-parse --short HEAD)"
BODY="Automated dual-screen AnotterKiosk x86 image build (${SHORT_SHA})."
if [[ -f "${ROOT}/version-info" ]]; then
	BODY="$(cat "${ROOT}/version-info")"
fi

auth_header="Authorization: token ${TOKEN}"
accept_header="Accept: application/json"

# Delete all existing releases (and auto-created tags) so only the latest release is kept
existing_releases="$(curl --cacert "${CA}" -sf -H "${auth_header}" -H "${accept_header}" \
	"${API}/repos/${REPO}/releases?limit=100" || echo "[]")"

echo "${existing_releases}" | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    print(f"{r.get(\"id\")} {r.get(\"tag_name\", \"\")}")
' | while read -r rel_id rel_tag; do
	if [[ -n "${rel_id}" ]]; then
		echo "Deleting previous release id=${rel_id} (tag=${rel_tag})..."
		curl --cacert "${CA}" -sf -X DELETE -H "${auth_header}" \
			"${API}/repos/${REPO}/releases/${rel_id}" || true
		if [[ "${rel_tag}" == "latest" ]] || [[ "${rel_tag}" == build-* ]]; then
			curl --cacert "${CA}" -sf -X DELETE -H "${auth_header}" \
				"${API}/repos/${REPO}/tags/${rel_tag}" || true
		fi
	fi
done

payload="$(
	TAG="${TAG}" \
	TARGET="${TARGET_COMMITISH}" \
	SHORT_SHA="${SHORT_SHA}" \
	BODY="${BODY}" \
	python3 -c '
import json, os
tag = os.environ["TAG"]
sha = os.environ["SHORT_SHA"]
print(json.dumps({
    "tag_name": tag,
    "target_commitish": os.environ["TARGET"],
    "name": f"AnotterKiosk x86 ({sha})" if tag == "latest" else f"AnotterKiosk {tag}",
    "body": os.environ["BODY"],
    "draft": False,
    "prerelease": False,
}))
'
)"

resp="$(curl --cacert "${CA}" -sS -w $'\n%{http_code}' \
	-H "${auth_header}" -H "${accept_header}" -H "Content-Type: application/json" \
	-d "${payload}" \
	"${API}/repos/${REPO}/releases")"
code="${resp##*$'\n'}"
body="${resp%$'\n'*}"
if [[ "${code}" != "201" ]]; then
	echo "Failed to create release ${TAG} (HTTP ${code}): ${body}" >&2
	exit 1
fi

RELEASE_ID="$(echo "${body}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
echo "Created Gitea Release ${TAG} (id=${RELEASE_ID})"

upload_asset() {
	local file="$1"
	local name
	name="$(basename "${file}")"
	local upload_url="${API}/repos/${REPO}/releases/${RELEASE_ID}/assets?name=${name}"
	local resp code body
	resp="$(curl --cacert "${CA}" -sS -w $'\n%{http_code}' \
		-H "${auth_header}" -H "${accept_header}" \
		-F "attachment=@${file}" \
		"${upload_url}")"
	code="${resp##*$'\n'}"
	body="${resp%$'\n'*}"
	if [[ "${code}" != "201" ]]; then
		echo "Upload failed for ${name} (HTTP ${code}): ${body}" >&2
		exit 1
	fi
	echo "Uploaded ${name}"
}

for img in "${IMAGES[@]}"; do
	upload_asset "${img}"
	upload_asset "${img}.sha256"
done
if [[ -f "${ROOT}/version-info" ]]; then
	upload_asset "${ROOT}/version-info"
fi

echo "Release URL: https://git.services.eisenmann-intec.local/${REPO}/releases/tag/${TAG}"
