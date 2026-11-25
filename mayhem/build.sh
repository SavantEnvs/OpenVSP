#!/usr/bin/env bash
#
# mayhem/build.sh — build the OpenVSP fuzz targets and the functional-test binaries.
#
# Targets (all AFL file-input, see mayhem/harnesses/vsp_aero_fuzz.cpp):
#   vspaero_geom    VSPAERO solver: .vspaero case + .vkey + .vspgeom readers and geometry setup (-geom)
#   vsploads_slice  vsploads (Adb2Load): .adb solution reader + .cuts reader + slicer (-slice)
#   vsploads_interp vsploads (Adb2Load): .adb reader + CalculiX .inp reader + search/interp (-interp)
# The VSPAERO tools are standalone C++ with no third-party dependencies; they are compiled here
# straight from upstream's source lists (src/vsp_aero/Solver/CMakeLists.txt, src/vsp_aero/Adb2Load).
# Upstream's tools exit() on bad input, hence AFL (afl-clang-fast, one process per input) rather
# than libFuzzer. The tools' main() is renamed to tool_main at compile time so the harness can unpack
# the multi-file input first.
#
#   vsp3_read       OpenVSP core library: vsp::ReadVSPFile (.vsp3 XML model) + Update()   (libFuzzer)
#   stl_import      OpenVSP core library: vsp::ImportFile( IMPORT_STL ) + Update()         (libFuzzer)
# The core targets build upstream's own CMake tree (src/, VSP_NO_GRAPHICS) with the sanitizers, against
# the vendored Libraries/ (libxml2, AngelScript, STEPcode, libIGES, ...) prebuilt uninstrumented in the
# image under /opt/toolchains/deps/openvsp-libraries-3.57.1 (see mayhem/Dockerfile).
#
# The test binaries (mayhem/out/test/{vspaero,vsploads}) are a separate build with normal flags.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${AFL_CXX:=afl-clang-fast++}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

OUT="$SRC/mayhem/out"
SOLVER="$SRC/src/vsp_aero/Solver"
ADB="$SRC/src/vsp_aero/Adb2Load"
mkdir -p "$OUT/obj-fuzz/solver" "$OUT/obj-fuzz/adb" "$OUT/obj-test/solver" "$OUT/obj-test/adb" "$OUT/test"

# Upstream's own source list for vspaero_lib (VSPAERO_CORE_FILES), plus the vspaero main.
mapfile -t SOLVER_SRCS < <(sed -n '/SET( VSPAERO_CORE_FILES/,/)/p' "$SOLVER/CMakeLists.txt" | grep -oE '^[A-Za-z_]+\.C' | sort -u)
SOLVER_SRCS+=(vspaero.C)
mapfile -t ADB_SRCS < <(cd "$ADB" && ls *.C)

COMMON_DEFS=(-DMYTIME -DVSPAERO_OPENMP -I"$SRC/mayhem/omp_stub" -w)

# compile <compiler> <srcdir> <objdir> <flags...> -- <files...>
compile() {
  local cxx="$1" srcdir="$2" objdir="$3"; shift 3
  local flags=()
  while [ "$1" != "--" ]; do flags+=("$1"); shift; done
  shift
  printf '%s\n' "$@" | xargs -P "$MAYHEM_JOBS" -I{} sh -c '
    f="$1"; shift; cxx="$1"; srcdir="$2"; objdir="$3"; shift 3
    extra=""
    # vspaero.C main() ends without a return statement, which is only defined behaviour while the
    # function is called main; once renamed, UBSan -fsanitize=return fires on every input that
    # gets through. Only that one check, only in that one file, is turned off.
    case "$f" in vspaero.C) extra="-Dmain=tool_main -fno-sanitize=return";; adb2loads.C) extra="-Dmain=tool_main";; esac
    exec "$cxx" "$@" $extra -c "$srcdir/$f" -o "$objdir/${f%.C}.o"' _ {} "$cxx" "$srcdir" "$objdir" "${flags[@]}"
}

# 1) Fuzz build: project sources + harness, AFL-instrumented, sanitized, DWARF 3.
# shellcheck disable=SC2206
FUZZ_FLAGS=(-O1 $SANITIZER_FLAGS $DEBUG_FLAGS "${COMMON_DEFS[@]}")
compile "$AFL_CXX" "$SOLVER" "$OUT/obj-fuzz/solver" "${FUZZ_FLAGS[@]}" -- "${SOLVER_SRCS[@]}"
compile "$AFL_CXX" "$ADB" "$OUT/obj-fuzz/adb" "${FUZZ_FLAGS[@]}" -- "${ADB_SRCS[@]}"
"$AFL_CXX" "${FUZZ_FLAGS[@]}" -c "$SRC/mayhem/lsan_off.cc" -o "$OUT/obj-fuzz/lsan_off.o"

harness() {  # harness <name> <define> <objdir>
  local name="$1" def="$2" objdir="$3"
  "$AFL_CXX" "${FUZZ_FLAGS[@]}" "-D$def" -c "$SRC/mayhem/harnesses/vsp_aero_fuzz.cpp" -o "$OUT/obj-fuzz/$name.o"
  "$AFL_CXX" "${FUZZ_FLAGS[@]}" "$OUT/obj-fuzz/$name.o" "$objdir"/*.o "$OUT/obj-fuzz/lsan_off.o" -lm -o "$OUT/$name"
}
harness vspaero_geom VSPFUZZ_TOOL_VSPAERO "$OUT/obj-fuzz/solver"
harness vsploads_slice VSPFUZZ_TOOL_SLICE "$OUT/obj-fuzz/adb"
harness vsploads_interp VSPFUZZ_TOOL_INTERP "$OUT/obj-fuzz/adb"

# 2) Test build: the real command-line tools, normal flags (main() not renamed).
# shellcheck disable=SC2206
TEST_FLAGS=(-O2 $COVERAGE_FLAGS "${COMMON_DEFS[@]}")
compile_test() {
  local srcdir="$1" objdir="$2"; shift 2
  printf '%s\n' "$@" | xargs -P "$MAYHEM_JOBS" -I{} sh -c '
    f="$1"; shift; cxx="$1"; srcdir="$2"; objdir="$3"; shift 3
    exec "$cxx" "$@" -c "$srcdir/$f" -o "$objdir/${f%.C}.o"' _ {} "$CXX" "$srcdir" "$objdir" "${TEST_FLAGS[@]}"
}
compile_test "$SOLVER" "$OUT/obj-test/solver" "${SOLVER_SRCS[@]}"
compile_test "$ADB" "$OUT/obj-test/adb" "${ADB_SRCS[@]}"
"$CXX" "${TEST_FLAGS[@]}" "$OUT/obj-test/solver"/*.o -lm -o "$OUT/test/vspaero"
"$CXX" "${TEST_FLAGS[@]}" "$OUT/obj-test/adb"/*.o -lm -o "$OUT/test/vsploads"

# 3) Core library (src/) with sanitizers + libFuzzer coverage, then the core harnesses.
: "${VSP_LIBRARY_PATH:=/opt/toolchains/deps/openvsp-libraries-3.57.1/build}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
CORE="$OUT/core-build"
CORE_FLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -w"
cmake -S "$SRC/src" -B "$CORE" -DVSP_LIBRARY_PATH="$VSP_LIBRARY_PATH" -DVSP_NO_GRAPHICS=ON -DVSP_NO_DOC=ON \
  -DCMAKE_BUILD_TYPE= -DCMAKE_C_FLAGS="$CORE_FLAGS" -DCMAKE_CXX_FLAGS="$CORE_FLAGS"
# vspscript links every core library, so building it builds them all; its flags.make and link.txt
# give the include path and the library list the harnesses use.
cmake --build "$CORE" --target vspscript -j "$MAYHEM_JOBS"
VSPS="$CORE/vsp/CMakeFiles/vspscript.dir"
CORE_INC=$(sed -n 's/^CXX_INCLUDES = //p' "$VSPS/flags.make")
CORE_DEF=$(sed -n 's/^CXX_DEFINES = //p' "$VSPS/flags.make")
CORE_LIBS=$(sed 's/.* -o vspscript //' "$VSPS/link.txt")
"$CC" -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OUT/obj-fuzz/standalone_main.o"
"$CXX" -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OUT/obj-fuzz/lsan_off_core.o"
core_harness() {  # core_harness <name> <mode>
  local name="$1" mode="$2"
  # shellcheck disable=SC2086
  (cd "$CORE/vsp" && "$CXX" -std=c++17 $CORE_FLAGS $CORE_DEF $CORE_INC "-DVSPCORE_MODE_$mode" \
     -c "$SRC/mayhem/harnesses/vsp_core_fuzz.cpp" -o "$OUT/obj-fuzz/$name.o")
  # The static libraries reference each other in a cycle, so link them as a group (from vsp/, where
  # link.txt's relative paths resolve).
  # shellcheck disable=SC2086
  (cd "$CORE/vsp" && "$CXX" -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OUT/obj-fuzz/$name.o" \
     "$OUT/obj-fuzz/lsan_off_core.o" -Wl,--start-group $CORE_LIBS -Wl,--end-group -o "$SRC/mayhem/out/$name")
  # shellcheck disable=SC2086
  (cd "$CORE/vsp" && "$CXX" -O1 $SANITIZER_FLAGS $DEBUG_FLAGS "$OUT/obj-fuzz/$name.o" "$OUT/obj-fuzz/standalone_main.o" \
     "$OUT/obj-fuzz/lsan_off_core.o" -Wl,--start-group $CORE_LIBS -Wl,--end-group -o "$SRC/mayhem/out/$name-standalone")
}
core_harness vsp3_read VSP3
core_harness stl_import STL

ls -la "$OUT/vsp3_read" "$OUT/stl_import" "$OUT/vspaero_geom" "$OUT/vsploads_slice" "$OUT/vsploads_interp" "$OUT/test/vspaero" "$OUT/test/vsploads"
