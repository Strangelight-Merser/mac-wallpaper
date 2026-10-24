# CI, release builds and Homebrew (implementation spec)

Status: spec for implementation (2026-10-24). Background: `docs/design.md` §6.31 (public open-source release). The
repository will live on GitHub (not created yet: use `${{ github.repository }}` in workflows and `OWNER/REPO`
placeholders elsewhere). No Apple Developer ID for now: release builds are ad-hoc signed; users open the app with
right-click → Open the first time. The reviewer writes all prose (README, release notes, cask descriptions' wording
can be minimal placeholders); never touch `Sources/` or docs.

## 1. Version

`scripts/build.sh` writes `CFBundleShortVersionString` 0.1 by hand. Make the version come from `VERSION` (env) with
a default from the latest `v*` git tag (`git describe --tags --abbrev=0`, strip `v`), else `0.0.0-dev`; also set
`CFBundleVersion` (build number: `BUILD` env, else commit count). Keep everything else in build.sh as it is (signing
identity selection, wecli signing, resources). Add `SIGN=adhoc` env to force ad-hoc signing (CI has no identity).

## 2. CI (`.github/workflows/ci.yml`)

On push and pull request: macOS runner with Xcode 26.3+ (pick the newest `macos-*` image that has it; select it
with `xcode-select` or `maxim-lobanov/setup-xcode` pinned by commit SHA; fail clearly if unavailable).
- Checkout with submodules (`ThirdParty/glslang`, `ThirdParty/SPIRV-Cross`, shallow).
- Cache `.build` keyed on `Package.resolved`/`Package.swift` and the submodule SHAs (glslang is slow to build).
- `swift build`, `swift test`. Tests that need Metal, Keychain, network or the WE assets must skip cleanly there:
  find every test that fails on a headless runner (no WE assets, no Keychain unlock, possibly no Metal device) and
  make it `XCTSkip` with a reason when its requirement is missing — don't weaken assertions. `scripts/regress.sh`
  needs the WE assets and samples: don't run it in CI.
- A job summary with the test counts.

## 3. Release (`.github/workflows/release.yml`)

On a pushed tag `v*`:
- Build with `VERSION` from the tag, `SIGN=adhoc`.
- Package `MacWallpaper.app` into `MacWallpaper-<version>.zip` with `ditto -c -k --keepParent` (keeps
  extended attributes/symlinks right), plus a SHA-256 file.
- Create a GitHub Release for the tag (draft, so the reviewer writes the notes before publishing) with the zip and
  checksum attached (`gh release create … --draft`; `GITHUB_TOKEN` with `contents: write`).
- Also attach `wecli` (zipped, ad-hoc signed) as a separate asset.

## 4. Homebrew (`packaging/homebrew/macwallpaper.rb`)

A cask for a tap repository (`OWNER/homebrew-tap`): `version`, `sha256`, `url` pointing at the release zip,
`app "MacWallpaper.app"`, `depends_on macos: ">= :sonoma"`, `depends_on arch: :arm64`, `zap` trash entries for
`~/Library/Application Support/MacWallpaper`, `~/Library/Caches/MacWallpaper`, `~/Library/Preferences/dev.macwallpaper.app.plist`.
Add `scripts/update-cask.sh <version>` that downloads nothing: it takes the local zip from `dist/` (or a path) and
rewrites version and sha256 in the cask file. Since builds are not notarized, include the caveat Homebrew allows for
quarantine (check the current Homebrew guidance; don't recommend disabling Gatekeeper globally).

## 5. Done means

YAML passes `actionlint` if available (else careful review); `scripts/build.sh` still works locally with the
reviewer's signing identity; `VERSION=1.2.3 SIGN=adhoc scripts/build.sh` produces an ad-hoc signed app with that
version; `swift test` passes locally. Do not commit. Report: files, what CI skips and why, anything you couldn't verify
(no network: the reviewer pushes and watches the first run).
