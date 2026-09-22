import SembleKit
import SwiftUI

/// Search-or-create field plus a scrollable, height-limited list of the
/// user's collections with round checkboxes.
struct CollectionPickerView: View {
    @ObservedObject var model: ShareSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Collections")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.sembleText)

            searchField

            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.canCreateCollection {
                        createRow
                    }
                    ForEach(model.visibleCollections) { collection in
                        row(for: collection)
                    }
                    if model.collections.isEmpty, !model.canCreateCollection {
                        Text("No collections yet.")
                            .font(.footnote)
                            .foregroundStyle(Color.sembleMutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                    }
                }
            }
            .frame(maxHeight: 220)
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

    private func row(for collection: CollectionSummary) -> some View {
        let isSelected = model.selected.contains(collection.id)
        return Button {
            model.toggle(collection)
        } label: {
            HStack(spacing: 12) {
                CheckCircle(isSelected: isSelected)
                Text(collection.name)
                    .foregroundStyle(Color.sembleText)
                    .lineLimit(1)
                Spacer()
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
