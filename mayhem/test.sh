#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer tests for the VSPAERO tools built by mayhem/build.sh
# (mayhem/out/test/{vspaero,vsploads}, normal flags). Upstream ships no runnable C++ test suite for
# these tools, so this runs them on a committed fuselage+wing case and asserts the computed results.
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

VSPAERO="$SRC/mayhem/out/test/vspaero"
VSPLOADS="$SRC/mayhem/out/test/vsploads"
TD="$SRC/mayhem/testdata"
for b in "$VSPAERO" "$VSPLOADS"; do
  [ -x "$b" ] || { echo "missing $b — run mayhem/build.sh first" >&2; emit_ctrf vspaero-kat 0 1; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vsptest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp "$TD/fuse_wing.vspaero" "$TD/fuse_wing.vkey" "$TD/fuse_wing.cuts" "$TD/fem.inp" "$WORK/"
cp "$SRC/src/test/py/tests/PrepareGeometryFuselageWing.vspgeom" "$WORK/fuse_wing.vspgeom"
cd "$WORK"

passed=0; failed=0
check() {  # check <name> <command...>: the command must succeed
  local name="$1"; shift
  if "$@"; then echo "PASS $name"; passed=$((passed+1)); else echo "FAIL $name"; failed=$((failed+1)); fi
}
near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(a != "" && d <= t) }'; }

# 1) vspaero solves the case: 3 wake iterations, Mach 0.11, AoA 5 -> CLtot ~ 0.04453.
"$VSPAERO" -omp 1 fuse_wing > vspaero.log 2>&1
last="$(grep -E '^ *[0-9]+ +0\.11' fuse_wing.history 2>/dev/null | tail -1)"
check vspaero_three_iterations [ "$(echo "$last" | awk '{print $1}')" = "3" ]
check vspaero_mach_alpha       near "$(echo "$last" | awk '{print $2 + $3}')" 5.11 1e-9
check vspaero_cl_total         near "$(echo "$last" | awk '{print $7}')" 0.044534 2e-4
check vspaero_wrote_adb        [ -s fuse_wing.adb ]

# 2) vsploads slices the .adb it wrote with the two cut planes in fuse_wing.cuts.
"$VSPLOADS" -slice fuse_wing > slice.log 2>&1
check slice_two_blocks   [ "$(grep -c '^BLOCK' fuse_wing.slc 2>/dev/null)" = "2" ]
check slice_y_cut_name   grep -q '^BLOCK Cut_1_at_Y:_1.000000' fuse_wing.slc
check slice_x_cut_name   grep -q '^BLOCK Cut_2_at_X:_2.000000' fuse_wing.slc
check slice_first_point  bash -c "awk 'NR==4 {printf \"%s %s %s\", \$1, \$2, \$3}' fuse_wing.slc | grep -qx '2.4425 1.0000 -0.0204'"

# 3) vsploads interpolates the solution onto the CalculiX model fem.inp.
"$VSPLOADS" -interp fuse_wing fem > interp.log 2>&1
check interp_static_nodes grep -qx '1,1.060000,0.650000,0.000000' fem.static.inp
check interp_static_load  grep -qx '\*DLOAD' fem.static.inp
check interp_buckle_file  [ -s fem.buckle.inp ]

emit_ctrf vspaero-kat "$passed" "$failed" 0
