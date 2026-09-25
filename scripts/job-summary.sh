#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 AND MIT
# SPDX-FileCopyrightText: 2026 Overture Maps
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Job summary helpers, sourced by publish-crate.sh.

# Escape a value for a single Markdown table cell: HTML metacharacters,
# the column delimiter, backticks and line breaks. The replacements are
# quoted so '&' stays literal under bash 5.2 patsub_replacement and
# no backslash leaks through on bash 3.2.
summary_cell() {
  local value="$1"
  value=${value//&/"&amp;"}
  value=${value//</"&lt;"}
  value=${value//>/"&gt;"}
  value=${value//|/"&#124;"}
  value=${value//\`/"&#96;"}
  value=${value//$'\r'/" "}
  value=${value//$'\n'/" "}
  printf '%s' "$value"
}

# Append one crate table to $GITHUB_STEP_SUMMARY. Arguments: crate
# name, crate version, release-tag check, package size (empty when not
# measured), size limit and result. A write failure warns rather than
# changing the exit status.
write_summary() {
  local name="${1:-Unavailable}" version="${2:-Unavailable}"
  local tag_check="$3" size="$4" limit="$5" outcome="$6"
  local package_size="Not measured"
  if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
    return 0
  fi
  if [ -n "$size" ]; then
    package_size="$size bytes"
  fi
  if ! printf '\n### Crate publishing\n\n| Field | Value |\n| --- | --- |\n| Crate | %s |\n| Version | %s |\n| Release-tag check | %s |\n| Package size | %s |\n| Size limit | %s bytes |\n| Result | %s |\n' \
    "$(summary_cell "$name")" \
    "$(summary_cell "$version")" \
    "$(summary_cell "$tag_check")" \
    "$(summary_cell "$package_size")" \
    "$(summary_cell "$limit")" \
    "$(summary_cell "$outcome")" 2> /dev/null >> "$GITHUB_STEP_SUMMARY"; then
    echo "::warning::Could not write crate publishing job summary" >&2
  fi
}
