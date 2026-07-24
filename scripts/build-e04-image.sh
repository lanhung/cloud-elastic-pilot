#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REPOSITORY="${E04_IMAGE_REPOSITORY:-hooke/e04}"
PLATFORM="${E04_IMAGE_PLATFORM:-linux/amd64}"
TAG=""
METADATA_FILE=""
PUSH=false
ALLOW_DIRTY=false

usage() {
  cat <<'USAGE'
Usage: build-e04-image.sh [options]

Build the E04 Redis producer/worker image. The image remains local unless
--push is explicitly supplied.

Options:
  --repository REPO   Image repository (default: hooke/e04)
  --platform PLATFORM Target platform (default: linux/amd64)
  --tag TAG           Override the generated immutable source tag
  --metadata FILE     Write shell-compatible build metadata
  --push              Push and emit an immutable repository digest
  --allow-dirty       Permit a local-only build from a dirty worktree
  -h, --help          Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) [[ $# -ge 2 ]] || { echo "--repository requires a value" >&2; exit 2; }; REPOSITORY="$2"; shift 2 ;;
    --platform) [[ $# -ge 2 ]] || { echo "--platform requires a value" >&2; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --tag) [[ $# -ge 2 ]] || { echo "--tag requires a value" >&2; exit 2; }; TAG="$2"; shift 2 ;;
    --metadata) [[ $# -ge 2 ]] || { echo "--metadata requires a value" >&2; exit 2; }; METADATA_FILE="$2"; shift 2 ;;
    --push) PUSH=true; shift ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "Docker Buildx is required" >&2; exit 1; }
[[ -n "$REPOSITORY" && "$REPOSITORY" != *@* && "$REPOSITORY" != *[[:space:]]* ]] || {
  echo "invalid repository: $REPOSITORY" >&2
  exit 2
}
[[ -n "$PLATFORM" ]] || { echo "--platform cannot be empty" >&2; exit 2; }

cd "$PROJECT_ROOT"
GIT_COMMIT="$(git rev-parse HEAD)"
GIT_SHORT="$(git rev-parse --short=12 HEAD)"
BUILD_DATE="$(git show -s --format=%cI HEAD)"
SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
SOURCE_STATE=clean
TAG_SUFFIX=""
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  SOURCE_STATE=dirty
  [[ "$ALLOW_DIRTY" == true ]] || {
    echo "Git worktree is dirty; commit changes or pass --allow-dirty for a local-only development build" >&2
    exit 1
  }
  [[ "$PUSH" == false ]] || {
    echo "refusing to push an E04 image built from a dirty worktree" >&2
    exit 1
  }
  TAG_SUFFIX="-dirty"
fi

: "${TAG:=e04-${GIT_SHORT}${TAG_SUFFIX}}"
[[ "$TAG" != *[[:space:]]* && "$TAG" != *:* && "$TAG" != *@* ]] || {
  echo "invalid tag: $TAG" >&2
  exit 2
}
LOCAL_REF="${REPOSITORY}:${TAG}"

echo "Building E04 Redis workload image: ${LOCAL_REF}" >&2
docker build --platform "$PLATFORM" \
  --provenance=false \
  --sbom=false \
  --file examples/keda-redis-app/Dockerfile \
  --tag "$LOCAL_REF" \
  --build-arg "VERSION=e04-${GIT_SHORT}" \
  --build-arg "COMMIT=${GIT_COMMIT}" \
  --build-arg "BUILD_DATE=${BUILD_DATE}" \
  --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
  .

IMAGE_ID="$(docker image inspect "$LOCAL_REF" --format '{{.Id}}')"
IMAGE_SIZE_BYTES="$(docker image inspect "$LOCAL_REF" --format '{{.Size}}')"
LABEL_COMMIT="$(docker image inspect "$LOCAL_REF" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
[[ "$LABEL_COMMIT" == "$GIT_COMMIT" ]] || {
  echo "E04 image revision label does not match the source commit" >&2
  exit 1
}

IMMUTABLE_REF=""
if [[ "$PUSH" == true ]]; then
  docker push "$LOCAL_REF"
  IMMUTABLE_REF="$(docker image inspect "$LOCAL_REF" --format '{{range .RepoDigests}}{{println .}}{{end}}' | awk -v prefix="${REPOSITORY}@" 'index($0,prefix)==1 {print; exit}')"
  [[ "$IMMUTABLE_REF" =~ @sha256:[0-9a-f]{64}$ ]] || {
    echo "push completed but the immutable E04 repository digest was not resolved" >&2
    exit 1
  }
fi

emit_metadata() {
  printf 'E04_APP_IMAGE_BUILD_COMMIT=%q\n' "$GIT_COMMIT"
  printf 'E04_APP_IMAGE_SOURCE_STATE=%q\n' "$SOURCE_STATE"
  printf 'E04_APP_IMAGE_PLATFORM=%q\n' "$PLATFORM"
  printf 'E04_APP_LOCAL_REF=%q\n' "$LOCAL_REF"
  printf 'E04_APP_IMAGE_ID=%q\n' "$IMAGE_ID"
  printf 'E04_APP_IMAGE_SIZE_BYTES=%q\n' "$IMAGE_SIZE_BYTES"
  printf 'E04_GO_BUILD_BASE=%q\n' "golang:1.23-bookworm@sha256:167053a2bb901972bf2c1611f8f52c44d5fe7e762e5cab213708d82c421614db"
  printf 'E04_RUNTIME_BASE=%q\n' "gcr.io/distroless/static-debian12:nonroot@sha256:f5b485ea962d9bd1186b2f6b3a061191539b905b82ec395de78cbfae51f20e35"
  if [[ "$PUSH" == true ]]; then
    printf 'E04_APP_IMAGE=%q\n' "$IMMUTABLE_REF"
  fi
}

if [[ -n "$METADATA_FILE" ]]; then
  umask 077
  mkdir -p "$(dirname "$METADATA_FILE")"
  emit_metadata >"$METADATA_FILE"
  echo "E04 image metadata: ${METADATA_FILE}" >&2
else
  emit_metadata
fi
