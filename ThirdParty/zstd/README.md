Decoder-only subset of [zstd](https://github.com/facebook/zstd) v1.5.7 (BSD license, see `LICENSE`), used to
unpack Steam's zstd-compressed depot chunks (`VSZa`). Files are unmodified copies from the v1.5.7 tag:
`lib/zstd.h`, `lib/zstd_errors.h`, `lib/common/` without `pool.*` and `threading.*` (compression only), and
`lib/decompress/` without `huf_decompress_amd64.S` (built with `ZSTD_DISABLE_ASM`). Built by the `CZstd`
target in `Package.swift`.
