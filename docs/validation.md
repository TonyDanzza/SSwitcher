# Validation — 0.1.22 / build 150

## Automated checks

On 10 October 2026, `swift test` ran **202 tests with zero failures**. `swift build -c release --product SSwitcher` completed successfully. The installed release was signed and its signature checked. GitHub Actions repeats tests and packages the app on macOS.

Core tests cover gesture admission, burst handling, UTF-16 ranges, coherent selection, conversion planning, delivery receipts, native Services packet validation and window geometry. Passing these checks does not establish compatibility with every editor.

## Observed MAX behavior

Tests on the MacBook display confirmed word conversion at the end, reverse conversion, a word before a space with its neighbor preserved, manual selection, refusal inside a word with the original cursor restored, and typing afterward. Tests used an unsent draft; no messages were sent.

One final word conversion took 343 ms, including a 33 ms commit stage. These are individual measurements, not benchmark percentiles or compositor timings. Eight rapid Shift presses preserved text without copies or deletion, but some requests were refused; the next ordinary attempt worked.

## Remaining issues

- MAX uses transient native selection: the selection can flash before replacement.
- A reported conversion of a selected phrase followed by conversion of the last word is still under investigation.
- MAX Services receipts prove response publication and native action acceptance, not whole-document or cursor verification through Accessibility.
- The browser, Notes and Figma routes were not all re-tested for this source snapshot.

## Manual regression checks

1. Type `ghbdtn`, place the cursor immediately after it, then double-tap Shift: expect `привет` and an empty cursor after the word.
2. Double-tap Shift again after a pause: expect the original word.
3. Select `ghbdtn ghbdtn`, convert, then convert only the last word without selecting it. This is the currently reported regression.
4. Check partial selection with untouched text on both sides, cursor inside a word, cursor after a space, punctuation and rapid repeated Shift.
5. Type immediately after conversion: the replacement must remain and the new text must appear at its end.

Do not treat a queue-delivery receipt or a Services response alone as verification of the editor's final text.
