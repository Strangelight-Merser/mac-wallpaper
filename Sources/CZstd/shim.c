#include "czstd.h"
#include "zstd/lib/zstd.h"

long czstd_decompress(void *dst, size_t capacity, const void *src, size_t size) {
    size_t written = ZSTD_decompress(dst, capacity, src, size);
    return ZSTD_isError(written) ? -1 : (long)written;
}

void *czstd_stream_create(void) { return ZSTD_createDStream(); }
void czstd_stream_free(void *stream) { ZSTD_freeDStream(stream); }
int czstd_stream_update(void *stream, const void *src, size_t *input_size, void *dst, size_t *output_size) {
    ZSTD_inBuffer in = {src, *input_size, 0};
    ZSTD_outBuffer out = {dst, *output_size, 0};
    size_t result = ZSTD_decompressStream(stream, &out, &in);
    *input_size = in.pos;
    *output_size = out.pos;
    return ZSTD_isError(result) ? -1 : result == 0 ? 1 : 0;
}
