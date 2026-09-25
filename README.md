<!--
# SPDX-License-Identifier: Apache-2.0 AND MIT
# SPDX-FileCopyrightText: 2026 Overture Maps
# SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# 🦀 Rust Crate Publish Action

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/rust-crate-publish-action) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/rust-crate-publish-action/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/rust-crate-publish-action)
<!-- prettier-ignore-end -->

Packages a Rust crate, checks its size against the crates.io upload cap,
verifies its version against a release tag, and publishes it to
crates.io.

## rust-crate-publish-action

The action publishes one crate per call. It targets crates.io and
suits
[Trusted Publishing](https://crates.io/docs/trusted-publishing), where
the calling workflow exchanges a GitHub OIDC token for a short-lived
crates.io token. The action never requests OIDC tokens itself: the
caller owns authentication, token scope and environment configuration.

## Usage Example

Verify in one job and publish from another. The `verify` job compiles
the crate with no credentials in reach. The `publish` job holds the
token but compiles nothing: given `expected_sha256`, it refuses any
archive that differs from the one `verify` checked. See
[Credential handling](#credential-handling) for why this separation
matters.

<!-- markdownlint-disable MD013 MD046 -->

```yaml
on:
  release:
    types: [published]

permissions: {}

jobs:
  verify:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    outputs:
      crate_sha256: ${{ steps.verify.outputs.crate_sha256 }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: "Verify crate"
        id: verify
        uses: lfreleng-actions/rust-crate-publish-action@main
        with:
          release_tag: ${{ github.event.release.tag_name }}
          dry_run: 'true'

  publish:
    needs: verify
    runs-on: ubuntu-latest
    # Must match the crate's Trusted Publisher configuration
    environment: crates-io
    permissions:
      contents: read
      id-token: write  # Mint the OIDC token crates.io exchanges
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: "Authenticate with crates.io"
        id: auth
        uses: rust-lang/crates-io-auth-action@c6f97d42243bad5fab37ca0427f495c86d5b1a18 # v1.0.5

      - name: "Publish crate"
        uses: lfreleng-actions/rust-crate-publish-action@main
        with:
          release_tag: ${{ github.event.release.tag_name }}
          registry_token: ${{ steps.auth.outputs.token }}
          expected_sha256: ${{ needs.verify.outputs.crate_sha256 }}
```

<!-- markdownlint-enable MD013 MD046 -->

### Check packaging on every pull request

A dry run needs no credentials, no `id-token` permission and no
environment:

<!-- markdownlint-disable MD013 MD046 -->

```yaml
steps:
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    with:
      persist-credentials: false

  - name: "Check crate packaging"
    uses: lfreleng-actions/rust-crate-publish-action@main
    with:
      dry_run: 'true'
```

<!-- markdownlint-enable MD013 MD046 -->

### Publish workspace members in dependency order

Call the action once per crate, dependencies first, and select each
member with `manifest_path`. Crates.io must list a Trusted Publisher
for each crate.

This example runs in a single job, because Cargo cannot package a
dependent crate until the dependency version it needs is on
crates.io. So it lacks the two-job isolation described in
[Credential handling](#credential-handling). A crate whose
dependencies are all published already can use the two-job pattern
instead:

<!-- markdownlint-disable MD013 MD046 -->

```yaml
- name: "Authenticate for the base crate"
  id: auth-base
  uses: rust-lang/crates-io-auth-action@c6f97d42243bad5fab37ca0427f495c86d5b1a18 # v1.0.5

- name: "Publish the base crate"
  uses: lfreleng-actions/rust-crate-publish-action@main
  with:
    manifest_path: crates/base/Cargo.toml
    release_tag: ${{ github.event.release.tag_name }}
    registry_token: ${{ steps.auth-base.outputs.token }}

- name: "Authenticate for the dependent crate"
  id: auth-app
  uses: rust-lang/crates-io-auth-action@c6f97d42243bad5fab37ca0427f495c86d5b1a18 # v1.0.5

- name: "Publish the dependent crate"
  uses: lfreleng-actions/rust-crate-publish-action@main
  with:
    manifest_path: crates/app/Cargo.toml
    release_tag: ${{ github.event.release.tag_name }}
    registry_token: ${{ steps.auth-app.outputs.token }}
```

<!-- markdownlint-enable MD013 MD046 -->

## Requirements

- Bash, `cargo` and `jq` on the runner. GitHub-hosted Ubuntu runners
  include all three; the action fails with a clear error naming any
  missing tool.
- A clean git checkout. Cargo refuses to package files that git
  reports as uncommitted.
- A committed `Cargo.lock` for crates with dependencies, since every
  Cargo stage runs with `--locked`.
- Network access to `index.crates.io` for the dry-run stage, plus
  `static.crates.io` to download dependencies and `crates.io` to
  publish. Block-mode egress policies must admit these hosts.

## Inputs

<!-- markdownlint-disable MD013 -->

| Name                 | Required | Default      | Description                                                                                     |
| -------------------- | -------- | ------------ | ----------------------------------------------------------------------------------------------- |
| path_prefix          | False    | `.`          | Directory containing the crate or workspace; must resolve within the workspace                  |
| manifest_path        | False    | `Cargo.toml` | Path to the crate's `Cargo.toml`, relative to `path_prefix`                                     |
| release_tag          | False    |              | Release tag that the `Cargo.toml` version must match, one leading `v` ignored                   |
| max_crate_size_bytes | False    | `10485760`   | Largest allowed packaged `.crate` size in bytes; the default matches the crates.io 10MB cap     |
| dry_run              | False    | `false`      | Check and package without publishing; needs no credentials                                      |
| registry_token       | False    |              | crates.io token for the upload alone; empty falls back to the caller's Cargo credentials        |
| expected_sha256      | False    |              | `crate_sha256` from an earlier `dry_run` job; skips compilation and refuses a differing archive |
| permit_fail          | False    | `false`      | Report success even when a stage fails                                                          |
| summary              | False    | `true`       | Write a crate table to the job summary                                                          |

<!-- markdownlint-enable MD013 -->

Boolean inputs accept the exact strings `true` and `false`; any other
value fails the run.

## Outputs

<!-- markdownlint-disable MD013 -->

| Name             | Description                                                |
| ---------------- | ---------------------------------------------------------- |
| crate_name       | Crate name, read from its `Cargo.toml`                     |
| crate_version    | Crate version, read from its `Cargo.toml`                  |
| crate_size_bytes | Packaged `.crate` file size in bytes                       |
| crate_sha256     | SHA-256 of the verified `.crate`, as crates.io records it  |
| published        | `true` when the crate reached crates.io, otherwise `false` |

<!-- markdownlint-enable MD013 -->

## Implementation Details

The action runs these stages in order, and the first failure stops it:

1. **Check inputs**: checks booleans, the size limit and the
   release tag character set, and confirms that `path_prefix` and
   `manifest_path` resolve within `GITHUB_WORKSPACE`. A symlinked
   `Cargo.toml` fails, since it could point outside the workspace.
2. **Read crate metadata**: `cargo metadata --no-deps` selects the
   package whose manifest matches `manifest_path`, which works for
   workspace members.
3. **Verify release tag**: when `release_tag` holds a value, the
   crate version must equal it, after removing one leading `v`.
4. **Package**: `cargo package --locked` builds the `.crate` file and
   compiles it, proving the packaged sources build. With
   `expected_sha256`, it packages with `--no-verify` and compiles
   nothing.
5. **Check package size**: compares the `.crate` file in Cargo's
   configured target directory against `max_crate_size_bytes`.
6. **Match verified digest**: with `expected_sha256`, the `.crate`
   must match it byte for byte.
7. **Dry-run publish**: `cargo publish --dry-run` runs the registry
   checks without uploading.
8. **Confirm package unchanged**: repackages without running crate
   code and requires a byte-identical `.crate`; see below.
9. **Publish**: unless `dry_run` is `true`, uploads the crate.

Cargo runs from `path_prefix`, so the project's `.cargo/config.toml`
and `rust-toolchain.toml` apply.

### Credential handling

Packaging compiles the crate, which runs its build scripts and
procedural macros, and those of its dependencies. Code in a job can
reach that job's credentials: on Linux, a same-user process can read
an ancestor's original environment through `/proc/<pid>/environ`,
whatever later steps unset. That includes `registry_token` and, with
`id-token: write`, the variables that mint a Trusted Publishing
token.

Isolation instead comes from separate jobs, as in the
[usage example](#usage-example):

- The `verify` job runs with `dry_run: 'true'` and no credentials or
  `id-token` permission. It compiles the crate and reports the
  archive's `crate_sha256`.
- The `publish` job passes that digest as `expected_sha256`. The
  action then packages with `--no-verify`, runs no crate code, and
  refuses to upload unless the archive matches byte for byte.
  Cargo's archives are reproducible across checkouts, so the same
  commit yields the same digest.

In a single job the action still limits exposure, as defence in
depth rather than isolation:

- `registry_token` goes to the final upload alone; the action unsets
  it before running Cargo and masks it in the log.
- It strips `CARGO_REGISTRY_TOKEN`, `CARGO_REGISTRIES_CRATES_IO_TOKEN`
  and the GitHub OIDC request variables (`ACTIONS_ID_TOKEN_REQUEST_*`)
  from every Cargo stage before the upload.
- The upload passes `--no-verify`, so it compiles nothing.

With `registry_token` set, the upload also forces Cargo's built-in
`cargo:token` credential provider. A project `.cargo/config.toml`
could otherwise name its own provider, which Cargo would run with the
token in its environment. With `registry_token` empty, the upload
uses whatever credentials and provider the caller configured.

### Package integrity

Cargo cannot upload a prebuilt archive: `cargo publish` always
packages afresh. Build scripts that ran during verification could
edit and commit the workspace sources, but Cargo's own check covers
the unpacked copy under `target/package`, not the workspace. The
upload would then ship sources that nobody compiled.

The **Confirm package unchanged** stage closes that gap. It
repackages with `--no-verify`, which runs no crate code, and fails
unless the result matches the verified archive's SHA-256 byte for
byte. Cargo's archives are reproducible and record the source
commit, so any change to the packaged inputs alters the digest. The
`crate_sha256` output reports that digest, which crates.io records
as the published crate's checksum.

A process started by a build script can outlive it, though, and the
action cannot rule out changes between that stage and the upload in
a single job. The two-job pattern avoids the question: no crate code
ever runs in the publishing job.

The action cannot hide files such as `$CARGO_HOME/credentials.toml`
from code in the same job, so prefer `registry_token` with a
short-lived Trusted Publishing token.

### Failure handling

Errors name the input or stage at fault and keep Cargo's exit code.
With `permit_fail` set to `true`, a failed stage produces a warning
and the step reports success; `published` then reads `false`. Invalid
inputs always fail the run, whatever `permit_fail` says.

Before a real upload the action prints a notice naming the repository
and workflow file, the fields a crates.io Trusted Publisher
configuration binds a token to.

### Job summary

Each call appends a table with the crate name, version, release-tag
check, package size, size limit and result. A failed run names the
stage that failed. The summary never includes credentials.

## Testing

`.github/workflows/testing.yaml` runs on every pull request:

- Unit tests: [Bats](https://github.com/bats-core/bats-core) suites
  in `tests/` drive `scripts/publish-crate.sh` against a Cargo
  stand-in, covering each stage, input validation and credential
  handling.
- Dry runs against a generated two-member workspace and against
  [test-rust-project](https://github.com/lfreleng-actions/test-rust-project).
- Failure cases, which must fail closed.

Run the unit tests locally with Bats 1.5.0 or later:

```bash
bats tests/
```

## Acknowledgements

This action derives from the `publish-crate-to-crates-io` action in
[OvertureMaps/workflows](https://github.com/OvertureMaps/workflows/tree/2ba5afb48f6cff2989cc52e6cf93fef509cc3e76/.github/actions/publish-crate-to-crates-io),
copyright 2026 Overture Maps and released under the MIT License. Files
derived from it carry both copyright notices and the SPDX expression
`Apache-2.0 AND MIT`; see `LICENSES/`.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/rust-crate-publish-action/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/rust-crate-publish-action/main.svg
