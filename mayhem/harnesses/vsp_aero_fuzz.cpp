// AFL file-input harness for the standalone VSPAERO tools (vspaero solver, vsploads/Adb2Load).
//
// Both tools take a BASE NAME on the command line and open several files derived from it
// (<base>.vspaero + <base>.vkey + <base>.vspgeom for vspaero; <base>.cuts + <base>.adb.cases + <base>.adb,
// or <fem>.inp + <base>.adb.cases + <base>.adb, for vsploads). So one fuzz input is a small "pack": the files' contents
// in a fixed order, separated by a line `@@VSPFUZZ@@`. Missing sections are simply not written
// (the tool then sees a missing file, as it would on a real run). The last section is taken
// verbatim to the end of the input, so the binary .adb solution file goes last.
//
// The harness unpacks into a fresh private directory under $TMPDIR, chdirs there and calls the
// tool's own main() (renamed at compile time) with the tool's real command line. The tools exit()
// on bad input, which is why this is an AFL (fork-server, one process per input) target and not
// libFuzzer: every input runs in a new process, so no state carries over between inputs. The
// scratch directory is removed at exit.
//
// Build with -DVSPFUZZ_TOOL_VSPAERO, -DVSPFUZZ_TOOL_SLICE or -DVSPFUZZ_TOOL_INTERP.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <ftw.h>
#include <unistd.h>
#include <sys/stat.h>

int tool_main(int argc, char **argv);

static std::string g_scratch;

static int rm_entry(const char *path, const struct stat *, int, struct FTW *) {
    remove(path);
    return 0;
}

static void cleanup(void) {
    if (!g_scratch.empty()) {
        if (chdir("/") != 0) { /* ignore */ }
        nftw(g_scratch.c_str(), rm_entry, 16, FTW_DEPTH | FTW_PHYS);
    }
}

static void write_file(const std::string &name, const std::string &data) {
    FILE *f = fopen(name.c_str(), "wb");
    if (!f) { perror(name.c_str()); abort(); }
    if (!data.empty()) fwrite(data.data(), 1, data.size(), f);
    fclose(f);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <packed input file>\n", argv[0]);
        return 2;
    }
    std::string in;
    {
        FILE *f = fopen(argv[1], "rb");
        if (!f) { perror(argv[1]); return 2; }
        char buf[65536];
        size_t n;
        while ((n = fread(buf, 1, sizeof buf, f)) > 0) in.append(buf, n);
        fclose(f);
    }

    // Split into sections.
#if defined(VSPFUZZ_TOOL_VSPAERO)
    const char *names[] = {"fuzz.vspaero", "fuzz.vkey", "fuzz.vspgeom"};
#elif defined(VSPFUZZ_TOOL_SLICE)
    const char *names[] = {"fuzz.cuts", "fuzz.adb.cases", "fuzz.adb"};
#elif defined(VSPFUZZ_TOOL_INTERP)
    const char *names[] = {"fem.inp", "fuzz.adb.cases", "fuzz.adb"};
#else
#error "define one VSPFUZZ_TOOL_*"
#endif
    const size_t nsec = sizeof(names) / sizeof(names[0]);
    static const std::string sep = "\n@@VSPFUZZ@@\n";
    std::vector<std::string> secs;
    size_t pos = 0;
    while (secs.size() + 1 < nsec) {
        size_t hit = in.find(sep, pos);
        if (hit == std::string::npos) break;
        secs.push_back(in.substr(pos, hit - pos + 1));  // keep the section's trailing newline
        pos = hit + sep.size();
    }
    secs.push_back(in.substr(pos));

    const char *tmp = getenv("TMPDIR");
    std::string tmpl = std::string(tmp && *tmp ? tmp : "/tmp") + "/vspfuzz.XXXXXX";
    std::vector<char> t(tmpl.begin(), tmpl.end());
    t.push_back('\0');
    if (!mkdtemp(t.data())) { perror("mkdtemp"); abort(); }
    g_scratch = t.data();
    atexit(cleanup);
    if (chdir(g_scratch.c_str()) != 0) { perror("chdir"); abort(); }
    for (size_t i = 0; i < secs.size(); i++) write_file(names[i], secs[i]);

#if defined(VSPFUZZ_TOOL_VSPAERO)
    // -geom: read the case, key and geometry files and set the solver up, but skip the solve.
    char *args[] = {(char *)"vspaero", (char *)"-omp", (char *)"1", (char *)"-geom", (char *)"fuzz", nullptr};
#elif defined(VSPFUZZ_TOOL_SLICE)
    char *args[] = {(char *)"vsploads", (char *)"-slice", (char *)"fuzz", nullptr};
#else
    char *args[] = {(char *)"vsploads", (char *)"-interp", (char *)"fuzz", (char *)"fem", nullptr};
#endif
    int rc = tool_main((int)(sizeof(args) / sizeof(args[0])) - 1, args);
    cleanup();
    g_scratch.clear();
    return rc;
}
