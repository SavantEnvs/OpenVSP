// libFuzzer harness over the OpenVSP core library's file readers (geom_api / geom_core).
//
//   VSPCORE_MODE_VSP3  vsp::ReadVSPFile  -> Vehicle::ReadXMLFile (.vsp3 XML model) + Update()
//   VSPCORE_MODE_STL   vsp::ImportFile( IMPORT_STL )  -> MeshGeom STL reader (ASCII + binary)
//
// The API only takes file names, so each input is written to a fresh mkstemps() file under
// $TMPDIR with the extension the reader expects, then removed. Per-input state: VSPRenew() wipes
// the vehicle (geoms, parms, settings) before every input, so a result depends only on its input.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>

#include "VSP_Geom_API.h"
#include "APIErrorMgr.h"

#if defined( VSPCORE_MODE_VSP3 )
static const char *kSuffix = ".vsp3";
#elif defined( VSPCORE_MODE_STL )
static const char *kSuffix = ".stl";
#else
#error "define one VSPCORE_MODE_*"
#endif

extern "C" int LLVMFuzzerInitialize( int *, char *** )
{
    vsp::VSPCheckSetup();
    vsp::ErrorMgr.SilenceErrors();
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput( const uint8_t *data, size_t size )
{
    const char *tmp = getenv( "TMPDIR" );
    if ( !tmp || !*tmp ) tmp = "/tmp";
    std::string path = std::string( tmp ) + "/vspcore_XXXXXX" + kSuffix;
    int fd = mkstemps( &path[0], (int)strlen( kSuffix ) );
    if ( fd < 0 ) return 0;
    size_t off = 0;
    while ( off < size )
    {
        ssize_t n = write( fd, data + off, size - off );
        if ( n <= 0 ) break;
        off += (size_t)n;
    }
    close( fd );

    vsp::VSPRenew();
#if defined( VSPCORE_MODE_VSP3 )
    vsp::ReadVSPFile( path );
#elif defined( VSPCORE_MODE_STL )
    vsp::ImportFile( path, vsp::IMPORT_STL, "" );
#endif
    vsp::Update();

    unlink( path.c_str() );
    // The API error queue is process-global; drain it so it does not grow across inputs.
    while ( vsp::ErrorMgr.GetNumTotalErrors() > 0 ) vsp::ErrorMgr.PopLastError();
    return 0;
}
