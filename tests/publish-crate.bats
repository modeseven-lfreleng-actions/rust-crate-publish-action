#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0 AND MIT
# SPDX-FileCopyrightText: 2026 Overture Maps
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Unit tests for scripts/publish-crate.sh, run against a cargo stand-in
# (fixtures/cargo.sh). No network access, compilation or publishing.

# Each @test runs in its own subshell and setup() resets the state, so
# variables exported inside one test are meant to stay local to it.
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

setup() {
  repo_dir="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  action_file="$repo_dir/action.yaml"
  script="$repo_dir/scripts/publish-crate.sh"
  mkdir -p "$BATS_TEST_TMPDIR/work space"
  workdir="$(cd "$BATS_TEST_TMPDIR/work space" && pwd -P)"
  project="$workdir/member crate"
  mkdir -p "$workdir/bin" "$project" "$workdir/cargo home"
  cp "$BATS_TEST_DIRNAME/fixtures/cargo.sh" "$workdir/bin/cargo"
  chmod +x "$workdir/bin/cargo"
  cp "$BATS_TEST_DIRNAME/fixtures/Cargo.toml" "$project/Cargo.toml"

  export PATH="$workdir/bin:$PATH"
  export GITHUB_WORKSPACE="$workdir"
  export GITHUB_OUTPUT="$workdir/github output"
  export GITHUB_STEP_SUMMARY="$workdir/job summary"
  export CARGO_HOME="$workdir/cargo home"
  export INPUT_PATH_PREFIX="member crate"
  export MOCK_EXPECT_MANIFEST="$project/Cargo.toml"
  export MOCK_CARGO_LOG="$workdir/cargo calls"
  export MOCK_CARGO_ENV="$workdir/cargo env"
  export MOCK_MANIFEST_JSON="$BATS_TEST_DIRNAME/fixtures/manifest.json"
  export MOCK_TARGET_DIRECTORY="$workdir/target"
  export MOCK_CRATE_SIZE=32
  unset INPUT_MANIFEST_PATH INPUT_RELEASE_TAG INPUT_MAX_CRATE_SIZE_BYTES
  unset INPUT_DRY_RUN INPUT_PERMIT_FAIL INPUT_SUMMARY INPUT_REGISTRY_TOKEN
  unset MOCK_FAIL_STAGE MOCK_MISSING_PACKAGE MOCK_INVALID_METADATA
  unset MOCK_INCLUDE_OTHER_PACKAGE CARGO_TARGET_DIR
  unset CARGO_REGISTRY_TOKEN CARGO_REGISTRIES_CRATES_IO_TOKEN
  unset ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL
  unset GITHUB_REPOSITORY GITHUB_WORKFLOW_REF
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  : > "$MOCK_CARGO_LOG"
  : > "$MOCK_CARGO_ENV"
}

run_action() {
  run "$BASH" "$script"
}

assert_calls() {
  [ "$(cat "$MOCK_CARGO_LOG")" = "$1" ]
}

assert_no_cargo() {
  [ ! -s "$MOCK_CARGO_LOG" ]
}

# Field N (1-based) of the recorded environment for a cargo stage:
# 2 cwd, 3 CARGO_REGISTRY_TOKEN, 4 CARGO_REGISTRIES_CRATES_IO_TOKEN,
# 5 ACTIONS_ID_TOKEN_REQUEST_TOKEN, 6 INPUT_REGISTRY_TOKEN.
stage_env() {
  awk -F'|' -v stage="$1" -v field="$2" \
    '$1 == stage { print $field }' "$MOCK_CARGO_ENV"
}

### Default flow ###

@test "publishes with default inputs and records every output" {
  run_action

  [ "$status" -eq 0 ]
  assert_calls $'metadata\npackage\ndry-run\npublish'
  [ "$(cat "$GITHUB_OUTPUT")" = $'crate_name=example-crate\ncrate_version=1.2.3\ncrate_size_bytes=32\npublished=true' ]
  [[ "$output" == *"Published example-crate 1.2.3 to crates.io"* ]]
}

@test "runs every cargo stage from the project directory" {
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_env metadata 2)" = "$project" ]
  [ "$(stage_env package 2)" = "$project" ]
  [ "$(stage_env dry-run 2)" = "$project" ]
  [ "$(stage_env publish 2)" = "$project" ]
}

### dry_run ###

@test "dry_run validates the package without a real publish" {
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  assert_calls $'metadata\npackage\ndry-run'
  grep -qx crate_size_bytes=32 "$GITHUB_OUTPUT"
  grep -qx published=false "$GITHUB_OUTPUT"
}

@test "dry_run still fails when package validation fails" {
  export INPUT_DRY_RUN=true INPUT_MAX_CRATE_SIZE_BYTES=31
  run_action

  [ "$status" -eq 1 ]
  assert_calls $'metadata\npackage'
}

@test "rejects non-boolean dry_run values before running cargo" {
  local value
  for value in TRUE True yes 1 ' ' $'true\nfalse'; do
    export INPUT_DRY_RUN="$value"
    : > "$MOCK_CARGO_LOG"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"dry_run must be 'true' or 'false'"* ]]
    assert_no_cargo
  done
}

@test "rejects non-boolean permit_fail and summary values" {
  export INPUT_PERMIT_FAIL=yes
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"permit_fail must be 'true' or 'false'"* ]]

  export INPUT_PERMIT_FAIL=false INPUT_SUMMARY=no
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"summary must be 'true' or 'false'"* ]]
  assert_no_cargo
}

### release_tag ###

@test "accepts an empty release tag" {
  export INPUT_RELEASE_TAG=""
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" != *"matches release tag"* ]]
}

@test "accepts a matching release tag with or without one leading v" {
  local tag
  for tag in 1.2.3 v1.2.3; do
    export INPUT_RELEASE_TAG="$tag"
    run_action

    [ "$status" -eq 0 ]
    [[ "$output" == *"example-crate version 1.2.3 matches release tag"* ]]
  done
}

@test "rejects a mismatched release tag before packaging" {
  export INPUT_RELEASE_TAG=v2.0.0
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match release tag (2.0.0)"* ]]
  assert_calls metadata
}

@test "strips only one leading v" {
  export INPUT_RELEASE_TAG=vv1.2.3
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match release tag (v1.2.3)"* ]]
  assert_calls metadata
}

@test "rejects release tags outside the allowed character set" {
  local tag
  cd "$workdir"
  # shellcheck disable=SC2016 # a literal command substitution
  for tag in '$(touch unexpected-tag-command)' 'v1.2.3 ' $'v1.2.3\n::error::x' 'v1/2'; do
    export INPUT_RELEASE_TAG="$tag"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"release_tag may contain only"* ]]
    [ ! -e unexpected-tag-command ]
    assert_no_cargo
  done
}

### max_crate_size_bytes ###

@test "enforces the packaged size limit at each boundary" {
  local case size limit expect_status
  local -a cases=(
    "10485759 10485760 0" # one byte below the default limit
    "10485760 10485760 0" # exactly at the default limit
    "10485761 10485760 1" # one byte above the default limit
    "32 31 1"             # smaller custom limit rejects
    "32 32 0"             # exactly at a custom limit
    "10485761 10485761 0" # larger custom limit accepts
  )
  for case in "${cases[@]}"; do
    read -r size limit expect_status <<< "$case"
    export MOCK_CRATE_SIZE="$size" INPUT_MAX_CRATE_SIZE_BYTES="$limit"
    : > "$MOCK_CARGO_LOG"
    : > "$GITHUB_OUTPUT"
    run_action

    [ "$status" -eq "$expect_status" ]
    grep -qx "crate_size_bytes=$size" "$GITHUB_OUTPUT"
    if [ "$expect_status" -ne 0 ]; then
      [[ "$output" == *"exceeding the ${limit}-byte limit"* ]]
      assert_calls $'metadata\npackage'
    fi
  done
}

@test "rejects malformed or out-of-range size limits before running cargo" {
  local limit
  # shellcheck disable=SC2016 # a literal command substitution
  for limit in -1 0 1.5 abc 010 1234567890123456789 \
    '$(touch unexpected-limit-command)'; do
    export INPUT_MAX_CRATE_SIZE_BYTES="$limit"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"max_crate_size_bytes must be a positive integer"* ]]
    assert_no_cargo
  done
}

### path_prefix and manifest_path ###

@test "accepts path_prefix '.' with a nested manifest_path containing spaces" {
  export INPUT_PATH_PREFIX=. INPUT_MANIFEST_PATH="member crate/Cargo.toml"
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_env metadata 2)" = "$workdir" ]
}

@test "accepts an absolute path_prefix inside the workspace" {
  export INPUT_PATH_PREFIX="$project"
  run_action

  [ "$status" -eq 0 ]
}

@test "resolves a relative path_prefix against the workspace, not the cwd" {
  cd /
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_env package 2)" = "$project" ]
}

@test "accepts a workspace reached through a symlink" {
  ln -s "$workdir" "$BATS_TEST_TMPDIR/linked workspace"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/linked workspace"
  run_action

  [ "$status" -eq 0 ]
  grep -qx crate_name=example-crate "$GITHUB_OUTPUT"
}

@test "rejects a path_prefix outside the workspace" {
  local prefix
  for prefix in / .. "$BATS_TEST_TMPDIR"; do
    export INPUT_PATH_PREFIX="$prefix"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"path_prefix must resolve within the workspace"* ]]
    assert_no_cargo
  done
}

@test "rejects a path_prefix that is not a directory" {
  export INPUT_PATH_PREFIX="missing directory"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"path_prefix is not a directory"* ]]
  assert_no_cargo
}

@test "rejects a manifest_path that is not a Cargo.toml" {
  local manifest
  for manifest in Cargo.lock "Cargo.toml.bak" "sub/NotCargo.toml"; do
    export INPUT_MANIFEST_PATH="$manifest"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"manifest_path must name a Cargo.toml file"* ]]
    assert_no_cargo
  done
}

@test "rejects a missing manifest" {
  export INPUT_MANIFEST_PATH="absent/Cargo.toml"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path does not exist below path_prefix"* ]]
  assert_no_cargo
}

@test "rejects a manifest_path that escapes the workspace" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  cp "$BATS_TEST_DIRNAME/fixtures/Cargo.toml" "$BATS_TEST_TMPDIR/outside/"
  export INPUT_MANIFEST_PATH="../../outside/Cargo.toml"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path must resolve within the workspace"* ]]
  assert_no_cargo
}

@test "fails clearly when cargo is not on PATH" {
  local tool saved_path="$PATH"
  mkdir -p "$workdir/no-cargo"
  for tool in jq wc dirname env; do
    ln -s "$(command -v "$tool")" "$workdir/no-cargo/$tool"
  done
  export PATH="$workdir/no-cargo"
  run_action
  export PATH="$saved_path"

  [ "$status" -eq 1 ]
  [[ "$output" == *"required tool not found on PATH: cargo"* ]]
}

### Cargo metadata ###

@test "uses metadata target_directory, including paths with spaces" {
  export CARGO_TARGET_DIR="$workdir/consumer target"
  export MOCK_TARGET_DIRECTORY="$CARGO_TARGET_DIR"
  run_action

  [ "$status" -eq 0 ]
  [ -f "$CARGO_TARGET_DIR/package/example-crate-1.2.3.crate" ]
  [ ! -e "$workdir/target/package" ]
}

@test "selects the workspace member matching the requested manifest" {
  export MOCK_INCLUDE_OTHER_PACKAGE=true
  run_action

  [ "$status" -eq 0 ]
  grep -qx crate_name=example-crate "$GITHUB_OUTPUT"
  [[ "$output" != *"other-crate"* ]]
}

@test "rejects invalid manifest JSON or missing manifest fields" {
  local manifest
  export MOCK_MANIFEST_JSON="$workdir/manifest.json"
  for manifest in 'not json' '{}' '{"name":"example-crate"}' '{"version":"1.2.3"}'; do
    printf '%s\n' "$manifest" > "$MOCK_MANIFEST_JSON"
    : > "$MOCK_CARGO_LOG"
    run_action

    [ "$status" -ne 0 ]
    assert_calls metadata
  done
}

@test "refuses metadata values that would be unsafe as step outputs" {
  local manifest
  export MOCK_MANIFEST_JSON="$workdir/manifest.json"
  for manifest in '{"name":"evil\n::error::x","version":"1.2.3"}' \
    '{"name":"example-crate","version":"1.2.3\nextra=1"}'; do
    printf '%s\n' "$manifest" > "$MOCK_MANIFEST_JSON"
    : > "$GITHUB_OUTPUT"
    : > "$MOCK_CARGO_LOG"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"cargo metadata returned an unexpected crate"* ]]
    [ "$(cat "$GITHUB_OUTPUT")" = "published=false" ]
    assert_calls metadata
  done
}

@test "fails on missing metadata target_directory without packaging" {
  export MOCK_INVALID_METADATA=true
  run_action

  [ "$status" -ne 0 ]
  assert_calls metadata
}

### Cargo failures ###

@test "cargo failures stop the run, keep the exit code and name the stage" {
  local failure expected calls
  for failure in metadata package dry-run publish; do
    case "$failure" in
      metadata) expected="Read crate metadata" calls=metadata ;;
      package) expected="Package" calls=$'metadata\npackage' ;;
      dry-run) expected="Dry-run publish" calls=$'metadata\npackage\ndry-run' ;;
      publish) expected="Publish" calls=$'metadata\npackage\ndry-run\npublish' ;;
    esac
    : > "$GITHUB_STEP_SUMMARY"
    : > "$GITHUB_OUTPUT"
    : > "$MOCK_CARGO_LOG"
    export MOCK_FAIL_STAGE="$failure" INPUT_RELEASE_TAG=v1.2.3
    run_action

    [ "$status" -eq 42 ]
    assert_calls "$calls"
    grep -qx published=false "$GITHUB_OUTPUT"
    grep -Fx "| Result | Failed: $expected |" "$GITHUB_STEP_SUMMARY"
    if [ "$failure" = metadata ]; then
      grep -Fx '| Crate | Unavailable |' "$GITHUB_STEP_SUMMARY"
      grep -Fx '| Release-tag check | Not checked |' "$GITHUB_STEP_SUMMARY"
    fi
  done
}

@test "fails on a missing package file without publishing" {
  export MOCK_MISSING_PACKAGE=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo package did not produce example-crate-1.2.3.crate"* ]]
  assert_calls $'metadata\npackage'
  run ! grep -q '^crate_size_bytes=' "$GITHUB_OUTPUT"
}

### permit_fail ###

@test "permit_fail reports success for a failed stage, with a warning" {
  export INPUT_PERMIT_FAIL=true INPUT_RELEASE_TAG=v9.9.9
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Stage 'Verify release tag' failed (exit 1)"* ]]
  grep -qx published=false "$GITHUB_OUTPUT"
  grep -Fx '| Result | Failed: Verify release tag (permitted) |' \
    "$GITHUB_STEP_SUMMARY"
}

@test "permit_fail covers a failed upload" {
  export INPUT_PERMIT_FAIL=true MOCK_FAIL_STAGE=publish
  run_action

  [ "$status" -eq 0 ]
  grep -qx published=false "$GITHUB_OUTPUT"
}

@test "permit_fail never masks invalid inputs" {
  export INPUT_PERMIT_FAIL=true INPUT_DRY_RUN=maybe
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" != *"permit_fail is 'true'"* ]]
}

### Credentials ###

@test "withholds ambient registry tokens from every stage but the upload" {
  export CARGO_REGISTRY_TOKEN="ambient token"
  export CARGO_REGISTRIES_CRATES_IO_TOKEN="ambient named token"
  run_action

  [ "$status" -eq 0 ]
  local stage
  for stage in metadata package dry-run; do
    [ "$(stage_env "$stage" 3)" = unset ]
    [ "$(stage_env "$stage" 4)" = unset ]
  done
  [ "$(stage_env publish 3)" = "ambient token" ]
  [ "$(stage_env publish 4)" = "ambient named token" ]
  [[ "$output" != *"ambient token"* ]]
}

@test "registry_token reaches the upload alone and never as an input variable" {
  export INPUT_REGISTRY_TOKEN="input-token"
  export CARGO_REGISTRY_TOKEN="ambient-token"
  run_action

  [ "$status" -eq 0 ]
  local stage
  for stage in metadata package dry-run publish; do
    [ "$(stage_env "$stage" 6)" = unset ]
  done
  [ "$(stage_env package 3)" = unset ]
  [ "$(stage_env publish 3)" = "input-token" ]
}

@test "registry_token is masked and not otherwise printed" {
  export INPUT_REGISTRY_TOKEN="input-token"
  run_action

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "::add-mask::input-token" ]
  [ "$(printf '%s\n' "$output" | grep -c input-token)" -eq 1 ]
}

@test "rejects a registry_token containing whitespace" {
  export INPUT_REGISTRY_TOKEN=$'first\nsecond'
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"registry_token must not contain whitespace"* ]]
  [[ "$output" != *"second"* ]]
  assert_no_cargo
}

@test "withholds GitHub OIDC request variables from every cargo stage" {
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="oidc-request-token"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://example.invalid/oidc"
  run_action

  [ "$status" -eq 0 ]
  local stage
  for stage in metadata package dry-run publish; do
    [ "$(stage_env "$stage" 5)" = unset ]
  done
}

@test "leaves Cargo credential files untouched" {
  local credentials=$'[registry]\ntoken = "consumer-file-token"'
  printf '%s\n' "$credentials" > "$CARGO_HOME/credentials.toml"
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$CARGO_HOME/credentials.toml")" = "$credentials" ]
  [[ "$output" != *"consumer-file-token"* ]]
}

### Trusted Publisher notice ###

@test "names the Trusted Publisher config surface before a real publish" {
  export GITHUB_REPOSITORY="example-org/example-crate"
  export GITHUB_WORKFLOW_REF="example-org/example-crate/.github/workflows/release.yaml@refs/tags/v1.2.3"
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::Trusted Publisher config surface for example-crate: repository example-org/example-crate, workflow .github/workflows/release.yaml."* ]]
}

@test "falls back to unknown repository and workflow outside GitHub Actions" {
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"repository unknown, workflow unknown."* ]]
}

@test "omits the Trusted Publisher notice for a dry run" {
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" != *"Trusted Publisher"* ]]
}

### Job summary ###

@test "successful publish writes the complete summary table" {
  export INPUT_RELEASE_TAG=v1.2.3
  run_action

  [ "$status" -eq 0 ]
  expected=$(cat << 'MARKDOWN'

### Crate publishing

| Field | Value |
| --- | --- |
| Crate | example-crate |
| Version | 1.2.3 |
| Release-tag check | Matched |
| Package size | 32 bytes |
| Size limit | 10485760 bytes |
| Result | Published |
MARKDOWN
  )
  [ "$(cat "$GITHUB_STEP_SUMMARY")" = "$expected" ]
}

@test "dry-run summary distinguishes skipped tags and never claims publication" {
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  grep -Fx '| Release-tag check | Skipped |' "$GITHUB_STEP_SUMMARY"
  grep -Fx '| Result | Dry-run passed |' "$GITHUB_STEP_SUMMARY"
  run ! grep -q Published "$GITHUB_STEP_SUMMARY"
}

@test "tag mismatch summary marks failure before package measurement" {
  export INPUT_RELEASE_TAG=v9.0.0
  run_action

  [ "$status" -eq 1 ]
  grep -Fx '| Release-tag check | Failed |' "$GITHUB_STEP_SUMMARY"
  grep -Fx '| Package size | Not measured |' "$GITHUB_STEP_SUMMARY"
  grep -Fx '| Result | Failed: Verify release tag |' "$GITHUB_STEP_SUMMARY"
}

@test "oversize summary includes measured size and custom limit" {
  export INPUT_MAX_CRATE_SIZE_BYTES=31
  run_action

  [ "$status" -eq 1 ]
  grep -Fx '| Package size | 32 bytes |' "$GITHUB_STEP_SUMMARY"
  grep -Fx '| Size limit | 31 bytes |' "$GITHUB_STEP_SUMMARY"
  grep -Fx '| Result | Failed: Check package size |' "$GITHUB_STEP_SUMMARY"
}

@test "summary 'false' writes no summary" {
  export INPUT_SUMMARY=false
  run_action

  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "multiple crate invocations append without overwriting earlier summaries" {
  printf 'Existing job notes\n' > "$GITHUB_STEP_SUMMARY"
  run_action
  [ "$status" -eq 0 ]
  export INPUT_DRY_RUN=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(grep -c '^### Crate publishing$' "$GITHUB_STEP_SUMMARY")" -eq 2 ]
  grep -Fx 'Existing job notes' "$GITHUB_STEP_SUMMARY"
  grep -Fx '| Result | Published |' "$GITHUB_STEP_SUMMARY"
  grep -Fx '| Result | Dry-run passed |' "$GITHUB_STEP_SUMMARY"
}

@test "local runs without GitHub output or summary paths still succeed" {
  unset GITHUB_STEP_SUMMARY GITHUB_OUTPUT
  run_action

  [ "$status" -eq 0 ]
  assert_calls $'metadata\npackage\ndry-run\npublish'
}

@test "summary write errors warn without replacing the exit status" {
  export GITHUB_STEP_SUMMARY="$workdir"
  run_action
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Could not write crate publishing job summary"* ]]

  export MOCK_FAIL_STAGE=publish
  run_action
  [ "$status" -eq 42 ]
  [[ "$output" == *"::warning::Could not write crate publishing job summary"* ]]
}

@test "summary escapes table delimiters, markup and newlines" {
  # shellcheck disable=SC2016 # expanded by the inner shell
  run "$BASH" -c 'source "$1"; summary_cell "$2"' -- \
    "$repo_dir/scripts/job-summary.sh" $'<tag> & | `value`\r\nnext'

  [ "$status" -eq 0 ]
  [ "$output" = '&lt;tag&gt; &amp; &#124; &#96;value&#96;  next' ]
}

@test "summary contains no credentials or authentication claims" {
  export INPUT_REGISTRY_TOKEN="private-consumer-token"
  run_action

  [ "$status" -eq 0 ]
  run ! grep -q private-consumer-token "$GITHUB_STEP_SUMMARY"
  run ! grep -iq 'auth\|token' "$GITHUB_STEP_SUMMARY"
}

### Action wiring ###

@test "action.yaml runs the script and passes exactly the inputs it reads" {
  local declared passed consumed
  # shellcheck disable=SC2016 # the literal line from action.yaml
  grep -Fqx '      run: bash "$ACTION_PATH/scripts/publish-crate.sh"' \
    "$action_file"
  declared="$(sed -n '/^inputs:/,/^outputs:/s/^  \([a-z_]*\):$/\1/p' \
    "$action_file" | tr '[:lower:]' '[:upper:]' | sed 's/^/INPUT_/' | sort)"
  passed="$(sed -n 's/^ *\(INPUT_[A-Z_]*\): .*/\1/p' "$action_file" | sort)"
  consumed="$(grep -o 'INPUT_[A-Z][A-Z_]*' "$script" | sort -u)"
  [ "$declared" = "$passed" ]
  [ "$passed" = "$consumed" ]
}

@test "action.yaml exposes the outputs the script writes" {
  local declared written
  declared="$(sed -n '/^outputs:/,/^runs:/s/^  \([a-z_]*\):$/\1/p' \
    "$action_file" | sort)"
  written="$(grep -o 'write_output [a-z_]*' "$script" \
    | awk '$2 != "" { print $2 }' | sort -u)"
  [ "$declared" = "$written" ]
  [ "$(grep -c 'steps.publish.outputs.' "$action_file")" -eq 4 ]
}
