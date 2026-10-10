# Architecture

The project is split into small boundaries so the SwiftUI application does not know about TagLib, file replacement details, or provider SDKs.

## Current package boundaries

- `TagMP3Model` contains `Sendable` value types: track identities and snapshots, normalized field keys and ordered values, artwork descriptors, audio properties, fingerprints, explicit tag patches, capabilities, and structured metadata errors.
- `TagMP3Metadata` contains the asynchronous `MetadataReading` and `MetadataWriting` protocols plus an actor-backed in-memory fake for deterministic tests. Production adapters will implement these protocols without exposing third-party types.
- `TagMP3FileSystem` contains the asynchronous `FileAccessService` boundary and its in-memory fake. Atomic replacement, bookmarks, and recursive discovery will be added behind this boundary.
- `TagMP3MetadataSpike` is temporary experiment code around the pinned TagLibSwift candidate. It is not a production adapter and is intentionally not imported by the app target.

## Patch semantics

`TagPatch` never uses an empty string as an instruction. Each field operation is explicitly `.keep`, `.set(FieldValues)`, or `.remove`; artwork has the corresponding keep/replace/remove operations. `FieldValues` preserves ordered repeated values instead of flattening them into a delimiter-separated string.

## Concurrency

The service protocols are `Sendable` and asynchronous. Test fakes are actors so callers exercise the same isolation boundary expected from real filesystem and metadata work. UI state remains in the main-actor application layer.
