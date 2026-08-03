# Native macOS XCUITest harness

This directory is the visual and interaction acceptance harness for Morbstack's real
macOS window. It exists outside the Swift package because SwiftPM has no UI-test host
or result-bundle integration. The project contains a standard XCUITest bundle and one
thin `MorbstackUITestHost` app target. The host has no window and no product code; it
exists solely because Xcode's macOS UI-test runner requires an application target in
`TEST_TARGET_NAME`. It does not build, link, render, or duplicate Morbstack's SwiftUI
views.

The test creates `XCUIApplication(url: appBundleURL)`, launches the assembled shipping
bundle with `--tour-fixtures`, and passes the fixture appearance and window size as
ordinary launch arguments. Screenshots come from
`app.windows.firstMatch.screenshot()` and are retained as `XCTAttachment`s in the
`.xcresult` bundle. They therefore include the actual WindowServer-composited window,
including its titlebar, traffic lights, unified toolbar, sidebar, inspector, menus, and
system material. This replaces neither production code nor Computer Use review.

## What it verifies

`MorbstackFixtureUITests.swift` deliberately exercises only safe fixture interactions:

- Every primary route in a 1440 x 900 window, separately in light and dark appearance.
  Each destination must show a deterministic fixture marker before its full-window
  screenshot and accessibility hierarchy are attached.
- The standard toolbar search field and its `ContentUnavailableView.search` empty state.
- Table-row selection and the standard inspector's show/hide control.
- The system-owned View > Show/Hide Sidebar command, so the app keeps the
  `NavigationSplitView` sidebar behavior people already liked rather than replacing it
  with a drawn control.
- Apple's `XCUIApplication.performAccessibilityAudit()` over a fixture route.

The tests intentionally do **not** press lifecycle, pull, prune, remove, or setup
actions. Fixture data means they never need the daemon, a VM, Docker Desktop, or a
network connection. A unit test failure reports a real interaction or accessibility
regression; the screenshot attachments are review evidence, not a synthetic pixel
baseline and not a claim that an offscreen render represents Tahoe chrome.

## Run it after the source tree is quiet

Do not run this alongside another Swift build or test process. First assemble the real
bundle from the current SwiftPM sources, then run this one Xcode UI-test target:

```sh
mise run app
mkdir -p dist/xcui
XCODE_DERIVED_DATA="$(mktemp -d -t morbstack-xcui)"
MORBSTACK_APP_PATH="$PWD/dist/Morbstack.app" \
  xcodebuild \
    -project mac/UITests/MorbstackUITests.xcodeproj \
    -scheme MorbstackUITests \
    -derivedDataPath "$XCODE_DERIVED_DATA" \
    -destination 'platform=macOS' \
    -resultBundlePath "$PWD/dist/xcui/MorbstackUITests.xcresult" \
    test
```

`MORBSTACK_APP_PATH` is deliberately explicit in automation. When it is absent, a
checkout-local test defaults to `dist/Morbstack.app`; it fails with an actionable error
if that bundle or `Contents/MacOS/MorbstackApp` is missing. The harness does not silently
fall back to `.build/debug/MorbstackApp`, `MorbShots`, a view cache, or any other program.

The result-bundle path must be new or removed after you have inspected the prior result;
`xcodebuild` refuses to overwrite an existing `.xcresult`. Open it in Xcode to inspect
test activities, PNG attachments, and the paired accessibility-tree attachments:

```sh
open dist/xcui/MorbstackUITests.xcresult
```

Use a fresh temporary `-derivedDataPath` for each evidence run. It prevents an interrupted
Xcode runner bundle from contaminating the next session; retain that directory only when
investigating a runner/build failure.

To run one focused regression while developing, keep the same assembled bundle and add
an Xcode test filter. For example:

```sh
MORBSTACK_APP_PATH="$PWD/dist/Morbstack.app" \
  xcodebuild \
    -project mac/UITests/MorbstackUITests.xcodeproj \
    -scheme MorbstackUITests \
    -derivedDataPath "$(mktemp -d -t morbstack-xcui)" \
    -destination 'platform=macOS' \
    -only-testing:MorbstackFixtureUITests/MorbstackFixtureUITests/testSearchSelectionAndInspectorUseNativeControls \
    test
```

## Why this project is separate

The existing app is intentionally built with SwiftPM and assembled by `mise run app`.
The shipping app remains intentionally built by SwiftPM and assembled by `mise run app`.
The Xcode project therefore has only a minimal, empty application target as the runner
host—not a second Morbstack application target or bundle manifest. The UI-test bundle is
associated with that host through the ordinary `TEST_TARGET_NAME`/`BUNDLE_LOADER` target
contract, while every test explicitly creates `XCUIApplication(url: appBundleURL())` for
the assembled shipping bundle. That keeps the boundary unambiguous: one production bundle
builder, one empty Xcode runner host, and one application actually inspected.

This approach follows Apple's XCTest/XCUIAutomation model:

- [XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation) for
  accessibility-driven interaction tests.
- [XCUIApplication](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication)
  for app lifecycle and launch arguments; macOS additionally supports initialization
  with a filesystem URL.
- [XCUIScreenshot](https://developer.apple.com/documentation/xcuiautomation/xcuiscreenshot)
  and [XCTAttachment](https://developer.apple.com/documentation/xctest/xctattachment)
  for durable native-window evidence.
- [Accessibility auditing](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/performaccessibilityaudit%28for%3A_%3A%29)
  to identify semantic and interaction defects that image inspection alone misses.

## Final acceptance remains a human UX review

XCUITest proves repeatable navigation, selection, search, inspector/sidebar behavior,
and accessibility using the real app. It cannot decide whether a screen has the right
information hierarchy, whether a toolbar's grouping makes operational sense, or whether
an adaptive system material feels coherent in context. After this harness is green,
perform the required Computer Use pass against the same assembled fixture bundle in
light and dark, normal and narrow windows. Review the attachments and the actual live
window together; then correct the source and repeat the serialized run.
