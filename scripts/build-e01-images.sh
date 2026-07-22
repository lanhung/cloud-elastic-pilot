#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REPOSITORY="${E01_IMAGE_REPOSITORY:-hooke/e01}"
SMALL_PADDING_MIB="${E01_SMALL_IMAGE_PADDING_MIB:-64}"
LARGE_PADDING_MIB="${E01_LARGE_IMAGE_PADDING_MIB:-512}"
PLATFORM="${E01_IMAGE_PLATFORM:-linux/amd64}"
SMALL_TAG=""
LARGE_TAG=""
METADATA_FILE=""
PUSH=false
ALLOW_DIRTY=false

usage() {
  cat <<'USAGE'
Usage: build-e01-images.sh [options]

Build deterministic E01 small/large smoke-app images. Images remain local
unless --push is explicitly supplied.

Options:
  --repository REPO       Image repository (default: hooke/e01)
  --small-padding-mib N   Incompressible padding in the small image (default: 64)
  --large-padding-mib N   Incompressible padding in the large image (default: 512)
  --platform PLATFORM     Target platform (default: linux/amd64)
  --small-tag TAG         Override generated small tag
  --large-tag TAG         Override generated large tag
  --metadata FILE         Write shell-compatible build metadata to FILE
  --push                  Push both images and emit immutable repo@sha256 refs
  --allow-dirty           Permit a local development build from a dirty tree
  -h, --help              Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) [[ $# -ge 2 ]] || { echo "--repository requires a value" >&2; exit 2; }; REPOSITORY="$2"; shift 2 ;;
    --small-padding-mib) [[ $# -ge 2 ]] || { echo "--small-padding-mib requires a value" >&2; exit 2; }; SMALL_PADDING_MIB="$2"; shift 2 ;;
    --large-padding-mib) [[ $# -ge 2 ]] || { echo "--large-padding-mib requires a value" >&2; exit 2; }; LARGE_PADDING_MIB="$2"; shift 2 ;;
    --platform) [[ $# -ge 2 ]] || { echo "--platform requires a value" >&2; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --small-tag) [[ $# -ge 2 ]] || { echo "--small-tag requires a value" >&2; exit 2; }; SMALL_TAG="$2"; shift 2 ;;
    --large-tag) [[ $# -ge 2 ]] || { echo "--large-tag requires a value" >&2; exit 2; }; LARGE_TAG="$2"; shift 2 ;;
    --metadata) [[ $# -ge 2 ]] || { echo "--metadata requires a value" >&2; exit 2; }; METADATA_FILE="$2"; shift 2 ;;
    --push) PUSH=true; shift ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo "gzip is required" >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "Docker Buildx is required" >&2; exit 1; }
[[ -n "$REPOSITORY" && "$REPOSITORY" != *@* && "$REPOSITORY" != *[[:space:]]* ]] || { echo "invalid repository: $REPOSITORY" >&2; exit 2; }
[[ "$SMALL_PADDING_MIB" =~ ^[0-9]+$ ]] || { echo "--small-padding-mib must be non-negative" >&2; exit 2; }
[[ "$LARGE_PADDING_MIB" =~ ^[1-9][0-9]*$ ]] || { echo "--large-padding-mib must be positive" >&2; exit 2; }
(( SMALL_PADDING_MIB <= 8192 )) || { echo "--small-padding-mib cannot exceed 8192" >&2; exit 2; }
(( LARGE_PADDING_MIB <= 8192 )) || { echo "--large-padding-mib cannot exceed 8192" >&2; exit 2; }
(( LARGE_PADDING_MIB > SMALL_PADDING_MIB )) || { echo "large padding must exceed small padding" >&2; exit 2; }
[[ -n "$PLATFORM" ]] || { echo "--platform cannot be empty" >&2; exit 2; }

cd "$PROJECT_ROOT"
GIT_COMMIT="$(git rev-parse HEAD)"
GIT_SHORT="$(git rev-parse --short=12 HEAD)"
BUILD_DATE="$(git show -s --format=%cI HEAD)"
SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
SOURCE_STATE=clean
TAG_SUFFIX=""
PADDING_SOURCE="$GIT_COMMIT"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  SOURCE_STATE=dirty
  [[ "$ALLOW_DIRTY" == true ]] || { echo "Git worktree is dirty; commit changes or pass --allow-dirty for a local-only development build" >&2; exit 1; }
  [[ "$PUSH" == false ]] || { echo "refusing to push images built from a dirty worktree" >&2; exit 1; }
  TAG_SUFFIX="-dirty"
  PADDING_SOURCE="${GIT_COMMIT}/dirty-local"
fi

: "${SMALL_TAG:=e01-${GIT_SHORT}-small-${SMALL_PADDING_MIB}mib${TAG_SUFFIX}}"
: "${LARGE_TAG:=e01-${GIT_SHORT}-large-${LARGE_PADDING_MIB}mib${TAG_SUFFIX}}"
SMALL_REF="${REPOSITORY}:${SMALL_TAG}"
LARGE_REF="${REPOSITORY}:${LARGE_TAG}"

build_variant() {
  local ref="$1" padding_mib="$2" variant="$3"
  docker build --platform "$PLATFORM" \
    --provenance=false \
    --sbom=false \
    --file examples/smoke-app/Dockerfile \
    --tag "$ref" \
    --build-arg "VERSION=e01-${GIT_SHORT}" \
    --build-arg "COMMIT=${GIT_COMMIT}" \
    --build-arg "BUILD_DATE=${BUILD_DATE}" \
    --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
    --build-arg "E01_PADDING_MIB=${padding_mib}" \
    --build-arg "E01_PADDING_SEED=e01/v1/${PADDING_SOURCE}/${variant}" \
    .
}

echo "Building small E01 image: ${SMALL_REF}" >&2
build_variant "$SMALL_REF" "$SMALL_PADDING_MIB" "small-${SMALL_PADDING_MIB}mib"
echo "Building large E01 image: ${LARGE_REF}" >&2
build_variant "$LARGE_REF" "$LARGE_PADDING_MIB" "large-${LARGE_PADDING_MIB}mib"

SMALL_ID="$(docker image inspect "$SMALL_REF" --format '{{.Id}}')"
LARGE_ID="$(docker image inspect "$LARGE_REF" --format '{{.Id}}')"
SMALL_SIZE="$(docker image inspect "$SMALL_REF" --format '{{.Size}}')"
LARGE_SIZE="$(docker image inspect "$LARGE_REF" --format '{{.Size}}')"
SMALL_APP_LAYER="$(docker image inspect "$SMALL_REF" --format '{{range .RootFS.Layers}}{{println .}}{{end}}' | awk 'NF { previous = last; last = $0 } END { print previous }')"
LARGE_APP_LAYER="$(docker image inspect "$LARGE_REF" --format '{{range .RootFS.Layers}}{{println .}}{{end}}' | awk 'NF { previous = last; last = $0 } END { print previous }')"
SMALL_PADDING_LAYER="$(docker image inspect "$SMALL_REF" --format '{{range .RootFS.Layers}}{{println .}}{{end}}' | awk 'NF { last = $0 } END { print last }')"
LARGE_PADDING_LAYER="$(docker image inspect "$LARGE_REF" --format '{{range .RootFS.Layers}}{{println .}}{{end}}' | awk 'NF { last = $0 } END { print last }')"
[[ -n "$SMALL_APP_LAYER" && "$SMALL_APP_LAYER" == "$LARGE_APP_LAYER" ]] || {
  echo "small and large variants do not share the same smoke-app layer" >&2
  exit 1
}
[[ -n "$SMALL_PADDING_LAYER" && -n "$LARGE_PADDING_LAYER" && "$SMALL_PADDING_LAYER" != "$LARGE_PADDING_LAYER" ]] || {
  echo "small and large variants unexpectedly share the padding layer" >&2
  exit 1
}
EXPECTED_DELTA=$(((LARGE_PADDING_MIB - SMALL_PADDING_MIB) * 1024 * 1024))
ACTUAL_DELTA=$((LARGE_SIZE - SMALL_SIZE))
(( ACTUAL_DELTA >= EXPECTED_DELTA )) || {
  echo "large image delta ${ACTUAL_DELTA} is smaller than requested padding ${EXPECTED_DELTA}" >&2
  exit 1
}

compressed_archive_size() {
  local ref="$1"
  docker image save "$ref" | gzip -1 -c | wc -c | tr -d '[:space:]'
}

SMALL_COMPRESSED_SIZE="$(compressed_archive_size "$SMALL_REF")"
LARGE_COMPRESSED_SIZE="$(compressed_archive_size "$LARGE_REF")"
COMPRESSED_DELTA=$((LARGE_COMPRESSED_SIZE - SMALL_COMPRESSED_SIZE))
MIN_COMPRESSED_DELTA=$((EXPECTED_DELTA * 98 / 100))
(( COMPRESSED_DELTA >= MIN_COMPRESSED_DELTA )) || {
  echo "compressed image delta ${COMPRESSED_DELTA} is below 98% of requested padding delta ${EXPECTED_DELTA}" >&2
  exit 1
}

SMALL_IMMUTABLE=""
LARGE_IMMUTABLE=""
if [[ "$PUSH" == true ]]; then
  docker push "$SMALL_REF"
  docker push "$LARGE_REF"
  SMALL_IMMUTABLE="$(docker image inspect "$SMALL_REF" --format '{{range .RepoDigests}}{{println .}}{{end}}' | awk -v prefix="${REPOSITORY}@" 'index($0,prefix)==1 {print; exit}')"
  LARGE_IMMUTABLE="$(docker image inspect "$LARGE_REF" --format '{{range .RepoDigests}}{{println .}}{{end}}' | awk -v prefix="${REPOSITORY}@" 'index($0,prefix)==1 {print; exit}')"
  [[ "$SMALL_IMMUTABLE" =~ @sha256:[0-9a-f]{64}$ && "$LARGE_IMMUTABLE" =~ @sha256:[0-9a-f]{64}$ ]] || {
    echo "push completed but immutable repository digests could not be resolved" >&2
    exit 1
  }
fi

emit_metadata() {
  printf 'E01_IMAGE_BUILD_COMMIT=%q\n' "$GIT_COMMIT"
  printf 'E01_IMAGE_SOURCE_STATE=%q\n' "$SOURCE_STATE"
  printf 'E01_IMAGE_PLATFORM=%q\n' "$PLATFORM"
  printf 'E01_GO_BUILD_BASE=%q\n' "golang:1.23-bookworm@sha256:167053a2bb901972bf2c1611f8f52c44d5fe7e762e5cab213708d82c421614db"
  printf 'E01_RUNTIME_BASE=%q\n' "gcr.io/distroless/static-debian12:nonroot@sha256:f5b485ea962d9bd1186b2f6b3a061191539b905b82ec395de78cbfae51f20e35"
  printf 'E01_SMALL_LOCAL_REF=%q\n' "$SMALL_REF"
  printf 'E01_SMALL_IMAGE_ID=%q\n' "$SMALL_ID"
  printf 'E01_SMALL_APP_LAYER_DIFF_ID=%q\n' "$SMALL_APP_LAYER"
  printf 'E01_SMALL_PADDING_LAYER_DIFF_ID=%q\n' "$SMALL_PADDING_LAYER"
  printf 'E01_SMALL_SIZE_BYTES=%q\n' "$SMALL_SIZE"
  printf 'E01_SMALL_COMPRESSED_ARCHIVE_BYTES=%q\n' "$SMALL_COMPRESSED_SIZE"
  printf 'E01_SMALL_PADDING_MIB=%q\n' "$SMALL_PADDING_MIB"
  printf 'E01_SMALL_PADDING_SEED=%q\n' "e01/v1/${PADDING_SOURCE}/small-${SMALL_PADDING_MIB}mib"
  printf 'E01_LARGE_LOCAL_REF=%q\n' "$LARGE_REF"
  printf 'E01_LARGE_IMAGE_ID=%q\n' "$LARGE_ID"
  printf 'E01_LARGE_APP_LAYER_DIFF_ID=%q\n' "$LARGE_APP_LAYER"
  printf 'E01_LARGE_PADDING_LAYER_DIFF_ID=%q\n' "$LARGE_PADDING_LAYER"
  printf 'E01_LARGE_SIZE_BYTES=%q\n' "$LARGE_SIZE"
  printf 'E01_LARGE_COMPRESSED_ARCHIVE_BYTES=%q\n' "$LARGE_COMPRESSED_SIZE"
  printf 'E01_LARGE_PADDING_MIB=%q\n' "$LARGE_PADDING_MIB"
  printf 'E01_LARGE_PADDING_SEED=%q\n' "e01/v1/${PADDING_SOURCE}/large-${LARGE_PADDING_MIB}mib"
  if [[ "$PUSH" == true ]]; then
    printf 'E01_SMALL_IMAGE=%q\n' "$SMALL_IMMUTABLE"
    printf 'E01_LARGE_IMAGE=%q\n' "$LARGE_IMMUTABLE"
  fi
}

if [[ -n "$METADATA_FILE" ]]; then
  umask 077
  mkdir -p "$(dirname "$METADATA_FILE")"
  emit_metadata >"$METADATA_FILE"
  echo "Build metadata: ${METADATA_FILE}" >&2
else
  emit_metadata
fi
