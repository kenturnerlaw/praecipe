import SwiftUI
import UIKit

// MARK: - Typography choice
//
// Lexend is the design target, but we use SF Pro Rounded + wide tracking instead of
// bundling Google fonts — same readability goals (open counters, calm rhythm) with
// zero font-registration overhead and full Dynamic Type support.

enum PraecipeColors {
    static let background = Color(hex: 0xF7F5F2)
    static let surface = Color(hex: 0xEEEBE6)
    static let card = Color(hex: 0xF3F1EC)

    static let textPrimary = Color(hex: 0x2C3345)
    static let textSecondary = Color(hex: 0x5C6578)
    static let textTertiary = Color(hex: 0x8B939E)

    static let accent = Color(hex: 0x6B8F7A)
    static let accentBlue = Color(hex: 0x5B7C99)
    static let destructive = Color(hex: 0xB85C4A)
    static let warning = Color(hex: 0xC4A574)
    static let junk = Color(hex: 0xA67C52)
    static let flag = Color(hex: 0xC49A6C)

    static let separator = Color(hex: 0xD9D4CC)
    static let unreadDot = accentBlue

    static let infoBanner = accentBlue.opacity(0.12)
    static let errorBanner = destructive.opacity(0.14)
}

enum PraecipeFont {
    static let largeTitle = Font.system(.largeTitle, design: .rounded).weight(.semibold)
    static let title = Font.system(.title2, design: .rounded).weight(.semibold)
    static let title3 = Font.system(.title3, design: .rounded).weight(.semibold)
    static let headline = Font.system(.headline, design: .rounded).weight(.semibold)
    static let body = Font.system(.body, design: .rounded)
    static let subheadline = Font.system(.subheadline, design: .rounded)
    static let footnote = Font.system(.footnote, design: .rounded)
    static let caption = Font.system(.caption, design: .rounded)
    static let caption2 = Font.system(.caption2, design: .rounded)

    static let trackingLargeTitle: CGFloat = 0.4
    static let trackingTitle: CGFloat = 0.35
    static let trackingHeadline: CGFloat = 0.3
    static let trackingBody: CGFloat = 0.55
    static let trackingSubheadline: CGFloat = 0.45
    static let trackingCaption: CGFloat = 0.35
    static let trackingCaption2: CGFloat = 0.3
}

enum PraecipeTheme {
    static func configureAppearance() {
        let bg = UIColor(PraecipeColors.background)
        let surface = UIColor(PraecipeColors.surface)
        let primary = UIColor(PraecipeColors.textPrimary)
        let separator = UIColor(PraecipeColors.separator)
        let accent = UIColor(PraecipeColors.accent)

        UITableView.appearance().backgroundColor = bg
        UITableView.appearance().separatorColor = separator.withAlphaComponent(0.55)

        UINavigationBar.appearance().largeTitleTextAttributes = [
            .foregroundColor: primary,
            .kern: PraecipeFont.trackingLargeTitle,
        ]
        UINavigationBar.appearance().titleTextAttributes = [
            .foregroundColor: primary,
            .kern: PraecipeFont.trackingHeadline,
        ]

        UITabBar.appearance().backgroundColor = surface
        UITabBar.appearance().unselectedItemTintColor = UIColor(PraecipeColors.textTertiary)
        UITabBar.appearance().tintColor = accent

        UISearchBar.appearance().tintColor = accent
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - View modifiers

struct PraecipeThemedRootModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(PraecipeColors.accent)
            .foregroundStyle(PraecipeColors.textPrimary)
            .background(PraecipeColors.background.ignoresSafeArea())
            .preferredColorScheme(.light)
    }
}

struct PraecipeListModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(PraecipeColors.background)
            .listRowSeparatorTint(PraecipeColors.separator.opacity(0.55))
            .listRowBackground(PraecipeColors.card)
            .listRowSpacing(0)
    }
}

struct PraecipeGroupedListModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(PraecipeColors.background)
            .listRowSeparatorTint(PraecipeColors.separator.opacity(0.45))
            .listSectionSpacing(12)
    }
}

struct PraecipeCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(PraecipeColors.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(PraecipeColors.separator.opacity(0.35), lineWidth: 0.5)
            )
    }
}

struct PraecipePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PraecipeFont.subheadline.weight(.semibold))
            .tracking(PraecipeFont.trackingSubheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(PraecipeColors.accent.opacity(configuration.isPressed ? 0.78 : 1), in: Capsule())
    }
}

struct PraecipeBorderedProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PraecipeFont.subheadline.weight(.semibold))
            .tracking(PraecipeFont.trackingSubheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(PraecipeColors.accent.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension View {
    func praecipeThemed() -> some View {
        modifier(PraecipeThemedRootModifier())
    }

    func praecipeList() -> some View {
        modifier(PraecipeListModifier())
    }

    func praecipeGroupedList() -> some View {
        modifier(PraecipeGroupedListModifier())
    }

    func praecipeCard() -> some View {
        modifier(PraecipeCardModifier())
    }

    func praecipeLargeTitle() -> some View {
        font(PraecipeFont.largeTitle).tracking(PraecipeFont.trackingLargeTitle)
    }

    func praecipeTitle() -> some View {
        font(PraecipeFont.title).tracking(PraecipeFont.trackingTitle)
    }

    func praecipeTitle3() -> some View {
        font(PraecipeFont.title3).tracking(PraecipeFont.trackingTitle)
    }

    func praecipeHeadline() -> some View {
        font(PraecipeFont.headline).tracking(PraecipeFont.trackingHeadline)
    }

    func praecipeBody(_ weight: Font.Weight = .regular) -> some View {
        font(PraecipeFont.body.weight(weight)).tracking(PraecipeFont.trackingBody)
    }

    func praecipeSubheadline(_ weight: Font.Weight = .regular) -> some View {
        font(PraecipeFont.subheadline.weight(weight)).tracking(PraecipeFont.trackingSubheadline)
    }

    func praecipeFootnote(_ weight: Font.Weight = .regular) -> some View {
        font(PraecipeFont.footnote.weight(weight)).tracking(PraecipeFont.trackingCaption)
    }

    func praecipeCaption(_ weight: Font.Weight = .regular) -> some View {
        font(PraecipeFont.caption.weight(weight)).tracking(PraecipeFont.trackingCaption)
    }

    func praecipeCaption2(_ weight: Font.Weight = .regular) -> some View {
        font(PraecipeFont.caption2.weight(weight)).tracking(PraecipeFont.trackingCaption2)
    }

    func praecipeSecondaryText() -> some View {
        foregroundStyle(PraecipeColors.textSecondary)
    }

    func praecipeTertiaryText() -> some View {
        foregroundStyle(PraecipeColors.textTertiary)
    }
}

struct PraecipePasswordField: View {
    var title = "Password"
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if revealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
                    .font(.body)
                    .foregroundStyle(PraecipeColors.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed ? "Hide password" : "Show password")
        }
    }
}
