#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-package-sha256.sh [--scope all|changed] [--jobs N] [--include-disabled] [--output-dir DIR] [--fail] [--fix]

Verify that TERMUX_PKG_SHA256 matches the SHA256 of downloaded TERMUX_PKG_SRCURL.

Outputs (written under --output-dir):
  - tasks.tsv
  - results.tsv
  - failures.tsv
  - summary.md

Notes:
  - build.sh files are sourced in a minimal bash environment to expand variables.
  - Only http(s) URLs are checked.
  - Entries with expected checksum 'SKIP_CHECKSUM' are skipped.
  - With --fix, build.sh files are updated *only if* checksums differ.
EOF
}

SCOPE="all"
JOBS=8
INCLUDE_DISABLED=false
OUTPUT_DIR="artifacts/sha256-check"
FAIL_ON_ISSUES=false
FIX=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="${2:-}"; shift 2;;
    --jobs) JOBS="${2:-}"; shift 2;;
    --include-disabled) INCLUDE_DISABLED=true; shift 1;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2;;
    --fail) FAIL_ON_ISSUES=true; shift 1;;
    --fix) FIX=true; shift 1;;
    -h|--help) usage; exit 0;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$SCOPE" =~ ^(all|changed)$ ]]; then
  echo "Invalid --scope: $SCOPE" >&2
  exit 2
fi

if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -lt 1 ]]; then
  echo "Invalid --jobs: $JOBS" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"

# Termux/Android environments sometimes restrict /tmp.
TMPBASE="${TMPDIR:-$PWD/.tmp}"
mkdir -p "$TMPBASE"

TASKS_TSV="$OUTPUT_DIR/tasks.tsv"
RESULTS_TSV="$OUTPUT_DIR/results.tsv"
FAILURES_TSV="$OUTPUT_DIR/failures.tsv"
SUMMARY_MD="$OUTPUT_DIR/summary.md"

repo_dirs=(packages x11-packages root-packages)
if $INCLUDE_DISABLED; then
  repo_dirs+=(disabled-packages)
fi

get_changed_build_sh() {
  local base="" head="HEAD"

  if [[ -n "${GITHUB_EVENT_PATH:-}" ]] && command -v jq >/dev/null 2>&1; then
    base=$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)
    if [[ -z "$base" ]]; then
      base=$(jq -r '.before // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)
    fi
    head=$(jq -r '.after // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)
    [[ -z "$head" ]] && head="HEAD"
  fi

  if [[ -z "$base" ]] && [[ -n "${GITHUB_BASE_REF:-}" ]]; then
    git fetch --no-tags --depth=1 origin "$GITHUB_BASE_REF" >/dev/null 2>&1 || true
    base="origin/$GITHUB_BASE_REF"
  fi

  [[ -z "$base" ]] && return 1

  git diff --name-only "$base".."${head:-HEAD}" \
    | grep -E '^(packages|x11-packages|root-packages|disabled-packages)/[^/]+/build\.sh$' || true
}

build_sh_list=()

if [[ "$SCOPE" == "changed" ]]; then
  mapfile -t changed < <(get_changed_build_sh || true)
  if [[ ${#changed[@]} -eq 0 ]]; then
    echo "No changed build.sh detected (or unable to compute base). Falling back to --scope all." >&2
    SCOPE="all"
  else
    for f in "${changed[@]}"; do
      if [[ "$f" == disabled-packages/* ]] && ! $INCLUDE_DISABLED; then
        continue
      fi
      build_sh_list+=("$f")
    done
  fi
fi

if [[ "$SCOPE" == "all" ]]; then
  for d in "${repo_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d '' f; do
      build_sh_list+=("${f#./}")
    done < <(find "$d" -mindepth 2 -maxdepth 2 -type f -name build.sh -print0)
  done
fi

# Tasks file format:
# build_sh\tpkg_dir\trepo_path\tpkg_name\tidx\turl\texpected_sha
printf 'build_sh\tpkg_dir\trepo_path\tpkg_name\tidx\turl\texpected_sha\n' > "$TASKS_TSV"

collect_tasks_for_build_sh() {
  local build_sh="$1"
  local pkg_dir repo_path pkg_name
  pkg_dir=$(dirname "$build_sh")
  repo_path=$(dirname "$pkg_dir")
  pkg_name=$(basename "$pkg_dir")

  local out ec
  set +e
  out=$(bash -c '
    set -e
    set +u
    cd "$1"
    source ./build.sh >/dev/null 2>&1 || source ./build.sh

    # Read URLs.
    urls=()
    if declare -p TERMUX_PKG_SRCURL >/dev/null 2>&1; then
      if declare -p TERMUX_PKG_SRCURL 2>/dev/null | grep -q "declare -a"; then
        urls=("${TERMUX_PKG_SRCURL[@]}")
      else
        read -r -a urls <<< "${TERMUX_PKG_SRCURL}"
      fi
    fi

    shas=()
    if declare -p TERMUX_PKG_SHA256 >/dev/null 2>&1; then
      if declare -p TERMUX_PKG_SHA256 2>/dev/null | grep -q "declare -a"; then
        shas=("${TERMUX_PKG_SHA256[@]}")
      else
        read -r -a shas <<< "${TERMUX_PKG_SHA256}"
      fi
    fi

    # If no source, nothing to do.
    if [[ ${#urls[@]} -eq 0 ]]; then
      exit 0
    fi

    # If SHA list is empty, still emit tasks with empty expected sha.
    for i in "${!urls[@]}"; do
      exp=""
      if [[ $i -lt ${#shas[@]} ]]; then
        exp="${shas[$i]}"
      fi
      printf "%s\t%s\n" "$i" "${urls[$i]}""$'\t'""$exp"
    done
  ' bash "$pkg_dir" 2>/dev/null)
  ec=$?
  set -e

  if [[ $ec -ne 0 ]]; then
    # Record an eval failure so the summary reflects it.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$build_sh" "$pkg_dir" "$repo_path" "$pkg_name" "-" "EVAL_FAIL" "" >> "$TASKS_TSV"
    return 0
  fi

  if [[ -z "${out:-}" ]]; then
    return 0
  fi

  while IFS=$'\t' read -r idx url expected; do
    [[ -z "${url:-}" ]] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$build_sh" "$pkg_dir" "$repo_path" "$pkg_name" "$idx" "$url" "${expected:-}" >> "$TASKS_TSV"
  done <<< "$out"
}

for build_sh in "${build_sh_list[@]}"; do
  collect_tasks_for_build_sh "$build_sh"
done

python - "$TASKS_TSV" "$RESULTS_TSV" "$FAILURES_TSV" "$SUMMARY_MD" "$JOBS" "$FIX" <<'PY'
import concurrent.futures
import hashlib
import os
import re
import sys
import urllib.request
from pathlib import Path

TASKS_TSV, RESULTS_TSV, FAILURES_TSV, SUMMARY_MD, JOBS, FIX = sys.argv[1:7]
JOBS = int(JOBS)
FIX = FIX.lower() == 'true'

header = None
tasks = []
with open(TASKS_TSV, 'r', encoding='utf-8') as f:
    for line_no, line in enumerate(f, 1):
        line = line.rstrip('\n')
        if line_no == 1:
            header = line
            continue
        parts = line.split('\t')
        if len(parts) != 7:
            # keep going; malformed line
            continue
        build_sh, pkg_dir, repo_path, pkg_name, idx, url, expected = parts
        tasks.append({
            'build_sh': build_sh,
            'pkg_dir': pkg_dir,
            'repo_path': repo_path,
            'pkg_name': pkg_name,
            'idx': idx,
            'url': url,
            'expected': expected,
        })


def should_check(url: str, expected: str) -> tuple[bool, str]:
    if url == 'EVAL_FAIL':
        return False, 'EVAL_FAIL'
    if expected == 'SKIP_CHECKSUM':
        return False, 'SKIP_CHECKSUM'
    if url.startswith('git+'):
        return False, 'SKIP_GIT'
    if not (url.startswith('http://') or url.startswith('https://')):
        return False, 'SKIP_SCHEME'
    if not expected:
        # empty checksum is an issue but we can't compare
        return True, 'EMPTY_EXPECTED'
    if not re.fullmatch(r'[0-9a-fA-F]{64}', expected):
        return False, 'SKIP_INVALID_EXPECTED'
    return True, ''


def download_sha256(url: str, timeout: int = 120) -> str:
    req = urllib.request.Request(
        url,
        headers={
            'User-Agent': 'termux-packages/check-package-sha256 (github-actions)',
        },
    )
    h = hashlib.sha256()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        while True:
            chunk = resp.read(1024 * 256)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def worker(t: dict) -> dict:
    build_sh = t['build_sh']
    url = t['url']
    expected = t['expected']

    do_check, reason = should_check(url, expected)
    if not do_check:
        return {**t, 'status': reason, 'actual': ''}

    try:
        actual = download_sha256(url)
    except Exception as e:
        return {**t, 'status': f'ERROR({type(e).__name__})', 'actual': ''}

    if not expected or reason == 'EMPTY_EXPECTED':
        return {**t, 'status': 'MISSING_EXPECTED', 'actual': actual}

    if actual.lower() == expected.lower():
        return {**t, 'status': 'OK', 'actual': actual}
    return {**t, 'status': 'MISMATCH', 'actual': actual}


results: list[dict] = []
with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as ex:
    futs = [ex.submit(worker, t) for t in tasks]
    for f in concurrent.futures.as_completed(futs):
        results.append(f.result())

# Stable ordering for reports
results.sort(key=lambda r: (r['build_sh'], r['idx'], r['url']))

Path(RESULTS_TSV).parent.mkdir(parents=True, exist_ok=True)
with open(RESULTS_TSV, 'w', encoding='utf-8') as f:
    f.write('repo\tpkg\turl\texpected\tactual\tstatus\tbuild_sh\tidx\n')
    for r in results:
        f.write('\t'.join([
            r['repo_path'], r['pkg_name'], r['url'], r['expected'], r['actual'], r['status'], r['build_sh'], r['idx']
        ]) + '\n')

failures = [r for r in results if r['status'] in ('MISMATCH', 'MISSING_EXPECTED') or r['status'].startswith('ERROR') or r['status'] == 'EVAL_FAIL']
with open(FAILURES_TSV, 'w', encoding='utf-8') as f:
    f.write('repo\tpkg\turl\texpected\tactual\tstatus\tbuild_sh\tidx\n')
    for r in failures:
        f.write('\t'.join([
            r['repo_path'], r['pkg_name'], r['url'], r['expected'], r['actual'], r['status'], r['build_sh'], r['idx']
        ]) + '\n')

# Optionally fix build.sh for packages where *all* checked URLs have actual shas and at least one mismatch.
fixed_files = []
if FIX:
    by_file: dict[str, list[dict]] = {}
    for r in results:
        by_file.setdefault(r['build_sh'], []).append(r)

    def update_build_sh(build_sh: str, new_shas: list[str]):
        p = Path(build_sh)
        s = p.read_text(encoding='utf-8', errors='replace')

        # Prefer replacing an array assignment if present.
        array_re = re.compile(r'(?ms)^TERMUX_PKG_SHA256=\((.*?)\)\s*$', re.MULTILINE)
        line_re = re.compile(r'(?m)^TERMUX_PKG_SHA256=.*$')

        if len(new_shas) == 1:
            replacement = f'TERMUX_PKG_SHA256={new_shas[0]}'
        else:
            body = "\n" + "".join([f"\t{sha}\n" for sha in new_shas]) + ")"
            replacement = "TERMUX_PKG_SHA256=(" + body

        if array_re.search(s):
            s2 = array_re.sub(replacement, s, count=1)
        elif line_re.search(s):
            s2 = line_re.sub(replacement, s, count=1)
        else:
            # If missing entirely, insert after SRCURL if possible, else append.
            srcurl_re = re.compile(r'(?m)^TERMUX_PKG_SRCURL=.*$')
            m = srcurl_re.search(s)
            if m:
                insert_at = m.end()
                s2 = s[:insert_at] + "\n" + replacement + s[insert_at:]
            else:
                s2 = s.rstrip('\n') + "\n" + replacement + "\n"

        if s2 != s:
            p.write_text(s2, encoding='utf-8')

    for build_sh, items in by_file.items():
        # Ignore eval failures (we cannot confidently fix).
        if any(i['status'] == 'EVAL_FAIL' for i in items):
            continue

        # Only consider URLs that were actually checked (OK/MISMATCH/MISSING_EXPECTED/ERROR)
        checked = [i for i in items if i['status'] in ('OK', 'MISMATCH', 'MISSING_EXPECTED') or i['status'].startswith('ERROR')]
        if not checked:
            continue

        if any(i['status'].startswith('ERROR') for i in checked):
            continue

        if any(i['status'] == 'MISSING_EXPECTED' for i in checked):
            # We *can* fix missing expected, but only if we have actual for all checked.
            pass

        # Need actual shas for all checked
        if any(not i['actual'] for i in checked):
            continue

        # Compute ordered shas by idx
        checked.sort(key=lambda r: int(r['idx']) if r['idx'].isdigit() else 999999)
        new_shas = [r['actual'] for r in checked]

        # Determine if change is needed.
        old_shas = [r['expected'] for r in checked]
        if [x.lower() for x in new_shas] == [x.lower() for x in old_shas]:
            continue

        update_build_sh(build_sh, new_shas)
        fixed_files.append(build_sh)

# Write summary
ok = sum(1 for r in results if r['status'] == 'OK')
mismatch = sum(1 for r in results if r['status'] == 'MISMATCH')
missing_expected = sum(1 for r in results if r['status'] == 'MISSING_EXPECTED')
errors = sum(1 for r in results if r['status'].startswith('ERROR'))
eval_fail = sum(1 for r in results if r['status'] == 'EVAL_FAIL')
skips = len(results) - (ok + mismatch + missing_expected + errors + eval_fail)

with open(SUMMARY_MD, 'w', encoding='utf-8') as f:
    f.write('## SHA256 check (TERMUX_PKG_SHA256 vs TERMUX_PKG_SRCURL)\n\n')
    f.write(f'- Total entries: {len(results)}\n')
    f.write(f'- OK: {ok}\n')
    f.write(f'- Mismatch: {mismatch}\n')
    f.write(f'- Missing expected: {missing_expected}\n')
    f.write(f'- Errors: {errors}\n')
    f.write(f'- Eval failures: {eval_fail}\n')
    f.write(f'- Skipped: {skips}\n')
    if FIX:
        f.write(f'- Fixed build.sh files: {len(fixed_files)}\n')

# Exit code logic is handled by bash wrapper via FAIL_ON_ISSUES.
PY

if $FAIL_ON_ISSUES; then
  # Fail if any failures found.
  if tail -n +2 "$FAILURES_TSV" | grep -q .; then
    echo "SHA256 check: failures found." >&2
    exit 1
  fi
fi

echo "Wrote: $TASKS_TSV"
echo "Wrote: $RESULTS_TSV"
echo "Wrote: $FAILURES_TSV"
echo "Wrote: $SUMMARY_MD"
