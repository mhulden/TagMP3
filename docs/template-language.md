# Filename template language

Rename templates are parsed before the preview is shown. Invalid syntax blocks
application and displays the parser error instead of silently producing a
different filename.

## Placeholders

Use braces around a field name:

```text
{title}
{artist} - {title}
{albumArtist}/{album}/{disc:02}-{track:02} {title}
```

The supported fields are `title`, `artist`, `album`, `albumArtist`, `track`,
`disc`, `date`, `genre`, `comment`, and `composer`. A numeric width after a
colon zero-pads numeric track or disc values, for example `{track:02}`.

## Optional segments and escaping

Square brackets make a segment conditional. The segment is included only when
one of its placeholders has a non-empty value:

```text
{title}[ ({artist})]
```

Double braces produce literal braces: `{{disc}}` renders as `{disc}`. Literal
slashes separate path components. Each component is sanitized for macOS
filenames before the rename preview is generated.

When folder organization is disabled, slashes are displayed as filename-safe
hyphens so the existing same-folder rename workflow remains unchanged. When it
is enabled, the selected files’ common parent is the plan root and the rendered
components become destination folders beneath that root.

The same templates can be used in reverse to parse a relative filename/path
into staged field values. A reverse match is exact, preserves the captured text
(including padded numbers), and produces no changes when the path does not
match. The UI will preview these patches before staging them.

Templates without `/` match the filename even when the imported relative path
includes a source folder, such as `Album/01 - Song.mp3`. Templates containing
`/` match the complete relative path and can therefore capture folder fields.

Literal text can follow a placeholder. For example,
`{track:02} - {title} 14LUFS` parses `01 - Songname 14LUFS.flac` as track
`01` and title `Songname`; the `.flac` extension is ignored automatically.
The hyphen-minus (`-`), en dash (`–`), and em dash (`—`) are treated as
equivalent in literal template text to accommodate filenames from different
sources.

When files are imported from a folder, the imported folder name is retained as
the first relative path component. For example, importing
`Album Name/01 - Song.mp3` allows `{album}/{track:02} - {title}` to capture
`Album Name`, `01`, and `Song`. The same rule applies when individual files are
opened: their containing folder is available to the parser. Parse Names only
stages fields selected in its review; normal Save is required to write files.

Unknown placeholders, missing closing braces/brackets, empty templates, and
invalid widths are rejected with an actionable error. Renames still preview
every source and destination and use the existing collision checks.
