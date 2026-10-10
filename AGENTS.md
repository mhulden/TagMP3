# tagmp3 Project Guide

## Purpose of this file

This file is the implementation contract and staged roadmap for `tagmp3`. It is written for human contributors and AI coding agents. Read it before changing the project. Keep it current as architecture decisions are made, scope changes, and substages are completed.

The final section of this file is the canonical ordered backlog. This file must always end with that section. A substage is complete only when its acceptance criteria, tests, and documentation are complete; change its marker from `[NOT COMPLETE]` to `[COMPLETE]` in the same change that finishes it.

## Product vision

`tagmp3` is an open-source, native macOS application for inspecting, editing, and organizing metadata in local music files. It should make common changes obvious for a first-time user while supporting precise batch workflows for large, personally curated collections.

The scraped Mp3tag website and Windows documentation in `www.mp3tag.de/` and `docs.mp3tag.de/` are research material, not a UI specification. They provide a useful inventory of proven workflows: a file table, a tag inspector, mixed-value batch editing, cover management, filename/tag conversion, filtering, online metadata lookup, reusable actions, playlists, and export. `tagmp3` must develop its own macOS-native interaction design, terminology, visual identity, icons, documentation, and implementation.

Do not copy Mp3tag source code, proprietary assets, screenshots, icons, branding, trade dress, or documentation prose into the product. Do not ship the scraped reference sites in an application bundle or release archive. Refer to them only to understand user needs and expected metadata behavior.

## Product principles

1. **Safe before clever.** Music files may be irreplaceable. A failed or cancelled edit must not leave a partially written file. Never overwrite audio bytes casually.
2. **Simple tasks stay simple.** Opening a folder, fixing a title, adding artwork, and saving should require no configuration or scripting knowledge.
3. **Batch intent is explicit.** Multiple-selection fields distinguish unchanged mixed values, a replacement value, and removal. Empty text must never ambiguously mean all three.
4. **Preview destructive organization.** Rename, move, remove, and bulk transformation operations show their exact per-file effects and conflicts before application.
5. **Native macOS behavior.** Use standard menus, commands, keyboard navigation, drag and drop, undo, accessibility, dark mode, window restoration, and system file panels.
6. **Format differences are not hidden failures.** Present a common field model, but report fields or artwork a target format cannot represent.
7. **Large collections remain responsive.** File discovery, metadata reads, image decoding, remote lookup, and writes run away from the main actor and support cancellation.
8. **Offline first and private by default.** Core tagging never requires an account or network. Online providers are opt-in and disclose requests.
9. **Small, replaceable boundaries.** UI, metadata I/O, filesystem mutation, transformations, and online providers communicate through protocols and value types.
10. **Accessible, localized foundations.** Do not encode meaning with color alone. User-facing strings belong in string catalogs from the beginning.

## Scope and non-goals

### In scope

- A folder- and file-oriented tagging workspace for local audio files.
- Reading technical properties and arbitrary supported tag fields.
- Single-file and multi-file editing with explicit save behavior.
- Embedded artwork import, display, replacement, removal, and export.
- Filename/folder organization driven by tags and tags parsed from names.
- Track/disc numbering, filtering, transformations, playlists, and export.
- Opt-in lookup from open or user-authorized metadata providers.
- A documented provider boundary so the community can add integrations.
- Signed, notarized direct downloads; other distribution channels may follow.

### Not initial goals

- Audio playback beyond an optional lightweight preview convenience.
- Audio transcoding, waveform editing, CD ripping, or loudness processing.
- A streaming service, sync service, or cloud-hosted music library.
- Direct mutation of the Apple Music application database.
- Exact feature parity with Mp3tag or visual imitation of its Windows UI.
- iOS, iPadOS, Windows, or Linux GUI ports. Core value types may remain portable where inexpensive.
- A persistent indexed media-library database in Stages 1-3. The workspace is session/document oriented and reads files as the source of truth.
- Third-party executable scripts with unrestricted filesystem/network access.

## Proposed technical direction

These defaults allow implementation to begin. Items labeled **Decision required** need maintainer confirmation before the related substage is finalized.

### Platform and language

- Build a native Swift application using the installed Xcode 15.2 toolchain and Swift 5.9.2; adopt Swift 6 language-mode checks where the Xcode 15 toolchain supports them without compromising the macOS 13 target.
- Deployment target: macOS 13 Ventura.
- Use SwiftUI for the application shell, inspector forms, sheets, settings, and commands. Use an `NSTableView` bridge when necessary for a high-performance, editable, multi-column track grid. Do not force a pure-SwiftUI table if profiling shows selection, editing, or thousands-of-row performance is inadequate.
- Use Swift concurrency with strict checking. UI state is main-actor isolated. Metadata and filesystem services expose `async` operations and return `Sendable` value types.
- Prefer Apple frameworks (`Foundation`, `SwiftUI`, `AppKit`, `UniformTypeIdentifiers`, `ImageIO`, `OSLog`) before adding dependencies.

### Metadata engine

- Put all metadata access behind a project-owned `MetadataReading`/`MetadataWriting` boundary. No view or feature reducer may import a third-party tagging library directly.
- The leading engine is upstream TagLib, currently an active multi-format library with text properties, complex picture properties, and macOS support. The first implementation spike should evaluate `TagLibSwift`, which vendors TagLib and exposes it through Swift/C++ interop.
- `TagLibSwift` is young and Swift/C++ interop is toolchain-sensitive. Pin the Xcode toolchain and exact package revision. Do not let the public package API leak into `TagMP3Core` models.
- If the wrapper cannot preserve unknown ID3 frames, support required artwork semantics, build reproducibly, or pass corruption/round-trip tests, implement a narrow project-owned C or Objective-C++ bridge to a pinned upstream TagLib release instead. Do not build a new ID3 parser as part of the app MVP.
- Treat TagLib licensing and wrapper notices as release requirements. Preserve all required LGPL/MPL/MIT notices and make relinkable/source obligations clear. The project license is Apache-2.0.
- The Stage 1 format is MP3 with ID3v2.3 and ID3v2.4. Preserve an existing tag version when possible. Do not silently create/remove ID3v1 or normalize all frames. Expose compatibility preferences only after round-trip behavior is tested.

### Domain model

The domain must not assume one value per field or one artwork item per file.

- `TrackID`: stable identity for the current workspace, separate from a mutable URL.
- `TrackSnapshot`: URL, filesystem attributes, audio properties, tag format information, normalized fields, artwork descriptors, warnings, and a file change fingerprint.
- `FieldKey`: case-normalized canonical identifier such as `TITLE`, `ARTIST`, `ALBUM`, `ALBUMARTIST`, `TRACKNUMBER`, `DISCNUMBER`, `DATE`, `GENRE`, `COMMENT`, and custom keys.
- `FieldValues`: ordered `[String]`; do not flatten duplicate/multi-value tags into an irreversible delimiter.
- `Artwork`: original encoded bytes or a lazy byte source, detected MIME type, pixel size, picture type, description, and stable content digest. UI thumbnails are separate cached derivatives.
- `AudioProperties`: duration, codec, bitrate, sample rate, channel count, and optional bits per sample.
- `TagPatch`: field-level and artwork-level intent. Each field operation is `.keep`, `.set([String])`, or `.remove`. This is essential for batch editing.
- `PendingEdit`: base file fingerprint plus a patch. Pending edits are non-destructive and survive selection changes.
- `WriteResult`: success/failure per file, unsupported keys, warnings, old/new fingerprint, and recoverability information.

Canonical fields map to the underlying format only inside the metadata adapter. Unsupported values must come back as warnings, never disappear silently. Preserve unknown frames/atoms/fields whenever the underlying library permits it.

### Workspace and state flow

The primary window is a three-region workspace rather than a clone of the Windows layout:

1. A compact source/sidebar area for the current folders and recent locations.
2. A central track table supporting selection, sort, filter, status, and optional inline edits.
3. A resizable inspector for common fields, all-fields editing, artwork, and technical details.

Opening files creates a transient workspace. Scanning emits incremental results so the table becomes useful before a large folder finishes. A workspace coordinator owns loaded tracks, selection, filtering, sorting, an optional user-defined display order, pending patches, operation progress, and errors.

Removing a track from the workspace is a non-destructive view operation; Delete
must never delete the underlying audio file. Reopening the source can restore it.

Edits are staged. Selection changes do not save files. Dirty rows and dirty inspector fields are visible. `Save Selected` and `Save All` commit writes. Standard undo/redo applies to staged edits; after a filesystem commit, do not claim that `Undo` can reconstruct original files unless a real backup/transaction mechanism exists.

Window close, workspace replacement, and application termination must prompt when unsaved edits exist. External file changes detected since scan must stop that file's write and offer reload/compare/force choices rather than overwrite newer data.

### File access and safe writes

- Centralize access in `FileAccessService`; feature code must not scatter `FileManager` mutations.
- Support Open panels and drag/drop for files and directories, with a recursive option, supported-type filtering, symlink-loop avoidance, package skipping, cancellation, and structured scan errors.
- Design folder grants so security-scoped bookmarks can be added without changing feature code. Initial development uses self-signed builds; notarized direct distribution and Mac App Store sandboxing are deferred until the distribution decision in Stage 5.
- Write one file at a time through a temporary sibling on the same volume: copy original to temp, mutate temp, reopen and verify expected metadata/audio properties, preserve permissions and relevant extended attributes, then atomically replace the original. Clean temp files on every failure path.
- Before replacing, verify the original fingerprint still matches the snapshot used to create the patch.
- A batch is not globally atomic. Report each file's result and allow retry of failures. Cancellation stops before the next replacement and never interrupts an atomic replace.
- Never require original audio content to fit in memory. Artwork may be bounded and decoded through ImageIO thumbnails.
- Tests must prove metadata-only edits leave audio essence unchanged. Use an appropriate payload hash or parser-derived audio-region hash, not a whole-file hash.

### Transformation architecture

Organization features operate as pure plans before filesystem execution:

- `Transformation` converts a snapshot and context to a `TagPatch`.
- `PathTemplate` converts fields to a proposed relative filename/path.
- `OperationPlan` lists source, destination, metadata patch, warnings, collisions, invalid characters, and unsupported results for every track.
- `OperationExecutor` applies an approved plan through `FileAccessService`.

Start with a small documented template language instead of cloning Mp3tag's complete format/scripting syntax. Initial placeholders use braces, for example `{track:02} - {title}` and `{albumArtist}/{album}/{disc:02}-{track:02} {title}`. Support literal escaping and deterministic path sanitization. Add functions only with parser tests and documentation. Do not execute arbitrary Swift, shell, JavaScript, or downloaded code.

### Online metadata

- Online lookup is Stage 3 and never blocks core local tagging.
- Begin with MusicBrainz and Cover Art Archive because they fit an open ecosystem. Identify the application correctly, respect rate limits, cache conservatively, and make field/artwork selection explicit before applying a result.
- Add Discogs only through its documented authorization and rate-limit rules. Tokens belong in Keychain, never preferences, logs, fixtures, or the repository.
- Provider results normalize into project-owned release, medium, track, credit, identifier, and artwork models. Matching UI must show local-to-remote track alignment and allow manual reorder/unmatch.
- Log provider request identifiers and sanitized diagnostics, never secrets or unnecessary personal data.

## Proposed repository structure

Create this structure incrementally; do not generate empty architecture for later stages.

```text
tagmp3/
├── AGENTS.md
├── README.md
├── LICENSE                         # after license decision
├── NOTICE.md                       # third-party notices when dependencies land
├── CONTRIBUTING.md
├── SECURITY.md
├── TagMP3/
│   ├── TagMP3.xcodeproj/
│   ├── App/
│   │   ├── TagMP3App.swift
│   │   ├── AppCommands.swift
│   │   └── AppEnvironment.swift
│   ├── Features/
│   │   ├── Workspace/
│   │   ├── TrackTable/
│   │   ├── TagInspector/
│   │   ├── Artwork/
│   │   ├── Organizer/
│   │   ├── Lookup/
│   │   └── Settings/
│   ├── Resources/
│   │   ├── Assets.xcassets/
│   │   └── Localizable.xcstrings
│   └── TagMP3UITests/
├── Packages/
│   └── TagMP3Core/
│       ├── Package.swift
│       ├── Sources/
│       │   ├── TagMP3Model/
│       │   ├── TagMP3Metadata/
│       │   ├── TagMP3FileSystem/
│       │   ├── TagMP3Transformations/
│       │   └── TagMP3Providers/     # create in Stage 3
│       └── Tests/
│           ├── TagMP3ModelTests/
│           ├── TagMP3MetadataTests/
│           ├── TagMP3FileSystemTests/
│           ├── TagMP3TransformationTests/
│           └── Fixtures/
├── docs/
│   ├── architecture.md
│   ├── metadata-mapping.md
│   ├── template-language.md
│   ├── provider-development.md
│   └── decisions/                  # short ADRs for consequential choices
├── scripts/
│   ├── bootstrap.sh
│   ├── test.sh
│   └── generate-test-fixtures.sh
├── .github/workflows/
│   ├── test.yml
│   └── release.yml                 # Stage 5
├── docs.mp3tag.de/                 # research input; never bundled
└── www.mp3tag.de/                  # research input; never bundled
```

Keep the Xcode application target thin. Put domain logic, parsing, write coordination, transformations, and provider normalization in Swift package targets with fast unit tests. Avoid a single catch-all `Utilities` module. Add a target only when it establishes a real dependency boundary.

## UI behavior requirements

### Track table

- Initial columns: dirty/error status, filename, title, artist, album, album artist, track, disc, year/date, genre, duration, bitrate, codec, and folder.
- Sort by one or more columns; preserve stable order for equal values.
- Stage 2 may add drag-to-reorder for a user-defined display order; when present,
  numbering in display order must use that order and remain distinct from
  column sorting.
- Support standard macOS range/toggle selection, Select All, keyboard traversal, context menus, column resizing/reordering, and horizontal scrolling.
- Double-clicking editable tag cells may stage an inline edit. Filename inline editing must use the same validation and conflict checks as the organizer.
- Rows display scan/write errors without removing the track from context.
- Table updates are incremental and do not jump selection while a scan is running.

### Inspector and batch semantics

- Common editor fields: title, artist, album, album artist, track/total, disc/total, date/year, genre, composer, comment, and artwork.
- A single selection shows exact values. Multiple selection shows a real mixed state; never store a display sentinel such as `<keep>` as metadata.
- Every multi-edit control supports: leave unchanged, set this value on all selected tracks, or remove from all selected tracks.
- An all-fields editor exposes custom and repeated fields without flattening them.
- Clearly mark read-only technical information separately from editable metadata.

### Artwork

- Stage 1 supports JPEG and PNG front-cover artwork in MP3 ID3v2 `APIC` frames.
- Add through file picker, paste, or drag/drop. Export through a save panel or outward drag. A track context menu may copy effective artwork to other selected tracks as one staged, undoable batch operation.
- Show encoded size, dimensions, detected type, picture role, and description where supported.
- Preserve original encoded bytes if the user does not request conversion. Downsample only thumbnail display, not stored artwork.
- Confirm replacement/removal across multiple files and preview how many files change.
- Later stages add multiple images, reorder, picture types, descriptions, format conversion, resize/crop, and quality controls.

### Errors and progress

- Use a non-modal operation area for scanning and large batches, with progress and cancel.
- Use sheets only when a decision is required. Do not show one alert per failed file.
- Summarize batch results with succeeded, skipped, warned, and failed groups; make file paths and recovery steps copyable.
- Logs use privacy annotations and must not contain cover bytes, tokens, or full metadata dumps by default.

## Engineering rules for contributors and agents

1. Check the final roadmap and work on the earliest incomplete dependency unless the user requests a specific substage.
2. Before editing, inspect applicable `AGENTS.md` files and the current working tree. Preserve unrelated user changes.
3. Implement vertical slices. A substage should leave the app buildable and demonstrably more useful.
4. Keep third-party APIs inside adapters. Do not import TagLib/TagLibSwift in app features or provider SDK types in domain models.
5. Model failure explicitly. Avoid `try?` around file reads/writes and do not discard unsupported-field results.
6. Use dependency injection through small protocols and initializers. Do not create a global service locator or singleton metadata engine.
7. Avoid speculative abstraction. Protocols are justified at I/O/provider boundaries and where tests need a fake.
8. Never mutate fixture originals in place. Each write test works on a uniquely created temporary copy and verifies cleanup.
9. Never add real copyrighted songs, downloaded commercial artwork, API keys, or user library paths to fixtures/snapshots.
10. User-visible behavior changes require tests and documentation in the same substage.
11. Use string catalogs and accessibility labels for new UI. Verify keyboard-only operation and VoiceOver grouping for major views.
12. Prefer deterministic tests: injected clocks/UUIDs, recorded provider responses stripped of secrets, fixed locales where formatting matters.
13. Measure before optimizing, but profile table rendering, scanning, image memory, and write throughput before calling a stage complete.
14. No stage is complete with compiler warnings, concurrency warnings, failing tests, or known file-corruption paths.
15. Do not claim a feature supports a format until read/edit/write/artwork round trips are covered by fixtures for that format.

## Build, testing, and validation

The authoritative build runs on macOS. Linux may be used for documentation, pure-model work, and any package tests that actually support it, but Linux results do not replace macOS validation.

Expected commands after Stage 1 scaffolding:

```bash
swift test --package-path Packages/TagMP3Core
xcodebuild \
  -project TagMP3/TagMP3.xcodeproj \
  -scheme TagMP3 \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Add a single `scripts/test.sh` entry point that runs formatting/lint checks if adopted, package tests, and Xcode tests. CI uses a pinned/current documented Xcode version rather than silently floating between toolchains.

### Fixture matrix

Generate or commit only redistributable tiny fixtures. Each supported tag container needs examples for:

- no tag, minimal tag, and common fields;
- Unicode including composed/decomposed macOS filenames and non-Latin metadata;
- repeated values and custom fields;
- empty versus absent values;
- JPEG and PNG artwork, then multiple artwork in later stages;
- ID3v2.3 and ID3v2.4 for MP3;
- unknown/private frames that must survive unrelated edits;
- malformed/truncated tags and read-only files;
- larger artwork and unusually long values;
- a file changed externally between scan and save.

Every metadata adapter test should read, patch, write, reopen, and compare semantic values. Write tests also check audio essence, file permissions, expected extended attributes, and failure cleanup.

### Stage-wide completion gates

A stage is complete only when all its substages are complete and:

- the app launches on the minimum supported macOS version;
- automated tests pass locally and in macOS CI;
- there is a written manual smoke-test checklist and it passes;
- new workflows are documented with original `tagmp3` screenshots where useful;
- accessibility and keyboard paths are tested for the new UI;
- performance and memory are acceptable for that stage's stated collection size;
- known limitations and data-integrity risks are documented;
- third-party license notices are accurate.

## Stage plan

### Stage 1 — Safe MP3 tagging MVP

**Outcome:** a runnable macOS GUI that can open folders of MP3 files, inspect and batch-edit common ID3 metadata, manage front-cover artwork, perform basic organization, and safely save verified results.

Target a useful collection of at least 5,000 MP3 files without blocking the UI. Stage 1 includes project foundations, not a disposable prototype. The metadata-engine spike is the first gate because every later format and workflow depends on reliable round trips.

The basic organization bar is intentionally modest: auto-number selected tracks, preview filename changes from a safe template, and apply collision-free renames. Advanced transformations wait for Stage 2.

### Stage 2 — Multi-format editing and organization

**Outcome:** the common workflow works across the formats most common in macOS libraries, and users can reshape tags and paths using previewable, reusable transformations.

Prioritize FLAC, M4A/MP4/ALAC, Ogg Vorbis/Opus, WAV, and AIFF based on TagLib verification. Add APE, WavPack, DSF, Matroska/WebM, and WMA only with real demand and complete fixtures. Format support is capability-driven rather than a marketing checklist.

This stage introduces the documented template/parser foundation, filename-to-tag matching, richer field/artwork management, filters, playlists, and CSV/JSON export. It does not attempt full Mp3tag scripting compatibility.

### Stage 3 — Online enrichment

**Outcome:** users can search an album, inspect candidate releases, align tracks, select fields/artwork, and stage the result without surrendering control of local metadata.

Build provider-independent UI and models around MusicBrainz/Cover Art Archive first. Add Discogs only after authentication, rate-limit, licensing/attribution, and cache behavior are reviewed. Provider errors must never jeopardize local edits.

### Stage 4 — Power workflows and customization

**Outcome:** repeated library-cleanup work becomes fast and shareable through saved action groups, customizable views, advanced filters, and extensible providers/templates.

Keep automation declarative and previewable. Importing community recipes is data import, not arbitrary code execution. A persistent library index may be proposed here only after measuring a concrete problem that session scanning cannot solve; it requires its own ADR and migration strategy.

### Stage 5 — Release hardening and community launch

**Outcome:** a stable, documented, accessible open-source release distributed as a signed/notarized universal macOS application with reproducible release procedures.

This stage includes threat modeling, fuzz/corrupt-file testing, performance work, localization readiness, contribution governance, update strategy, release automation, and recovery documentation. Mac App Store packaging is separate and only pursued if the sandbox/distribution decision supports it.

## Canonical substage backlog

01-01: Decide and record the minimum macOS version, Swift/Xcode pin, app license, distribution/sandbox goal, bundle identifier, and metadata-engine experiment criteria in ADRs. Build a TagLibSwift spike that reads and writes common/repeated/custom ID3v2.3 and ID3v2.4 fields plus JPEG/PNG artwork, preserves unknown frames, and verifies unchanged audio essence; choose TagLibSwift or a project-owned bridge from evidence. [NOT COMPLETE]

01-02: Scaffold the Xcode macOS app, `TagMP3Core` Swift package, unit/UI test targets, string catalog, logging categories, CI workflow, bootstrap/test scripts, README, notices, and contributor/security documents. The empty app must launch and all test commands must pass on the pinned macOS toolchain. [NOT COMPLETE]

01-03: Implement format-independent domain values and metadata/file-access protocols, including multi-value fields, artwork descriptors, fingerprints, explicit `.keep`/`.set`/`.remove` patches, structured errors, capability reporting, and unit-test fakes. [NOT COMPLETE]

01-04: Implement cancellable file/folder opening, recursive discovery, drag/drop, supported-file filtering, symlink/package safety, incremental MP3 metadata reads, recent locations, scan progress, and aggregated errors without blocking the main actor. [NOT COMPLETE]

01-05: Build the native workspace shell with source area, performant multi-select track table, inspector, filter field, status/progress area, menus, keyboard commands, window restoration, dark mode, accessibility foundations, and an optional lightweight local audio preview player with play/pause, seeking, volume, and selection-aware stopping. Use generated/demo snapshots for UI tests rather than real music. [NOT COMPLETE]

01-06: Implement single and batch common-field editing with true mixed states, staged dirty patches, dirty row/field indicators, staged undo/redo, discard/reload flows, all-fields inspection, unsaved-close protection, and no implicit saving on selection changes. [NOT COMPLETE]

01-07: Implement Stage 1 artwork workflows for MP3 front covers: view metadata, add via picker/paste/drop, preserve original JPEG/PNG bytes, replace, remove, export, outward drag, batch intent confirmation, thumbnail caching, and memory/size safeguards. [NOT COMPLETE]

01-08: Implement safe MP3 commits using temporary siblings, pre-write fingerprint checks, post-write reopen/semantic verification, audio-essence verification in tests, permission/xattr preservation, atomic replacement, cancellation boundaries, cleanup, and per-file batch result reporting/retry. [NOT COMPLETE]

01-09: Implement basic organization: selection-order auto track numbering with optional totals/zero padding, a small brace-based filename template, live old/new preview, macOS filename sanitization, case-only rename handling, collision detection, and safe planned rename execution. [NOT COMPLETE]

01-10: Complete Stage 1 fixture coverage, 5,000-file performance test, corruption/read-only/external-change tests, UI smoke tests, keyboard/VoiceOver review, original quick-start documentation, and the first runnable development build. [NOT COMPLETE]

02-01: Add verified adapters and capability fixtures for FLAC and Ogg Vorbis/Opus, including multi-value Vorbis Comments and single/multiple picture round trips without audio changes. [NOT COMPLETE]

02-02: Add verified adapters and mappings for M4A/MP4/ALAC, WAV, and AIFF, documenting format-specific field/artwork limitations and rejecting unsupported writes visibly. [NOT COMPLETE]

02-03: Add capability-driven support for additional high-demand formats only after fixture/engine evaluation; document why APE/WavPack/DSF/Matroska/WebM/WMA formats are supported, deferred, or read-only. [NOT COMPLETE]

02-04: Implement the versioned template language as a pure parser/evaluator with placeholders, width/padding, optional segments, literal escaping, path components, sanitization, previews, and full grammar/error documentation. [NOT COMPLETE]

02-05: Add tag-to-filename/folder planning and filename/folder-to-tag matching, including per-file captures, destination previews, collisions, invalid paths, cross-volume behavior, and rollback-aware execution reporting. [NOT COMPLETE]

02-06: Add drag-to-reorder for a user-defined workspace order, with keyboard-accessible move commands and display-order numbering; add reusable transformations for copy/compose field, literal/regular-expression replace, case conversion, trim, field removal, auto numbering across folders/discs, and transformation chains with before/after previews. [NOT COMPLETE]

02-07: Add advanced field and artwork management: repeated/custom fields, multiple images, picture roles/descriptions, reorder/apply-to-all, optional crop/resize/format/quality conversion, and explicit per-format loss warnings. [NOT COMPLETE]

02-08: Add fast simple filtering plus parsed field filters for equality, contains, presence/absence, numeric comparison, regular expressions, AND/OR/NOT, saved filters, syntax diagnostics, and large-workspace performance tests. [NOT COMPLETE]

02-09: Add M3U/M3U8 playlist load/save/generation and CSV/JSON metadata export with encoding/path choices, deterministic ordering, previews, and round-trip tests. [NOT COMPLETE]

02-10: Complete cross-format conformance, mixed-format batch, organization failure/recovery, 20,000-file scan/filter, accessibility, documentation, and Stage 2 beta gates. [NOT COMPLETE]

03-01: Define provider-neutral release/medium/track/credit/identifier/artwork models, provider protocols, cache policy, request attribution, rate limiter, sanitized logging, Keychain secret storage, and deterministic mock-provider tests. [NOT COMPLETE]

03-02: Implement MusicBrainz search/detail retrieval and Cover Art Archive lookup with required application identification, throttling, cancellation, response caching, attribution, and recorded sanitized fixtures. [NOT COMPLETE]

03-03: Build lookup UI for search criteria, candidate comparison, edition/media selection, local-to-remote track alignment, manual reorder/unmatch, confidence/warnings, and retryable provider failures. [NOT COMPLETE]

03-04: Build an import review that lets users choose each field and artwork, previews every resulting local patch, preserves local values by default, and applies results only to staged edits until the normal save command. [NOT COMPLETE]

03-05: Evaluate and, if approved, add Discogs with documented OAuth/token setup, Keychain storage, rate limiting, attribution/licensing review, logout/revocation, sanitized fixtures, and feature parity with the provider-neutral review flow. [NOT COMPLETE]

03-06: Complete offline/provider failure, cache expiry, rate-limit, ambiguous matching, multi-disc, compilation, accessibility, privacy documentation, and Stage 3 release gates. [NOT COMPLETE]

04-01: Add named action groups composed from safe declarative transformations, with reorder, enable/disable, dry-run diff, JSON schema/versioning, import/export, validation, and no arbitrary code execution. [NOT COMPLETE]

04-02: Add workspace customization for table columns, inspector fields, toolbar items, saved layouts, default field values, preferences migration, and reset-to-default behavior while retaining accessibility. [NOT COMPLETE]

04-03: Add richer exports and reports through escaped, sandboxed templates; include HTML and configurable delimited text without allowing filesystem traversal or executable template code. [NOT COMPLETE]

04-04: Publish and validate the provider integration contract, example provider, test harness, capability declaration, secret handling rules, API/version compatibility policy, and community review checklist. [NOT COMPLETE]

04-05: Evaluate session-scan performance and user research; only if justified, design and implement an optional persistent index with explicit source-of-truth, invalidation, privacy, migration, rebuild, and deletion behavior. Otherwise document the decision to remain session-based. [NOT COMPLETE]

04-06: Complete action/customization migration tests, untrusted recipe/template tests, 50,000-file performance profiling, power-user documentation, and Stage 4 release gates. [NOT COMPLETE]

05-01: Finalize project governance and legal material: chosen license, code of conduct, contribution/DCO or CLA policy, maintainership, third-party notices/source offers, provider attribution, trademark-safe branding, privacy statement, and security disclosure process. [NOT COMPLETE]

05-02: Harden metadata and filesystem boundaries with fuzzing/corpus tests, malformed and hostile files, huge metadata/artwork limits, path traversal/symlink/race tests, cancellation at every write phase, crash recovery, and an external security review checklist. [NOT COMPLETE]

05-03: Meet release quality targets for startup, 50,000-file incremental scanning, filtering/sorting, table interaction, bounded artwork memory, concurrent I/O, energy use, and no main-thread file/network operations; document measured baselines. [NOT COMPLETE]

05-04: Complete macOS fit and finish: full keyboard navigation, VoiceOver audit, contrast/dynamic text, reduced motion, localization extraction and pseudolocalization, help book/website content, onboarding, recovery guidance, app icon, and original screenshots. [NOT COMPLETE]

05-05: Implement reproducible universal builds (using a GitHub-hosted macOS workflow to build and verify arm64/x86_64 slices when local hardware is unavailable), signing, hardened runtime, notarization, stapling, SBOM/checksums, changelog, release provenance, install/update strategy, rollback instructions, and a dry-run release from a clean machine. [NOT COMPLETE]

05-06: Run the full automated/manual release matrix on every supported macOS version and both Apple Silicon and Intel where supported, resolve all release-blocking defects, publish `1.0.0`, and create evidence-backed post-1.0 priorities instead of promising unvalidated parity. [NOT COMPLETE]
