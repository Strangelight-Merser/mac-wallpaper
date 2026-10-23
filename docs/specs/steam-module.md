# WESteam — native Steam module (implementation spec)

Status: implemented 2026-10-22 (see `docs/design.md` §6.21 for review fixes and live results). Background: §6.19–6.20.

## 1. Goal and scope

A Swift module that lets mac-wallpaper act as a minimal Steam client for one purpose: **a user who owns
Wallpaper Engine (app 431960) logs in once with a QR code and we can list and download their workshop
wallpapers**. Everything below was proven in a spike (Node `steam-user` + hand-written HTTPS calls); this
module re-implements it natively.

In scope:
1. Login over Steam's `IAuthenticationService` HTTPS API: QR code (primary) and account name + password with
   Steam Guard (fallback). Result: refresh token (+ access token).
2. Token storage in the macOS Keychain.
3. Web session cookies for steamcommunity/store (for an embedded WKWebView, implemented later by the UI).
4. A Connection Manager (CM) client over **WebSocket only**: logon with the refresh token, heartbeat, jobs,
   unified service calls, depot decryption keys.
5. Workshop: item details (public API), the user's subscriptions, download of one item's content
   (manifest → chunks → decrypt → decompress → verify → files).
6. `wecli steam …` commands to exercise all of the above live.
7. Offline unit tests.

Out of scope (do not implement): TCP CM transport and channel encryption, friends/chat, PICS app info,
downloading apps (only workshop items), uploading, Steam Guard TOTP generation, UI of any kind.

## 2. Hard constraints

- **No third-party dependencies, no network access at build time.** System frameworks only: Foundation,
  Security (Keychain, RSA), CommonCrypto (AES, SHA-1), CryptoKit if convenient, zlib (`libz`), and the
  system `liblzma` (`/usr/lib/liblzma.dylib`; the SDK ships `liblzma.tbd` but **no `lzma.h`** — declare the
  handful of functions/structs you need in a small C target, see §9).
- No SwiftProtobuf: hand-write a minimal protobuf encoder/decoder (varint, zigzag not needed, fixed32/64,
  length-delimited; skip unknown fields) and encode/decode only the messages listed here.
- **Verify every message ID, field number and enum value against the references in §3** — numbers in this
  spec are from memory and may be wrong. If they disagree, the reference wins; note it in a code comment.
- Swift 6 language mode compatible; public API is `async`/`await` and `Sendable` where it crosses tasks.
  Match the repo's style (see `Sources/WEVideo`, `Sources/WEWeb`): doc comments on public types, few inline
  comments, no banner comments.
- Never log or print tokens, passwords or cookie values (log lengths/hashes at most).
- User data is limited: anything that downloads content must report the total size **before** downloading
  and honour a byte limit (see §8.3).

## 3. References (read-only, on this machine)

`REF=<scratchpad>/steamuser/node_modules`

| What | Where |
|---|---|
| CM protocol, logon, jobs, multi, heartbeat | `$REF/steam-user/components/02-connection.js`, `03-messages.js`, `09-logon.js`, `connection_protocols/websocket.js` |
| Unified service calls | `$REF/steam-user/components/03-messages.js` (`_sendUnified`) |
| Depot keys, manifests, chunks, servers | `$REF/steam-user/components/cdn.js`, `apps.js`, `content_manifest.js`, `cdn_compression.js` |
| Workshop details | `$REF/steam-user/components/pubfiles.js` |
| EMsg and enum values | `$REF/steam-user/enums/EMsg.js`, `EResult.js`, `EDepotFileFlag.js`, … |
| Message definitions (field numbers) | `$REF/steam-user/protobufs/*.proto` (e.g. `steammessages_base.proto`, `steammessages_clientserver_login.proto`, `steammessages_clientserver_2.proto`, `content_manifest.proto`, `steammessages_contentsystem.steamclient.proto`, `steammessages_publishedfile.steamclient.proto`, `steammessages_auth.steamclient.proto`) |
| Auth flow over WebAPI | `$REF/steam-session/` (`dist/…` — `LoginSession`, `AuthenticationClient`, `WebApiTransport`) |
| AES scheme | `$REF/@doctormckay/steam-crypto/index.js` (**its unpadding is buggy on Node 26 — see §7.3; follow §7.3, not its code**) |

These are MIT-licensed JavaScript; port behaviour, do not copy text verbatim.

## 4. Package layout

```
Package.swift                   + targets below; add WESteam to wecli's dependencies
Sources/CSteamSupport/          C target: include/steam_support.h (+ a .c if needed)
                                minimal liblzma declarations (lzma_stream, lzma_ret, lzma_action,
                                lzma_alone_decoder / lzma_raw_decoder + lzma_properties_decode, lzma_code,
                                lzma_end; and the encoder side only if tests need it), linkedLibrary("lzma"),
                                linkedLibrary("z")
Sources/WESteam/
  Protobuf.swift                ProtoWriter / ProtoReader
  WebAPI.swift                  HTTPS calls to api.steampowered.com (form-encoded POST / GET, JSON responses,
                                x-eresult header → error)
  Auth.swift                    QR + credentials login, access-token renewal
  Tokens.swift                  SteamTokens, JWT claim decoding (no signature check), Keychain store
  WebSession.swift              cookies for WKWebView
  CMClient.swift                actor: directory, WebSocket, framing, multi, jobs, heartbeat, logon, unified,
                                depot keys
  Messages.swift                the message structs (encode/decode) used by CMClient
  Workshop.swift                details, subscriptions
  ContentDownloader.swift       servers, manifest request codes, manifests, chunks, files
  ContentManifest.swift         manifest container + payload/metadata parsing, filename decryption
  ChunkCodec.swift              AES decrypt, VZip (LZMA) / zip / zstd detection, verification
Sources/wecli/main.swift        `steam` subcommands (§10)
Tests/WESteamTests/             XCTest, offline only (§11)
```

## 5. Login (HTTPS, `https://api.steampowered.com/IAuthenticationService/<Method>/v1/`)

Requests are `POST application/x-www-form-urlencoded` (`+` must be percent-encoded as `%2B`), responses JSON
`{"response":{…}}`; the HTTP header `x-eresult` carries the EResult (1 = OK). This form/JSON style is
**verified live for the QR methods**; for the others follow steam-session's field names. If a method
rejects form input, fall back to `input_protobuf_encoded=<base64 protobuf>` as steam-session does.

### 5.1 QR (verified)
1. `BeginAuthSessionViaQR`: `device_friendly_name` (e.g. "mac-wallpaper on <Mac model/hostname>"),
   `platform_type=1` (k_EAuthTokenPlatformType_SteamClient — required: its tokens work for CM logon and web
   cookies). Response: `client_id` (string of a uint64), `challenge_url` (`https://s.team/q/1/<id>`),
   `request_id` (base64), `interval` (seconds), `allowed_confirmations`.
2. Poll `PollAuthSessionStatus` (`client_id`, `request_id`) every `interval` seconds. Fields that may appear:
   `new_challenge_url` (the QR must be redrawn), `new_client_id` (**ignore it** — live tests showed that
   switching to it after a scan ends the session with EResult 9; keep polling with the original `client_id`),
   `had_remote_interaction` (scanned, waiting for confirmation), and on success `refresh_token`,
   `access_token`, `account_name`.
3. Expiry: stop after 10 minutes or on a terminal EResult; the caller may start a new session.

API sketch (adjust names to taste, keep the shape):
```swift
public enum QRLoginEvent: Sendable { case challenge(URL), scanned, succeeded(SteamTokens) }
public struct SteamQRLogin: Sendable {
    public init(deviceName: String)
    /// Events until success; throws on expiry, cancellation (Task cancel) or Steam errors.
    public func events() -> AsyncThrowingStream<QRLoginEvent, Error>
}
```
Rendering the QR image is the caller's job (CoreImage `CIQRCodeGenerator` in wecli; note the code needs an
**opaque white quiet zone** — a transparent border breaks phone scanners on dark backgrounds).

### 5.2 Credentials + Steam Guard (unverified, port from steam-session)
`GetPasswordRSAPublicKey` (GET, `account_name`) → `publickey_mod`, `publickey_exp` (hex), `timestamp`;
encrypt the password with RSA PKCS#1 v1.5 (Security: build a PKCS#1 `RSAPublicKey` DER from modulus/exponent,
`SecKeyCreateWithData`, `.rsaEncryptionPKCS1`), base64 → `BeginAuthSessionViaCredentials` (`account_name`,
`encrypted_password`, `encryption_timestamp`, `remember_login=true`, `platform_type=1`, `persistence=1`,
device details as in steam-session) → `client_id`, `request_id`, `steamid`, `allowed_confirmations`
(types: none, email code, device code, device confirmation, email confirmation — enum
`EAuthSessionGuardType`). Codes go to `UpdateAuthSessionWithSteamGuardCode` (`client_id`, `steamid`,
`code`, `code_type`); device confirmation just keeps polling. Then poll as in 5.1.

### 5.3 Access token renewal
Access tokens live ~1 day, refresh tokens ~7 months. `GenerateAccessTokenForApp` (`refresh_token`,
`steamid`, optional `renewal_type`) returns a new `access_token` (and maybe a new `refresh_token` — store it).
Expose `func freshAccessToken(_ tokens: SteamTokens) async throws -> SteamTokens` that renews when the
access token's JWT `exp` is under 1 hour away.

Note (verified): the Steam **Web API** (e.g. `IPublishedFileService/GetUserFiles` with `access_token`)
rejects these SteamClient tokens with 401. Do not design anything around it.

## 6. Tokens, Keychain, web session

```swift
public struct SteamTokens: Codable, Sendable, Equatable {
    public var accountName: String
    public var steamID: UInt64          // from the JWT `sub`
    public var refreshToken: String
    public var accessToken: String?
}
public enum SteamKeychain {             // kSecClassGenericPassword, service "dev.macwallpaper.steam"
    public static func save(_ t: SteamTokens) throws        // account = accountName, data = JSON, AfterFirstUnlock
    public static func load(account: String?) throws -> SteamTokens?   // nil account → most recently saved
    public static func delete(account: String) throws
    public static func accounts() throws -> [String]
}
```
Also expose JWT claim decoding (`sub`, `aud`, `exp`) without verifying signatures.

Web session (verified): cookie `steamLoginSecure=<steamid>%7C%7C<access token>` (the value is
literally `steamid||token` with `|` percent-encoded) plus `sessionid=<24 random hex>` for domains
`steamcommunity.com` and `store.steampowered.com`, `Path=/`, `Secure`, `HttpOnly` for steamLoginSecure.
Provide `func webCookies(_ t: SteamTokens) -> [HTTPCookie]` (requires an access token).

## 7. CM client (actor)

### 7.1 Connecting
- Server list: `GET https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&format=json`
  → `response.serverlist[]` with `endpoint`, `type` (`websockets`/`netfilter`), `load`, `wtd_load`, `dc`.
  Use `websockets` entries, best `wtd_load` first; try up to 5 with a 10 s connect timeout each.
- Connect `URLSessionWebSocketTask` to `wss://<endpoint>/cmsocket/`. WebSocket CMs are TLS-protected and
  need **no** ChannelEncrypt handshake.
- Each binary WebSocket message is one packet. Protobuf-backed packet layout (little endian):
  `uint32 emsg | 0x80000000`, `uint32 headerLength`, `CMsgProtoBufHeader`, body.
  Ignore non-protobuf packets except to log their EMsg.
- `CMsgProtoBufHeader` (steammessages_base.proto) fields you need: `steamid`, `client_sessionid`,
  `jobid_source`, `jobid_target`, `target_job_name`, `eresult`, `error_message`, `realm` (if steam-user sets
  it). After logon, every outgoing header carries the steamid and session id from the logon response.
- `EMsg.Multi` (`CMsgMulti`: `size_unzipped`, `message_body`): if `size_unzipped > 0` the body is gzip
  (inflate with zlib, windowBits 16+15); the result is repeated `[uint32 length][packet]`.

### 7.2 Logon, session, jobs
- `ClientLogon` (`CMsgClientLogon`): mirror `09-logon.js` for a refresh-token logon (`access_token` =
  refresh token, `account_name`, `should_remember_password`, `protocol_version`, `client_os_type`,
  `machine_name`, `client_language`, `obfuscated_private_ip`, `machine_id` if steam-user sends one, etc.).
  Header steamid for logon = individual account, public universe, desktop instance, account id from the
  token's `sub` (see steam-user).
- `ClientLogOnResponse`: `eresult`, `heartbeat_seconds`, `cell_id`, `public_ip`, `ip_country_code`,
  `client_supplied_steamid` …; header gives `steamid` and `client_sessionid`. Non-OK → throw with the EResult
  (map at least: InvalidPassword/AccessDenied/Expired → "token invalid, log in again", TryAnotherCM /
  ServiceUnavailable → try next server).
- Heartbeat: `ClientHeartBeat` every `heartbeat_seconds` (`CMsgClientHeartBeat`, `send_reply` false).
- Jobs: allocate `jobid_source` (monotonic UInt64 starting at 1); responses come back with `jobid_target`.
  Pending jobs time out after 15 s. On disconnect, fail all pending jobs; no automatic reconnect in this
  version (callers reconnect).
- `ClientLoggedOff` / socket close → session ends with an error event.
- Logoff: `ClientLogOff`, then close.

```swift
public actor SteamCMClient {
    public init(machineName: String)
    public func connect() async throws
    public func logOn(_ tokens: SteamTokens) async throws -> SteamSession   // steamID, cellID, ipCountry
    public func callService(_ method: String, _ body: Data) async throws -> Data   // "Service.Method#1"
    public func depotDecryptionKey(appID: UInt32, depotID: UInt32) async throws -> Data   // 32 bytes
    public func disconnect() async
}
```
- Unified call: send `ServiceMethodCallFromClient` with header `target_job_name` = method and a job id;
  reply `ServiceMethodResponse` with matching `jobid_target`; header `eresult` ≠ 1 → throw.
- Depot key: `ClientGetDepotDecryptionKey` (`depot_id`, `app_id`) → `ClientGetDepotDecryptionKeyResponse`
  (`eresult`, `depot_id`, `depot_encryption_key`). Cache per depot for the session.

### 7.3 Chunk/filename AES scheme (verified)
Ciphertext = 16-byte block + rest. IV = AES-256-**ECB**-decrypt(first block) with the depot key (no
padding). Plaintext = AES-256-**CBC**-decrypt(rest, key, IV) without automatic padding, then strip
**PKCS#7** padding manually: last byte `n` must be 1…16 and the last `n` bytes must all equal `n`, else
error. (steam-crypto on Node 26 removed 16 bytes instead of 7 and cut off the `zv` footer — test this.)

## 8. Workshop and content

### 8.1 Details (public, verified)
`POST https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/` with `itemcount=N`,
`publishedfileids[i]=…` (batch ≤ 100). Map to:
```swift
public struct WorkshopItem: Sendable, Codable, Equatable {
    public var id: UInt64; public var appID: UInt32; public var title: String
    public var fileSize: Int64; public var timeUpdated: Date; public var contentManifestID: UInt64  // hcontent_file
    public var previewURL: URL?; public var tags: [String]
    public var kind: Kind?          // from tags: Scene / Video / Web / Application / Preset
    public var rating: Rating?      // from tags: Everyone / Questionable / Mature
    public var result: Int          // EResult per item (9 = not found / removed)
}
```
`file_url` is empty for these items; content comes only through the depot download below.

### 8.2 Subscriptions
Primary: unified `PublishedFile.GetUserFiles#1` over the CM session (`steamid`, `appid=431960`,
`type="mysubscriptions"`, `numperpage=100`, paging, `ids_only` or minimal returns) — **verified live**; if
Steam rejects it, fall back to the web page, which is **verified**:
`https://steamcommunity.com/profiles/<steamid>/myworkshopfiles/?appid=431960&browsefilter=mysubscriptions&p=<n>&numperpage=30`
fetched with the §6 cookies; collect `sharedfiles/filedetails/?id=(\d+)`, stop when a page adds no new IDs;
verify login by finding the user's steamid in the page (e.g. `g_steamID = "<id>"`). Return IDs; details come
from 8.1. Expose which path was used (for diagnostics).

### 8.3 Download one workshop item (verified end to end)
For workshop content of app 431960 the **depot ID equals the app ID** and the manifest ID is `hcontent_file`.
1. Servers: `GET https://api.steampowered.com/IContentServerDirectoryService/GetServersForSteamPipe/v1/?cell_id=<cellID>`
   → `response.servers[]` (`type` SteamCache/CDN, `https_support`, `host`, `vhost`, `weighted_load`,
   `allowed_app_ids`, `use_as_proxy`). Use servers without proxy/app restrictions, HTTPS, lowest load; keep
   several for rotation. (These caches did not need a CDN auth token; if a server has `usetokenauth`, skip it.)
2. Manifest request code: unified `ContentServerDirectory.GetManifestRequestCode#1` (`app_id`, `depot_id`,
   `manifest_id`, `app_branch="public"`) → `manifest_request_code` (uint64).
3. `GET https://<host>/depot/<depot>/manifest/<manifestID>/5/<requestCode>` → compressed manifest (normally a
   zip archive with one entry; use the same decompressor as chunks).
4. Manifest container: repeated `[uint32 magic][uint32 length][bytes]` (LE):
   `0x71F617D0` payload (`ContentManifestPayload`), `0x1F4812BE` metadata (`ContentManifestMetadata`),
   `0x1B81B817` signature (ignore), `0x32C415AB` end marker (no length). Check magics against
   `content_manifest.js`. Payload: `mappings[]` = `filename`, `size`, `flags`, `sha_filename`, `sha_content`,
   `chunks[]` (`sha`, `crc`, `offset`, `cb_original`, `cb_compressed`), `linktarget`.
   If metadata `filenames_encrypted`: filename = base64-decode → §7.3 decrypt → UTF-8, trim trailing NULs.
   Normalise `\` to `/`; reject absolute paths and `..` components.
5. Before downloading: compute total `cb_compressed` (network bytes) and total `size`; call the size check
   (`maxBytes` parameter; throw `.tooLarge(total)` if exceeded) and report sizes to the caller.
6. Chunks: `GET https://<host>/depot/<depot>/chunk/<sha hex>`; check length = `cb_compressed`; decrypt
   (§7.3); decompress by header:
   - `VZa` (LZMA): `"VZa"` + 4 bytes (CRC or timestamp) + 5 bytes LZMA properties + data + footer
     `uint32 crc32(decompressed)`, `uint32 decompressedSize`, `"zv"`. Decode raw LZMA1 with liblzma
     (`lzma_raw_decoder` with props from `lzma_properties_decode`, or wrap as `.lzma` "alone" by appending an
     8-byte size to the props and use `lzma_alone_decoder`). Check size and CRC32 (zlib `crc32`).
   - `VSZa` (zstd): **not supported yet** — throw `.unsupportedCompression("zstd")` (we will add a decoder
     after the user approves vendoring zstd).
   - `PK\x03\x04`: zip with one entry; inflate raw deflate (zlib, windowBits -15) or stored.
   Then verify `SHA1(plain) == chunk.sha` and `plain.count == cb_original`.
7. Files: write into `<dest>.partial/<path>` at each chunk's `offset` (pwrite or a preallocated file);
   directories (flag `EDepotFileFlag.Directory`) are created; empty files created; symlinks
   (`linktarget`) skipped with a warning. Verify `SHA1(file) == sha_content` when `sha_content` is not all
   zero. Resume: a file in `<dest>.partial` whose SHA-1 already matches is not downloaded again.
   When all files verify: replace `<dest>` atomically (move old aside, move new in, delete old).
   Write `<dest>/.steam-manifest.json` with `{ "publishedFileID", "manifestID", "timeUpdated", "files": N,
   "bytes": total }` so updates can be detected later.
8. Concurrency: 6 chunk downloads in flight (configurable), 3 retries per chunk rotating servers, 30 s request
   timeout. Progress: `AsyncStream` or callback with `(networkBytesDone, networkBytesTotal, filesDone, filesTotal)`.

```swift
public struct WorkshopDownloader {
    public init(client: SteamCMClient, session: SteamSession)
    public func plan(_ item: WorkshopItem) async throws -> DownloadPlan        // manifest fetched, sizes known
    public func download(_ plan: DownloadPlan, to dest: URL, maxBytes: Int64,
                         progress: @Sendable (DownloadProgress) -> Void) async throws -> DownloadResult
}
```

## 9. liblzma declarations

The SDK has `usr/lib/liblzma.tbd` but no header. In `Sources/CSteamSupport/include/steam_support.h` declare
exactly what you use, copying the ABI from liblzma 5.x's public `lzma.h` (public domain): `lzma_ret`,
`lzma_action`, `lzma_stream` (all fields, in order, including the reserved ones), `LZMA_STREAM_INIT`
equivalent, `lzma_filter`, `LZMA_FILTER_LZMA1`, `lzma_properties_decode`, `lzma_raw_decoder`,
`lzma_alone_decoder`, `lzma_code`, `lzma_end`, and (tests only) `lzma_alone_encoder` + `lzma_options_lzma`
+ `lzma_lzma_preset`. Add a C test or Swift test that round-trips data to prove the struct layout is right.

## 10. wecli commands

Add to `wecli` (keep help text short and plain; I will edit wording):
```
wecli steam login [--password <account>] [--qr-out qr.png]   QR by default: writes the PNG, also prints the
                                                             code with Unicode blocks; saves to Keychain
wecli steam whoami                                           account, steamid, token expiry (no secrets)
wecli steam logout [<account>]
wecli steam details <id>...                                  type, rating, size, title, updated
wecli steam subs [--json]                                    subscriptions (+details), path used
wecli steam download <id> --out <dir> [--max-mb N] [--yes]   prints the size first; without --yes refuses
                                                             anything over --max-mb (default 10)
```

## 11. Tests (offline, `swift test`)

Add `Tests/WESteamTests` (XCTest). No network. Cover:
- Protobuf: varint edge cases, fixed64, nested messages, unknown-field skipping; round trip of the header and
  logon messages; decode of a hand-built `ClientLogOnResponse`.
- Packet framing and `Multi` unpacking (build a gzip body with zlib in the test).
- AES scheme: encrypt test vectors with CommonCrypto (ECB IV + CBC + PKCS#7 for every padding length
  1…16) → decrypt matches; corrupt padding → error.
- VZip: produce LZMA data with `lzma_alone_encoder` (or raw encoder), wrap as VZa with footer → decodes, size
  and CRC checked; bad footer → error. zip (stored and deflated) → decodes. `VSZa` → `.unsupportedCompression`.
- Manifest container: synthetic payload/metadata (with encrypted filenames) → parsed mappings and paths;
  path traversal rejected.
- Download planner: synthetic manifest → totals, `tooLarge` when over the limit.
- JWT claim decoding; cookie formatting (`%7C%7C`).
- Keychain round trip under a unique test service name, skipped (XCTSkip) if Keychain access fails.

## 12. Done means

- `swift build` and `swift test` pass with zero warnings in WESteam; `scripts/regress.sh` still passes
  (no renderer changes expected).
- Every number taken from the references has a comment pointing to its source file when non-obvious.
- A short `Sources/WESteam/README.md` is **not** needed; doc comments are enough.
- Leave live verification (QR login, subscriptions, a small download) to the reviewer — do not attempt
  network access.
