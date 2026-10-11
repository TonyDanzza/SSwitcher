# Validation — 0.1.22 / build 160

## Automated checks

On 11 October 2026, `swift test` ran **212 tests with zero failures**, including the final build 160 source. The signed release build completed successfully. The installed release's signature was checked. GitHub Actions repeats tests and packages the app on macOS.

Build 151 records a successful input-source selection only after reading back the requested source ID. A delayed or duplicate notification of that same selection no longer resets the next gesture or clears burst protection. Tests cover a notice between the two Shift taps, real external source changes, failed selection and unavailable source identity. This addresses a cancellation race; it does not establish that this race caused every reported MAX failure.

Core tests cover gesture admission, burst handling, UTF-16 ranges, coherent selection, conversion planning, delivery receipts, native Services packet validation and window geometry. Passing these checks does not establish compatibility with every editor.

Build 153 posts MAX navigation, its dependent Services shortcuts and cursor restoration through one session route. The earlier split between process-directed arrows and session-directed Services did not establish their relative arrival order. A native window-bound session navigation check showed that MAX accepted this route. Callback outcomes are retained separately from the final aggregate report, without raw text, so a refusal is no longer overwritten by a later dispatch result. This removes an ordering risk; the exact guard behind the earlier intermittent failure was not recovered.

## Observed MAX behavior

Build 157 reproduced another selected-phrase failure: converting all of `ghbdtn ghbdtn` succeeded, but a prompt second double Shift left the last word unchanged. The menu report still advertised an enabled conversion item; its native action was accepted without a replacement callback. Scope dispatch now uses the responder's Services callbacks rather than that cached item. Five core tests cover positive reply/delivery ordering, missing callbacks, the empty-response barrier, refusal and failed delivery.

Build 160 passed the same two-gesture sequence on the MacBook display with both 150 ms and 600 ms additional gaps in the test driver. Actual composer crops showed `ghbdtn ghbdtn` → `привет привет` → `привет ghbdtn`. A subsequent gesture returned the last word to Russian. Ordinary physical Space/A input appended text after conversion; an inside-word gesture preserved the text and refused conversion. The test draft and end caret were restored. No messages were sent; general pasteboard metadata was unchanged and modifier checks found no held keys.

The empty-selection probe reuses the 250 ms native return settle before a dependent boundary request. Without it, the boundary callback could be lost even after successful delivery. Individual word transaction reports were roughly 627–646 ms; these exclude initial gesture/menu admission and are not compositor measurements. This fixes the reproduced functional failure, not replacement latency or complete visual invisibility.

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

## Snapshot presentation checks

Build 154 hid selection but the user reported that the whole MAX window jerked. A short, local ScreenCaptureKit recording reproduced scaling of the snapshot during panel presentation/removal. A stable snapshot fidelity check matched the original image exactly, so scaling/color conversion was not the established cause. The panel's implicit AppKit window animation was disabled in build 155 and retained in build 157.

Window recordings on builds 155–157 no longer showed the reproduced whole-window scaling. One build 157 reverse-conversion recording had no changed sampled pixels outside the composer; another had a small localized difference of 313 samples rather than the tens of thousands observed during the earlier scaling. These are bounded fixture observations, not a general perceptual benchmark. The earlier selection-color detector was not calibrated and is not accepted as proof of absent selection flash.

Actual final composer images and native reports on build 157 confirmed conversion before a space with the neighbor preserved, selected-phrase → last-word conversion without another manual selection, and reverse last-word conversion. Build 156 additionally refused an inside-word attempt without changing text and preserved both words during eight Shift taps, with no held modifier keys afterward. No messages were sent. Later test-draft changes were preserved rather than deleted or overwritten to force an earlier fixture.

Individual visual-shield lifetimes measured roughly 0.4–0.5 seconds. The 250 ms native requestor-return settle remains. The mask adds capture and presentation time; this change establishes a fix for the reproduced panel scaling, not a latency improvement. Production captures one image in memory; short video recordings and cropped fixture images were explicit local diagnostic tools, not production recording.

## Remaining issues

- MAX uses transient native selection. With screen capture unavailable, timed out, or cancelled by input, it can flash before replacement.
- The selected-phrase → cursor-word transition passed the build 160 checks after the reproduced stale-menu failure was fixed, but intermittent failures are not ruled out.
- MAX Services receipts prove response publication and native action acceptance, not whole-document or cursor verification through Accessibility.
- The browser, Notes and Figma routes were not all re-tested for this source snapshot.

## Manual regression checks

1. Type `ghbdtn`, place the cursor immediately after it, then double-tap Shift: expect `привет` and an empty cursor after the word.
2. Double-tap Shift again after a pause: expect the original word.
3. Select `ghbdtn ghbdtn`, convert, then convert only the last word without selecting it. Repeat in both directions to check the reported regression.
4. Check partial selection with untouched text on both sides, cursor inside a word, cursor after a space, punctuation and rapid repeated Shift.
5. Type immediately after conversion: the replacement must remain and the new text must appear at its end.

Do not treat a queue-delivery receipt or a Services response alone as verification of the editor's final text.
