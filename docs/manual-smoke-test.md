# Manual smoke test

Run this checklist against a disposable copy of a small MP3 fixture set. Never
use irreplaceable library files for destructive tests.

1. Launch the app and confirm the empty workspace and inspector placeholder.
2. Open a folder and confirm supported MP3 files appear incrementally; opening
   another folder or using Open Files replaces the current workspace.
3. Drop an MP3 file into the track area and confirm it is imported.
4. Select one track, edit a common field, and confirm the pencil/unsaved state.
5. Clear that field back to its original value and confirm the dirty state clears.
6. Save the edit, reopen the file, and confirm the value persisted.
7. Select multiple tracks and verify Leave unchanged, Set for all, and Remove
   from all have distinct behavior.
8. Add, replace, remove, export, and outward-drag front-cover artwork.
8a. Copy an image to the macOS clipboard, paste it into one selected track,
    then select multiple tracks and use Paste to All. Confirm both operations
    stage artwork without saving immediately and undo them as one edit each.
8b. Select a source track and one or more target tracks, then use the source
     row’s context menu to copy artwork to the other selected tracks. Confirm
     the miniature artwork indicator appears on affected rows and the batch
     operation is staged as one undoable edit.
8c. On a PNG or otherwise large artwork item, choose Convert to JPEG and
    confirm the dimensions remain unchanged while the format and byte count
    change. Confirm the conversion remains staged until Save.
9. Number tracks and preview/apply a rename template; verify a file in a
   different subfolder remains in that folder.
10. In Rename Files, enable Organize into template folders and preview a
    template such as `{album}/{track:02} - {title}`. Confirm destination paths,
    new directories, duplicate destinations, and existing-file conflicts are
    reported before applying.
10a. Select tracks and open Parse Names. Match a template such as
     `{track:02} - {title}`, choose fields, and confirm the preview identifies
     each target field and shows per-file old/new values. Stage the result,
     verify it is one undoable edit, then save and reload to confirm persistence.
11. Filter by title, artist, album, number, and a staged value; sort ascending
    and descending and verify staged edits move immediately.
11. Choose Workspace order, click Reorder, drag tracks into a new order, and
    verify Number Tracks follows that order.
12. Export the workspace as CSV and JSON and verify staged field values are
    represented without embedding artwork bytes.
13. Export M3U and M3U8 playlists, reorder the workspace, and verify the playlist
    follows display order. Open an exported playlist and verify it loads the same
    files, including files referenced by relative paths. Playlist import replaces
    the current workspace, so discard or save staged edits first when prompted.
14. Try simple filtering (`artist:Pommihyseri`), exact matching (`genre=Fribarock`),
    presence (`album?`), numeric comparison (`track>1`), regular expressions
    (`title~^K`), and OR groups (`artist:Pommihyseri OR artist:Other`). Invalid
    expressions should show a diagnostic instead of silently hiding everything.
15. Save a valid filter from the Filters menu, close and relaunch the app, and
    verify the saved expression can be selected and reused.
16. Select a file with an additional custom tag field, edit that field in the
    Additional Fields section, and verify the staged value can be saved and
    read back.
17. Inspect artwork and verify its role and description are shown when present.
18. Select one or more tracks and press Delete, or use the row context menu, and
    verify they disappear from the workspace without being deleted from disk.
19. Select tracks, open Transform…, and test copy, literal replace, trim, case
    conversion, and field removal. Verify changes are staged and participate in
    Save, Undo, and Discard.
20. Confirm the Transform… sheet previews old and new values before staging the
    operation, including values already staged in the inspector.
21. Open valid Ogg Vorbis, Oga, and Opus files when available and verify common
    fields, artwork, staged edits, and save/reload round trips. Do not treat an
    extension-only scan as format support.
22. Open valid M4A, MP4, or ALAC files when available and verify common fields,
    artwork, staged edits, and save/reload round trips. Confirm unsupported
    format-specific fields are reported rather than silently discarded.
23. Open valid WAV and AIFF/AIF files when available and verify technical
    properties, metadata edits, staged saves, and reload behavior. Confirm any
    format-specific limitations are visible.
24. Open valid APE, WavPack, and DSF files when available and verify technical
    properties, metadata edits, staged saves, and reload behavior. Do not treat
    extension-only recognition as format support.
25. Exercise Save All, Discard, Undo, Redo, and close/reopen behavior with
    staged edits.
26. Change a scanned file outside tagmp3, attempt to save a staged edit, and
    confirm the write is refused with a Reload Changed Files action.
27. Stage an edit, then open another folder or file; verify the Save Changes,
    Discard Changes, and Cancel choices protect the staged edit as expected.
28. Confirm malformed or unsupported files remain visible with an actionable
    error, that the failed entry can be dismissed, and that a failed write does
    not remove the original.
29. Select one audio track and test the preview player: play/pause, Spacebar,
    seeking, volume, and stopping when selection changes. Confirm unsupported
    Ogg/Opus preview shows a warning without affecting metadata editing.
