# Architecture

## Components

- `SwitcherCore`: deterministic gesture state, UTF-16 conversion plans, packet and delivery validation, cancellation deadlines, window geometry. Independent of the app's UI.
- `KeyboardMonitor`: listening event tap, physical modifier tracking, input generations, double-Shift admission and burst handling.
- `ConversionCoordinator` and `AXClient`: ordinary editor discovery, coherent text/range evidence, one replacement and document/cursor verification.
- `NativeSelectionServiceProof`, `NativeWordServiceCoordinator` and `NativeServiceDiagnostic`: the MAX Services transaction and explicitly armed diagnostics.
- `WindowMoveController`: directional window transfer using Accessibility; `WindowMoveHotKeys` owns the Carbon shortcut registrations.
- `DiagnosticsWindow`, `PerformanceRecorder` and `ReplacementOverlay`: status, bounded measurements and an optional visual transition for editors with reliable geometry.

The app uses AppKit. External Accessibility reads are serialized off the main thread; own UI and Services callbacks stay on the main thread. The normal build includes no third-party dependencies or network behavior.

## Ordinary editor transaction

1. Admit one gesture after Shift is released and the burst quiet interval has elapsed.
2. Capture the foreground app and focused editor; verify editable role, coherent document and exact selection/cursor range.
3. Prepare the complete replacement before issuing input. Read fresh evidence and check unchanged input/focus immediately before mutation.
4. Use a proven native selected-text/value setter or prepared Backspace/Unicode events. No conversion-path general clipboard access or Cmd+C/V.
5. Check the expected document and an empty cursor at the replacement end. Do not retry an issued mutation if acknowledgement is missing.

Word replacement is allowed only when the cursor is immediately after the last character. Unicode coordinates are UTF-16; deletion requires a bounded, safe character plan. Unsupported composition, embedded objects in the replaced fragment, protected input or inconsistent replies cause refusal.

Electron Accessibility preparation is bounded and cached; enabling it does not itself prove a usable editor. Spotlight has a narrowly verified search-field scope because the foreground application can remain Finder while the search field owns input.

## MAX transaction

MAX does not expose its composer as a usable Accessibility text editor in the tested version. The app uses the system Services protocol with a dedicated packet:

- Validate original app/window and menu discovery, then issue window-bound selection and return-only Services requests. Cached menu enablement does not decide whether text is selected: MAX can leave a conversion item enabled after collapsing selection.
- A positive selection response and event delivery finish the selection conversion. Do not wait for a subsequent service that Qt can drop after committing a response. With no response publication, only an actual return-only callback plus delivery permits the word branch; a timeout or refused publication never does.
- Cursor word: after the native requestor-return settle, obtain a native right-boundary response. Positive text and event delivery are separate receipts. An empty response needs the return-only service barrier; the stale menu is not used as boundary evidence.
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

Option+Shift+arrows choose a neighbor from the actual display topology with no wraparound. Ordinary windows preserve size in points and relative placement where possible. Full/half/quarter work-area geometry maps to the corresponding target fraction. Oversized windows shrink only when supported; fullscreen Spaces are refused.

The original focused window, owner and display snapshot are revalidated before each position/size setter. Each issued step has a bounded acknowledgement check and is not retried blindly. User activity and topology changes cancel pending work.

## Idle work, measurement and privacy

There is no permanent polling of editor text. Layout maps and bounded Accessibility preparation results are cached. Permission polling stops after access is granted; diagnostics refresh only while visible.

Performance summaries retain a bounded number of numeric samples. Median and p95 require at least 20 acknowledged attempts in the same editor/mode. Document acknowledgement does not measure compositor completion. Text, clipboard contents and pixels are excluded from reports; optional snapshots exist only in memory. The explicit diagnostics-copy button may copy the displayed report to the general clipboard.

Login registration is changed only through the user's menu action. The retained InputMethodKit experiment is not registered, enabled or selected by the normal utility.

Primary implementation references are collected in [native-text-research.md](native-text-research.md).
