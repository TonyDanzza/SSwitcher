# Retained InputMethodKit experiment

The repository retains an experimental `SSwitcherInputMethod` product and supporting source. It is disconnected from the normal utility's conversion route and **not installed, enabled or selected by the standard build**. Normal use keeps the ordinary macOS English and Russian layouts.

InputMethodKit can provide an active input method with its text client and replacement-range APIs. This requires a separate input source; the experiment did not establish reliable MAX compatibility and was withdrawn from normal use.

`scripts/build-input-method.sh` only creates the experimental bundle in the ignored `build` directory. Its presence in the repository is not a recommendation to register it or add its sources to macOS.

See [Apple InputMethodKit](https://developer.apple.com/documentation/inputmethodkit) and [IMKInputController replacementRange](https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller/replacementrange%28%29). The normal architecture is described in [architecture.md](architecture.md).
