import SwiftData
import SwiftUI

/// Predefined legal-practice tags (stored lowercase; displayed with # prefix).
enum MailTagCatalog {
    static let predefined: [String] = [
        "client", "court", "eservice", "opposing", "intake", "billing", "follow-up"
    ]

    static func display(_ tag: String) -> String {
        let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return "" }
        return clean.hasPrefix("#") ? clean : "#\(clean)"
    }

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
    }

    static func color(for tag: String) -> Color {
        switch tag.lowercased() {
        case "client": return Color(hex: 0x5B7C99)
        case "court": return Color(hex: 0x7A6B8F)
        case "eservice": return Color(hex: 0x5F8F8A)
        case "opposing": return Color(hex: 0xB8895A)
        case "intake": return Color(hex: 0x6B8F7A)
        case "billing": return Color(hex: 0x667A99)
        case "follow-up": return Color(hex: 0x9A7A8F)
        default:
            let palette: [Color] = [
                Color(hex: 0x6B8F9A),
                Color(hex: 0x7A9488),
                Color(hex: 0xA69B6B),
                Color(hex: 0x8F7A6B),
                Color(hex: 0x8F6B7A),
            ]
            let hash = abs(tag.lowercased().hashValue)
            return palette[hash % palette.count]
        }
    }
}

enum MailTagIndex {
    static func counts(in messages: [MailMessage]) -> [(tag: String, count: Int)] {
        var tallies: [String: Int] = [:]
        for msg in messages where !msg.deleted {
            for tag in msg.tags {
                tallies[tag, default: 0] += 1
            }
        }
        return tallies.map { (tag: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.tag < rhs.tag
            }
    }

    /// All tags to show in pickers: predefined first, then mailbox tags, deduped.
    static func pickerTags(in messages: [MailMessage]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for tag in MailTagCatalog.predefined {
            if seen.insert(tag).inserted { ordered.append(tag) }
        }
        let used = Set(messages.flatMap(\.tags).map { $0.lowercased() })
        for tag in used.sorted() where seen.insert(tag).inserted {
            ordered.append(tag)
        }
        return ordered
    }
}

extension MailMessage {
    func toggleTag(_ raw: String) {
        let tag = MailTagCatalog.normalize(raw)
        guard !tag.isEmpty else { return }
        if tags.contains(tag) {
            removeTag(tag)
        } else {
            addTag(tag)
        }
    }

    func hasTag(_ raw: String) -> Bool {
        tags.contains(MailTagCatalog.normalize(raw))
    }
}

// MARK: - Chips

struct TagChipRow: View {
    let tags: [String]
    var compact = false
    var isSelected: ((String) -> Bool)? = nil
    var onTap: ((String) -> Void)?
    var onRemove: ((String) -> Void)?

    var body: some View {
        FlowLayout(spacing: compact ? 4 : 6) {
            ForEach(tags, id: \.self) { tag in
                TagChip(
                    tag: tag,
                    compact: compact,
                    selected: isSelected?(tag) ?? false,
                    onTap: onTap.map { handler in { handler(tag) } },
                    onRemove: onRemove.map { handler in { handler(tag) } }
                )
            }
        }
    }
}

private struct TagChip: View {
    let tag: String
    var compact: Bool
    var selected = false
    var onTap: (() -> Void)?
    var onRemove: (() -> Void)?

    private var tint: Color { MailTagCatalog.color(for: tag) }

    var body: some View {
        HStack(spacing: 3) {
            if selected {
                Image(systemName: "checkmark")
                    .font(compact ? .caption2.weight(.bold) : .caption2.weight(.bold))
                    .foregroundStyle(tint)
            }
            Text(MailTagCatalog.display(tag))
                .font(compact ? PraecipeFont.caption2.weight(.medium) : PraecipeFont.caption.weight(.medium))
                .tracking(compact ? PraecipeFont.trackingCaption2 : PraecipeFont.trackingCaption)
                .foregroundStyle(tint)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(tint.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(tint.opacity(selected ? 0.22 : 0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(selected ? 0.55 : 0.35), lineWidth: selected ? 1 : 0.5))
        .contentShape(Capsule())
        .onTapGesture { onTap?() }
    }
}

/// Simple horizontal wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}

// MARK: - Tag picker sheet

struct MailTagPickerTarget: Identifiable {
    let id: PersistentIdentifier
    let message: MailMessage
    var focusNewTag: Bool

    init(_ message: MailMessage, focusNewTag: Bool = false) {
        self.message = message
        self.id = message.persistentModelID
        self.focusNewTag = focusNewTag
    }
}

struct MailTagPickerSheet: View {
    @Bindable var message: MailMessage
    let allMessages: [MailMessage]
    var focusNewTag: Bool
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""
    @FocusState private var newTagFocused: Bool

    private var pickerTags: [String] {
        MailTagIndex.pickerTags(in: allMessages)
    }

    var body: some View {
        NavigationStack {
            List {
                if !message.tags.isEmpty {
                    Section("On this message") {
                        TagChipRow(tags: message.tags.sorted()) { tag in
                            message.removeTag(tag)
                            try? context.save()
                        }
                    }
                }
                Section("Tags") {
                    ForEach(pickerTags, id: \.self) { tag in
                        Button {
                            message.toggleTag(tag)
                            try? context.save()
                        } label: {
                            HStack {
                                Text(MailTagCatalog.display(tag))
                                    .foregroundStyle(MailTagCatalog.color(for: tag))
                                Spacer()
                                if message.hasTag(tag) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(PraecipeColors.accent)
                                }
                            }
                        }
                    }
                }
                Section("New tag") {
                    HStack {
                        TextField("e.g. urgent", text: $newTag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($newTagFocused)
                        Button("Add") { addNewTag() }
                            .disabled(MailTagCatalog.normalize(newTag).isEmpty)
                    }
                }
            }
            .praecipeList()
            .navigationTitle("Tag Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if focusNewTag {
                    newTagFocused = true
                }
            }
        }
    }

    private func addNewTag() {
        let tag = MailTagCatalog.normalize(newTag)
        guard !tag.isEmpty else { return }
        message.addTag(tag)
        newTag = ""
        try? context.save()
    }
}

// MARK: - Tag management

struct MailTagManagementView: View {
    @Query(sort: \MailMessage.sentAt, order: .reverse) private var messages: [MailMessage]
    @Binding var search: String
    @Environment(\.dismiss) private var dismiss

    private var tagCounts: [(tag: String, count: Int)] {
        MailTagIndex.counts(in: messages)
    }

    var body: some View {
        List {
            if tagCounts.isEmpty {
                ContentUnavailableView("No Tags", systemImage: "number", description: Text("Long-press a message and choose Tag… to add hashtags."))
            } else {
                Section("Tags in mailbox") {
                    ForEach(tagCounts, id: \.tag) { entry in
                        Button {
                            search = MailTagCatalog.display(entry.tag)
                            dismiss()
                        } label: {
                            HStack {
                                Text(MailTagCatalog.display(entry.tag))
                                    .foregroundStyle(MailTagCatalog.color(for: entry.tag))
                                Spacer()
                                Text("\(entry.count)")
                                    .praecipeSubheadline()
                                    .monospacedDigit()
                                    .praecipeSecondaryText()
                            }
                        }
                    }
                }
            }
            Section {
                Text("Tap a tag to filter the mail list. Search with #tag anytime.")
                    .praecipeFootnote()
                    .praecipeSecondaryText()
            }
        }
        .praecipeList()
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
    }
}
