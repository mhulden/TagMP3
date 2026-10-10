# Provider development

Online lookup is opt-in and never writes files directly. Providers return
project-owned release, medium, track, artist, and artwork values; the UI turns
the user’s explicit selections into staged `TagPatch` values and the normal
Save command performs the write.

The first providers are MusicBrainz and Cover Art Archive. MusicBrainz search
and lookup use JSON over `https://musicbrainz.org/ws/2/`. Every request must
include a meaningful contactable User-Agent containing the application name and
version. Requests are limited to approximately one per second, and provider
errors or cancellation must leave local edits untouched. Cover Art Archive
artwork is discovered from a MusicBrainz release identifier and remains a URL
until the user selects an image for download and staging.

`TagMP3Providers` contains the provider-neutral models, response-cache
boundary, and rate limiter. Network clients and provider-specific JSON
decoding belong in adapters in this module; UI code must not depend on remote
response types. Fixtures must be sanitized and deterministic, with no API
tokens, personal data, or downloaded commercial artwork.
