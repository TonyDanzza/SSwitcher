# Validation — 0.1.22 / build 153

## Automated checks

On 11 October 2026, `swift test` ran **207 tests with zero failures**. The signed release build completed successfully. The installed release's signature was checked. GitHub Actions repeats tests and packages the app on macOS.

Build 151 records a successful input-source selection only after reading back the requested source ID. A delayed or duplicate notification of that same selection no longer resets the next gesture or clears burst protection. Tests cover a notice between the two Shift taps, real external source changes, failed selection and unavailable source identity. This addresses a cancellation race; it does not establish that this race caused every reported MAX failure.

Core tests cover gesture admission, burst handling, UTF-16 ranges, coherent selection, conversion planning, delivery receipts, native Services packet validation and window geometry. Passing these checks does not establish compatibility with every editor.

Build 153 posts MAX navigation, its dependent Services shortcuts and cursor restoration through one session route. The earlier split between process-directed arrows and session-directed Services did not establish their relative arrival order. A native window-bound session navigation check showed that MAX accepted this route. Callback outcomes are retained separately from the final aggregate report, without raw text, so a refusal is no longer overwritten by a later dispatch result. This removes an ordering risk; the exact guard behind the earlier intermittent failure was not recovered.

## Observed MAX behavior

On build 151, converting a selected two-word phrase succeeded, but the next cursor-word attempt left the last word selected and unchanged. The aggregate report did not preserve the callback rejection reason.

On build 153, tests on the MacBook display confirmed:

- Word conversion at the end without manual selection, and reverse conversion.
- Conversion before a space with the neighboring word preserved.
- Conversion of a selected two-word phrase, followed by conversion of only the final word without selecting it.
- The same next-word gesture with a duplicate input-source notification between Shift taps.
- Refusal inside a word with unchanged text and no remaining selection, followed by successful conversion at the word end.
- Eight repeated Shift taps preserved both words without copies or deletion; this observation does not establish how many conversions were admitted.

Screenshots of the actual composer were checked in addition to service reports. The original unsent draft was restored; no messages were sent. Modifier checks found no held modifier keys. Build 150 had also been checked for typing after conversion; that typing check was not repeated on build 153.

One final word conversion took 317 ms, including a 17 ms commit stage. These are individual measurements, not benchmark percentiles or compositor timings. The existing 250 ms requestor-return settle remains; this change does not establish a latency improvement.

## Remaining issues

- MAX uses transient native selection: the selection can flash before replacement.
- The selected-phrase → cursor-word transition passed the bounded build 153 checks, but intermittent failures are not ruled out.
- MAX Services receipts prove response publication and native action acceptance, not whole-document or cursor verification through Accessibility.
- The browser, Notes and Figma routes were not all re-tested for this source snapshot.

## Manual regression checks

1. Type `ghbdtn`, place the cursor immediately after it, then double-tap Shift: expect `привет` and an empty cursor after the word.
2. Double-tap Shift again after a pause: expect the original word.
3. Select `ghbdtn ghbdtn`, convert, then convert only the last word without selecting it. Repeat in both directions to check the reported regression.
4. Check partial selection with untouched text on both sides, cursor inside a word, cursor after a space, punctuation and rapid repeated Shift.
5. Type immediately after conversion: the replacement must remain and the new text must appear at its end.

Do not treat a queue-delivery receipt or a Services response alone as verification of the editor's final text.
