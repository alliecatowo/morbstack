# SDK-LIQUID-GLASS — archived second-pass SDK notes

> **Historical API notes — nonbinding implementation guidance.** Validate any API against
> the installed SDK and current Apple documentation. In particular, the older examples
> that use `Theme`, `MorbGlass`, hand-made pills, or custom visual wrappers are not
> permitted in the system-native implementation. The binding policy is in the
> [native macOS playbook](../NATIVE-MACOS-PLAYBOOK.md) and
> [HIG coverage audit](../HIG-COVERAGE-AUDIT.md).

Every signature below was read out of the shipping `.swiftinterface` / header on this machine.
Nothing here is recalled from memory. Anything I could not find is in
[§7 Unverified](#7-unverified--do-not-use) and must be treated as nonexistent.

**Environment (verified):**

- SDK: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`
- `SDKSettings.plist` → `CanonicalName = macosx26.4`, `Version = 26.4`
- SwiftUI interface: `…/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface` (25 517 lines)
- SwiftUICore interface: `…/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface` (21 762 lines)
- AppKit headers: `…/AppKit.framework/Headers/`

> **Where the glass lives.** Almost all of the Liquid Glass *view* surface is declared in
> **SwiftUICore**, not SwiftUI. `grep glassEffect` against `SwiftUI.swiftinterface` returns
> **zero** hits and will make you think the API doesn't exist. It does — it is on
> `extension SwiftUICore.View` in `SwiftUICore.swiftinterface`. Both modules are re-exported by
> `import SwiftUI`, so you never write `import SwiftUICore`; just don't grep the wrong file.

**Deployment target requirement.** Every API in §1 is `macOS 26.0+`. If the package's minimum is
below that, each use needs `if #available(macOS 26, *)` or the whole target must move to
`.macOS(.v26)`. Confirm the current minimum in `Package.swift` before writing any of this.

---

## 1. Liquid Glass — verified

### 1.1 `glassEffect(_:in:)`

`SwiftUICore.swiftinterface:2526-2529`

```swift
extension SwiftUICore.View {
  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
  @available(visionOS, unavailable)
  nonisolated public func glassEffect(
    _ glass: SwiftUICore.Glass = .regular,
    in shape: some Shape = DefaultGlassEffectShape()
  ) -> some SwiftUICore.View
}
```

`DefaultGlassEffectShape` (`:2533`, same availability) is a real public `Shape` — it is the
capsule-ish default. You normally pass your own shape.

```swift
Text("3 new lines")
    .font(.system(size: 11, weight: .medium))
    .padding(.horizontal, 12).padding(.vertical, 6)
    .glassEffect(.regular, in: .capsule)
```

### 1.2 `Glass`

`SwiftUICore.swiftinterface:5751-5765`

```swift
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
@available(visionOS, unavailable)
public struct Glass : Swift.Equatable, Swift.Sendable {
  public static var regular: SwiftUICore.Glass { get }
  public static var clear: SwiftUICore.Glass { get }
  public static var identity: SwiftUICore.Glass { get }
  public func tint(_ color: SwiftUICore.Color?) -> SwiftUICore.Glass
  public func interactive(_ isEnabled: Swift.Bool = true) -> SwiftUICore.Glass
}
```

Three variants only. `.identity` is the "no glass" value — use it to switch glass off in a
`ViewModifier` without branching the view tree.

```swift
.glassEffect(.regular.tint(Theme.brand).interactive(), in: .rect(cornerRadius: 20))
```

`.interactive()` is what makes glass respond to pointer/press. Put it on anything clickable;
leave it off static chrome.

### 1.3 `GlassEffectContainer`

`SwiftUICore.swiftinterface:9043-9053`

```swift
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
@available(visionOS, unavailable)
@MainActor @preconcurrency
public struct GlassEffectContainer<Content> : SwiftUICore.View where Content : SwiftUICore.View {
  @MainActor @preconcurrency
  public init(spacing: CoreFoundation.CGFloat? = nil, @ViewBuilder content: () -> Content)
}
```

**This is the most important and most-skipped API in the set.** Sibling glass views that are not
inside a container are each rendered in their own pass and do not blend. Inside a container within
`spacing`, they merge — and it is materially cheaper.

```swift
GlassEffectContainer(spacing: 12) {
    HStack(spacing: 8) {
        Button("Follow") { }.buttonStyle(.glass)
        Button("Times")  { }.buttonStyle(.glass)
    }
}
```

### 1.4 `glassEffectID(_:in:)`

`SwiftUICore.swiftinterface:17369-17372`

```swift
extension SwiftUICore.View {
  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
  @available(visionOS, unavailable)
  nonisolated public func glassEffectID(
    _ id: (some (Hashable & Sendable))?,
    in namespace: SwiftUICore.Namespace.ID
  ) -> some SwiftUICore.View
}
```

Matched-geometry for glass: two glass shapes with the same id in the same namespace morph into
each other across a state change, instead of cross-fading. Requires an enclosing
`GlassEffectContainer`.

```swift
@Namespace private var glassNS

GlassEffectContainer(spacing: 8) {
    if isFollowing {
        followPill.glassEffect(.regular, in: .capsule).glassEffectID("logpill", in: glassNS)
    } else {
        newLinesPill.glassEffect(.regular, in: .capsule).glassEffectID("logpill", in: glassNS)
    }
}
```

### 1.5 `glassEffectUnion(id:namespace:)`

`SwiftUICore.swiftinterface:9877-9880`

```swift
extension SwiftUICore.View {
  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
  @available(visionOS, unavailable)
  @MainActor @preconcurrency
  public func glassEffectUnion(
    id: (some (Hashable & Sendable))?,
    namespace: SwiftUICore.Namespace.ID
  ) -> some SwiftUICore.View
}
```

Note the label is `namespace:`, **not** `in:` — different from `glassEffectID`. Getting this wrong
is a compile error, and it is an easy one to make.

Union merges several *simultaneously visible* glass shapes into one continuous piece of glass.
This is how you build a segmented cluster of glass buttons that reads as one control.

### 1.6 `GlassEffectTransition` + `glassEffectTransition(_:)`

`SwiftUICore.swiftinterface:2845-2864`

```swift
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
@available(visionOS, unavailable)
public struct GlassEffectTransition : Swift.Sendable {
  public static var matchedGeometry: SwiftUICore.GlassEffectTransition { get }
  public static var materialize:     SwiftUICore.GlassEffectTransition { get }
  public static var identity:        SwiftUICore.GlassEffectTransition { get }
}

extension SwiftUICore.View {
  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
  @available(visionOS, unavailable)
  @MainActor @preconcurrency
  public func glassEffectTransition(_ transition: SwiftUICore.GlassEffectTransition) -> some View
}
```

`.identity` is the reduce-motion escape hatch: swap `.materialize` → `.identity` when
`accessibilityReduceMotion` is on, no branching of the view tree required.

### 1.7 `.buttonStyle(.glass)` and `.glassProminent`

`SwiftUI.swiftinterface:1237-1256` and `:3369-3386`

```swift
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
@available(visionOS, unavailable)
extension SwiftUI.PrimitiveButtonStyle where Self == SwiftUI.GlassButtonStyle {
  public static var glass: SwiftUI.GlassButtonStyle { get }
  public static func glass(_ glass: SwiftUICore.Glass) -> Self
}

@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
@available(visionOS, unavailable)
public struct GlassButtonStyle : SwiftUI.PrimitiveButtonStyle {
  public init()
  @available(iOS 26.1, macOS 26.1, tvOS 26.1, watchOS 26.1, *)   // ← note: 26.1, not 26.0
  public init(_ glass: SwiftUICore.Glass)
}

@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
@available(visionOS, unavailable)
extension SwiftUI.PrimitiveButtonStyle where Self == SwiftUI.GlassProminentButtonStyle {
  public static var glassProminent: SwiftUI.GlassProminentButtonStyle { get }
}
```

**Availability trap:** `GlassButtonStyle.init(_ glass:)` — and therefore
`.buttonStyle(.glass(.regular.tint(…)))` — is **macOS 26.1+**, one minor above the rest of the
family. Plain `.buttonStyle(.glass)` is 26.0. If the deployment target is 26.0, tint the button
with `.tint(_:)` instead of with a `Glass` value.

`.glassProminent` has **no** `Glass`-taking initialiser at all. Tint it with `.tint(_:)`.

```swift
Button("Start Engine") { engine.start() }
    .buttonStyle(.glassProminent)
    .tint(Theme.brand)
    .controlSize(.large)
```

### 1.8 `ToolbarSpacer`

`SwiftUI.swiftinterface:21890-21901`

```swift
@available(iOS 26.0, macOS 26.0, *)
@available(tvOS, unavailable) @available(watchOS, unavailable) @available(visionOS, unavailable)
public struct ToolbarSpacer : SwiftUI.ToolbarContent, SwiftUI.CustomizableToolbarContent {
  public init(_ sizing: SwiftUI.SpacerSizing = .flexible,
              placement: SwiftUI.ToolbarItemPlacement = .automatic)
}
```

On 26, toolbar items are automatically grouped into glass capsules; `ToolbarSpacer` is how you say
where one group ends and the next begins. Without it every trailing item lands in one capsule.

```swift
.toolbar {
    ToolbarItem(placement: .primaryAction) { Button("Stop", systemImage: "stop.fill") {} }
    ToolbarItem(placement: .primaryAction) { Button("Restart", systemImage: "arrow.clockwise") {} }
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) { Menu("More", systemImage: "ellipsis") { … } }
}
```

`SpacerSizing` has `.flexible` and (used above) `.fixed` — **`.fixed` I did not separately verify
as a member of `SpacerSizing`; confirm before use, or just call `ToolbarSpacer()`.**

### 1.9 `backgroundExtensionEffect()`

`SwiftUI.swiftinterface:12093-12099`

```swift
extension SwiftUICore.View {
  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @MainActor @preconcurrency public func backgroundExtensionEffect() -> some View

  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @MainActor @preconcurrency public func backgroundExtensionEffect(isEnabled: Bool) -> some View
}
```

Mirrors and blurs a view's edges outward so content flows under adjacent glass instead of ending
in a hard line. Note this one **is** available on visionOS, unlike the rest of the family.

### 1.10 `scrollEdgeEffectStyle` / `scrollEdgeEffectHidden`

`SwiftUI.swiftinterface:12165-12177`, style type at `:12166`

```swift
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
public struct ScrollEdgeEffectStyle : Swift.Hashable, Swift.Sendable {
  public static var automatic: SwiftUI.ScrollEdgeEffectStyle { get }
  public static var hard:      SwiftUI.ScrollEdgeEffectStyle { get }
  public static var soft:      SwiftUI.ScrollEdgeEffectStyle { get }
}

extension SwiftUICore.View {
  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
  @available(visionOS, unavailable)
  nonisolated public func scrollEdgeEffectStyle(_ style: SwiftUI.ScrollEdgeEffectStyle?,
                                                for edges: SwiftUICore.Edge.Set) -> some View

  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
  @available(visionOS, unavailable)
  nonisolated public func scrollEdgeEffectHidden(_ hidden: Bool = true,
                                                 for edges: Edge.Set = .all) -> some View
}
```

Controls the fade/blur where scrolling content passes under floating chrome. **`.hard` is the
correct value for the log viewport** — a soft blur on monospaced text at the toolbar edge is
exactly the artefact `REPORT.md` complains about in `hero-logs`.

### 1.11 `symbolColorRenderingMode` / `symbolVariableValueMode`

`SwiftUICore.swiftinterface:6814-6862`

```swift
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
public struct SymbolColorRenderingMode : Swift.Equatable, Swift.Sendable {
  public static let flat:     SwiftUICore.SymbolColorRenderingMode
  public static let gradient: SwiftUICore.SymbolColorRenderingMode
}

@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
public struct SymbolVariableValueMode : Swift.Equatable, Swift.Sendable {
  public static let color: SwiftUICore.SymbolVariableValueMode
  public static let draw:  SwiftUICore.SymbolVariableValueMode
}
```

Each has three application points, all at the same availability:

```swift
extension View  { func symbolColorRenderingMode(_ mode: SymbolColorRenderingMode?) -> some View }
extension Image { func symbolColorRenderingMode(_ mode: SymbolColorRenderingMode?) -> Image }
extension EnvironmentValues { var symbolColorRenderingMode: SymbolColorRenderingMode? { get set } }
```

(and the identical trio for `symbolVariableValueMode`).

`.gradient` is the macOS 26 look for a filled symbol. `.draw` on a variable-value symbol animates
the symbol being *drawn* rather than recoloured — the right treatment for a pull/build progress
glyph.

```swift
Image(systemName: "shippingbox.fill")
    .symbolColorRenderingMode(.gradient)
    .foregroundStyle(Theme.brand)

Image(systemName: "arrow.down.circle", variableValue: pullProgress)
    .symbolVariableValueMode(.draw)
```

### 1.12 AppKit: `NSGlassEffectView` / `NSGlassEffectContainerView`

`AppKit.framework/Headers/NSGlassEffectView.h`, exported from `AppKit.h:48`

```objc
typedef NS_ENUM(NSInteger, NSGlassEffectViewStyle) {
    NSGlassEffectViewStyleRegular,
    NSGlassEffectViewStyleClear
} API_AVAILABLE(macos(26.0)) NS_SWIFT_NAME(NSGlassEffectView.Style);

API_AVAILABLE(macos(26.0))
@interface NSGlassEffectView : NSView
@property (nullable, strong) __kindof NSView *contentView;
@property CGFloat cornerRadius;
@property (nullable, copy) NSColor *tintColor;
@property NSGlassEffectViewStyle style;
@end

API_AVAILABLE(macos(26.0))
@interface NSGlassEffectContainerView : NSView
@property (nullable, strong) __kindof NSView *contentView;
@property CGFloat spacing;
@end
```

Swift-side that is `NSGlassEffectView.Style.regular` / `.clear`.

The header carries two warnings worth repeating verbatim in spirit:

- `NSGlassEffectView` **only guarantees `contentView` is inside the glass.** Arbitrary subviews get
  no z-order or effect guarantee. Set `contentView`; do not `addSubview`.
- `NSGlassEffectContainerView` elevates descendants of `contentView` above it, merges sufficiently
  similar glass views within `spacing`, and batches them for performance. Default `spacing` is 0,
  which still gets you the batching without unwanted merging.

**Only reach for these if you are already hosting AppKit.** In this codebase the SwiftUI path
covers every surface we need; `NSGlassEffectView` is relevant only if the menu-bar popover ends up
being driven by `NSPopover` directly (which `REPORT.md` notes it is).

---

## 2. Structural APIs we should be using — verified

All verified in `SwiftUI.swiftinterface` at the line cited, unless marked `[core]`.

| API | Line | Availability | Signature / note |
|---|---|---|---|
| `NavigationSplitView` column width | `:288`, `:290` | (base) | `func navigationSplitViewColumnWidth(_ width: CGFloat)` and `func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil)` |
| `NavigationSplitViewVisibility` | `:20432` | (base) | `struct NavigationSplitViewVisibility : Equatable, Codable, Sendable` — bind it and persist it |
| `.navigationSplitViewStyle(.balanced)` | `:1723` | (base) | `BalancedNavigationSplitViewStyle` |
| `.inspector(isPresented:content:)` | `:11399` | macOS 14+ | `func inspector<V>(isPresented: Binding<Bool>, @ViewBuilder content: () -> V) -> some View` |
| `.inspectorColumnWidth` | `:11401`, `:11403` | macOS 14+ | `(min:ideal:max:)` and `(_ width:)` |
| `.searchable(text:placement:prompt:)` | `:5657` | macOS 12+ | `placement: SearchFieldPlacement = .automatic` |
| `SearchFieldPlacement` | — | — | `.automatic`, `.toolbar`, `.toolbarPrincipal` (macOS 12+), `.sidebar` (macOS, available). **`.navigationBarDrawer` is `@available(macOS, unavailable)`** |
| `Table` + column customisation | `:1181`–`:1186` | macOS 12+ | `init(of:selection:sortOrder:columnCustomization: Binding<TableColumnCustomization<Value>>, columns:rows:)` |
| `.tableStyle(_:)` | `:19746` | macOS 12+ | styles: `.automatic` `:18424`, `.inset` `:12598`, `.bordered` `:21324` |
| `InsetTableStyle` | `:12612` | macOS 12+ | `.inset(alternatesRowBackgrounds:)` is **deprecated** — the message says: *"Use the `.inset` style with the `.alternatingRowBackgrounds()` view modifier"* |
| `Form` + `.formStyle(_:)` | `:15636` | macOS 13+ | `func formStyle<S>(_ style: S) -> some View where S : FormStyle` — `.grouped` is the Settings answer |
| `.labeledContentStyle(_:)` | `:22775` | macOS 13+ | for the Configuration key/value list |
| `.toolbar(id:content:)` | `:17930` | macOS 13+ | `func toolbar<Content>(id: String, @ToolbarContentBuilder content: () -> Content) -> some View where Content : CustomizableToolbarContent` — user-customisable toolbar |
| `ToolbarDefaultItemKind` | `:16726` | — | `.sidebarToggle` `:16727`, `.title` `:16731`, `.search` `:16735`; used via `init(kind:placement:)` `:6212` |
| `ContentUnavailableView` | `:17171` | **macOS 14+** | `init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil)` and the full `init(label:description:actions:)` |
| `.contextMenu(forSelectionType:menu:primaryAction:)` | `:21399` | (base) | `func contextMenu<I, M>(forSelectionType itemType: I.Type = I.self, @ViewBuilder menu: @escaping (Set<I>) -> M, primaryAction: ((Set<I>) -> Void)? = nil) -> some View` — the selection-aware context menu, which is what tables need |
| `.focusedValue(_:_:)` | `:19671`, `:19674` | (base) | keypath form; also `focusedValue<T>(_ object: T?)` `:3584` for `Observable` |
| `.keyboardShortcut(_:modifiers:)` | `:20262` | (base) | plus `(_ shortcut:)`, `(_ shortcut:)?`, and a `localization:` overload `:20276` |
| `.symbolEffect(_:options:isActive:)` | `[core] :4350` | (base) | indefinite effects |
| `.symbolEffect(_:options:value:)` | `[core] :4355` | (base) | discrete effects, fires on `value` change |
| `.contentTransition(_:)` | `[core] :15840` | (base) | **in SwiftUICore, not SwiftUI** |
| `.scrollPosition(_:anchor:)` | `:21755` | (base) | `Binding<ScrollPosition>`; also `scrollPosition(id:anchor:)` `:21760` |
| `.containerBackground(_:for:)` | `:—` (ext of `SwiftUICore.View`) | macOS 14+ | `containerBackground<S>(_ style: S, for container: ContainerBackgroundPlacement)` and a `@ViewBuilder content:` form |
| `ContainerBackgroundPlacement.window` | `:—` | **macOS 15+, macOS-only** | `.tabView`/`.navigation`/`.navigationSplitView` are all `@available(macOS, unavailable)` — **only `.window` exists on Mac** |
| `.windowStyle(_:)` | `:3542` | (base) | `.hiddenTitleBar` `:9637`, `.titleBar` `:3015` |
| `.windowToolbarStyle(_:)` | `:18089` | (base) | `.unified` `:19029`, `.unifiedCompact` `:23889`, `.unifiedCompact(showsTitle:)` `:23894`, `.automatic` `:3828`. **There is no `.toolbarStyle(_:)` on Scene — the name is `windowToolbarStyle`.** |
| `Settings` scene | `:433` | (base) | `struct Settings<Content> : Scene`; `SettingsLink` `:9176` |
| `MenuBarExtra` styles | `:4629`, `:6186` | (base) | `WindowMenuBarExtraStyle` → `.window` `:4643`; `PullDownMenuBarExtraStyle` → `.menu` |
| `.buttonSizing(_:)` | `[core] :3519` | **macOS 26+** | `ButtonSizing` `[core] :3495`: `.automatic`, `.flexible`, `.fitted` |
| `.safeAreaBar(edge:alignment:spacing:content:)` | `:16987`, `:16990` | (base in this SDK) | vertical and horizontal edge overloads — the sanctioned way to float a bar over scrolling content |
| `.toolbarBackground(_:for:)` | `:9959` | (base) | plus `toolbarBackgroundVisibility(_:for:)` `:9968` |
| `.presentationBackground(_:)` | `:22946`, `:22948` | (base) | style and `@ViewBuilder` forms |
| `.tint(_:)` | `[core] :19242` | (base) | `ShapeStyle` and `Color?` overloads |
| `.backgroundStyle(_:)` | `[core] :9137` | (base) | |
| `.monospacedDigit()` | `[core] :12212` (Font), `:12977` (Text), `:16752` (View) | (base) | all three exist |
| `.monospaced(_:)` | `[core] :12220`/`:12222` (Font), `:12973` (Text) | (base) | |
| `accessibilityReduceMotion` | `[core] :18070` | (base) | `EnvironmentValues.accessibilityReduceMotion: Bool` |
| `Material.bar` | `[core] :6335` | (base) | |

### 2.1 AppKit materials (for anything hosted)

`AppKit.framework/Headers/NSVisualEffectView.h` — the semantic materials, with the raw values:

| Material | Value | Since |
|---|---|---|
| `.titlebar` | 3 | 10.10 |
| `.selection` | 4 | 10.10 |
| `.menu` | 5 | 10.11 |
| `.popover` | 6 | 10.11 |
| `.sidebar` | 7 | 10.11 |
| `.headerView` | 10 | 10.14 |
| `.sheet` | 11 | 10.14 |
| `.windowBackground` | 12 | 10.14 |
| `.hudWindow` | 13 | 10.14 |
| `.fullScreenUI` | 15 | 10.14 |
| `.toolTip` | 17 | 10.14 |
| `.contentBackground` | 18 | 10.14 |
| `.underWindowBackground` | 21 | 10.14 |
| `.underPageBackground` | 22 | 10.14 |

`.appearanceBased`, `.light`, `.dark`, `.mediumLight`, `.ultraDark` are all **deprecated as of
10.14**. Do not use them.

---

## 3. Traps — read this before writing code

1. **`glassEffect*` is in SwiftUICore.** Grepping `SwiftUI.swiftinterface` returns nothing and
   will convince you the API is absent. It isn't.
2. **`glassEffectID(_:in:)` vs `glassEffectUnion(id:namespace:)`** — different argument labels for
   the same conceptual thing. Do not pattern-match one from the other.
3. **`GlassButtonStyle.init(_ glass:)` is macOS 26.1**, not 26.0, unlike everything else in §1.
4. **`.glassProminent` takes no `Glass`.** Colour it with `.tint(_:)`.
5. **`ContainerBackgroundPlacement` on macOS has exactly one member: `.window`** (macOS 15+).
   `.navigation`, `.navigationSplitView`, `.tabView` are `@available(macOS, unavailable)`.
6. **The Scene modifier is `windowToolbarStyle`, not `toolbarStyle`.** `toolbarStyle` does not
   exist on `Scene` in this SDK.
7. **`.inset(alternatesRowBackgrounds:)` is deprecated** with an explicit replacement in the
   message. Use `.tableStyle(.inset)` plus `.alternatingRowBackgrounds()`. Note this does not fix
   the whole-viewport striping `REPORT.md` describes — that is AppKit behaviour, not an API choice.
8. **All of §1 is `visionOS, unavailable`** except `backgroundExtensionEffect`. Irrelevant here,
   but it means `#if os(visionOS)` guards are wrong; use `#available`.
9. **`SpacerSizing.fixed`** — I used it in the §1.8 snippet but did **not** independently verify
   `.fixed` as a member. Verify or use `ToolbarSpacer()` with the default `.flexible`.

---

## 4. Highest-value APIs we are demonstrably not using

Ranked by how much of the critique each one closes.

1. **`.toolbar` / `.toolbar(id:)` / `ToolbarSpacer`** — closes CRITIQUE §0 outright, and gets
   Liquid Glass on every toolbar control for free. Nothing else in this document matters as much.
2. **`GlassEffectContainer` + `.glassEffect(.regular.interactive(), in:)`** — the command palette,
   the log floating pills, the menu-bar header. Currently zero uses.
3. **`ContentUnavailableView`** (macOS 14+, so it has been available the entire life of this
   project) — deletes the lavender-circle empty state and the Builds placeholder.
4. **`Form` + `.formStyle(.grouped)`** — deletes the hand-built Settings cards, the Save/Revert
   bar, and the slider scaffolding.
5. **`.contentTransition(.numericText())` + `.symbolEffect`** — makes live CPU/memory/count
   readouts tick instead of snap. This is the cheapest "expensive-feeling" change in the app.

Runners-up: `.contextMenu(forSelectionType:)` (deletes 36 controls from the Images table),
`.searchable` (deletes the custom search field), `.inspector()` (the Containers detail pane),
`symbolColorRenderingMode(.gradient)` (the sidebar's dead icon column),
`scrollEdgeEffectStyle(.hard, for: .top)` (the `hero-logs` clipped-first-line artefact).

---

## 5. Minimal correct usage — composite reference

The shell every screen should hang off. Every symbol here is verified above.

```swift
struct MorbWindow: View {
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var query = ""
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 196, ideal: 216, max: 280)
        } detail: {
            ContainersTable(query: query)
                .scrollEdgeEffectStyle(.hard, for: .top)
                .inspector(isPresented: $showInspector) {
                    ContainerInspector()
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $query, placement: .toolbar, prompt: "Name, image, project")
        .toolbar(id: "containers") {
            ToolbarItem(id: "state", placement: .principal) { StateFilterPicker() }
            ToolbarSpacer(placement: .primaryAction)
            ToolbarItem(id: "start", placement: .primaryAction) {
                Button("Start", systemImage: "play.fill") { }
            }
            ToolbarItem(id: "more", placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") { … }
            }
        }
        .containerBackground(.regularMaterial, for: .window)   // macOS 15+, .window is the only Mac case
    }
}
```

And the scene:

```swift
@main struct MorbstackApp: App {
    var body: some Scene {
        Window("Morbstack", id: "main") { MorbWindow() }
            .windowToolbarStyle(.unified)          // NOT .toolbarStyle
        Settings { SettingsRoot() }                // system Settings scene, ⌘, for free
        MenuBarExtra("Morbstack", systemImage: "shippingbox") { MorbMenuBarContent() }
            .menuBarExtraStyle(.window)
    }
}
```

---

## 6. Reduce motion — verified plumbing

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion   // [core] :18070

// indefinite symbol effects: gate with isActive
Image(systemName: "arrow.trianglehead.2.clockwise")
    .symbolEffect(.rotate, isActive: isRestarting && !reduceMotion)

// glass presentation
.glassEffectTransition(reduceMotion ? .identity : .materialize)

// numeric tick
.contentTransition(reduceMotion ? .identity : .numericText())
```

`ContentTransition.identity` — **not separately verified.** If it does not exist, branch the
modifier instead of the value.

---

## 7. Unverified — do NOT use

Named for completeness so nobody "remembers" them into the codebase. Each was searched for and
**not found** in this SDK, or found but not fully confirmed:

| Symbol | Status |
|---|---|
| `.toolbarStyle(_:)` on `Scene` | **Not present.** Zero hits. The name is `windowToolbarStyle`. |
| `symbolColorRenderingMode` in `SwiftUI.swiftinterface` | **Not there** — it is in SwiftUICore. Same symbol, different file; listed here only because the grep is misleading. |
| `SpacerSizing.fixed` | Not independently verified. `ToolbarSpacer(_ sizing: SpacerSizing = .flexible, …)` is verified; the `.fixed` member is assumed. |
| `ContentTransition.identity` | Not verified. |
| `Glass.thin` / `.thick` / any variant beyond `regular` / `clear` / `identity` | **Do not exist.** The struct has exactly three statics plus `tint` and `interactive`. |
| A SwiftUI `.glassBackgroundEffect(…)` | **Not present on macOS** in this SDK. Do not confuse with visionOS API surface. |
| `NSGlassEffectView.isEmphasized` / `.material` | **Not present.** The class has exactly four properties: `contentView`, `cornerRadius`, `tintColor`, `style`. |
| Any `.liquidGlass*` spelling | **Nothing in the SDK is named this.** "Liquid Glass" is the marketing name; the API prefix is `glass`. |
| Icon Composer `.icon` bundle format details | `Icon Composer.app` **does exist** at `/Applications/Xcode.app/Contents/Applications/Icon Composer.app`, so the authoring tool is present. The internal `.icon` document schema was not inspected and must not be hand-generated. See IDENTITY.md §1.6. |

**Rule for implementers: if a symbol you want is not in §1 or §2 of this file, it does not exist.
Do not write it and let the compiler decide.**
