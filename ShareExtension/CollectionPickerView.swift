import SembleKit
import SwiftUI

/// Search-or-create field plus a scrollable list of collections with round
/// checkboxes: the user's own, then other people's open ones. The list takes
/// whatever height the sheet leaves it, and its bottom row fades out while
/// there's more to scroll to.
struct CollectionPickerView: View {
    @ObservedObject var model: ShareSheetModel

    /// The bottom of the rows, in the list's own (visible) coordinate space.
    @State private var contentBottom: CGFloat = 0

    private static let listSpace = "collectionList"
    /// About one row tall.
    private static let fadeHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Collections")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.sembleText)

            searchField

            GeometryReader { viewport in
                ScrollView {
                    rows
                        .background {
                            GeometryReader { content in
                                let bottom = content.frame(in: .named(Self.listSpace)).maxY
                                Color.clear.onChange(of: bottom, initial: true) { _, newBottom in
                                    contentBottom = newBottom
                                }
                            }
                        }
                }
                .coordinateSpace(.named(Self.listSpace))
                .mask {
                    fade(isOn: contentBottom > viewport.size.height + 1)
                }
            }
            // Two rows, so the list stays usable with the keyboard up.
            .frame(minHeight: 88)
        }
    }

    private var rows: some View {
        let own = model.visibleCollections
        let shared = model.visibleSharedCollections
        return LazyVStack(alignment: .leading, spacing: 0) {
            if !shared.isEmpty, model.canCreateCollection || !own.isEmpty {
                groupHeader("Mine")
            }
            if model.canCreateCollection {
                createRow
            }
            ForEach(own) { collection in
                row(for: collection)
            }
            if !shared.isEmpty {
                groupHeader("Shared")
                ForEach(shared) { collection in
                    row(for: collection)
                }
            }
            if model.collections.isEmpty, shared.isEmpty, !model.canCreateCollection {
                Text("No collections yet.")
                    .font(.footnote)
                    .foregroundStyle(Color.sembleMutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
    }

    /// Opaque, with a row-tall fade at the bottom when `isOn`.
    private func fade(isOn: Bool) -> some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: isOn ? Self.fadeHeight : 0)
        }
    }

    // MARK: Pieces

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.sembleMutedText)
            TextField("Search or create a collection…", text: $model.query)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .onSubmit {
                    if model.canCreateCollection {
                        model.createCollection()
                    }
                }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.sembleMutedText)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(Color.sembleField)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var createRow: some View {
        Button {
            model.createCollection()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.sembleOrange)
                Text("Create new collection “\(model.creationName)”")
                    .foregroundStyle(Color.sembleText)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 10)
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.sembleMutedText)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(for collection: CollectionSummary) -> some View {
        let isSelected = model.selected.contains(collection.id)
        let isUnavailable = model.unavailableCollections.contains(collection.id)
        return Button {
            model.toggle(collection)
        } label: {
            HStack(spacing: 12) {
                if isUnavailable {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.sembleMutedText)
                        .frame(width: 22, height: 22)
                        .accessibilityLabel("Unavailable")
                } else {
                    CheckCircle(isSelected: isSelected)
                }
                Text(collection.name)
                    .foregroundStyle(isUnavailable ? Color.sembleMutedText : Color.sembleText)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let owner = collection.ownerHandle {
                    Text("@" + owner)
                        .font(.footnote)
                        .foregroundStyle(Color.sembleMutedText)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A round checkbox: an outlined circle, or a filled orange circle with a tick.
struct CheckCircle: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? Color.sembleOrange : Color.sembleStone300, lineWidth: 1.5)
                .background {
                    Circle().fill(isSelected ? Color.sembleOrange : Color.clear)
                }
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}
