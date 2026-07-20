#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_config="${script_dir}/../configs/attribution-pilot.env"

has_config=false
for argument in "$@"; do
  if [[ "$argument" == "--config" ]]; then
    has_config=true
    break
  fi
done

if [[ "$has_config" == true ]]; then
  exec "${script_dir}/ack-first-smoke.sh" "$@"
fi
exec "${script_dir}/ack-first-smoke.sh" --config "$default_config" "$@"
