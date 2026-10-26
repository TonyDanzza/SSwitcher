# Validation — 0.1.27 / build 181

## Displays pane — build 181

On 12 October 2026 the LG HDR QHD (vendor 0x1e6d, product 0x5b96) already had an override from one-key-hidpi (`Icons.plist` beside it) with 35 entries; `system_profiler` showed 5120 × 2880, "looks like" 2560 × 1440 at 75 Hz, with BetterDisplay quit and BetterDisplay's settings listing no virtual screens. The user confirmed the picture stayed sharp without BetterDisplay. A copy of that override is in `~/Library/Application Support/SSwitcher/DisplayOverrides/backup-2026-10-12`.

`CGDisplayVendorNumber`/`CGDisplayModelNumber` returned the same ids as the file name; the mode list read through public CoreGraphics contains the HiDPI sizes. Unit tests compare the generated entries with the working file's bytes (`AAAUAAAAC0AAAAABACAAAA==` for 2560 × 1440).

The user then saw "2560 × 1440, без HiDPI" selected: the LG was at scale 1 (`CGDisplayCopyDisplayMode` 2560 × 1440 px 2560). The crisp 2560 × 1440 existed only in SkyLight's list (modes 76–79, scale 2.0); the public list never had it and build 181 showed it only while it was current. The pane now reads SkyLight's list; for the LG it offers 2560 × 1440 (HiDPI), 2560 × 1440 without HiDPI, and 9 smaller 16:9 HiDPI sizes.

Not checked by the agent: writing or removing an override (system folder, administrator password), applying a size through SkyLight (it changes the user's display), the pane's look.


## Switch rows, trigger key and conflict checks — build 180

On 12 October 2026, `swift test`: **268 tests, zero failures** (new: parsing `AppleSymbolicHotKeys` with the Fn flag and disabled entries, fixed and application shortcuts, Dictation-style double taps, modifier+arrow meanings, an Option double tap ignoring Shift).

Adding applications: the user reported that "Dota 2" from Applications was not added. It is a Steam shortcut (`run.sh` → `open steam://run/570`) without a bundle identifier. Build 180 follows the app id through `libraryfolders.vdf` and `appmanifest_570.acf` to `steamapps/common/dota 2 beta` and the first bundle with an identifier: on this Mac `com.valvesoftware.dota2` in 0.09 s (also `gg.leyline.Ember` for the Guildrun Demo shortcut). Other bundles without an identifier now show an explanation instead of doing nothing.

The menu toggles are drawn by SSwitcher (`MenuToggle`): a menu is never the key window, so `NSSwitch` drew "on" in inactive gray (user's screenshot). The Fn switch was inverted to the user's meaning: on = brightness and sound without fn.

Settings panes now share one size (600×620 measured on all seven tabs) with no transition; per-pane heights made the window jump when switching tabs.

The three switch rows were rendered off screen: title, second line, a 1 pt rule before ⌃⌥⌘F, the switch on the right. The installed build's open menu could not be captured: the screen was locked (loginwindow above all windows). Not checked by the agent: the rows inside the real menu, toggling from the menu, the conflict alerts, a non-Shift double tap by hand.


## Settings window and short menu — build 179

On 12 October 2026, MacBook display only (one display), `swift test`: **262 tests, zero failures** (new: window shortcut directions for a monitor above, side by side, three and mirrored displays; shortcut validation and storage; left/right Shift choice and interval).

- The status menu, read through System Events, has 7 items: double Shift, "Переносить окна" with the subtitle "Ждёт второго дисплея", "F1–F12 без fn", "Не засыпать", "Настройки…", "Завершить SSwitcher".
- All seven Settings panes were captured with `screencapture -l`; after fixes the toolbar fits without overflow, notes under groups are left aligned, shortcut fields sit on their label's row.
- Keep-awake shortcut: recording ⌃⌥⌘K through System Events stored keyCode 40 with ⌃⌥⌘; pressing it created the "SSwitcher: keep display awake" assertion, pressing again removed it; Delete in the field stored an empty shortcut.

Not checked: automatic arrows with a second display connected (unit tests only), adding applications through the menu and the open panel, exclusions, Shift choice and speed by hand, battery threshold and unplug stop, the top-row toggle from Settings.


## Top-row mode and keep awake — build 178

New: the top-row (F1–F12 / media keys) toggle with Control+Option+Command+F and per-application rules, and "Не засыпать" with presets, a custom duration and a 20% battery stop.

On 12 October 2026, macOS 27.0.1, MacBook Air (Mac16,12), on battery at 71%:

- Before the change, `HIDFKeyMode` (IOHIDSystem) and `com.apple.keyboard.fnState` both read 0; build 178 launched with no rules left both unchanged.
- The status menu, read through System Events, showed the new items; the frontmost process at that moment was loginwindow (screen locked), which led to excluding non-Dock agents from rules.
- "Не засыпать → 15 минут": `pmset -g assertions` listed SSwitcher's `PreventUserIdleDisplaySleep` with "Timeout will fire in 889 secs Action=TimeoutActionRelease"; the menu showed "ещё 15 мин" and the end time. "Выключить" removed the assertion. The Cyrillic assertion name printed as empty in pmset, so the name is now ASCII.

Not checked by the agent: switching the top-row mode and pressing F-keys (the user's own keyboard setting; synthetic events do not pass through the F-key mapping), the shortcut and its notice, per-application rules, the custom-duration dialog, the battery stop below 20%, expiry after sleep. The icon dot was checked as a rendered image only.

Afterwards the user checked build 178 on this Mac and reported that everything works.


## Pages — build 177

The user reported that double Shift did nothing in Pages. Reports showed `editingGuard` with the focus chain AXScrollArea → AXSplitGroup → AXWindow → AXApplication. In a freshly launched Pages 15.4 the application focus stayed on the scroll area and its window had no text element; reading `AXContents`, hit-testing the canvas and walking all 83 window elements changed nothing. One request to set `AXEnhancedUserInterface` (answered with -25208) made the body `AXTextArea` ("Основной текст") appear and take the focus, with a range, settable value and `AXStringForRange`.

Build 177 in a freshly launched Pages, own new document: the first gesture after typing a word reported `canvasPrepared` and `converted`. An earlier check in an already woken Pages converted a word at the end and converted it back. Not checked: selections, tables, text boxes, headers and footers, Keynote and Numbers (not installed).

During the cold check the user was typing in another window; while the test brought Pages forward some of those keystrokes reached the test document, so its final word is not a clean fixture. The gesture itself was reported as `converted` by the editor check. `swift test`: **240 tests, zero failures**.


## Window transfer — build 175

The user reported that Option+Shift+arrows put a window "in a random place, not the expected size". Display geometry on this Mac, as the menu bar app reads it (AX coordinates, points; both displays at scale 2): LG main display (0, 0, 2560×1440), visible (0, 31, 2560×1409); notched MacBook below (579, 1440, 1470×956), visible (579, 1474, 1470×922). A command-line process reported the MacBook's visible frame 2 pt taller (1472/924); the app's value matches where macOS actually places windows.

Reproduced on build 174 with the real shortcut on a test TextEdit window: the MacBook right half moved up became (1280, 31, 769×1409), "result not confirmed". A test harness that mirrors the controller showed the cause: the size step issued 1–5 ms after the cross-display move was clipped at the previous display's right edge (x = 2049) — full width 2049 instead of 2560. With 0–10 ms between the move and the resize the width was clipped every time; from about 16 ms (TextEdit) or 12 ms (Finder) after the move returned it was not. `AXWindowMoved` arrives about 1.3 ms after the move, before that point, so it cannot serve as the signal. Fractional targets were floored by AppKit (407.77 → 407), so round trips crept by a point.

On build 175, with the real shortcut via System Events, on test windows only (a new TextEdit document and a new Finder window):

- MacBook right half → up: (1280, 31, 1280×1409), 79 ms (Finder 99 ms); back down: (1314, 1474, 735×922).
- MacBook full → up: (0, 31, 2560×1409), 69 ms (Finder 94 ms); LG full → down: (579, 1474, 1470×922).
- LG window 1749×1200 → down: shrunk to the MacBook work area.
- MacBook top-left quarter → up: (0, 31, 1280×705); LG bottom-right quarter → down: (1314, 1935, 735×461).
- Ordinary 600×340 window, three round trips: settled at (760, 1562) ↔ (408, 193), 3–9 ms per move.
- A window 85% on the LG, hanging over its bottom edge → down: bottom-aligned on the MacBook; up again: fully inside the LG; up from the LG: "no neighbor".

Every result above was reported as `moved` (within 4 pt of the plan). Not checked: Safari and other applications, Terminal-style size increments, the "tiled windows have margins" setting (off on this Mac), minimum sizes that exceed the target, other physical display arrangements (covered only by unit tests), and the repeated-growth path, which these applications never needed.

`swift test` ran **238 tests with zero failures**. The signed build was installed and its signature checked.


## Refactoring — build 174

Build 174 removes the explicitly armed MAX diagnostics (about 1,700 lines and four buttons in the diagnostics window), moves MAX routing into `MaxConversionRouter`, collects reports in memory, and trims per-event work in the keyboard tap. The conversion routes are meant to be unchanged.

On 11 October 2026, `swift test` ran **231 tests with zero failures**. The signed release build was installed and its signature checked. Checks on the MacBook display:

- TextEdit, own new document: word at the end (`ghbdtn` → `Привет`; TextEdit capitalized the sentence start itself), reverse conversion, a selected word, then typing `!` after the conversion. All reports said `converted`.
- MAX test chat draft, own suffix only: a freshly typed word was retyped with Option+Backspace (107 ms); after a plain Right arrow the direct Services request converted it back (41 ms transaction, snapshot removed after 227 ms); after Shift+Left/Shift+Right the full Services route converted it (582 ms transaction); a selected word was converted as a selection. The caret stayed at the end with no selection. The draft was returned to its previous text; no messages were sent.

These are single checks, not percentiles.


## Already written MAX word — builds 169–173

The user reported that a word typed earlier converted slowly. Reports confirmed it used the full Services route (about 600 ms in the transaction, 850 ms to the new frame). Build 173 adds the direct single-request mode described in [architecture.md](architecture.md).

Checks in the unsent MAX draft on the MacBook display, after moving the caret with a plain Right arrow so the typed word was unknown:

- Direct transaction 30–88 ms after admission (full route 600–660 ms). 60 Hz composer recordings: the new word appeared 304 and 341 ms after the second Shift release, with no selection frame; 464 ms before the snapshot started early; 323 ms without a snapshot, but then the selection was visible for about 130 ms.
- Caret after a typed space: the word before it converted, the space stayed, and the next typed letter appeared after the space.
- Direct conversion followed by another gesture used the retyping path (114 ms) and restored the word.
- Digits only (`123`): no response was published, the selection was collapsed, the text and end caret were unchanged.
- The draft was returned to the user's own text; no messages were sent.

## Freshly typed MAX word — builds 165–168 (unchanged in 173)

Build 168: the user's hardware-keyboard check on build 167 used the slower Services route, so the typed word was not known. Build 168 translates a key with the current layout when its event carries no text, and records a text-free `TypedWordStateReport` (candidate kind, last reset reason, key counts) for each MAX gesture. The cause is not yet confirmed from that report.

On 11 October 2026, `swift test` ran **227 tests with zero failures**, including tracker and event-batch tests. The signed release build was installed and its signature checked.

Checks used ordinary key events in an unsent MAX draft on the MacBook display; no messages were sent and the observed draft was restored afterwards.

- Letters after a typed space (`привет` ↔ `ghbdtn`, `оберем` → `j,thtv`) converted in both directions with Option+Backspace (checked on interim build 165; this path is unchanged in 166); reports 102–145 ms from the second Shift release to delivery.
- Words with a comma or digit converted with exact Backspaces: `j,thtv` → `оберем` on build 165 (one Backspace per receipt), `привет1` ↔ `ghbdtn1` on build 166 (one batch); 112–151 ms.
- Typing after conversion appended to the converted word; the next gesture converted the extended word.
- After MAX regained focus, the run was forgotten and the gesture used the Services path as designed.
- 60 Hz composer recordings: the Option+Backspace path went from the old to the new word in one frame, with no selection. The Backspace path showed one intermediate frame missing one character, then the new word, about 190 ms after the release. An earlier per-character receipt-paced variant showed three intermediate frames and was replaced.
- Twelve consecutive single-batch Backspace + Unicode replacements left the expected text. The earlier failed unpaced experiment used window-framed events re-created from `NSEvent`; the plain CGEvents used now were not observed to lose keys. This is a bounded fixture, not proof for every system load.

Final build 167 check: `ghbdtn` → `привет` with Option+Backspace in 127 ms; the draft was restored.

Caramba Switcher Pro was started once for comparison but did not react in MAX in this setup (it has no saved configuration); no permissions were changed, so no comparison is claimed.

# Validation — 0.1.22 / build 164

## Automated checks

On 11 October 2026, `swift test` ran **212 tests with zero failures**, including the final build 164 source. The signed release build completed successfully. The installed release's signature was checked. GitHub Actions repeats tests and packages the app on macOS.

Build 151 records a successful input-source selection only after reading back the requested source ID. A delayed or duplicate notification of that same selection no longer resets the next gesture or clears burst protection. Tests cover a notice between the two Shift taps, real external source changes, failed selection and unavailable source identity. This addresses a cancellation race; it does not establish that this race caused every reported MAX failure.

Core tests cover gesture admission, burst handling, UTF-16 ranges, coherent selection, conversion planning, delivery receipts, native Services packet validation and window geometry. Passing these checks does not establish compatibility with every editor.

Build 153 posts MAX navigation, its dependent Services shortcuts and cursor restoration through one session route. The earlier split between process-directed arrows and session-directed Services did not establish their relative arrival order. A native window-bound session navigation check showed that MAX accepted this route. Callback outcomes are retained separately from the final aggregate report, without raw text, so a refusal is no longer overwritten by a later dispatch result. This removes an ordering risk; the exact guard behind the earlier intermittent failure was not recovered.

## Observed MAX behavior

Build 164 removes the synchronous menu-discovery dependency from normal MAX conversion. The registered responder callbacks retain scope authority; menu inspection remains available for explicit diagnostics. Visual capture/presentation now overlaps the first 250 ms requestor-return settle rather than following it. Both readiness conditions must complete before navigation. The native service settle remains 250 ms: a 50 ms candidate lost the word request and was not retained. The post-submission visual cover is 100 ms to cover a sampled selection flash seen with 50 ms.

On the MacBook display, the final build passed selected phrase → last word with a 150 ms additional driver gap, reverse conversion, ordinary Space/A input, and inside-word refusal followed by recovery. Actual composer crops were inspected. The original test draft and end caret were restored; no messages were sent. General pasteboard change count/type count stayed unchanged and no held modifier keys were found.

Two individual recordings of the same Russian-to-English last-word conversion showed the first changed frame approximately 930 ms after the second Shift release on build 160 and 850 ms on build 164. The preceding old-text frames were one 60 Hz frame earlier. This is a small observed improvement, not median/p95 data or a guarantee of imperceptible replacement. Recordings interrupted by focus/input changes were excluded. Local recordings, screenshots and test scripts are not part of the repository or normal application behavior.

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

Build 185 drops the right-boundary read from the full Services route: after an empty selection probe it runs the direct word request. One requestor-return settle remains, shortened from 250 to 150 ms. On the MacBook display, in the user's own chat draft, a word typed and followed by Cmd+Right (which forces the full route) was converted 10/10 times at 150 ms (transaction ~200 ms) and 10/10 at 100 ms (~145 ms). At 75 ms the third request was lost: MAX gave no word packet, the text stayed unchanged and unselected. Composer captures confirmed alternating `ghbdtn` ↔ `привет`. The full route measured ~590 ms on build 183 and 340 ms with the 250 ms settle. No messages were sent and the draft was left empty.

Build 190 aligns Chromium selection offsets with AXValue in multi-line editors. In the Claude app composer, with pasted Markdown and code above the last line, the reported selection was 110 UTF-16 units before the selected text's only occurrence in AXValue (4164 units, 139 newlines). A local Chrome contenteditable page reproduced a 7-unit shift; there AXStringForRange returned the selected text for the reported range and joined paragraphs without newlines. The reported range is shifted only when its own range text occurs once in AXValue (for a caret: the longest suffix of the preceding range text, at least 8 units, covering the caret's word); otherwise the snapshot is refused. In that page selected-line and caret-word conversions were confirmed by readback; a multi-line TextEdit document still converted unchanged.

Build 192 deletes a caret word before typing its replacement and waits for the editor to show it gone (`DeletionProgress`); Backspaces are sent again (at most twice) only when deletion started and then stalled for 250 ms, so a slow page's queued Backspaces never delete past the word. In the Yandex Market search field in Safari, the combined batch had left `yjнощетбд`: the page applied Backspaces late, so the text landed inside the old word. With the split, Market and YouTube search each converted `yjen,er` → `ноутбук` 3/3 (104–189 ms), and TextEdit still converted. On a Market results page each Backspace took about 60 ms to apply (7 letters ≈ 0.5 s); build 193 deletes a letters-only word in Safari and Chromium browsers with one Option+Backspace, and the search query converted back and forth 6/6 in 0.37–0.53 s instead of 0.52–0.64 s.

## Snapshot presentation checks

Build 154 hid selection but the user reported that the whole MAX window jerked. A short, local ScreenCaptureKit recording reproduced scaling of the snapshot during panel presentation/removal. A stable snapshot fidelity check matched the original image exactly, so scaling/color conversion was not the established cause. The panel's implicit AppKit window animation was disabled in build 155 and retained in build 157.

Window recordings on builds 155–157 no longer showed the reproduced whole-window scaling. One build 157 reverse-conversion recording had no changed sampled pixels outside the composer; another had a small localized difference of 313 samples rather than the tens of thousands observed during the earlier scaling. These are bounded fixture observations, not a general perceptual benchmark. The earlier selection-color detector was not calibrated and is not accepted as proof of absent selection flash.

Actual final composer images and native reports on build 157 confirmed conversion before a space with the neighbor preserved, selected-phrase → last-word conversion without another manual selection, and reverse last-word conversion. Build 156 additionally refused an inside-word attempt without changing text and preserved both words during eight Shift taps, with no held modifier keys afterward. No messages were sent. Later test-draft changes were preserved rather than deleted or overwritten to force an earlier fixture.

Individual visual-shield lifetimes measured roughly 0.4–0.5 seconds. The 250 ms native requestor-return settle remains. The mask adds capture and presentation time; this change establishes a fix for the reproduced panel scaling, not a latency improvement. Production captures one image in memory; short video recordings and cropped fixture images were explicit local diagnostic tools, not production recording.

## Isolated alternative mechanism — not shipped

On 11 October, native Option + Backspace plus explicit Unicode insertion was tested only on known words in the MAX composer on the MacBook display. It converted in both directions, preserved a preceding word, and allowed ordinary typing afterward. The original observed draft was restored, general pasteboard metadata remained unchanged, no held modifiers were found, and no messages were sent. The installed build 164 was unchanged.

| Variant | Observed result | Limitation |
| --- | --- | --- |
| Word deletion, then insertion after a target receipt | Correct forward/reverse replacement; first changed frames about 73–75 ms after submission | A frame without the word appeared during forward replacement. |
| Prepared deletion and insertion posted together | Correct forward/reverse replacement; first changed frames about 68–77 ms after submission | A neighboring-word trial still showed an empty last-word frame before replacement. |

These individual 60 Hz frame samples start at command submission, whereas the installed build's 850 ms sample starts at the second Shift release. They are not directly comparable end-to-end benchmarks. Recordings interrupted by unrelated input were excluded. The experiment has no validated source of arbitrary current word/caret context and does not establish atomic or invisible editing. Test scripts and composer images remain outside Git.

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
