# Reading the start of a Steam chunk cheaply (implementation spec)

Status: spec for implementation (2026-10-24). Background: `docs/specs/workshop-browse.md` §2 (compatibility survey),
`Sources/WESteam/WorkshopProbe.swift`, `Sources/WESteam/ChunkCodec.swift`. Never touch `Sources/WallpaperApp/`,
docs or user-facing text.

## 1. Problem

The survey (`wecli workshop survey --pkg-headers`) needs only the file table at the start of each `scene.pkg` (a few
KB), but downloads the package's whole first chunk (0.75–1 MB, almost all texture data). The user's data is limited.

Measured (2026-10-24, reviewer):
- Steam content servers **ignore `Range`**: `Range: bytes=0-32767` returns the whole chunk (200).
- URLSession streaming + cancel after 32 KB: about **340 KB** per chunk actually arrives (the server sends far ahead).
- A plain BSD socket to **port 80, plain HTTP/1.1**, `SO_RCVBUF` = 16 KB set before `connect`, read ~32 KB then close:
  **≤ 80 KB** per chunk on the wire (`netstat -ib`), `HTTP/1.1 200 OK` from e.g. `cache16-lax1.steamcontent.com`
  with `Host: <vhost>`. Plain HTTP is acceptable here: chunks are AES-encrypted and the decoded prefix is only used
  for a survey (it can't be verified against the chunk SHA-1 anyway, since that covers the whole chunk).

## 2. Implement (`Sources/WESteam/`)

### 2.1 Streaming chunk decoder (`ChunkStream`)

Incremental version of `ChunkCodec.decrypt` + `decompress` that turns a *prefix* of the encrypted chunk into a
*prefix* of the plaintext:
- `init(key:)`, `mutating func append(_ encrypted: Data) throws -> Data` (returns newly available plaintext),
  `var plaintext: Data` (all so far).
- Decryption: the first 16 bytes are the IV encrypted with AES-256-ECB (as `ChunkCodec.decrypt`); then AES-256-CBC.
  Decrypt every complete 16-byte block as it arrives; hold back the last complete block until more data or the end
  (it may carry PKCS#7 padding). Keep CommonCrypto (`CCCryptorCreate` with update calls is fine).
- Decompression by magic (`steam-user/components/cdn_compression.js`, see `ChunkCodec.decompress`):
  - `VSZa`: zstd frame after the 8-byte header → zstd streaming (`ZSTD_decompressStream`; add a small streaming
    shim next to `czstd_decompress` in `Sources/CZstd`; the vendored zstd has the streaming API).
  - `VZa`: LZMA: properties at bytes 7..<12, raw LZMA data from 12; the uncompressed size is only in the footer, so
    use a decoder that doesn't need it (`lzma_alone_decoder` with size `UINT64_MAX`/unknown, or `lzma_raw_decoder` with
    `LZMA_FILTER_LZMA1` and the properties) and feed it incrementally with `LZMA_RUN`.
  - `PK\x03\x04`: ZIP local file header (30 bytes + name + extra), then raw deflate (method 8) → `inflate` with
    `windowBits` −15, incrementally; method 0 (stored) → copy. Data descriptors don't matter for a prefix.
  - Unknown magic → `SteamError.unsupportedCompression`.
- Output cap (`maxOutput`, e.g. 4 MiB) so a hostile stream can't blow up memory.

### 2.2 Peeking over a plain socket (`ChunkPeek`)

`func peek(server: ContentServer, depot: UInt32, sha: Data, key: Data, enough: (Data) throws -> Bool,
maxBytes: Int) async throws -> (plaintext: Data, bytesRead: Int)`:
- BSD socket (IPv4 and IPv6 via `getaddrinfo`), `SO_RCVBUF` 16 KB before `connect`, `SO_NOSIGPIPE`, connect/read
  timeouts (e.g. 10 s), on a background thread or with non-blocking I/O; cancellable.
- Send `GET /depot/<depot>/chunk/<sha hex> HTTP/1.1`, `Host: <vhost>`, `Connection: close`, a `User-Agent` like the
  existing downloader's if it sends one.
- Parse the status line and headers robustly (status must be 200; support `Content-Length` and
  `Transfer-Encoding: chunked`; reject anything else; cap header size).
- Feed body bytes to `ChunkStream`; after each read call `enough(plaintext)`; stop and close the socket as soon as it
  returns true, the body ends, or `maxBytes` raw bytes were read. Return the bytes actually read from the socket
  (headers included) for budget accounting.
- Try the plan's servers in order on connection failure or non-200.

### 2.3 Survey

`WorkshopProbe.inspect` with `--pkg-headers` uses `ChunkPeek` for `scene.pkg` first chunks with
`enough = { WorkshopPackageHeader.names(in: $0, fileSize:) != nil }` and `maxBytes` 256 KB per package (then give up
on that item with a note; do not fall back to downloading the full chunk). Packages that fit in one chunk: same
(peek its only chunk). Small `project.json`/`scene.json` stay as today (full download, they're tiny). Budget: count
`bytesRead`; `--max-mb` limits the sum; `--plan` prints the estimate (items × ~64 KB) instead of the old whole-chunk
sizes. Print the real total read at the end.

## 3. Tests (offline)

- `ChunkStream`: encrypt synthetic chunks in the test (AES-256-ECB IV + CBC with PKCS#7; build VSZa, VZa and ZIP
  payloads — the existing `CodecTests` may already have encoders/fixtures for full chunks), then feed them in random
  splits (1 byte, 7 bytes, 16 bytes, 4 KB…) and check the plaintext prefix equals the original prefix at every step,
  and the full plaintext at the end. Truncated input yields a correct shorter prefix, never garbage.
- `ChunkPeek`: a loopback HTTP server in the test (listen on 127.0.0.1, random port) serving a synthetic chunk with
  `Content-Length`, with chunked encoding, with a 404, and a slow/large body; check early stop (`enough` true after the
  first KB → the socket is closed and `bytesRead` is far below the body size), the `maxBytes` cap, header parsing
  errors, timeouts. Make `ContentServer` usable with a port for tests if needed (keep production on 80 for peeks and
  https for downloads).
- Survey: `inspect` with a fake peek (protocol/closure injection) — names found, budget exhausted, give-up note.

## 4. Done means

`swift build` / `swift test` pass, no new warnings; no change to normal downloads (`ContentDownloader`) or their
tests. Changes limited to `Sources/WESteam/`, `Sources/CZstd/`, `Sources/wecli/main.swift` (survey flags/output only),
`Tests/`. Do not commit; no prose files. Report: files, API, what you couldn't verify (no network in your sandbox:
the reviewer runs the live survey).
