#!/usr/bin/env bash
set -Eeuo pipefail

CHART_URL="https://aliacs-app-catalog.oss-cn-hangzhou.aliyuncs.com/charts-incubator/ack-kube-queue-1.26.3.tgz"
CHART_SHA256="1d0c7979006394fe7e8eb0b62adb6730c70042c578ee82b30c1e259071ad9e5b"
KUBE_CONTEXT=""
NAMESPACE="kube-queue"
RELEASE="ack-kube-queue"
IMAGE_PREFIX="registry-cn-wulanchabu-vpc.ack.aliyuncs.com"
CHECK_ONLY=false

usage() {
  cat <<'USAGE'
Usage: install-ack-kube-queue-1263.sh --context CONTEXT [--check-only]

Installs the exact ACK Kube Queue 1.26.3 marketplace chart. The published
chart renders /manager for job-extensions, but its pinned image contains
/usr/bin/kube-queue-controllers. This installer verifies the chart archive,
applies that single version-scoped template correction in a temporary
directory, validates the rendered images/command, and performs a Helm
upgrade/install.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) [[ $# -ge 2 ]] || exit 2; KUBE_CONTEXT="$2"; shift 2 ;;
    --namespace) [[ $# -ge 2 ]] || exit 2; NAMESPACE="$2"; shift 2 ;;
    --release) [[ $# -ge 2 ]] || exit 2; RELEASE="$2"; shift 2 ;;
    --image-prefix) [[ $# -ge 2 ]] || exit 2; IMAGE_PREFIX="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { printf 'install-ack-kube-queue-1263: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

[[ -n "$KUBE_CONTEXT" ]] || die "--context is required"
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "invalid namespace"
[[ "$RELEASE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "invalid release"
[[ "$IMAGE_PREFIX" =~ ^[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] || die "invalid image prefix"
for command in curl helm kubectl python3 sha256sum tar mktemp; do
  require_cmd "$command"
done
kubectl --context "$KUBE_CONTEXT" config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1 || \
  die "kube context not found: ${KUBE_CONTEXT}"

WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

ARCHIVE="${WORK_DIR}/ack-kube-queue-1.26.3.tgz"
curl --fail --location --silent --show-error "$CHART_URL" --output "$ARCHIVE"
printf '%s  %s\n' "$CHART_SHA256" "$ARCHIVE" | sha256sum --check --status || \
  die "chart SHA-256 mismatch"
tar -xzf "$ARCHIVE" -C "$WORK_DIR"
CHART_DIR="${WORK_DIR}/ack-kube-queue"
[[ -f "${CHART_DIR}/Chart.yaml" && -f "${CHART_DIR}/templates/controller.yaml" ]] || \
  die "chart archive layout is invalid"

python3 - "${CHART_DIR}/templates/controller.yaml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
deployment = """kind: Deployment
metadata:
  name: job-extensions
"""
start = text.find(deployment)
if start < 0:
    raise SystemExit("job-extensions Deployment was not found")
end = text.find("\n---", start)
if end < 0:
    end = len(text)
section = text[start:end]
needle = "            - /manager"
if section.count(needle) != 1:
    raise SystemExit(
        f"expected one /manager command in job-extensions, got {section.count(needle)}"
    )
section = section.replace(
    needle, "            - /usr/bin/kube-queue-controllers", 1
)
path.write_text(text[:start] + section + text[end:], encoding="utf-8")
PY

VALUES=(
  --set-string "global.imagePrefix=${IMAGE_PREFIX}"
  --set-string "global.clusterProfile=Default"
  --set-string "global.clusterType=ManagedKubernetes"
)
helm lint "$CHART_DIR" "${VALUES[@]}" >/dev/null
RENDERED="${WORK_DIR}/rendered.yaml"
helm template "$RELEASE" "$CHART_DIR" --namespace "$NAMESPACE" "${VALUES[@]}" >"$RENDERED"
[[ "$(grep -c -- '/usr/bin/kube-queue-controllers' "$RENDERED")" == 1 ]] || \
  die "rendered job-extensions command is not uniquely corrected"
grep -q -- "${IMAGE_PREFIX}/acs/kube-queue:v1.3.2.1dca84f5" "$RENDERED" || \
  die "rendered kube-queue image is unexpected"
grep -q -- "${IMAGE_PREFIX}/acs/job-extensions:v1.3.2-aliyun-1dca84f5" "$RENDERED" || \
  die "rendered job-extensions image is unexpected"

if [[ "$CHECK_ONLY" == true ]]; then
  printf 'ACK Kube Queue 1.26.3 chart validation passed\n'
  exit 0
fi

helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --kube-context "$KUBE_CONTEXT" \
  --rollback-on-failure --wait --timeout 10m \
  "${VALUES[@]}"
