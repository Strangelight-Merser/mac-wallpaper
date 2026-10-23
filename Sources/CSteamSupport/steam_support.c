#include "steam_support.h"
/* Catch accidental ABI changes on the supported 64-bit macOS targets. */
_Static_assert(sizeof(lzma_stream) == 136, "liblzma stream ABI");
_Static_assert(sizeof(lzma_options_lzma) == 112, "liblzma options ABI");
