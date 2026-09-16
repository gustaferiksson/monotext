# MonoText

TextEdit without the rich text. A document-based macOS plain-text editor: no RTF,
no RTFD, no HTML, no Word, no ruler, no attachments — just text, an encoding, and
a multi-cursor editor.

## Running

```sh
./run.sh
```

Builds the executable, wraps it in `.build/MonoText.app`, and launches it.
Requires macOS 26 or later.

## Multi-cursor shortcuts

| Shortcut | Command |
| --- | --- |
| ⌥⌘↑ | Add Cursor Above |
| ⌥⌘↓ | Add Cursor Below |
| ⌘D | Add Next Occurrence |
| ⌘K ⌘D | Move Last Selection to Next Occurrence |
| ⇧⌘L | Select All Occurrences |
| ⌘F2 | Select All Occurrences of Word |
| ⇧⌥I | Add Cursors to Line Ends |
| ⌘U | Undo Last Cursor Operation |
| ⎋ | Collapse to One Cursor |

## Known limitations

- **Vertical motion loses the goal column.** AppKit keeps one goal column per view
  and `setSelectedRange` resets it, so after ↑/↓ crosses a short line a caret stays
  clamped to that line's width instead of springing back. Fixing it means owning a
  per-caret goal column and reimplementing vertical motion.
- **Secondary carets blink out of phase** with the primary one. macOS draws the
  primary with `NSTextInsertionIndicator`, which exposes no blink phase to sync to.
  Under Reduce Motion nothing blinks.
- **Cut with multiple empty carets deletes nothing.** VS Code cuts the whole line;
  cut with actual selections is correct.
- **⌘K is held as a chord prefix** for a second, so it cannot also be a menu shortcut.
- **Column select drag, ⌥click and the ⌘K ⌘D chord are unverified by test** — this
  machine grants no assistive access, so synthetic mouse and key events are
  impossible. Their underlying logic is asserted directly; the event plumbing is not.
- **Wrap to Page is 10pt narrow** against its container (line-fragment padding);
  text wraps at the page width, but the last column sits under the frame edge.
- **Rich text is gone on purpose.** Opening an RTF file shows its source, and there
  is no Format menu beyond the display font and the wrap toggle.
