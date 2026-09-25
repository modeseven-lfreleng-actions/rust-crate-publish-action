#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 AND MIT
# SPDX-FileCopyrightText: 2026 Overture Maps
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Check, package, size-check and publish one crate to crates.io.
#
# Inputs arrive as INPUT_* environment variables (see action.yaml).
# Stages run in order, and the first failure stops the run:
#
#   Check inputs -> Read crate metadata -> Verify release tag
#   -> Package -> Check package size -> Dry-run publish -> Publish
#
# 'cargo package' compiles the packaged sources, which runs build
# scripts. It is the only stage that executes crate code, so the real
# publish passes --no-verify rather than compiling a second time with a
# credential present.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/job-summary.sh
source "$script_dir/job-summary.sh"

path_prefix="${INPUT_PATH_PREFIX:-.}"
manifest_path="${INPUT_MANIFEST_PATH:-Cargo.toml}"
release_tag="${INPUT_RELEASE_TAG:-}"
max_bytes="${INPUT_MAX_CRATE_SIZE_BYTES:-10485760}"
dry_run="${INPUT_DRY_RUN:-false}"
permit_fail="${INPUT_PERMIT_FAIL:-false}"
summary="${INPUT_SUMMARY:-true}"
registry_token="${INPUT_REGISTRY_TOKEN:-}"
# Keep the token out of the environment that build scripts inherit.
unset INPUT_REGISTRY_TOKEN

crate_name=""
crate_version=""
crate_size=""
published="false"
stage="Check inputs"
tag_result="Skipped"
if [ -n "$release_tag" ]; then
  tag_result="Not checked"
fi
result="Dry-run passed"
failures_permitted="false"

fail() {
  echo "::error::$*"
  exit 1
}

write_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

finish() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    result="Failed: $stage"
    if [ "$stage" = "Verify release tag" ]; then
      tag_result="Failed"
    fi
    if [ "$failures_permitted" = "true" ]; then
      result="$result (permitted)"
    fi
  fi
  write_output published "$published"
  if [ "$summary" = "true" ]; then
    write_summary "$crate_name" "$crate_version" "$tag_result" \
      "$crate_size" "$max_bytes" "$result"
  fi
  if [ "$status" -ne 0 ] && [ "$failures_permitted" = "true" ]; then
    echo "::warning::Stage '$stage' failed (exit $status);" \
      "permit_fail is 'true', so the step reports success"
    exit 0
  fi
  exit "$status"
}
trap finish EXIT

# Build scripts and proc-macros run during 'cargo package'. Withhold
# registry tokens, and the variables that mint GitHub OIDC tokens for
# crates.io Trusted Publishing, from every stage except the upload.
scrubbed_cargo() {
  env -u CARGO_REGISTRY_TOKEN -u CARGO_REGISTRIES_CRATES_IO_TOKEN \
    -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL \
    cargo "$@"
}

# A prefix assignment, rather than an 'env NAME=value' argument, keeps
# the token out of the process argument list.
publishing_cargo() {
  if [ -n "$registry_token" ]; then
    CARGO_REGISTRY_TOKEN="$registry_token" \
      env -u ACTIONS_ID_TOKEN_REQUEST_TOKEN \
      -u ACTIONS_ID_TOKEN_REQUEST_URL cargo "$@"
  else
    env -u ACTIONS_ID_TOKEN_REQUEST_TOKEN \
      -u ACTIONS_ID_TOKEN_REQUEST_URL cargo "$@"
  fi
}

require_boolean() {
  case "$2" in
    true | false) ;;
    *) fail "$1 must be 'true' or 'false'" ;;
  esac
}

# Resolve a path against a base directory unless already absolute.
resolve_against() {
  case "$2" in
    /*) printf '%s' "$2" ;;
    *) printf '%s/%s' "$1" "$2" ;;
  esac
}

require_within_workspace() {
  case "$2/" in
    "$workspace_real"/*) ;;
    *) fail "$1 must resolve within the workspace" ;;
  esac
}

# A crates.io token for Trusted Publishing is bound to the repository,
# workflow file and optional environment. Name the first two, so a
# rejected token can be checked against the crate's publisher settings.
describe_trusted_publisher() {
  local workflow_file="${GITHUB_WORKFLOW_REF:-unknown}"
  workflow_file="${workflow_file#*/*/}"
  workflow_file="${workflow_file%@*}"
  echo "::notice::Trusted Publisher config surface for $crate_name:" \
    "repository ${GITHUB_REPOSITORY:-unknown}, workflow $workflow_file." \
    "If this job runs under a GitHub Actions environment, the" \
    "crates.io Trusted Publisher config may need that environment too."
}

### Check inputs ###

# Messages name the offending input rather than echoing its value: an
# unvalidated value containing a newline could otherwise start a new
# workflow command.
require_boolean dry_run "$dry_run"
require_boolean permit_fail "$permit_fail"
require_boolean summary "$summary"

# Eighteen digits keeps the value inside a 64-bit shell integer.
if [[ ! "$max_bytes" =~ ^[1-9][0-9]{0,17}$ ]]; then
  fail "max_crate_size_bytes must be a positive integer"
fi

if [ -n "$release_tag" ] && [[ ! "$release_tag" =~ ^[0-9A-Za-z._+-]+$ ]]; then
  fail "release_tag may contain only: 0-9 A-Z a-z . _ + -"
fi

for tool in cargo jq wc; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    fail "required tool not found on PATH: $tool"
  fi
done

workspace="${GITHUB_WORKSPACE:-$PWD}"
if ! workspace_real="$(cd -- "$workspace" 2> /dev/null && pwd -P)"; then
  fail "GITHUB_WORKSPACE is not a directory"
fi

project_dir="$(resolve_against "$workspace_real" "$path_prefix")"
if ! project_dir="$(cd -- "$project_dir" 2> /dev/null && pwd -P)"; then
  fail "path_prefix is not a directory"
fi
require_within_workspace path_prefix "$project_dir"

case "$manifest_path" in
  Cargo.toml | */Cargo.toml) ;;
  *) fail "manifest_path must name a Cargo.toml file" ;;
esac
manifest_file="$(resolve_against "$project_dir" "$manifest_path")"
if [ ! -f "$manifest_file" ]; then
  fail "manifest_path does not exist below path_prefix"
fi
# Canonicalise once, for the containment check below, and hand cargo
# that same path: cargo echoes the manifest path it was given, so the
# metadata lookup then matches whatever symlinks the checkout involves.
manifest_dir="$(cd -- "$(dirname -- "$manifest_file")" && pwd -P)"
manifest_abs="$manifest_dir/Cargo.toml"
require_within_workspace manifest_path "$manifest_abs"

# add-mask applies per line, so a multi-line value would leak its tail.
case "$registry_token" in
  *[[:space:]]*) fail "registry_token must not contain whitespace" ;;
esac
if [ -n "$registry_token" ]; then
  echo "::add-mask::$registry_token"
fi

# Permit failures only once the inputs are known to be well-formed; a
# misconfigured call should never pass silently.
failures_permitted="$permit_fail"

# Cargo discovers .cargo/config.toml and rustup discovers
# rust-toolchain.toml from the working directory, not from the
# manifest path, so run from the project directory.
cd -- "$project_dir"

### Read crate metadata ###

stage="Read crate metadata"
metadata="$(scrubbed_cargo metadata --no-deps --format-version 1 \
  --manifest-path "$manifest_abs")"
# A workspace lists every member: select the requested manifest.
crate_name="$(jq -er --arg manifest "$manifest_abs" \
  '.packages[] | select(.manifest_path == $manifest) | .name
   | strings | select(length > 0)' <<< "$metadata")"
crate_version="$(jq -er --arg manifest "$manifest_abs" \
  '.packages[] | select(.manifest_path == $manifest) | .version
   | strings | select(length > 0)' <<< "$metadata")"
target_dir="$(jq -er '.target_directory | strings | select(length > 0)' \
  <<< "$metadata")"
# Cargo enforces these shapes already. Checking them again guarantees
# the values are single-line and safe to write as step outputs.
if [[ ! "$crate_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
  crate_name=""
  fail "cargo metadata returned an unexpected crate name"
fi
if [[ ! "$crate_version" =~ ^[0-9A-Za-z.+-]+$ ]]; then
  crate_version=""
  fail "cargo metadata returned an unexpected crate version"
fi
case "$target_dir" in
  *$'\n'* | *$'\r'*) fail "cargo metadata returned an unexpected target directory" ;;
esac
write_output crate_name "$crate_name"
write_output crate_version "$crate_version"
echo "Crate: $crate_name $crate_version"

### Verify release tag ###

stage="Verify release tag"
if [ -n "$release_tag" ]; then
  expected="${release_tag#v}"
  if [ "$crate_version" != "$expected" ]; then
    fail "$crate_name Cargo.toml version ($crate_version) does not" \
      "match release tag ($expected)"
  fi
  tag_result="Matched"
  echo "$crate_name version $crate_version matches release tag ✅"
fi

### Package ###

stage="Package"
scrubbed_cargo package --locked --manifest-path "$manifest_abs"

### Check package size ###

stage="Check package size"
crate_file="$target_dir/package/$crate_name-$crate_version.crate"
if [ ! -f "$crate_file" ]; then
  fail "cargo package did not produce $crate_name-$crate_version.crate"
fi
crate_size="$(wc -c < "$crate_file")"
crate_size="${crate_size//[[:space:]]/}"
write_output crate_size_bytes "$crate_size"
echo "$crate_name package size: $crate_size bytes (limit: $max_bytes)"
if [ "$crate_size" -gt "$max_bytes" ]; then
  fail "$crate_name package is $crate_size bytes, exceeding the" \
    "$max_bytes-byte limit"
fi

### Dry-run publish ###

# Registry-side checks only: 'cargo package' has already compiled the
# packaged sources, so --no-verify skips a redundant second build.
stage="Dry-run publish"
scrubbed_cargo publish --dry-run --no-verify --locked --registry crates-io \
  --manifest-path "$manifest_abs"

### Publish ###

if [ "$dry_run" = "true" ]; then
  echo "Dry run: $crate_name $crate_version validated, not published ✅"
  exit 0
fi

stage="Publish"
describe_trusted_publisher
publishing_cargo publish --no-verify --locked --registry crates-io \
  --manifest-path "$manifest_abs"
published="true"
result="Published"
echo "Published $crate_name $crate_version to crates.io ✅"
