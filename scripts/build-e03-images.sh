#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REPOSITORY="${E03_IMAGE_REPOSITORY:-hooke/e03}"
SIZES_MIB="${E03_IMAGE_SIZES_MIB:-100,500,1024}"
IMAGES_PER_SIZE="${E03_IMAGES_PER_SIZE:-4}"
PLATFORM="${E03_IMAGE_PLATFORM:-linux/amd64}"
METADATA_FILE=""
PUSH=false
ALLOW_DIRTY=false

usage() {
  cat <<'USAGE'
Usage: build-e03-images.sh [options]

Build deterministic E03 smoke-app images. For every size, four distinct
padding layers are generated so concurrent cells perform independent pulls
instead of sharing one digest. Images remain local unless --push is supplied.

Options:
  --repository REPO       Image repository (default: hooke/e03)
  --sizes-mib CSV         Frozen size levels (default: 100,500,1024)
  --images-per-size N     Distinct images per size (must be 4)
  --platform PLATFORM     Target platform (default: linux/amd64)
  --metadata FILE         Write shell-compatible metadata
  --push                  Push images and emit immutable repo@sha256 refs
  --allow-dirty           Permit local-only builds from a dirty worktree
  -h, --help              Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) [[ $# -ge 2 ]] || { echo "--repository requires a value" >&2; exit 2; }; REPOSITORY="$2"; shift 2 ;;
    --sizes-mib) [[ $# -ge 2 ]] || { echo "--sizes-mib requires a value" >&2; exit 2; }; SIZES_MIB="$2"; shift 2 ;;
    --images-per-size) [[ $# -ge 2 ]] || { echo "--images-per-size requires a value" >&2; exit 2; }; IMAGES_PER_SIZE="$2"; shift 2 ;;
    --platform) [[ $# -ge 2 ]] || { echo "--platform requires a value" >&2; exit 2; }; PLATFORM="$2"; shift 2 ;;
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
[[ -n "$REPOSITORY" && "$REPOSITORY" != *@* && "$REPOSITORY" != *[[:space:]]* ]] || {
  echo "invalid repository: $REPOSITORY" >&2
  exit 2
}
[[ "$SIZES_MIB" == "100,500,1024" ]] || {
  echo "--sizes-mib must preserve the frozen E03 levels: 100,500,1024" >&2
  exit 2
}
[[ "$IMAGES_PER_SIZE" == 4 ]] || {
  echo "--images-per-size must be 4 for the E03 concurrency factor" >&2
  exit 2
}
[[ -n "$PLATFORM" ]] || { echo "--platform cannot be empty" >&2; exit 2; }

IFS=',' read -r -a SIZE_LEVELS <<<"$SIZES_MIB"
for size in "${SIZE_LEVELS[@]}"; do
  [[ "$size" =~ ^[1-9][0-9]*$ ]] || { echo "invalid size: $size" >&2; exit 2; }
  (( size <= 8192 )) || { echo "size cannot exceed 8192 MiB: $size" >&2; exit 2; }
done

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
  [[ "$ALLOW_DIRTY" == true ]] || {
    echo "Git worktree is dirty; commit changes or pass --allow-dirty for a local-only build" >&2
    exit 1
  }
  [[ "$PUSH" == false ]] || {
    echo "refusing to push images built from a dirty worktree" >&2
    exit 1
  }
  TAG_SUFFIX="-dirty"
  PADDING_SOURCE="${GIT_COMMIT}/dirty-local"
fi

declare -A LOCAL_REF IMAGE_ID APP_LAYER PADDING_LAYER SIZE_BYTES
declare -A COMPRESSED_BYTES IMMUTABLE_REF PADDING_SEED PADDING_BYTES
EXPECTED_APP_LAYER=""
declare -A OBSERVED_PADDING_LAYERS=()
SIZE_TOLERANCE_BYTES=4096
MAX_CALIBRATION_ATTEMPTS=6

compressed_archive_size() {
  local ref="$1"
  docker image save "$ref" | gzip -1 -c | wc -c | tr -d '[:space:]'
}

CALIBRATION_REF="${REPOSITORY}:e03-${GIT_SHORT}-calibration-0b${TAG_SUFFIX}"
CALIBRATION_SEED="e03/v1/${PADDING_SOURCE}/calibration-0b"
echo "Building zero-padding E03 calibration image: ${CALIBRATION_REF}" >&2
docker build --platform "$PLATFORM" \
  --provenance=false \
  --sbom=false \
  --file examples/smoke-app/Dockerfile \
  --tag "$CALIBRATION_REF" \
  --build-arg "VERSION=e03-${GIT_SHORT}" \
  --build-arg "COMMIT=${GIT_COMMIT}" \
  --build-arg "BUILD_DATE=${BUILD_DATE}" \
  --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
  --build-arg "E01_PADDING_MIB=0" \
  --build-arg "E01_PADDING_BYTES=0" \
  --build-arg "E01_PADDING_SEED=${CALIBRATION_SEED}" \
  .
CALIBRATION_SIZE_BYTES="$(docker image inspect "$CALIBRATION_REF" --format '{{.Size}}')"
[[ "$CALIBRATION_SIZE_BYTES" =~ ^[1-9][0-9]*$ ]] || {
  echo "could not resolve calibration image size" >&2
  exit 1
}

build_variant() {
  local ref="$1" seed="$2" padding_bytes="$3"
  docker build --platform "$PLATFORM" \
    --provenance=false \
    --sbom=false \
    --file examples/smoke-app/Dockerfile \
    --tag "$ref" \
    --build-arg "VERSION=e03-${GIT_SHORT}" \
    --build-arg "COMMIT=${GIT_COMMIT}" \
    --build-arg "BUILD_DATE=${BUILD_DATE}" \
    --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
    --build-arg "E01_PADDING_MIB=0" \
    --build-arg "E01_PADDING_BYTES=${padding_bytes}" \
    --build-arg "E01_PADDING_SEED=${seed}" \
    .
}

CALIBRATED_PADDING_BYTES=""
calibrate_padding() {
  local size="$1" target_size_bytes="$2"
  local ref seed padding_bytes actual_size error absolute_error attempt
  ref="${REPOSITORY}:e03-${GIT_SHORT}-${size}mib-p1${TAG_SUFFIX}"
  seed="e03/v1/${PADDING_SOURCE}/${size}mib/p1"
  (( CALIBRATION_SIZE_BYTES < target_size_bytes )) || {
    echo "calibration image is not smaller than ${size} MiB target" >&2
    return 1
  }
  padding_bytes=$((target_size_bytes - CALIBRATION_SIZE_BYTES))
  for ((attempt=1; attempt<=MAX_CALIBRATION_ATTEMPTS; attempt++)); do
    echo "Calibrating E03 ${size} MiB padding, attempt ${attempt}: ${padding_bytes} bytes" >&2
    build_variant "$ref" "$seed" "$padding_bytes"
    actual_size="$(docker image inspect "$ref" --format '{{.Size}}')"
    [[ "$actual_size" =~ ^[1-9][0-9]*$ ]] || {
      echo "could not resolve calibrated image size for ${ref}" >&2
      return 1
    }
    error=$((actual_size - target_size_bytes))
    absolute_error="$error"
    (( absolute_error < 0 )) && absolute_error=$((-absolute_error))
    echo "E03 ${size} MiB calibration: actual=${actual_size}, target=${target_size_bytes}, error=${error}" >&2
    if (( absolute_error <= SIZE_TOLERANCE_BYTES )); then
      CALIBRATED_PADDING_BYTES="$padding_bytes"
      return 0
    fi
    padding_bytes=$((padding_bytes - error))
    (( padding_bytes > 0 )) || {
      echo "calibrated padding became non-positive for ${size} MiB" >&2
      return 1
    }
  done
  echo "E03 ${size} MiB padding did not converge after ${MAX_CALIBRATION_ATTEMPTS} attempts" >&2
  return 1
}

for size in "${SIZE_LEVELS[@]}"; do
  target_size_bytes=$((size * 1024 * 1024))
  calibrate_padding "$size" "$target_size_bytes" || exit 1
  padding_bytes="$CALIBRATED_PADDING_BYTES"

  group_calibrated=false
  for ((attempt=1; attempt<=MAX_CALIBRATION_ATTEMPTS; attempt++)); do
    min_error=0
    max_error=0
    first_error=true
    for ((slot=1; slot<=IMAGES_PER_SIZE; slot++)); do
      key="${size}_${slot}"
      ref="${REPOSITORY}:e03-${GIT_SHORT}-${size}mib-p${slot}${TAG_SUFFIX}"
      seed="e03/v1/${PADDING_SOURCE}/${size}mib/p${slot}"
      echo "Building E03 image ${size} MiB slot ${slot}: ${ref}" >&2
      build_variant "$ref" "$seed" "$padding_bytes"
      actual_size="$(docker image inspect "$ref" --format '{{.Size}}')"
      [[ "$actual_size" =~ ^[1-9][0-9]*$ ]] || {
        echo "could not resolve image size for ${ref}" >&2
        exit 1
      }
      error=$((actual_size - target_size_bytes))
      if [[ "$first_error" == true ]]; then
        min_error="$error"
        max_error="$error"
        first_error=false
      else
        (( error < min_error )) && min_error="$error"
        (( error > max_error )) && max_error="$error"
      fi
    done
    if (( min_error >= -SIZE_TOLERANCE_BYTES && max_error <= SIZE_TOLERANCE_BYTES )); then
      group_calibrated=true
      break
    fi
    (( max_error - min_error <= 2 * SIZE_TOLERANCE_BYTES )) || {
      echo "same-size E03 variants cannot share one padding within tolerance: ${size} MiB errors ${min_error}..${max_error}" >&2
      exit 1
    }
    center_error=$(((min_error + max_error) / 2))
    if (( center_error == 0 )); then
      if (( max_error > SIZE_TOLERANCE_BYTES )); then
        center_error=1
      else
        center_error=-1
      fi
    fi
    padding_bytes=$((padding_bytes - center_error))
    (( padding_bytes > 0 )) || {
      echo "group-calibrated padding became non-positive for ${size} MiB" >&2
      exit 1
    }
    echo "Re-centering E03 ${size} MiB variants by ${center_error} bytes" >&2
  done
  [[ "$group_calibrated" == true ]] || {
    echo "E03 ${size} MiB variants did not converge on one padding size" >&2
    exit 1
  }
  for ((slot=1; slot<=IMAGES_PER_SIZE; slot++)); do
    key="${size}_${slot}"
    ref="${REPOSITORY}:e03-${GIT_SHORT}-${size}mib-p${slot}${TAG_SUFFIX}"
    seed="e03/v1/${PADDING_SOURCE}/${size}mib/p${slot}"
    LOCAL_REF["$key"]="$ref"
    PADDING_SEED["$key"]="$seed"
    PADDING_BYTES["$key"]="$padding_bytes"
    IMAGE_ID["$key"]="$(docker image inspect "$ref" --format '{{.Id}}')"
    SIZE_BYTES["$key"]="$(docker image inspect "$ref" --format '{{.Size}}')"
    APP_LAYER["$key"]="$(docker image inspect "$ref" --format '{{range .RootFS.Layers}}{{println .}}{{end}}' | awk 'NF { previous = last; last = $0 } END { print previous }')"
    PADDING_LAYER["$key"]="$(docker image inspect "$ref" --format '{{range .RootFS.Layers}}{{println .}}{{end}}' | awk 'NF { last = $0 } END { print last }')"
    [[ -n "${APP_LAYER[$key]}" && -n "${PADDING_LAYER[$key]}" ]] || {
      echo "could not resolve app/padding layers for ${ref}" >&2
      exit 1
    }
    if [[ -z "$EXPECTED_APP_LAYER" ]]; then
      EXPECTED_APP_LAYER="${APP_LAYER[$key]}"
    elif [[ "${APP_LAYER[$key]}" != "$EXPECTED_APP_LAYER" ]]; then
      echo "E03 variants do not share one smoke-app layer" >&2
      exit 1
    fi
    if [[ -n "${OBSERVED_PADDING_LAYERS[${PADDING_LAYER[$key]}]:-}" ]]; then
      echo "E03 variants unexpectedly share padding layer ${PADDING_LAYER[$key]}" >&2
      exit 1
    fi
    OBSERVED_PADDING_LAYERS["${PADDING_LAYER[$key]}"]="$key"

    size_delta=$((SIZE_BYTES[$key] - target_size_bytes))
    (( size_delta < 0 )) && size_delta=$((-size_delta))
    (( size_delta <= SIZE_TOLERANCE_BYTES )) || {
      echo "image ${ref} size ${SIZE_BYTES[$key]} differs from target ${target_size_bytes} by more than ${SIZE_TOLERANCE_BYTES} bytes" >&2
      exit 1
    }
    COMPRESSED_BYTES["$key"]="$(compressed_archive_size "$ref")"
    minimum_compressed=$((padding_bytes * 98 / 100))
    (( ${COMPRESSED_BYTES[$key]} >= minimum_compressed )) || {
      echo "compressed image ${ref} is below the incompressible-padding floor" >&2
      exit 1
    }

  done
done

if [[ "$PUSH" == true ]]; then
  for size in "${SIZE_LEVELS[@]}"; do
    for ((slot=1; slot<=IMAGES_PER_SIZE; slot++)); do
      key="${size}_${slot}"
      ref="${LOCAL_REF[$key]}"
      docker push "$ref"
      immutable="$(docker image inspect "$ref" --format '{{range .RepoDigests}}{{println .}}{{end}}' | awk -v prefix="${REPOSITORY}@" 'index($0,prefix)==1 {print; exit}')"
      [[ "$immutable" =~ @sha256:[0-9a-f]{64}$ ]] || {
        echo "push completed but immutable digest could not be resolved for ${ref}" >&2
        exit 1
      }
      IMMUTABLE_REF["$key"]="$immutable"
    done
  done
fi

emit_metadata() {
  printf 'E03_IMAGE_BUILD_COMMIT=%q\n' "$GIT_COMMIT"
  printf 'E03_IMAGE_SOURCE_STATE=%q\n' "$SOURCE_STATE"
  printf 'E03_IMAGE_PLATFORM=%q\n' "$PLATFORM"
  printf 'E03_IMAGE_REPOSITORY=%q\n' "$REPOSITORY"
  printf 'E03_IMAGE_SIZE_LEVELS_MIB=%q\n' "$SIZES_MIB"
  printf 'E03_IMAGES_PER_SIZE=%q\n' "$IMAGES_PER_SIZE"
  printf 'E03_CALIBRATION_SIZE_BYTES=%q\n' "$CALIBRATION_SIZE_BYTES"
  printf 'E03_GO_BUILD_BASE=%q\n' "golang:1.23-bookworm@sha256:167053a2bb901972bf2c1611f8f52c44d5fe7e762e5cab213708d82c421614db"
  printf 'E03_RUNTIME_BASE=%q\n' "gcr.io/distroless/static-debian12:nonroot@sha256:f5b485ea962d9bd1186b2f6b3a061191539b905b82ec395de78cbfae51f20e35"
  for size in "${SIZE_LEVELS[@]}"; do
    for ((slot=1; slot<=IMAGES_PER_SIZE; slot++)); do
      key="${size}_${slot}"
      prefix="E03_IMAGE_${size}_P${slot}"
      printf '%s_LOCAL_REF=%q\n' "$prefix" "${LOCAL_REF[$key]}"
      printf '%s_IMAGE_ID=%q\n' "$prefix" "${IMAGE_ID[$key]}"
      printf '%s_APP_LAYER_DIFF_ID=%q\n' "$prefix" "${APP_LAYER[$key]}"
      printf '%s_PADDING_LAYER_DIFF_ID=%q\n' "$prefix" "${PADDING_LAYER[$key]}"
      printf '%s_SIZE_BYTES=%q\n' "$prefix" "${SIZE_BYTES[$key]}"
      printf '%s_COMPRESSED_ARCHIVE_BYTES=%q\n' "$prefix" "${COMPRESSED_BYTES[$key]}"
      printf '%s_TARGET_SIZE_MIB=%q\n' "$prefix" "$size"
      printf '%s_PADDING_BYTES=%q\n' "$prefix" "${PADDING_BYTES[$key]}"
      printf '%s_PADDING_SEED=%q\n' "$prefix" "${PADDING_SEED[$key]}"
      if [[ "$PUSH" == true ]]; then
        printf '%s=%q\n' "$prefix" "${IMMUTABLE_REF[$key]}"
      fi
    done
  done
}

if [[ -n "$METADATA_FILE" ]]; then
  umask 077
  mkdir -p "$(dirname "$METADATA_FILE")"
  emit_metadata >"$METADATA_FILE"
  echo "Build metadata: ${METADATA_FILE}" >&2
else
  emit_metadata
fi
