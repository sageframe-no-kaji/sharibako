#!/usr/bin/env bash
#
# generate-man.sh — generate section-1 man pages for the `sharibako` CLI.
#
# The pages are GENERATED from the ParsableCommand tree via swift-argument-parser's
# official `generate-manual` plugin. The prose lives in each command's
# `CommandConfiguration` (abstract, discussion) and per-argument `help:` strings —
# not in this script. To improve a man page, edit the command definition under
# Sources/SharibakoCLI/, then re-run this script.
#
# This script then post-processes the generated mdoc pages to:
#   - enrich each subcommand's SEE ALSO with a link back to sharibako(1) and to
#     its sibling subcommands (the plugin only cross-links a command's own
#     children);
#   - append a REPORTING BUGS section to every page.
# The AUTHOR section is emitted by the plugin from the --authors argument below.
#
# Output: one section-1 page per command in docs/man/ (multi-page mode).
#
# Usage:
#   scripts/generate-man.sh              generate + post-process
#   scripts/generate-man.sh --post-only  post-process existing docs/man/*.1 only
#                                         (skips the plugin; use when the pages are
#                                         already generated and only the SEE ALSO /
#                                         REPORTING BUGS / apostrophe-guard passes
#                                         need re-running)
set -euo pipefail

POST_ONLY=0
if [[ "${1:-}" == "--post-only" ]]; then
  POST_ONLY=1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/docs/man"

AUTHOR_NAME="Andrew Marcus"
AUTHOR_EMAIL="andrew@sageframe.net"
ISSUES_URL="https://github.com/sageframe-no-kaji/sharibako/issues"

cd "${REPO_ROOT}"

if [[ "${POST_ONLY}" -eq 0 ]]; then
  echo "==> Generating man pages into ${OUT_DIR}"
  mkdir -p "${OUT_DIR}"
  # Clear stale pages so a renamed/removed command doesn't leave an orphan page.
  rm -f "${OUT_DIR}"/*.1

  swift package \
    --allow-writing-to-directory "${OUT_DIR}" \
    generate-manual \
    --multi-page \
    --authors "${AUTHOR_NAME}<${AUTHOR_EMAIL}>" \
    --section 1 \
    --output-directory "${OUT_DIR}"
else
  echo "==> Post-only: reprocessing existing pages in ${OUT_DIR}"
fi

echo "==> Post-processing SEE ALSO and REPORTING BUGS"

# Collect every generated page's mdoc title (e.g. "sharibako-run") so we can
# build sibling cross-links.
shopt -s nullglob
pages=("${OUT_DIR}"/*.1)
if [[ ${#pages[@]} -eq 0 ]]; then
  echo "error: no man pages were generated" >&2
  exit 1
fi

# Base names without the .1 suffix, sorted. Drop the auto-generated `help`
# pseudo-command — it is not a verb worth cross-linking.
declare -a titles=()
for p in "${pages[@]}"; do
  base="$(basename "${p}" .1)"
  [[ "${base}" == "sharibako.help" ]] && continue
  titles+=("${base}")
done
IFS=$'\n' titles=($(sort <<<"${titles[*]}")); unset IFS

# post_process <page-file> <this-title>
# Rewrites the SEE ALSO section to reference sharibako(1) plus every sibling
# page, then appends a REPORTING BUGS section before the end of the document.
post_process() {
  local page="$1" self="$2"
  local tmp
  tmp="$(mktemp)"

  # Build the SEE ALSO body: comma-separated .Xr cross-references to every
  # OTHER page (root first, then the rest), each rendered as `.Xr name 1`.
  local refs=()
  # Root always first if present and not self.
  for t in "${titles[@]}"; do
    [[ "${t}" == "${self}" ]] && continue
    refs+=("${t}")
  done

  # Emit the page up to (but not including) any existing SEE ALSO section,
  # then our SEE ALSO, then a REPORTING BUGS section, then the tail.
  awk -v self="${self}" -v issues="${ISSUES_URL}" \
      -v apos="'" \
      -v reflist="$(IFS=,; echo "${refs[*]}")" '
    function emit_see_also(   n, arr, i) {
      print ".Sh SEE ALSO"
      n = split(reflist, arr, ",")
      for (i = 1; i <= n; i++) {
        if (i < n) {
          print ".Xr " arr[i] " 1 ,"
        } else {
          print ".Xr " arr[i] " 1"
        }
      }
    }
    function emit_reporting_bugs() {
      print ".Sh REPORTING BUGS"
      print "Report bugs, or security issues privately per SECURITY.md, at"
      print ".Lk " issues " ."
    }
    BEGIN { in_see = 0; printed_see = 0; in_rb = 0 }
    # Swallow any existing REPORTING BUGS section (idempotent re-runs): the END
    # block re-emits it. It runs to end-of-file, so drop everything after it.
    /^\.Sh REPORTING BUGS/ { in_rb = 1; next }
    in_rb == 1 {
      if ($0 ~ /^\.Sh /) { in_rb = 0 } else { next }
    }
    # Detect start of the SEE ALSO section (plugin-generated or from a re-run).
    /^\.Sh SEE ALSO/ {
      in_see = 1
      emit_see_also()
      printed_see = 1
      next
    }
    # While inside the old SEE ALSO, swallow its lines until the next section.
    in_see == 1 {
      if ($0 ~ /^\.Sh /) {
        in_see = 0
        # fall through to normal printing of this new section header
      } else {
        next
      }
    }
    {
      # A body-text line beginning with an apostrophe (a paragraph opening with
      # a quoted verb like the run verb) is swallowed by roff, which treats a
      # leading apostrophe as a no-break control character. Prefix "\&"
      # (zero-width) so the line renders as text. mdoc macro lines begin with
      # "." and are never matched here. Skip lines already guarded (idempotent).
      if (substr($0, 1, 1) == apos) {
        print "\\&" $0
      } else {
        print
      }
    }
    END {
      if (printed_see == 0) {
        # No SEE ALSO existed (leaf with no subcommands): add one.
        emit_see_also()
      }
      emit_reporting_bugs()
    }
  ' "${page}" >"${tmp}"

  mv "${tmp}" "${page}"
}

for p in "${pages[@]}"; do
  post_process "${p}" "$(basename "${p}" .1)"
done

echo "==> Done. Pages in ${OUT_DIR}:"
ls -1 "${OUT_DIR}"
echo
echo "Preview: man ${OUT_DIR}/sharibako.1"
