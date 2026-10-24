#ifndef CZSTD_H
#define CZSTD_H
#include <stddef.h>

/* One-shot zstd decompression (vendored zstd v1.5.7 decoder, ThirdParty/zstd).
   Returns the number of bytes written to dst, or -1 on corrupt input or if the output exceeds capacity. */
long czstd_decompress(void *dst, size_t capacity, const void *src, size_t size);

void *czstd_stream_create(void);
void czstd_stream_free(void *stream);
int czstd_stream_update(void *stream, const void *src, size_t *input_size, void *dst, size_t *output_size);

#endif
