# CodeEdit Patterns Reference

Source: `/tmp/CodeEdit/` (cloned from CodeEditApp/CodeEdit)

## Project Organization
- **Feature-based**: `Features/{FeatureName}/` with nested `Models/`, `Views/`, `ViewModels/`
- **One file per view** — never multiple views in one file
- **Shared UI library**: `Features/CodeEditUI/Views/` and `Styles/`
- **Extensions organized by type**: `Utils/Extensions/{Type}/{Type}+{Category}.swift`

## Settings Architecture (6 layers)
1. **`Settings`** — singleton `ObservableObject`, owns `@Published var preferences: SettingsData`
2. **`SettingsData`** — Codable struct with nested settings structs per category
3. **Per-category models** — e.g. `SettingsData.GeneralSettings`, each `Codable + Hashable`
4. **`@AppSettings` property wrapper** — `DynamicProperty` bridging Environment + Settings.shared + Binding
5. **`SettingsView`** — `NavigationSplitView`, sidebar list + `switch` on selectedPage for detail
6. **Per-page views** — use `@AppSettings(\.category)` + `SettingsForm` + computed properties in `private extension`

Key: JSON persistence to `~/Library/Application Support/`, 2-second throttled saves

## View Composition Pattern
```swift
struct SomeSettingsView: View {
    @AppSettings(\.category) var settings

    var body: some View {
        SettingsForm {
            Section { settingA; settingB }
            Section { settingC; settingD }
        }
    }
}

private extension SomeSettingsView {
    var settingA: some View { Picker("Label", selection: $settings.prop) { ... } }
    var settingB: some View { Toggle("Label", isOn: $settings.flag) }
}
```

**Key insight**: Every individual setting is a computed property in a `private extension`. Body just composes them into Sections.

## Code Style
- **Property order**: constants → @Environment → @State/@FocusState → @StateObject/@ObservedObject/@EnvironmentObject → custom wrappers → init → body
- **MARK sections**: `// MARK: - SectionName`
- **Import order**: Foundation/SwiftUI → external packages → local modules
- **Access control**: struct is internal, helpers in `private extension`
- **Doc comments** on public types: `/// A view that implements...`
- **File headers**: standard Xcode `//  FileName.swift  //  CodeEdit  //  Created by...`

## Notable Patterns
- **`private extension` over `private` on each member** — cleaner, groups related code
- **`@AppSettings` property wrapper** — eliminates manual Binding/onChange boilerplate
- **`SettingsForm`** — generic container wrapping `NavigationStack { Form { ... } }`
- **Throttled saves** — Combine `.throttle(for: 2)` on settings changes
- **`ServiceContainer`** — DI container for singletons (LSPService, etc.)
- **`SearchableSettingsPage` protocol** — each settings model provides `searchKeys` for search
- **`NSViewRepresentable`** for native controls (SearchField, EffectView)
