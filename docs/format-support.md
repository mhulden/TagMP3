# Format support

Format recognition is intentionally capability-driven. An extension is added
to discovery only when the metadata adapter can open it and return useful audio
properties; real-file read, edit, write, artwork, and audio-essence round trips
are still required before calling a format fully supported.

## Experimental development set

TagLib provides native file handlers for these additional formats, so tagmp3
currently accepts them for scanning and adapter evaluation:

- APE (`.ape`)
- WavPack (`.wv`)
- DSD Stream File (`.dsf`)

The common field model and safe temporary-sibling writer are shared with the
other supported formats. Any field or artwork operation rejected by the format
adapter must remain visible as an error; it must not be silently discarded.

## Deferred evaluation

Matroska/WebM and WMA/ASF remain deferred. They require dedicated fixtures and
capability checks for container-specific metadata and artwork before discovery
should expose them. They are not currently accepted by the application.
