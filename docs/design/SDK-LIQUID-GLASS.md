# SDK-LIQUID-GLASS — the sanctioned surface, verified

Every signature below was read out of the shipping `.swiftinterface` in this machine's
SDK. Nothing is from memory, a blog post, or a WWDC transcript.

```
SDK          /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/
             Developer/SDKs/MacOSX.sdk   (CanonicalName macosx26.4, Version 26.4)
compiler     Apple Swift 6.3 (swiftlang-6.3.0.123.4)
SwiftUI      user-module-version 7.4.27
```

Sources, by short name used in the "Source" column:

| Short | Path |
| --- | --- |
| `SwiftUI.if` | `…/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface` |
| `SwiftUICore.if` | `…/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface` |
| `AppKit.h` | `…/AppKit.framework/Headers/NSGlassEffectView.h` |
| `Symbols.if` | `…/Symbols.framework/Versions/A/Modules/Symbols.swiftmodule/arm64e-apple-macos.swiftinterface` |

> Note: most SwiftUI *view modifiers* now live in `SwiftUICore`, re-exported by SwiftUI
> (`@_exported import SwiftUICore` at the top of `SwiftUI.if`). `grep` of SwiftUI alone
> returns nothing for `glassEffect`; that is not evidence of absence. Grep both.

---

## 0. THE DEPLOYMENT-TARGET RULE — read this before writing a line of glass

`mac/Package.swift` declares:

```swift
platforms: [ .macOS(.v15) ]
```

**Every Liquid Glass API in this document is `macOS 26.0`.** At a `.v15` deployment target
the compiler will reject an ungated call. There are exactly two legal shapes:

```swift
// A. Runtime branch — required whenever there is a sensible pre-26 fallback.
if #available(macOS 26.0, *) {
    content.glassEffect(.regular, in: .rect(cornerRadius: 12, style: .continuous))
} else {
    content.background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
}

// B. Annotated helper — for a whole view that only exists on 26.
@available(macOS 26.0, *)
struct GlassOnlyThing: View { … }
```

Because shape B poisons every call site, **the reference implementation in
`MorbstackAppCore/Design/` uses shape A exclusively**, wrapped once per surface in
`MorbGlass.swift` so that no feature file ever writes `#available` itself. Implementation
agents must call the wrappers. **An agent that writes a bare `.glassEffect(…)` in a feature
file has broken the build for anyone on macOS 15 and will be reverted.**

Raising the floor to `.macOS(.v26)` is a separate decision with release-engineering
consequences and is **not** in scope for this redesign.

---

## 1. Liquid Glass core

### 1.1 `View.glassEffect(_:in:)` — VERIFIED

```swift
// SwiftUICore.if:2525–2529
extension SwiftUICore.View {
  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
  @available(visionOS, unavailable)
  nonisolated public func glassEffect(
      _ glass: SwiftUICore.Glass = .regular,
      in shape: some Shape = DefaultGlassEffectShape()
  ) -> some SwiftUICore.View
}
```

```swift
// SwiftUICore.if:2532–2534
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
@available(visionOS, unavailable)
public struct DefaultGlassEffectShape : SwiftUICore.Shape { public init() }
```

Minimal usage:

```swift
if #available(macOS 26.0, *) {
    Text("Prune")
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
}
```

### 1.2 `Glass` — VERIFIED

```swift
// SwiftUICore.if:5751–5766
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

Three variants only: `.regular`, `.clear`, `.identity`. There is **no** `.thin`,
`.thick`, or `.prominent` on `Glass` — do not write them.

```swift
if #available(macOS 26.0, *) {
    view.glassEffect(.regular.tint(Theme.brand).interactive(), in: .capsule)
}
```

### 1.3 `GlassEffectContainer` — VERIFIED

```swift
// SwiftUICore.if:9043–9052
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
@available(visionOS, unavailable)
@MainActor @preconcurrency
public struct GlassEffectContainer<Content> : SwiftUICore.View where Content : SwiftUICore.View {
  @MainActor @preconcurrency
  public init(spacing: CoreFoundation.CGFloat? = nil, @ViewBuilder content: () -> Content)
}
// SwiftUICore.if:20977
extension SwiftUICore.GlassEffectContainer : Swift.Sendable {}
```

```swift
if #available(macOS 26.0, *) {
    GlassEffectContainer(spacing: 12) {
        HStack(spacing: 12) {
            Button("Stop") {}.buttonStyle(.glass)
            Button("Restart") {}.buttonStyle(.glass)
        }
    }
}
```

### 1.4 `glassEffectID(_:in:)` — VERIFIED

```swift
// SwiftUICore.if:17369–17372
extension SwiftUICore.View {
  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
  @available(visionOS, unavailable)
  nonisolated public func glassEffectID(
      _ id: (some (Hashable & Sendable))?,
      in namespace: SwiftUICore.Namespace.ID
  ) -> some SwiftUICore.View
}
```

### 1.5 `glassEffectUnion(id:namespace:)` — VERIFIED

```swift
// SwiftUICore.if:9877–9880
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

Note the **argument-label difference**: `glassEffectID(_:in:)` but
`glassEffectUnion(id:namespace:)`. They are not symmetric.

```swift
@Namespace private var glassNS

if #available(macOS 26.0, *) {
    GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
            Button("Up")      {}.glassEffectUnion(id: "stack-ops", namespace: glassNS)
            Button("Restart") {}.glassEffectUnion(id: "stack-ops", namespace: glassNS)
            Button("Down")    {}.glassEffectUnion(id: "stack-ops", namespace: glassNS)
        }
    }
}
```

### 1.6 `GlassEffectTransition` + `glassEffectTransition(_:)` — VERIFIED

```swift
// SwiftUICore.if:2845–2861
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
  public func glassEffectTransition(_ transition: SwiftUICore.GlassEffectTransition) -> some SwiftUICore.View
}
```

### 1.7 Glass button styles — VERIFIED

```swift
// SwiftUI.if:1237–1252
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
@available(visionOS, unavailable)
extension SwiftUI.PrimitiveButtonStyle where Self == SwiftUI.GlassButtonStyle {
  @MainActor public static var glass: SwiftUI.GlassButtonStyle { get }
  @MainActor public static func glass(_ glass: SwiftUICore.Glass) -> Self
}
public struct GlassButtonStyle : SwiftUI.PrimitiveButtonStyle {
  public init()
  @available(iOS 26.1, macOS 26.1, tvOS 26.1, watchOS 26.1, *)
  public init(_ glass: SwiftUICore.Glass)          // ← 26.1, not 26.0
}
```

```swift
// SwiftUI.if:3370–3375
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
@available(visionOS, unavailable)
extension SwiftUI.PrimitiveButtonStyle where Self == SwiftUI.GlassProminentButtonStyle {
  @MainActor public static var glassProminent: SwiftUI.GlassProminentButtonStyle { get }
}
```

**Availability trap:** `.buttonStyle(.glass)` (the zero-argument static) is macOS **26.0**.
`.buttonStyle(.glass(_:))` taking a `Glass` value resolves to `GlassButtonStyle.init(_:)`,
which is macOS **26.1**. Gate the tinted form at 26.1 or avoid it. The reference
implementation avoids it.

```swift
if #available(macOS 26.0, *) {
    Button("Start Engine") { }.buttonStyle(.glassProminent).controlSize(.large)
} else {
    Button("Start Engine") { }.buttonStyle(.borderedProminent).controlSize(.large)
}
```

### 1.8 `ToolbarSpacer` — VERIFIED

```swift
// SwiftUI.if:21888–21899
@available(iOS 26.0, macOS 26.0, *)
@available(tvOS, unavailable) @available(watchOS, unavailable) @available(visionOS, unavailable)
public struct ToolbarSpacer : SwiftUI.ToolbarContent, SwiftUI.CustomizableToolbarContent {
  public init(_ sizing: SwiftUI.SpacerSizing = .flexible,
              placement: SwiftUI.ToolbarItemPlacement = .automatic)
}
```

```swift
// SwiftUI.if — SpacerSizing
public struct SpacerSizing : Swift.Sendable {
  public static let flexible: SwiftUI.SpacerSizing
  public static let fixed:    SwiftUI.SpacerSizing
}
```

`ToolbarSpacer` is what breaks a toolbar into separate glass capsules. Without it, every
item in a placement merges into one blob.

```swift
.toolbar {
    ToolbarItem(placement: .primaryAction) { Button("Stop") {} }
    if #available(macOS 26.0, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
    ToolbarItem(placement: .primaryAction) { Button("Remove", systemImage: "trash") {} }
}
```

> `ToolbarSpacer` inside a `@ToolbarContentBuilder` under an `if #available` is legal —
> `ToolbarContentBuilder.buildLimitedAvailability` exists (`SwiftUI.if:9630`).

### 1.9 `sharedBackgroundVisibility(_:)` — VERIFIED

```swift
// SwiftUI.if:5701–5714
@available(iOS 26.0, macOS 26.0, *)
@available(tvOS, unavailable) @available(watchOS, unavailable) @available(visionOS, unavailable)
extension SwiftUI.ToolbarContent {
  nonisolated public func sharedBackgroundVisibility(_ visibility: SwiftUICore.Visibility) -> some SwiftUI.ToolbarContent
}
extension SwiftUI.CustomizableToolbarContent {
  nonisolated public func sharedBackgroundVisibility(_ visibility: SwiftUICore.Visibility) -> some SwiftUI.CustomizableToolbarContent
}
```

Use `.hidden` on a toolbar item that should not sit on the shared glass capsule (e.g. a
status indicator that is not a control).

### 1.10 `backgroundExtensionEffect()` — VERIFIED

```swift
// SwiftUI.if:12091–12096
extension SwiftUICore.View {
  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @MainActor @preconcurrency public func backgroundExtensionEffect() -> some SwiftUICore.View
  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @MainActor @preconcurrency public func backgroundExtensionEffect(isEnabled: Swift.Bool) -> some SwiftUICore.View
}
```

Mirrors and blurs an image out under adjacent glass. **We have no full-bleed imagery, so
this is out of scope for Morbstack.** Recorded so nobody spends an afternoon on it.

### 1.11 `scrollEdgeEffectStyle` / `scrollEdgeEffectHidden` — VERIFIED

```swift
// SwiftUI.if:12167–12173
extension SwiftUICore.View {
  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
  @available(visionOS, unavailable)
  nonisolated public func scrollEdgeEffectStyle(_ style: SwiftUI.ScrollEdgeEffectStyle?,
                                                for edges: SwiftUICore.Edge.Set) -> some SwiftUICore.View
  nonisolated public func scrollEdgeEffectHidden(_ hidden: Swift.Bool = true,
                                                 for edges: SwiftUICore.Edge.Set = .all) -> some SwiftUICore.View
}

public struct ScrollEdgeEffectStyle : Swift.Hashable, Swift.Sendable {
  public static var automatic: SwiftUI.ScrollEdgeEffectStyle { get }
  public static var hard:      SwiftUI.ScrollEdgeEffectStyle { get }
  public static var soft:      SwiftUI.ScrollEdgeEffectStyle { get }
}
```

`.hard` gives a crisp division — correct above a dense table. `.soft` fades — correct
above prose. See `IDENTITY.md` §5 for which surface gets which.

### 1.12 `safeAreaBar(edge:…)` — VERIFIED (26.0, and it is the right home for the engine pill)

```swift
// SwiftUI.if:16985–16991
extension SwiftUICore.View {
  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  nonisolated public func safeAreaBar(edge: SwiftUICore.VerticalEdge,
                                      alignment: SwiftUICore.HorizontalAlignment = .center,
                                      spacing: CoreFoundation.CGFloat? = nil,
                                      @ViewBuilder content: () -> some View) -> some SwiftUICore.View
  nonisolated public func safeAreaBar(edge: SwiftUICore.HorizontalEdge,
                                      alignment: SwiftUICore.VerticalAlignment = .center,
                                      spacing: CoreFoundation.CGFloat? = nil,
                                      @ViewBuilder content: () -> some View) -> some SwiftUICore.View
}
```

Unlike `safeAreaInset`, a `safeAreaBar` gets the system's bar treatment (glass + edge
effect) for free. Fall back to `.safeAreaInset(edge:spacing:content:)` below 26.

### 1.13 AppKit: `NSGlassEffectView` / `NSGlassEffectContainerView` — VERIFIED

```objc
// AppKit.h  (AppKit/Headers/NSGlassEffectView.h, © 2025)
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

Swift spelling: `NSGlassEffectView`, `NSGlassEffectView.Style.regular` / `.clear`,
`NSGlassEffectContainerView`. **Not exposed in `AppKit.swiftinterface`** — it arrives
through the ObjC header, which is why `grep Glass AppKit.swiftinterface` is empty.

**Morbstack should not need this.** We have no `NSViewRepresentable` chrome. Recorded only
so that if someone ever wraps an `NSTextView`-backed log viewport, they know the AppKit
spelling exists and does *not* need a SwiftUI bridge.

---

## 2. Structural APIs we are currently not using

### 2.1 `.inspector(isPresented:content:)` — VERIFIED, macOS 14.0

```swift
// SwiftUI.if:11393–11404
@available(iOS 17.0, macOS 14.0, *)
@available(tvOS, unavailable) @available(watchOS, unavailable) @available(visionOS, unavailable)
extension SwiftUICore.View {
  nonisolated public func inspector<V>(isPresented: Binding<Bool>,
                                       @ViewBuilder content: () -> V) -> some View where V : View
  nonisolated public func inspectorColumnWidth(min: CGFloat? = nil, ideal: CGFloat,
                                               max: CGFloat? = nil) -> some View
  nonisolated public func inspectorColumnWidth(_ width: CGFloat) -> some View
}
```

**macOS 14 — no availability gate needed.** This replaces the hand-rolled third column
in the containers screen outright.

```swift
ContainersList(model: model)
    .inspector(isPresented: $model.isInspectorShown) {
        ContainerDetail(container: selected)
            .inspectorColumnWidth(min: 380, ideal: 460, max: 640)
    }
```

### 2.2 `.searchable` + `SearchFieldPlacement` — VERIFIED, macOS 12.0

```swift
// SwiftUI.if:5655–5666
@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
extension SwiftUICore.View {
  nonisolated public func searchable(text: Binding<String>,
                                     placement: SwiftUI.SearchFieldPlacement = .automatic,
                                     prompt: SwiftUICore.Text? = nil) -> some View
  nonisolated public func searchable(text: Binding<String>,
                                     placement: SwiftUI.SearchFieldPlacement = .automatic,
                                     prompt: LocalizedStringKey) -> some View
}
// SwiftUI.if:5673–5686 — the isPresented: overloads, macOS 13.0 / 14.0 (StringProtocol form)
```

```swift
// SwiftUI.if — SearchFieldPlacement
public struct SearchFieldPlacement : Swift.Sendable {
  public static let automatic: SearchFieldPlacement
  @available(tvOS, unavailable) public static let toolbar: SearchFieldPlacement
  @available(iOS 15.0, macOS 12.0, *) public static var toolbarPrincipal: SearchFieldPlacement { get }
  @available(tvOS, unavailable) @available(watchOS, unavailable)
  public static var sidebar: SearchFieldPlacement { get }
  // navigationBarDrawer — iOS/watchOS only, macOS unavailable
}
```

macOS-legal placements: `.automatic`, `.toolbar`, `.toolbarPrincipal`, `.sidebar`.
**`.navigationBarDrawer` is `@available(macOS, unavailable)` — never write it.**

### 2.3 `Table` + `.tableStyle` — VERIFIED

```swift
// SwiftUI.if:1119
@available(iOS 16.0, macOS 12.0, *)
@available(tvOS, unavailable) @available(watchOS, unavailable)
public struct Table<Value, Rows, Columns> : SwiftUICore.View
  where Value == Rows.TableRowValue, Rows : TableRowContent, Columns : TableColumnContent,
        Rows.TableRowValue == Columns.TableRowValue

// SwiftUI.if:19744–19746
@available(iOS 16.0, macOS 12.0, *)
extension SwiftUICore.View {
  nonisolated public func tableStyle<S>(_ style: S) -> some View where S : SwiftUI.TableStyle
}
```

Styles:

| Style | Source | Availability |
| --- | --- | --- |
| `.automatic` | `SwiftUI.if:18424` | iOS 16 / macOS 12 |
| `.inset` | `SwiftUI.if:12598` | iOS 16 / macOS 12 |
| `.bordered` | `SwiftUI.if:21324` | **macOS 12 only** (`iOS unavailable`) |

`inset(alternatesRowBackgrounds:)` and `bordered(alternatesRowBackgrounds:)` are both
**deprecated** — the interface says *"Use the `.inset` style with the
`.alternatingRowBackgrounds()` view modifier"*. Use the modifier.

Related, VERIFIED at `SwiftUI.if:1321`: `AlternatingRowBackgroundBehavior` with
`.automatic`, and `@AppStorage`/`@SceneStorage` overloads taking
`TableColumnCustomization<RowValue>` (`SwiftUI.if:3814–3822`, iOS 17 / macOS 14) — that is
how a `Table`'s column widths and visibility persist.

### 2.4 `Form` + `.formStyle` — VERIFIED

```swift
// SwiftUI.if:13138
public struct Form<Content> : View where Content : View { public init(@ViewBuilder content: () -> Content) }

// SwiftUI.if:15634–15636
@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
extension SwiftUICore.View {
  nonisolated public func formStyle<S>(_ style: S) -> some View where S : SwiftUI.FormStyle
}

// SwiftUI.if:14621–14623
@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
extension SwiftUI.FormStyle where Self == SwiftUI.GroupedFormStyle {
  @MainActor public static var grouped: SwiftUI.GroupedFormStyle { get }
}
```

Also present: `.columns` (`SwiftUI.if:1740`) and `.automatic` (`SwiftUI.if:22704`).
`.grouped` is the macOS Settings idiom. Pair with `LabeledContent`
(`labeledContentStyle`, `SwiftUI.if:22780`, macOS 13).

### 2.5 `.toolbar(id:)` — customisable toolbars — VERIFIED, macOS 11.0

```swift
// SwiftUI.if:17924–17930
@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)
extension SwiftUICore.View {
  nonisolated public func toolbar<Content>(@ViewBuilder content: () -> Content) -> some View where Content : View
  nonisolated public func toolbar<Content>(@ToolbarContentBuilder content: () -> Content) -> some View where Content : ToolbarContent
  nonisolated public func toolbar<Content>(id: Swift.String,
                                           @ToolbarContentBuilder content: () -> Content) -> some View
                                           where Content : CustomizableToolbarContent
}
```

The `id:` form gives the user *Customize Toolbar…*. Items must be `ToolbarItem(id:placement:)`
and the whole content must be `CustomizableToolbarContent`. `ToolbarSpacer` conforms to
both protocols, so it is legal inside an `id:` toolbar.

Also VERIFIED, `SwiftUI.if:16989`: `toolbar(removing: ToolbarDefaultItemKind?)`
(macOS 14) — how you drop the automatic sidebar-toggle item if a screen needs to.

`ToolbarItemPlacement` statics legal on macOS: `.automatic`, `.principal`, `.navigation`,
`.primaryAction`, `.secondaryAction`, `.status`, `.confirmationAction`,
`.cancellationAction`, `.destructiveAction`, `.keyboard`, `.title`, `.subtitle`.
(`topBarLeading`, `bottomBar`, `bottomOrnament`, `largeTitle`, `largeSubtitle` exist in the
struct but are iOS/visionOS placements — do not use them here.)

### 2.6 `ContentUnavailableView` — VERIFIED, macOS 14.0

```swift
// SwiftUI.if:17170–17177
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public struct ContentUnavailableView<Label, Description, Actions> : View
  where Label : View, Description : View, Actions : View {
  public init(@ViewBuilder label: () -> Label,
              @ViewBuilder description: () -> Description = { EmptyView() },
              @ViewBuilder actions: () -> Actions = { EmptyView() })
}

// SwiftUI.if:17180–17200 — convenience where Label == Label<Text, Image>
nonisolated public init(_ title: LocalizedStringKey, image name: String, description: Text? = nil)
nonisolated public init(_ title: LocalizedStringKey, systemImage name: String, description: Text? = nil)

// SwiftUI.if:17205–17210
extension ContentUnavailableView where Label == SearchUnavailableContent.Label, … {
  public static var search: ContentUnavailableView<…> { get }
  public static func search(text: String) -> ContentUnavailableView<Label, Description, Actions>
}
```

```swift
ContentUnavailableView {
    Label("The engine isn’t running", systemImage: "shippingbox")
} description: {
    Text("Start it to see your containers, images and volumes.")
} actions: {
    Button("Start Engine") { }.buttonStyle(.borderedProminent)
}
```

`ContentUnavailableView.search(text:)` is the correct answer for "no containers match
your filter" and it localises itself.

### 2.7 `.contextMenu(forSelectionType:menu:primaryAction:)` — VERIFIED, macOS 13.0

```swift
// SwiftUI.if:21396–21399
@available(iOS 16.0, macOS 13.0, *)
@available(tvOS, unavailable) @available(watchOS, unavailable)
extension SwiftUICore.View {
  nonisolated public func contextMenu<I, M>(forSelectionType itemType: I.Type = I.self,
                                            @ViewBuilder menu: @escaping (Set<I>) -> M,
                                            primaryAction: ((Set<I>) -> Void)? = nil) -> some View
                                            where I : Hashable, M : View
}
```

This is the **multi-selection** context menu — the menu closure receives the whole
selection, and `primaryAction` is the double-click handler. Attach to the `List`/`Table`,
not to the row.

```swift
Table(images, selection: $selectedIDs) { … }
  .contextMenu(forSelectionType: Image.ID.self) { ids in
      Button("Copy Image ID") { copy(ids) }
      Button("Remove…", role: .destructive) { confirmRemove(ids) }
  } primaryAction: { ids in
      inspect(ids)
  }
```

### 2.8 `.keyboardShortcut` — VERIFIED, macOS 11.0

```swift
// SwiftUI.if:20260–20288
extension SwiftUICore.View {
  nonisolated public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View
  nonisolated public func keyboardShortcut(_ shortcut: KeyboardShortcut) -> some View
  @available(iOS 15.4, macOS 12.3, …) nonisolated public func keyboardShortcut(_ shortcut: KeyboardShortcut?) -> some View
  @available(iOS 17.0, macOS 14.0, …)
  nonisolated public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command,
                                           localization: KeyboardShortcut.Localization) -> some View
}
extension SwiftUI.Scene { /* same, macOS 11 / 14 */ }
```

Note `modifiers` defaults to `.command` — `.keyboardShortcut("k")` is ⌘K, not bare K.

### 2.9 `.symbolEffect` — VERIFIED, macOS 14.0

```swift
// SwiftUI.if:4348–4360
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUICore.View {
  public func symbolEffect<T>(_ effect: T, options: Symbols.SymbolEffectOptions = .default,
                              isActive: Swift.Bool = true) -> some View
                              where T : IndefiniteSymbolEffect, T : SymbolEffect
  public func symbolEffect<T, U>(_ effect: T, options: Symbols.SymbolEffectOptions = .default,
                                 value: U) -> some View
                                 where T : DiscreteSymbolEffect, T : SymbolEffect, U : Equatable
}
// SwiftUI.if:2510 — symbolEffectsRemoved(_ isEnabled: Bool = true)
```

Effect types available in `Symbols.if`: `PulseSymbolEffect`, `BounceSymbolEffect`,
`VariableColorSymbolEffect`, `ScaleSymbolEffect`, `AppearSymbolEffect`,
`DisappearSymbolEffect`, `ReplaceSymbolEffect`, `WiggleSymbolEffect`,
`RotateSymbolEffect`, `BreatheSymbolEffect`, `DrawOnSymbolEffect`, `DrawOffSymbolEffect`.

```swift
Image(systemName: "arrow.triangle.2.circlepath")
    .symbolEffect(.rotate, isActive: container.isRestarting)
```

### 2.10 `.contentTransition` — VERIFIED, macOS 13.0

```swift
// SwiftUICore.if:15839–15842
@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
extension SwiftUICore.View {
  public func contentTransition(_ transition: SwiftUICore.ContentTransition) -> some View
}
public struct ContentTransition : Equatable, Sendable {
  public static let identity:    ContentTransition
  public static let opacity:     ContentTransition
  public static let interpolate: ContentTransition
  public static func numericText(countsDown: Swift.Bool = false) -> ContentTransition
  @available(iOS 17.0, macOS 14.0, …) public static func numericText(value: Swift.Double) -> ContentTransition
}
```

`.numericText(value:)` is the correct treatment for a live CPU/memory readout.

### 2.11 `.containerBackground(for: .window)` — VERIFIED, macOS 15.0 for `.window`

```swift
// SwiftUI.if:12521–12527
@available(iOS 17.0, tvOS 17.0, macOS 14.0, watchOS 10.0, *)
extension SwiftUICore.View {
  nonisolated public func containerBackground<S>(_ style: S,
                                                 for container: ContainerBackgroundPlacement) -> some View
                                                 where S : ShapeStyle
  nonisolated public func containerBackground<V>(for container: ContainerBackgroundPlacement,
                                                 alignment: Alignment = .center,
                                                 @ViewBuilder content: () -> V) -> some View where V : View
}
```

```swift
// SwiftUI.if — ContainerBackgroundPlacement
@available(macOS 15.0, *)
@available(iOS, unavailable) @available(tvOS, unavailable)
@available(visionOS, unavailable) @available(watchOS, unavailable)
public static let window: SwiftUI.ContainerBackgroundPlacement
```

**Careful:** the *modifier* is macOS 14 but the `.window` *placement* is **macOS 15**, and
`.tabView` / `.navigation` / `.navigationSplitView` are all `@available(macOS, unavailable)`.
On macOS the only legal placement is `.window`. Our deployment target is exactly 15, so
`.containerBackground(_:for: .window)` needs **no** gate.

### 2.12 `.windowStyle` / `.windowToolbarStyle` — VERIFIED, macOS 11.0

```swift
// SwiftUI.if:3540–3542
extension SwiftUI.Scene { nonisolated public func windowStyle<S>(_ style: S) -> some Scene where S : WindowStyle }
// SwiftUI.if:18087–18089
extension SwiftUI.Scene { nonisolated public func windowToolbarStyle<S>(_ style: S) -> some Scene where S : WindowToolbarStyle }
```

| Value | Type | Source |
| --- | --- | --- |
| `.automatic` | `DefaultWindowStyle` | `SwiftUI.if:5899` |
| `.titleBar` | `TitleBarWindowStyle` | `SwiftUI.if:3014` |
| `.hiddenTitleBar` | `HiddenTitleBarWindowStyle` | `SwiftUI.if:9636` |
| `.plain` | `PlainWindowStyle` | `SwiftUI.if:13752` |
| `.automatic` | `DefaultWindowToolbarStyle` | `SwiftUI.if:3827` |
| `.unified` / `.unified(showsTitle:)` | `UnifiedWindowToolbarStyle` | `SwiftUI.if:19028` |
| `.unifiedCompact` / `.unifiedCompact(showsTitle:)` | `UnifiedCompactWindowToolbarStyle` | `SwiftUI.if:23888` |
| `.expanded` | `ExpandedWindowToolbarStyle` | `SwiftUI.if:22783` |

All macOS 11.0. `.unifiedCompact(showsTitle: false)` is the OrbStack-ish look: a short
titlebar that merges with the toolbar and hides the redundant window title.

### 2.13 `.presentationBackground` — VERIFIED, macOS 13.3

```swift
// SwiftUI.if:22944–22949
@available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *)
extension SwiftUICore.View {
  nonisolated public func presentationBackground<S>(_ style: S) -> some View where S : ShapeStyle
  nonisolated public func presentationBackground<V>(alignment: Alignment = .center,
                                                    @ViewBuilder content: () -> V) -> some View where V : View
}
// SwiftUI.if:21227 — presentationBackgroundInteraction(_:)
```

`presentationBackground(_:)` takes a **`ShapeStyle`**. `Material` conforms; `Glass` does
**not** (`Glass` is not a `ShapeStyle` — verified, it declares only `Equatable, Sendable`).
So the command palette's glass must come from `.glassEffect` on the palette's own root
view *inside* the presentation, with `.presentationBackground(.clear)` underneath it.

### 2.14 `.symbolColorRenderingMode` — VERIFIED, macOS 26.0

```swift
// SwiftUICore.if:6838–6850
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
public struct SymbolColorRenderingMode : Equatable, Sendable {
  public static let flat:     SymbolColorRenderingMode
  public static let gradient: SymbolColorRenderingMode
}
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension SwiftUICore.View {
  public func symbolColorRenderingMode(_ mode: SymbolColorRenderingMode?) -> some View
}
@available(iOS 26.0, …) extension SwiftUICore.Image {
  public func symbolColorRenderingMode(_ mode: SymbolColorRenderingMode?) -> SwiftUICore.Image
}
```

Sibling, also 26.0 (`SwiftUICore.if:6822`): `symbolVariableValueMode(_:)`.

Note this is **visionOS 26.0 available**, unlike the glass APIs which are
`@available(visionOS, unavailable)` — different availability shape, so a shared
`#available(macOS 26.0, *)` block covering both is still correct on our platform.

---

## 3. Explicitly UNVERIFIED — do not use

Searched for and **not found** in this SDK's interfaces. If an implementation agent
believes one of these exists, they must re-grep and amend this file with a line number
before using it.

| Name searched | Result |
| --- | --- |
| `Glass.thin`, `.thick`, `.prominent`, `.ultraThin` | **NOT FOUND.** Only `.regular`, `.clear`, `.identity`. |
| `Material` conformance on `Glass` | **NOT FOUND.** `Glass : Equatable, Sendable` only. Cannot be passed where a `ShapeStyle` is required. |
| `.glassBackgroundEffect` | **NOT FOUND** on macOS (visionOS-only spelling). |
| `.toolbarStyle(…)` on a `View` | **NOT FOUND.** The modifier is `windowToolbarStyle` and it is on `Scene`, not `View`. |
| `.containerBackground(for: .navigation)` on macOS | **FOUND but `@available(macOS, unavailable)`.** Only `.window` is legal. |
| `.searchable(placement: .navigationBarDrawer)` on macOS | **FOUND but `@available(macOS, unavailable)`.** |
| `NSGlassEffectView` in `AppKit.swiftinterface` | **NOT FOUND** there; it is in the ObjC header only. Importable, but there is no Swift-interface declaration to cite. |
| `.buttonStyle(.glass(_:))` at macOS 26.0 | **The static exists at 26.0 but `GlassButtonStyle.init(_:)` is 26.1.** Treat the tinted form as 26.1. |
| `.listRowGlass`, `.glassRow`, `.sidebarGlass` | **NOT FOUND.** Invented names. |
| A glass variant of `.menuBarExtraStyle` | **NOT FOUND.** `.window` and `.menu` only; a `.window` popover gets glass by applying it to your own root view. |

---

## 4. The five-line summary for implementers

1. Deployment target is macOS 15 → **every glass call goes through `Design/MorbGlass.swift`**,
   never inline.
2. Glass has exactly three variants and two decorators: `.regular` / `.clear` / `.identity`,
   `.tint(_:)`, `.interactive(_:)`.
3. Group glass with `GlassEffectContainer(spacing:)` + `glassEffectUnion(id:namespace:)`;
   separate toolbar capsules with `ToolbarSpacer(_:placement:)`.
4. Most of the "native Mac" win is **not** glass — it is `.toolbar`, `.inspector`,
   `.searchable`, `Table`, `Form(.grouped)` and `ContentUnavailableView`, all of which are
   available at our current deployment target with no gate at all.
5. When in doubt, `grep` the interface. An invented API is worse than a missing one.
