// Serial stand-in for <omp.h>. VSPAERO's sources call omp_get_max_threads() even when built
// without OpenMP (VSP_Solver.C), and the base image ships no libomp. Building with
// -DVSPAERO_OPENMP -I mayhem/omp_stub (and no -fopenmp) makes the `#pragma omp` lines no-ops and
// these calls report a single thread, so the fuzz and test builds are serial and deterministic.
#ifndef VSPFUZZ_OMP_STUB_H
#define VSPFUZZ_OMP_STUB_H
static inline int omp_get_max_threads(void) { return 1; }
static inline int omp_get_thread_num(void) { return 0; }
static inline int omp_get_num_threads(void) { return 1; }
static inline void omp_set_num_threads(int) {}
#endif
