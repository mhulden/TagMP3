# Security policy

Please do not report a suspected vulnerability in a public issue. Until a
dedicated security contact is published, contact the maintainers privately with
a concise description, reproduction steps, affected version, and any proposed
mitigation.

Do not include music files, artwork, private library paths, credentials, or
other personal data in a report unless absolutely necessary.

Important safety properties:

- core tagging is local and offline;
- writes verify the source fingerprint before replacement;
- metadata edits use a temporary sibling and atomic replacement;
- provider credentials, when introduced, must use Keychain rather than files
  or preferences.

