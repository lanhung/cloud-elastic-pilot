#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

STACK_REPOSITORY="${E09_STACK_IMAGE_REPOSITORY:-hooke/e09-stack}"
PROBE_REPOSITORY="${E09_PROBE_IMAGE_REPOSITORY:-hooke/e09-probe}"
PLATFORM="${E09_IMAGE_PLATFORM:-linux/amd64}"
CUDA_DEVEL_IMAGE="${E09_CUDA_DEVEL_IMAGE:-}"
CUDA_RUNTIME_IMAGE="${E09_CUDA_RUNTIME_IMAGE:-}"
TAG=""
METADATA_FILE=""
PUSH=false
ALLOW_DIRTY=false

usage() {
  cat <<'USAGE'
Usage: build-e09-images.sh [options]

Build the E09 Hooke collector stack and real CUDA probe images. Both images
remain local unless --push is explicitly supplied.

Options:
  --stack-repository REPO  Hooke stack repository
  --probe-repository REPO  CUDA probe repository
  --cuda-devel-image REF   Immutable CUDA devel base (repository@sha256:...)
  --cuda-runtime-image REF Immutable CUDA runtime base (repository@sha256:...)
  --platform PLATFORM      Target platform (default: linux/amd64)
  --tag TAG                Override the generated source tag
  --metadata FILE          Write shell-compatible build metadata
  --push                   Push both images and emit immutable digests
  --allow-dirty            Permit local-only builds from a dirty worktree
  -h, --help               Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-repository) [[ $# -ge 2 ]] || { echo "--stack-repository requires a value" >&2; exit 2; }; STACK_REPOSITORY="$2"; shift 2 ;;
    --probe-repository) [[ $# -ge 2 ]] || { echo "--probe-repository requires a value" >&2; exit 2; }; PROBE_REPOSITORY="$2"; shift 2 ;;
    --cuda-devel-image) [[ $# -ge 2 ]] || { echo "--cuda-devel-image requires a value" >&2; exit 2; }; CUDA_DEVEL_IMAGE="$2"; shift 2 ;;
    --cuda-runtime-image) [[ $# -ge 2 ]] || { echo "--cuda-runtime-image requires a value" >&2; exit 2; }; CUDA_RUNTIME_IMAGE="$2"; shift 2 ;;
    --platform) [[ $# -ge 2 ]] || { echo "--platform requires a value" >&2; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --tag) [[ $# -ge 2 ]] || { echo "--tag requires a value" >&2; exit 2; }; TAG="$2"; shift 2 ;;
    --metadata) [[ $# -ge 2 ]] || { echo "--metadata requires a value" >&2; exit 2; }; METADATA_FILE="$2"; shift 2 ;;
    --push) PUSH=true; shift ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command in docker git awk; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "missing required command: $command" >&2
    exit 1
  }
done
docker buildx version >/dev/null 2>&1 || {
  echo "Docker Buildx is required" >&2
  exit 1
}

valid_repository() {
  [[ -n "$1" && "$1" != *@* && "$1" != *[[:space:]]* ]]
}
immutable_image() {
  [[ "$1" =~ ^[^[:space:]@]+@sha256:[0-9a-fA-F]{64}$ ]]
}
valid_repository "$STACK_REPOSITORY" || {
  echo "invalid stack repository: $STACK_REPOSITORY" >&2
  exit 2
}
valid_repository "$PROBE_REPOSITORY" || {
  echo "invalid probe repository: $PROBE_REPOSITORY" >&2
  exit 2
}
[[ "$STACK_REPOSITORY" != "$PROBE_REPOSITORY" ]] || {
  echo "stack and probe repositories must be distinct" >&2
  exit 2
}
immutable_image "$CUDA_DEVEL_IMAGE" || {
  echo "--cuda-devel-image must be an immutable repository@sha256 reference" >&2
  exit 2
}
immutable_image "$CUDA_RUNTIME_IMAGE" || {
  echo "--cuda-runtime-image must be an immutable repository@sha256 reference" >&2
  exit 2
}
[[ "$PLATFORM" =~ ^linux/(amd64|arm64)$ ]] || {
  echo "--platform must be linux/amd64 or linux/arm64" >&2
  exit 2
}

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
    echo "refusing to push E09 images built from a dirty worktree" >&2
    exit 1
  }
  TAG_SUFFIX="-dirty"
fi

: "${TAG:=e09-${GIT_SHORT}${TAG_SUFFIX}}"
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || {
  echo "invalid tag: $TAG" >&2
  exit 2
}
STACK_LOCAL_REF="${STACK_REPOSITORY}:${TAG}"
PROBE_LOCAL_REF="${PROBE_REPOSITORY}:${TAG}"

echo "Building E09 stack image: ${STACK_LOCAL_REF}" >&2
docker build --platform "$PLATFORM" \
  --provenance=false \
  --sbom=false \
  --file examples/e09-gpu-dra-mig/stack.Dockerfile \
  --tag "$STACK_LOCAL_REF" \
  --build-arg "VERSION=e09-${GIT_SHORT}" \
  --build-arg "COMMIT=${GIT_COMMIT}" \
  --build-arg "BUILD_DATE=${BUILD_DATE}" \
  --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
  .

echo "Building E09 CUDA probe image: ${PROBE_LOCAL_REF}" >&2
docker build --platform "$PLATFORM" \
  --provenance=false \
  --sbom=false \
  --file examples/e09-gpu-dra-mig/Dockerfile \
  --tag "$PROBE_LOCAL_REF" \
  --build-arg "CUDA_DEVEL_IMAGE=${CUDA_DEVEL_IMAGE}" \
  --build-arg "CUDA_RUNTIME_IMAGE=${CUDA_RUNTIME_IMAGE}" \
  --build-arg "VERSION=e09-${GIT_SHORT}" \
  --build-arg "COMMIT=${GIT_COMMIT}" \
  --build-arg "BUILD_DATE=${BUILD_DATE}" \
  .

STACK_IMAGE_ID="$(docker image inspect "$STACK_LOCAL_REF" --format '{{.Id}}')"
PROBE_IMAGE_ID="$(docker image inspect "$PROBE_LOCAL_REF" --format '{{.Id}}')"
STACK_IMAGE_SIZE_BYTES="$(docker image inspect "$STACK_LOCAL_REF" --format '{{.Size}}')"
PROBE_IMAGE_SIZE_BYTES="$(docker image inspect "$PROBE_LOCAL_REF" --format '{{.Size}}')"
for image in "$STACK_LOCAL_REF" "$PROBE_LOCAL_REF"; do
  label_commit="$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  [[ "$label_commit" == "$GIT_COMMIT" ]] || {
    echo "image revision label does not match source commit: $image" >&2
    exit 1
  }
done

resolve_digest() {
  local repository="$1" local_ref="$2"
  docker image inspect "$local_ref" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' |
    awk -v prefix="${repository}@" 'index($0,prefix)==1 {print; exit}'
}

STACK_IMMUTABLE_REF=""
PROBE_IMMUTABLE_REF=""
if [[ "$PUSH" == true ]]; then
  docker push "$STACK_LOCAL_REF"
  docker push "$PROBE_LOCAL_REF"
  STACK_IMMUTABLE_REF="$(resolve_digest "$STACK_REPOSITORY" "$STACK_LOCAL_REF")"
  PROBE_IMMUTABLE_REF="$(resolve_digest "$PROBE_REPOSITORY" "$PROBE_LOCAL_REF")"
  immutable_image "$STACK_IMMUTABLE_REF" || {
    echo "push completed but the immutable E09 stack digest was not resolved" >&2
    exit 1
  }
  immutable_image "$PROBE_IMMUTABLE_REF" || {
    echo "push completed but the immutable E09 probe digest was not resolved" >&2
    exit 1
  }
fi

emit_metadata() {
  printf 'E09_IMAGE_BUILD_COMMIT=%q\n' "$GIT_COMMIT"
  printf 'E09_IMAGE_SOURCE_STATE=%q\n' "$SOURCE_STATE"
  printf 'E09_IMAGE_PLATFORM=%q\n' "$PLATFORM"
  printf 'E09_STACK_LOCAL_REF=%q\n' "$STACK_LOCAL_REF"
  printf 'E09_PROBE_LOCAL_REF=%q\n' "$PROBE_LOCAL_REF"
  printf 'E09_STACK_IMAGE_ID=%q\n' "$STACK_IMAGE_ID"
  printf 'E09_PROBE_IMAGE_ID=%q\n' "$PROBE_IMAGE_ID"
  printf 'E09_STACK_IMAGE_SIZE_BYTES=%q\n' "$STACK_IMAGE_SIZE_BYTES"
  printf 'E09_PROBE_IMAGE_SIZE_BYTES=%q\n' "$PROBE_IMAGE_SIZE_BYTES"
  printf 'E09_CUDA_DEVEL_IMAGE=%q\n' "$CUDA_DEVEL_IMAGE"
  printf 'E09_CUDA_RUNTIME_IMAGE=%q\n' "$CUDA_RUNTIME_IMAGE"
  printf 'E09_GO_BUILD_BASE=%q\n' "golang:1.23-bookworm@sha256:167053a2bb901972bf2c1611f8f52c44d5fe7e762e5cab213708d82c421614db"
  printf 'E09_STACK_RUNTIME_BASE=%q\n' "gcr.io/distroless/static-debian12:nonroot@sha256:f5b485ea962d9bd1186b2f6b3a061191539b905b82ec395de78cbfae51f20e35"
  if [[ "$PUSH" == true ]]; then
    printf 'E09_STACK_IMAGE=%q\n' "$STACK_IMMUTABLE_REF"
    printf 'E09_PROBE_IMAGE=%q\n' "$PROBE_IMMUTABLE_REF"
  fi
}

if [[ -n "$METADATA_FILE" ]]; then
  umask 077
  mkdir -p "$(dirname "$METADATA_FILE")"
  emit_metadata >"$METADATA_FILE"
  echo "E09 image metadata: ${METADATA_FILE}" >&2
else
  emit_metadata
fi
