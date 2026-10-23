//
//  Theme.swift
//  PokeParty
//
//  Color themes for iOS — a pro feature. The default theme leaves the system
//  look untouched; the others tint the app and recolor list backgrounds and
//  rows. On macOS the modifiers are no-ops so shared views can use them freely.
//

import SwiftUI

#if os(iOS)
import UIKit

/// The colors a theme applies. Every color adapts to light and dark mode.
struct ThemeColors: Equatable {
    var background: Color
    var surface: Color
    var accent: Color
    var secondaryAccent: Color

    /// Builds a scheme from light and dark hex values.
    fileprivate init(
        background: (light: UInt32, dark: UInt32),
        surface: (light: UInt32, dark: UInt32),
        accent: (light: UInt32, dark: UInt32),
        secondaryAccent: (light: UInt32, dark: UInt32)
    ) {
        self.background = Self.adaptive(background)
        self.surface = Self.adaptive(surface)
        self.accent = Self.adaptive(accent)
        self.secondaryAccent = Self.adaptive(secondaryAccent)
    }

    private static func adaptive(_ hex: (light: UInt32, dark: UInt32)) -> Color {
        // `@Sendable` keeps the closure off the main actor: UIKit resolves dynamic
        // colors on whatever thread SwiftUI renders on.
        Color(uiColor: UIColor { @Sendable traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? hex.dark : hex.light)
        })
    }
}

private extension UIColor {
    nonisolated convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The themes people can choose from. Only the default is free.
enum AppTheme: String, CaseIterable, Identifiable {
    case standard, ocean, forest, rose, sunset, graphite, midnight, lavender

    static let defaultsKey = "appTheme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .rose: "Rose"
        case .sunset: "Sunset"
        case .graphite: "Graphite"
        case .midnight: "Midnight"
        case .lavender: "Lavender"
        }
    }

    var isFree: Bool { self == .standard }

    /// The theme that actually applies: a locked theme falls back to the default.
    func available(unlocked: Bool) -> AppTheme {
        isFree || unlocked ? self : .standard
    }

    /// nil for the standard theme, which keeps the system appearance.
    var colors: ThemeColors? {
        switch self {
        case .standard:
            nil
        case .ocean:
            ThemeColors(
                background: (0xE8F3F8, 0x0D1B26),
                surface: (0xD3E7F0, 0x17303F),
                accent: (0x0E7C9B, 0x4FC3E8),
                secondaryAccent: (0x2E5E9E, 0x8FB4F0)
            )
        case .forest:
            ThemeColors(
                background: (0xEEF3E6, 0x111C14),
                surface: (0xDDE8CF, 0x1D2E22),
                accent: (0x3E7D32, 0x7BD389),
                secondaryAccent: (0x8A5A2B, 0xE0B07A)
            )
        case .rose:
            ThemeColors(
                background: (0xFCEFF2, 0x24121A),
                surface: (0xF6DCE3, 0x361D28),
                accent: (0xC2185B, 0xFF7FB0),
                secondaryAccent: (0x6A4C93, 0xC3A6F0)
            )
        case .sunset:
            ThemeColors(
                background: (0xFFF4E0, 0x211608),
                surface: (0xF9E2BC, 0x33230E),
                accent: (0xC26A00, 0xFFB347),
                secondaryAccent: (0x9C2F2F, 0xF08A8A)
            )
        case .graphite:
            ThemeColors(
                background: (0xF3F3F5, 0x121214),
                surface: (0xE4E4E8, 0x232327),
                accent: (0x3D4A5F, 0x9AA5B8),
                secondaryAccent: (0x7A5CC2, 0xB9A6F2)
            )
        case .midnight:
            ThemeColors(
                background: (0xEEF0FA, 0x0A0E1F),
                surface: (0xDCE0F3, 0x151B38),
                accent: (0x3949AB, 0x7C8CFF),
                secondaryAccent: (0x00838F, 0x4DD0E1)
            )
        case .lavender:
            ThemeColors(
                background: (0xF5F0FB, 0x1B1526),
                surface: (0xE8DEF5, 0x2B2140),
                accent: (0x7E57C2, 0xB39DDB),
                secondaryAccent: (0xAD1457, 0xF48FB1)
            )
        }
    }
}

extension EnvironmentValues {
    @Entry var themeColors: ThemeColors? = nil
}

private struct ThemedBackground: ViewModifier {
    @Environment(\.themeColors) private var colors

    func body(content: Content) -> some View {
        if let colors {
            content
                .scrollContentBackground(.hidden)
                .background(colors.background.ignoresSafeArea())
        } else {
            content
        }
    }
}

private struct ThemedRow: ViewModifier {
    @Environment(\.themeColors) private var colors

    func body(content: Content) -> some View {
        content.listRowBackground(colors?.surface)
    }
}

/// Rows of plain-style lists: section headers sit on the page background, so
/// rows use it too, or each section reads as a pale band over a darker block.
private struct ThemedPlainRow: ViewModifier {
    @Environment(\.themeColors) private var colors

    func body(content: Content) -> some View {
        content.listRowBackground(colors?.background)
    }
}

/// Tints the bar above a list: the theme background when themed, else a material.
private struct ThemedBar: ViewModifier {
    @Environment(\.themeColors) private var colors

    func body(content: Content) -> some View {
        if let colors {
            content.background(colors.background)
        } else {
            content.background(.regularMaterial)
        }
    }
}

/// Win/loss text color. The stock loss red is too pale on tinted light-mode cards,
/// so themes get a deeper red in light mode.
private struct ThemedOutcomeColor: ViewModifier {
    let favorable: Bool
    @Environment(\.themeColors) private var colors

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }

    private var color: Color {
        if favorable { return Theme.win }
        guard colors != nil else { return Theme.loss }
        return Color(uiColor: UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: 0xFF5858) : UIColor(hex: 0xB71C1C)
        })
    }
}

extension View {
    /// Background for a bar pinned above a list.
    func themedBar() -> some View {
        modifier(ThemedBar())
    }

    /// Foreground color for a win/loss rating.
    func outcomeForeground(favorable: Bool) -> some View {
        modifier(ThemedOutcomeColor(favorable: favorable))
    }

    /// Replaces a list or form's background with the current theme's.
    func themedBackground() -> some View {
        modifier(ThemedBackground())
    }

    /// Themed fill for the rows of a section. `listRowBackground` only reaches
    /// rows inside the view it's applied to, so this goes on each Section.
    func themedRow() -> some View {
        modifier(ThemedRow())
    }

    /// Row fill for sections in plain-style lists.
    func themedPlainRow() -> some View {
        modifier(ThemedPlainRow())
    }

    /// Applies a theme to this view and its children, including the tint.
    func appTheme(_ theme: AppTheme) -> some View {
        self
            .environment(\.themeColors, theme.colors)
            .tint(theme.colors?.accent)
    }
}

// MARK: - Settings

/// The Appearance section of Settings: pick a theme, or unlock them all.
struct ThemeSettingsSection: View {
    @Environment(EntitlementStore.self) private var entitlements
    @AppStorage(AppTheme.defaultsKey) private var selectedTheme = AppTheme.standard
    @State private var showingPaywall = false

    var body: some View {
        Section {
            ForEach(AppTheme.allCases) { theme in
                Button {
                    choose(theme)
                } label: {
                    ThemeRow(
                        theme: theme,
                        isSelected: theme == selectedTheme.available(unlocked: entitlements.isUnlocked),
                        isLocked: !theme.isFree && !entitlements.isUnlocked
                    )
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text(entitlements.isUnlocked
                ? "Themes change the colors used across the app."
                : "Themes are part of PokeParty Pro.")
        }
        .themedRow()
        .sheet(isPresented: $showingPaywall) {
            NavigationStack {
                PaywallView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { showingPaywall = false }
                        }
                    }
            }
        }
        .onChange(of: entitlements.isUnlocked) { _, unlocked in
            if unlocked { showingPaywall = false }
        }
    }

    private func choose(_ theme: AppTheme) {
        if theme.isFree || entitlements.isUnlocked {
            selectedTheme = theme
        } else {
            showingPaywall = true
        }
    }
}

/// Four dots showing a theme's background, surface and accent colors.
private struct ThemeSwatch: View {
    let theme: AppTheme

    var body: some View {
        HStack(spacing: -6) {
            if let colors = theme.colors {
                dot(colors.background)
                dot(colors.surface)
                dot(colors.accent)
                dot(colors.secondaryAccent)
            } else {
                dot(Color(uiColor: .systemBackground))
                dot(Color(uiColor: .secondarySystemBackground))
                dot(.blue)
                dot(.indigo)
            }
        }
        .accessibilityHidden(true)
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 22, height: 22)
            .overlay { Circle().strokeBorder(.separator) }
    }
}

private struct ThemeRow: View {
    let theme: AppTheme
    let isSelected: Bool
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 12) {
            ThemeSwatch(theme: theme)
            Text(theme.title)
            Spacer()
            if isLocked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Locked")
            } else if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Selected")
            }
        }
        .contentShape(.rect)
    }
}

#else

// macOS keeps the system appearance.
enum AppTheme {
    static let defaultsKey = "appTheme"
}

extension View {
    func themedBackground() -> some View { self }
    func themedRow() -> some View { self }
    func themedPlainRow() -> some View { self }
    func themedBar() -> some View { background(.regularMaterial) }
    func outcomeForeground(favorable: Bool) -> some View {
        foregroundStyle(favorable ? Theme.win : Theme.loss)
    }
}

#endif
