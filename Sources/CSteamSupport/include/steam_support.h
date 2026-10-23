#ifndef STEAM_SUPPORT_H
#define STEAM_SUPPORT_H
#include <stddef.h>
#include <stdint.h>
#include <zlib.h>
#include <CommonCrypto/CommonCryptor.h>

/* liblzma 5.x ABI, verified against lzma/base.h and lzma/lzma12.h.
   Only the alone decoder/encoder is needed; no Homebrew headers or library at build time. */
typedef enum { LZMA_OK = 0, LZMA_STREAM_END = 1 } lzma_ret;
typedef enum { LZMA_RUN = 0, LZMA_FINISH = 3 } lzma_action;
typedef struct {
    const uint8_t *next_in;
    size_t avail_in;
    uint64_t total_in;
    uint8_t *next_out;
    size_t avail_out;
    uint64_t total_out;
    const void *allocator;
    void *internal;
    void *reserved_ptr1, *reserved_ptr2, *reserved_ptr3, *reserved_ptr4;
    uint64_t reserved_int1, reserved_int2;
    size_t reserved_int3, reserved_int4;
    int reserved_enum1, reserved_enum2;
} lzma_stream;
#define LZMA_STREAM_INIT {0}
typedef struct {
    uint32_t dict_size;
    const uint8_t *preset_dict;
    uint32_t preset_dict_size, lc, lp, pb;
    int mode;
    uint32_t nice_len;
    int mf;
    uint32_t depth;
    uint32_t reserved_int1, reserved_int2, reserved_int3, reserved_int4;
    uint32_t reserved_int5, reserved_int6, reserved_int7, reserved_int8;
    int reserved_enum1, reserved_enum2, reserved_enum3, reserved_enum4;
    void *reserved_ptr1, *reserved_ptr2;
} lzma_options_lzma;
extern lzma_ret lzma_alone_decoder(lzma_stream *, uint64_t);
extern lzma_ret lzma_alone_encoder(lzma_stream *, const lzma_options_lzma *);
extern uint8_t lzma_lzma_preset(lzma_options_lzma *, uint32_t);
extern lzma_ret lzma_code(lzma_stream *, lzma_action);
extern void lzma_end(lzma_stream *);
#endif
