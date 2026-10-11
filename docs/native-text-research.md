# Native text conversion: implementation references

## Accessibility

Accessibility can expose the focused editor, text, selection and writable attributes. SSwitcher requires coherent replies and checks the original editor before mutation. Exposed attribute names alone do not prove editable text: an AX group can return dummy character counts and ranges when its underlying toolkit lacks a text interface.

Apple documents [AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement), including [hit-testing](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition). Qt's implementation is visible in [qcocoaaccessibilityelement.mm](https://github.com/qt/qtbase/blob/v6.11.2/src/plugins/platforms/cocoa/qcocoaaccessibilityelement.mm).

## Keyboard events

Prepared Backspace and Unicode events allow the ordinary editor route to replace a known word without selecting it. A delivery receipt only proves that events traversed the event system: the application must separately verify its document and cursor. This approach is unsafe if the word or cursor position is unknown.

References: [Apple CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent) and [Cocoa text key-event handling](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TextEditing/Tasks/InterceptKeys.html).

## macOS Services and MAX

A Services request passes a dedicated text packet from an application's selected text to the provider and returns a replacement response. SSwitcher does not use the general clipboard for this route. Qt's Cocoa integration reads the current selection and commits the returned plain string; this Services interface does not supply an arbitrary document replacement range.

MAX currently uses this route for manual selection and an internally selected word. Navigation is bound to the original window, callbacks are one-shot, uncertain boundaries are refused, and no failed mutation is retried. An optional screen-capture capability now hides temporary word selection with a nonanimated snapshot; without it, selection can remain visible. This changes presentation, not the native editing mechanism. Response publication is not whole-document acknowledgement.

References: [Apple Services provider guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html) and [Qt qnsview_complextext.mm](https://github.com/qt/qtbase/blob/v6.11.2/src/plugins/platforms/cocoa/qnsview_complextext.mm).

## Direct text clients

[NSTextInputClient insertText:replacementRange:](https://developer.apple.com/documentation/appkit/nstextinputclient/inserttext%28_%3Areplacementrange%3A%29) is an API on the receiving view's client, not a public cross-process way for any menu-bar app to acquire another application's editor. [InputMethodKit](https://developer.apple.com/documentation/inputmethodkit) exposes the active input method's client; the separate source experiment is retained but disabled in normal use.

## Other implementations

Open-source switches offer useful implementation comparisons, including [UASwitcher](https://github.com/deimoc/UASwitcher), [simple-switcher](https://github.com/VAndr/simple-switcher) and [keyflow](https://github.com/weird-mirror/keyflow). Remembering recent typing can avoid selection for a freshly typed word, but arbitrary cursor movement and replacement of manually selected text require additional state validation. These implementations do not prove that the same mechanism works reliably in MAX.

Caramba's observed behavior is a comparison target. Its closed implementation has not been established from public source; do not claim it uses the clipboard or a specific native API without evidence.

## MAX word deletion experiment — 11 October 2026

An isolated test used the native previous-word deletion command (Option + Backspace), followed by a prepared Unicode payload. Qt documents this command as `DeleteStartOfWord` in [QKeySequence](https://doc.qt.io/qt-6/qkeysequence.html). The experiment used known six-letter words in an explicitly observed test draft, with no Services call, general clipboard access, selection or snapshot cover. It is not an installed conversion backend.

Both directions preserved a neighboring word, and ordinary typing after conversion worked. Target event receipts took 32–52 ms. The first replacement frames in narrow 60 Hz composer recordings appeared roughly 68–77 ms after command submission. These are individual command-to-frame samples, not double-Shift-to-frame measurements or benchmark percentiles.

Sending deletion and Unicode insertion together did not make the edit atomic. A prefix-preservation trial showed the last word absent in a frame about 60 ms after submission, then replaced about 77 ms after submission. Single-word trials happened not to show that intermediate state. Consequently this route is faster in the controlled fixture, but it fails the strict invisible-replacement requirement.

It also requires reliable knowledge of the complete current word and caret. Remembering a typed suffix after an arbitrary click does not establish the unknown prefix; deleting the whole word would risk erasing that prefix. Event receipts establish delivery, not document state. Do not integrate this experiment as an arbitrary-cursor replacement without resolving both context authority and intermediate rendering.

Qt's Cocoa bridge applies a native `replacementRange` through one input-method commit inside the receiving text client. This is the relevant single-edit mechanism, but a separate process cannot obtain that client merely by observing CGEvents. Services supplies the actual selection instead. Shorter service waits, a snapshot cover, and faster key posting do not create a remote range-editing API.

See [architecture.md](architecture.md) for the implemented route and [validation.md](validation.md) for tested behavior and open issues.
