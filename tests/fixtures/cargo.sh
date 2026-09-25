#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 AND MIT
# SPDX-FileCopyrightText: 2026 Overture Maps
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for cargo. Checks each call's exact arguments, records the
# stage, working directory and visible credentials, then simulates the
# side effects publish-crate.sh depends on.

set -euo pipefail

manifest="$MOCK_EXPECT_MANIFEST"
case "${1:-}" in
  metadata)
    stage=metadata
    expected=(metadata --no-deps --format-version 1 --manifest-path "$manifest")
    ;;
  package)
    stage=package
    expected=(package --locked --manifest-path "$manifest")
    ;;
  publish)
    if [ "${2:-}" = "--dry-run" ]; then
      stage=dry-run
      expected=(publish --dry-run --no-verify --locked --registry crates-io
        --manifest-path "$manifest")
    else
      stage=publish
      expected=(publish --no-verify --locked --registry crates-io
        --manifest-path "$manifest")
    fi
    ;;
  *)
    echo "Unexpected cargo command: ${1:-}" >&2
    exit 90
    ;;
esac

printf '%s\n' "$stage" >> "$MOCK_CARGO_LOG"
printf '%s|%s|%s|%s|%s|%s\n' "$stage" "$(pwd -P)" \
  "${CARGO_REGISTRY_TOKEN-unset}" \
  "${CARGO_REGISTRIES_CRATES_IO_TOKEN-unset}" \
  "${ACTIONS_ID_TOKEN_REQUEST_TOKEN-unset}" \
  "${INPUT_REGISTRY_TOKEN-unset}" >> "$MOCK_CARGO_ENV"

[ "$#" -eq "${#expected[@]}" ] || exit 91
for argument in "${expected[@]}"; do
  [ "$1" = "$argument" ] || exit 92
  shift
done

if [ "${MOCK_FAIL_STAGE:-}" = "$stage" ]; then
  echo "Mock cargo $stage failed" >&2
  exit 42
fi

case "$stage" in
  metadata)
    if [ "${MOCK_INVALID_METADATA:-false}" = "true" ]; then
      # Valid package metadata, but no target_directory.
      jq -n --arg manifest "$manifest" \
        '{packages: [{name: "example-crate", version: "1.2.3",
          manifest_path: $manifest}]}'
      exit 0
    fi
    other_packages="[]"
    if [ "${MOCK_INCLUDE_OTHER_PACKAGE:-false}" = "true" ]; then
      other_packages='[{"name":"other-crate","version":"9.9.9",
        "manifest_path":"/workspace/other-crate/Cargo.toml"}]'
    fi
    jq -n --arg manifest "$manifest" --arg target "$MOCK_TARGET_DIRECTORY" \
      --argjson pkg "$(cat "$MOCK_MANIFEST_JSON")" \
      --argjson extra "$other_packages" \
      '{packages: ($extra + [($pkg + {manifest_path: $manifest})]),
        target_directory: $target}'
    ;;
  package)
    if [ "${MOCK_MISSING_PACKAGE:-false}" != "true" ]; then
      mkdir -p "$MOCK_TARGET_DIRECTORY/package"
      head -c "$MOCK_CRATE_SIZE" /dev/zero \
        > "$MOCK_TARGET_DIRECTORY/package/example-crate-1.2.3.crate"
    fi
    ;;
esac
