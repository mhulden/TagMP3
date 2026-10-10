# ADR 0001: Project foundation

## Status

Accepted for initial implementation; metadata engine selection remains provisional until the spike passes its round-trip criteria.

## Decisions

- Minimum deployment target: macOS 13 Ventura.
- Development toolchain: Xcode 15.2, Swift 5.9.2 (installed toolchain). The project will use Swift 6 language-mode checks where supported by the target and will document any Xcode 15 compatibility exception.
- Application license: Apache-2.0.
- Initial distribution: self-signed development builds. Signing, notarization, and Mac App Store packaging are deferred to Stage 5.
- Provisional bundle identifier: `com.tagmp3.app`.
- Repository: Git, with `main` as the initial branch.
- Release architecture plan: keep local development on the available x86_64
  machine, then use a GitHub-hosted macOS workflow during release hardening to
  build arm64 and x86_64 separately, combine the complete app bundle, and
  verify every embedded executable with `lipo`. No GitHub workflow or remote
  publishing is enabled yet.

## Metadata-engine experiment

The first candidate is TagLibSwift `0.2.0-rc.1` at revision `530f2e1b78c0851a28fca16a279b649b17810029`. It vendors TagLib 2.3.1 and exposes text properties, audio properties, and picture data through Swift/C++ interoperability.

The spike must prove, using redistributable synthetic fixtures, all of the following on macOS 13 and the pinned Xcode toolchain:

1. Read and write common, repeated, and custom ID3v2.3 and ID3v2.4 values.
2. Preserve unknown/private frames across unrelated edits.
3. Read, replace, and remove JPEG and PNG front-cover artwork while preserving encoded bytes when unchanged.
4. Reopen the written file and compare semantic metadata.
5. Verify the audio payload is unchanged by metadata-only edits.
6. Report rejected/unsupported properties rather than silently dropping them.
7. Build reproducibly for the development architecture without requiring a prebuilt binary unavailable on the developer machine; validate arm64 and universal package integration during release hardening.

If any criterion fails, evaluate a narrow project-owned C or Objective-C++ bridge to a pinned upstream TagLib release. No third-party API may cross into `TagMP3Core` models or UI code.

## Consequences

The package currently contains an intentionally small spike target. This is not yet a production metadata adapter and does not justify marking substage 01-01 complete.
