# Conversion and cancellation

`ConversionCoordinator` owns one main-thread `ConversionAttempt`. The attempt contains its input-generation predicates, cancellation token, lifecycle, original/expected document, clipboard transaction, optional image, deadlines and trace. There is no global mutable conversion state. Only the active attempt may deliver a callback; its lifecycle permits one mutation reservation and one completion. Real input invalidates its token/lifecycle before deferred cleanup. Cancellation before Paste is distinct from an unverified result after Paste. Termination uses synchronous main-thread cleanup so clipboard restoration does not depend on another run-loop turn.

`KeyboardMonitor` keeps the listening event callback short: detector/gate counters, generations, modifier tracking and local cancellation. AppKit overlay cleanup is deferred. `ShiftBurstGate` has idle, pending, running, draining and blocked states. Requests during an attempt never become a queue. The draining state extends on every remaining Shift event until a complete quiet interval. An unverified attempt blocks further mutations until real input/focus changes. A physical modifier held at any mutation boundary refuses the operation.

`PhysicalModifierState` combines unmarked modifier transitions with `CGEventSource.keyState(.hidSystemState, key:)`. Aggregate shortcut flags are deliberately excluded. Live testing found that leaving shortcut flags on a synthetic key-up could leave Command sticky even in HID state checks. Synthetic key-down carries the intended shortcut and key-up clears its flags. The monitor ignores its own marker on synthetic events. A hardware plus tracked-state guard catches a modifier already held when monitoring starts or before initial Copy, Paste and selection restoration. Between canvas arrow batches, queued synthetic Shift can still appear in the HID table. That continuation and its final non-destructive verification Copy instead require unchanged input/focus, secure-input checks and clear unmarked tracked modifiers. Real modifier transitions still stop the operation; no per-batch delay is added.

`AccessibilityExecution` separates external and local AX calls. A remote `AXClient` serializes synchronous work on one dispatch queue; main never waits synchronously for that queue. A separate main-bound client handles this application's own AX objects, because local AX can invoke AppKit setters and getters directly. Each client owns separate caches, confined to its execution context. System-wide focus discovery runs remotely and does not read this application's focused view there. Both clients configure the messaging timeout on every acquired AX object, batch initial attributes, and narrow repeated confirmation to value/range. CFNull, AXError and wrong AXValue types are decoded safely. The main continuation checks input generation, process activation, secure input and physical modifiers again after remote validation, immediately before posting the prepared event sequence.

An AX setter is a synchronous message to another process. The selected-range path checks cancellation before validation and immediately before the single setter, then verifies range/document and actual Copy. An already in-flight IPC cannot be revoked by a later input event. This is an OS boundary, not a guarantee of atomicity across two applications. No native setter is used for word mode or Figma canvas.

`EditorCompatibilityPolicy` centralizes Figma's transient focus and mirror behavior. A native selected replacement requires full-document acknowledgement before restoring its selected range once. This avoids the previous per-character selection rendering for long selections. Canvas/unsupported editors retain exact Shift+Left restoration, in 32-character batches without mandatory batch sleeps; Copy follows the arrows and must return exactly the converted text. Copy and Paste are never retried. Figma's initial copied text must match independent text-edit selection evidence; layer/object clipboard data is not treated as a character selection. Live testing showed that Copy can clear Figma's AX range while the actual canvas selection stays selected. Selected-canvas preflight therefore uses the matching real Copy, unchanged input/focus and unchanged document, rather than the post-Copy AX range. The word path still requires its exact original caret range. One confirmed canvas selection is kept in memory only until real input/focus changes, to support reversal when the AX mirror collapses.

Figma exposes an atomic text selection setter through its [plugin API](https://developers.figma.com/docs/plugins/api/properties/PageNode-selectedtextrange/). That API runs inside a Figma plugin and is not an external macOS Accessibility operation. This app has no runtime Figma plugin/server integration, so it cannot promise that long canvas selections redraw atomically.

# Timing policy

All budgets are in `ConversionTiming`. Readiness deadlines stop waiting when evidence arrives; they are not mandatory sleeps.

| Budget | Value | Reason |
| --- | ---: | --- |
| Final Shift-release quiet interval | 90 ms | Conservative reduction from 145 ms; the explicit running/draining states protect interleavings during and after replacement. |
| One AX message | 120 ms | Bounds an unresponsive IPC without blocking UI; each newly acquired object is configured. |
| Copy result / Paste acknowledgement deadline | 500 ms each | Allows slow editors/providers while refusing an unverified destructive retry. |
| Readiness poll | 20 ms | Temporary, only during an attempt; no permanent text/permission polling. |
| Canvas Paste fallback | 320 ms | Used only when truthful document acknowledgement is unavailable; actual Copy remains the final proof. |
| Canvas selection fallback | 35 ms | Short bounded editor-handler allowance after ordered arrow delivery; never considered proof. |
| Screenshot delivery budget | 55 ms | Allows typical warm captures while preventing a cold service from adding 100 ms. Geometry IPC is measured separately as AX work. |
| Reveal | 90 ms | Short fade after editor acknowledgement; never included as rendered completion. |
| Visible overlay watchdog | 650 ms | Releases the panel/image even if editor acknowledgement does not arrive. |

An AXObserver is optional according to Apple and notifications may be unsupported. This implementation uses bounded value/range polling instead of registering several notifications on every gesture: observer setup adds IPC and cannot prove success. `ReadinessDeadline` tests demonstrate that repeated polling cannot extend the original deadline; only matching editor evidence establishes success.

`ReplacementOverlay` owns both a pending screenshot delivery and the current nonactivating, click-through panel. `PreparationResult.cancelled` cannot resume mutation; `.skipped` may proceed without an optional animation. Cancellation, timeout and late screenshot completion deliver at most once. Missing/zero geometry, multiline text, offscreen rectangles, secure input, old OS, missing permission and Reduce Motion skip capture. There is no guessed Figma geometry, full-screen screenshot, stream, OCR, disk image or network transport. A closed panel releases its view/image and presenter reference.

# Capability and idle-work bounds

Capability keys contain process identifier, launch session, bundle version and AX element identity. Positive capabilities expire within 30 seconds; unsupported results are short lived. A failed geometry request is scoped additionally to its range, expires after two seconds and is cleared by real input/focus. A canvas failure cannot blacklist a sidebar field. AXManualAccessibility activation is cached per process session for 60 seconds after success or three seconds after failure.

Once input monitoring and Accessibility permission are granted and the tap runs, no permission timer remains. Missing permission/startup triggers at most 15 two-second retries, then recovery occurs on app activation, menu opening or diagnostics opening. Diagnostic updates run only while the window is visible and stop on close/minimize. No text polling runs at idle.

# Measurement and small optional features

`PerformanceRecorder` uses paired OSSignposter intervals for gate, AX operations, capture, event posting, confirmation wait, reveal and gesture-release-to-result. Each interval state is consumed once; an `EditorAcknowledged` event is emitted only after successful verification. Signposts carry fixed names/identifiers only. Numeric summaries retain 64 samples per metric in up to eight process-session/mode buckets. Median and p95 appear only after 20 confirmed samples in the same bucket. Failed/cancelled attempts do not enter confirmed-replacement distributions. AX duration accumulates AX work in the selected execution context; confirmation includes waiting for the editor. These timings overlap by design and must not be summed as disjoint wall-clock phases.

Editor acknowledgement means an expected document or actual Copy was verified. It does not measure the compositor's completed on-screen frame. Reveal duration reports the overlay, not target-app rendering. No user text, clipboard payload or pixels enter diagnostics or logs.

`LoginAtLaunch` reads `SMAppService.mainApp.status` and mutates registration only after the user presses its menu item. It never registers on launch. Status/approval/error display follows macOS; registration work is dispatched off UI. The diagnostics-copy button writes only the displayed status/timings plus app/OS versions to the user's clipboard, after an explicit click.

# Primary sources and SDK checks

The implementation was checked against these Apple sources and local SDK declarations (`AXUIElement.h`, `AXValue.h`, `CGEventSource.h`, `SCScreenshotManager.h`, `SMAppService.h`, and the `os.swiftinterface`):

- [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness): keep UI responsive and dispatch blocking non-UI work away from main.
- [AXUIElementCopyMultipleAttributeValues](https://developer.apple.com/documentation/applicationservices/1462051-axuielementcopymultipleattribute): per-slot CFNull/AXError results can coexist with a successful batch.
- [AXUIElementSetMessagingTimeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout): timeout belongs to the configured object.
- [AXObserverCreate](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate) and the notification SDK declarations: optional notifications are not confirmation.
- [CGEventSource.keyState](https://developer.apple.com/documentation/coregraphics/cgeventsource/keystate(_:key:)) and [HID state](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid/hidsystemstate): sample key-down state separately from aggregate flags.
- [CGEvent.tapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)): listening event tap uses its registered run loop.
- [Timer energy guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html): temporary timers, bounded waits and invalidation when no longer needed.
- [OSSignposter](https://developer.apple.com/documentation/os/ossignposter): retain each begin state and pair it with exactly one matching end.
- [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager): the region screenshot API is guarded for macOS 15.2+; baseline remains macOS 13.
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [register](https://developer.apple.com/documentation/servicemanagement/smappservice/register()), and [requiresApproval](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval): main-app login registration is explicit and can require a System Settings action.
