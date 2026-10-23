#include "czstd.h"
#include "zstd/lib/zstd.h"

long czstd_decompress(void *dst, size_t capacity, const void *src, size_t size) {
    size_t written = ZSTD_decompress(dst, capacity, src, size);
    return ZSTD_isError(written) ? -1 : (long)written;
}
