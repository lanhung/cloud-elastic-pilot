#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

docker compose -f deploy/compose/docker-compose.yaml up --build -d mysql migrate ingester
until curl -fsS http://127.0.0.1:8080/readyz >/dev/null; do sleep 2; done

run_json="$(go run ./cmd/hookectl run create --api http://127.0.0.1:8080 --cluster local --name local-smoke --slo-seconds 30)"
echo "$run_json"
run_id="$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')"

echo "RUN_ID=$run_id"
echo "Use this ID when running the sample application or posting events."
