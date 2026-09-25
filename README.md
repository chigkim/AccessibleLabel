# AccessibleName

A macOS menu bar app that shows the name VoiceOver reads for the element under the pointer, so sighted helpers can tell VoiceOver users exactly what to look for.

Press the shortcut (⌃Esc by default) to show a popup with the element's name, value, role and hint. Settings let you change the shortcut, have the result spoken, change the text size, and choose when the popup hides (or have it follow the pointer). Drag or resize the popup to pin it in place.

## Build

Requires macOS 13 or later and the Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh
open build/AccessibleName.app
```

The app needs Accessibility permission (System Settings → Privacy & Security → Accessibility). `build.sh` signs with your first Apple Development or Developer ID identity if you have one, so the permission survives rebuilds. Set `SIGN_IDENTITY` to choose one, otherwise it falls back to ad-hoc signing.
