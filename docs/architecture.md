# Architecture

## Components

- `SwitcherCore`: deterministic gesture state, UTF-16 conversion plans, packet and delivery validation, cancellation deadlines, window geometry. Independent of the app's UI.
- `KeyboardMonitor`: listening event tap, physical modifier tracking, input generations, double-Shift admission and burst handling.
- `ConversionCoordinator` and `AXClient`: ordinary editor discovery, coherent text/range evidence, one replacement and document/cursor verification.
- `TypedWordTracker`: in-memory characters typed since the caret last moved, used only while MAX is frontmost.
- `MaxConversionRouter`: picks the MAX route with the pure `MaxConversionRoute` (retype a typed word, one direct Services request, or the full Services transaction) and runs it.
- `NativeServiceProvider`, `NativeSelectionServiceProof` and `NativeWordServiceCoordinator`: the MAX Services provider (Cmd+F19 packet, Cmd+F20 barrier) and its transaction.
- `WindowMoveController`: directional window transfer using Accessibility; `WindowMoveHotKeys` owns the Carbon shortcut registrations.
- `FunctionKeyController` and `FunctionKeyHotKey`: the top-row mode (pure rules in `FunctionKeyPolicy`) and its Control+Option+Command+F shortcut; `StatusHUD` confirms the shortcut.
- `KeepAwakeController`: one display-sleep power assertion with a timer and a battery stop (parsing and plurals in `KeepAwakeDuration`).
- `DiagnosticsWindow`, `PerformanceRecorder` and `ReplacementOverlay`: status, bounded measurements and an optional visual transition for editors with reliable geometry.

The app uses AppKit. External Accessibility reads are serialized off the main thread; own UI and Services callbacks stay on the main thread. The normal build includes no third-party dependencies or network behavior.

## Ordinary editor transaction

1. Admit one gesture after Shift is released and the burst quiet interval has elapsed.
2. Capture the foreground app and focused editor; verify editable role, coherent document and exact selection/cursor range.
3. Prepare the complete replacement before issuing input. Read fresh evidence and check unchanged input/focus immediately before mutation.
4. Use a proven native selected-text/value setter or prepared Backspace/Unicode events. No conversion-path general clipboard access or Cmd+C/V.
5. Check the expected document and an empty cursor at the replacement end. Do not retry an issued mutation if acknowledgement is missing.

Word replacement is allowed only when the cursor is immediately after the last character. Unicode coordinates are UTF-16; deletion requires a bounded, safe character plan. Unsupported composition, embedded objects in the replaced fragment, protected input or inconsistent replies cause refusal.

Electron Accessibility preparation is bounded and cached; enabling it does not itself prove a usable editor. Pages reports its document scroll area as focused until an assistive client requests `AXEnhancedUserInterface`; when the focus is such a container with no text range, the client requests it once (Pages answers "not implemented" but builds its text elements), waits up to 0.4 s for the application's own focus to become a focused text element with a range, and turns the flag off again only if the application kept it. Spotlight has a narrowly verified search-field scope because the foreground application can remain Finder while the search field owns input.

## MAX freshly typed word

While MAX is frontmost, the listening tap records the characters of ordinary key presses since the caret last moved. Clicks, navigation and function keys, Command/Control/Option shortcuts, Return, Tab, Escape, app activation, tap interruption and Backspace across a space forget the run. The last case exists because MAX autocorrects the previous word when a space is typed. A key event without text is translated with the current keyboard layout (`UCKeyTranslate`); a dead key forgets the run. Only text after the last typed space is a candidate; a run longer than one 64-character word is unknown.

A double Shift with a known candidate converts it without selection, Services, Accessibility or clipboard: one prepared batch of exactly as many Backspaces as typed characters, followed by the Unicode text event, posted through the session and paced by MAX's own key-up receipt. A word of letters preceded by a typed space uses one Option+Backspace instead, which MAX applied in the same frame as the insertion. Composed or astral characters, missing layouts or posting permission fall back to the Services transaction before any key is sent. After delivery the tracker records the converted text, so another gesture converts it back.

The word is what the user typed, not a proven document state: after a click it may continue an existing word, and only the typed part is replaced. An editor that rewrites text without a key event (autocompletion) can make the run stale. Delivery receipts do not prove MAX handled the events.

## MAX direct word request

The monitor also tracks whether a MAX selection can exist. Typing, Backspace, plain navigation keys and a plain single click leave none; drags, multi-clicks, modified clicks, Shift navigation, shortcuts, other control keys and activation make one possible. When none can exist and the typed word is unknown (or the caret follows a typed space, where autocorrection may have changed the word), `NativeWordServiceCoordinator` runs in direct mode: one window-bound batch of Option+Shift+Left and the conversion service. The packet is the word before the caret plus any whitespace the caret followed; the whitespace is returned unchanged, so the caret stays in place. This skips the selection and boundary probes and both 250 ms requestor-return settles. A caret inside a word converts the part to its left. If the callback arrives but no response is published, the selection is collapsed with Right after the return settle. The converted text seeds the typed-word tracker, so the next gesture uses the retyping path.

The visual shield for this request starts at the second Shift release, during the burst quiet interval; an unclaimed snapshot closes after 0.4 s. A recording without the shield showed the selection for about 130 ms, so the shield stays.

## MAX Services transaction

MAX does not expose its composer as a usable Accessibility text editor in the tested version. The app uses the system Services protocol with a dedicated packet:

- Validate the original app/window, then issue window-bound selection and return-only Services requests. Cached menu enablement does not decide whether text is selected: MAX can leave a conversion item enabled after collapsing selection.
- A positive selection response and event delivery finish the selection conversion. Do not wait for a subsequent service that Qt can drop after committing a response. With no response publication, only an actual return-only callback plus delivery permits the word branch; a timeout or refused publication never does.
- The Services menu is not inspected. Static Services are registered at launch; actual responder callbacks establish capability on the conversion path. Missing callbacks still stop the attempt at its deadline.
- Cursor word: prepare the visual shield during the native requestor-return settle, then obtain a native right-boundary response. Positive text and event delivery are separate receipts. An empty response needs the return-only service barrier; the stale menu is not used as boundary evidence.
- After the bounded requestor-return settle, select the word once and convert its actual packet in the same callback. Do not re-read a cached candidate and issue a second conversion action.
- Publish one response after source, foreground, input-generation, secure-input and deadline checks. No remote AX call runs inside the synchronous Services callback.

Navigation and its dependent Service shortcut events use the same session/AppKit posting route, with native events bound to the original MAX window. A target-process receipt confirms delivery; it does not prove editor handling. Mixing process-directed arrows with session-directed Service shortcuts was removed because cross-route ordering was not established. The app temporarily releases its own Option+Shift arrow registrations during this finite transaction because they otherwise consume Qt's word-selection command, then restores the user's current preference.

The Services path still selects text temporarily. `NativeWordVisualShield` covers this intermediate state with one in-memory screenshot of the original window's verified bounds. Its nonactivating, click-through panel explicitly disables AppKit order-in/order-out animation; otherwise the entire captured window can visibly scale during presentation and removal. There is no fade. Bare repeated Shift is drained without removing the mask; real input and focus changes cancel it. A capture timeout and a one-second panel watchdog bound its lifetime. Missing capture capability leaves the Services transaction unchanged. This is presentation only, not editor authority or an additional input source.

Transaction state is retired before the shield is closed: closing a pending capture can synchronously release its preparation completion, which must not dispatch keys for a cancelled request. Publication and native action acceptance are receipts, not verification of MAX's whole document. Callback refusals are retained separately from the aggregate result, without retaining text. The visual and selected-phrase → cursor-word checks are documented in [validation.md](validation.md).

## Cancellation and repeat handling

Each transaction owns cancellation, deadlines and an input-generation predicate. Real typing, pointer activity, focus/source changes or secure input invalidate it. Only the current attempt may resume callbacks; mutation is one-shot. Late callbacks cannot authorize another edit.

`ShiftBurstGate` separates idle, pending, running, draining and blocked states. Requests during a conversion are not queued. A burst tail drains through a quiet interval. An unverified mutation blocks another attempt until real input or a focus change, preventing repeated blind deletion.

Synthetic events are marked and excluded from real-input cancellation. Key-down carries its intended modifiers and key-up clears them; physical keyboard state is checked separately from synthetic shortcut flags.

## Window transfer

Option+Shift+arrows choose a neighbor from the actual display topology with no wraparound. Ordinary windows preserve size in points and relative placement where possible; the target origin is rounded to whole points because AppKit floors fractional origins. Full/half/quarter work-area geometry maps to the corresponding target fraction; a tile is recognized when every edge is within 4 pt (macOS's own tiles differ from exact fractions by 1–2 pt). Oversized windows shrink only when supported; fullscreen Spaces are refused. All geometry is in points: `NSScreen.frame`/`visibleFrame` converted to AX coordinates with the primary display's top.

The sequence shrinks on the source display, moves, then grows on the destination. Right after a window changes displays, its application still limits a resize to the previous display's edge for about 12–16 ms (TextEdit and Finder on this Mac); no AX notification marks the moment it adopts the new display. Growth after a display change therefore waits 50 ms, and a growth that still comes back short is issued once more after 150 ms.

The original focused window, owner and display snapshot are revalidated before each position/size setter. A step is accepted when the AX frame matches it, when a changed frame stays the same for 40 ms (macOS or the application adjusted it), or when an unchanged frame stays for 200 ms; otherwise it stops at 0.5 s. A later position step is skipped when the origin macOS accepted for the move already holds. The final frame is classified against the plan within 4 pt per edge as moved, adjusted (on the destination display) or unconfirmed. `WindowMoveReport` keeps the displays, plan, steps and final frame, without titles. User activity and topology changes cancel pending work.

## Top-row mode

The base mode is the global preference `com.apple.keyboard.fnState`, the same one System Settings writes; it is reread on every application switch, so a change made there is adopted. The live mode is IOHIDSystem's `HIDFKeyMode` parameter, read with `IOHIDCopyCFTypeParameter` and set with `IOHIDSetCFTypeParameter` through a `kIOHIDParamConnectType` connection (no privacy permission). A base change writes both. An application rule (stored by bundle identifier in `functionKeyApplications`) only sets the live parameter while that application is frontmost; SSwitcher itself and non-Dock agents such as loginwindow never get rules. Quitting sets the live parameter back to the preference. The shortcut is a Carbon hot key, independent of the listening event tap.

## Keep awake

`IOPMAssertionCreateWithProperties` creates one `PreventUserIdleDisplaySleep` assertion. A timed assertion carries `TimeoutSeconds` with `TimeoutActionRelease`, so powerd releases it on schedule even if SSwitcher stops; the app timer (plus a wake check, since timers do not advance during sleep) only clears the menu and the icon dot. While active, an `IOPSNotificationCreateRunLoopSource` source stops it on battery power below 20%. Nothing persists across launches except the last custom duration.

## Idle work, measurement and privacy

There is no permanent polling of editor text. Layout maps, bounded Accessibility preparation results and each running application's package description are cached. Permission polling stops after access is granted; diagnostics refresh only while visible. The status menu is rebuilt when it opens, not on layout or display changes. The keyboard tap queues work only when an overlay or attempt cache exists to clear.

Text-free diagnostic reports (`defaults read com.tonydanzza.SSwitcher`) are collected by `DiagnosticReports` in memory and written together at most once per second and on quit, never inside a Services callback.

Performance summaries retain a bounded number of numeric samples. Median and p95 require at least 20 acknowledged attempts in the same editor/mode. Document acknowledgement does not measure compositor completion. Text, clipboard contents and pixels are excluded from reports; optional snapshots exist only in memory. The explicit diagnostics-copy button may copy the displayed report to the general clipboard.

Login registration is changed only through the user's menu action. The retained InputMethodKit experiment is not registered, enabled or selected by the normal utility.

Primary implementation references are collected in [native-text-research.md](native-text-research.md).
