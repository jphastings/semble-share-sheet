import SembleKit
import SwiftUI

/// The whole share sheet: header, URL preview, collection picker, note and
/// the save button, or a full-screen status when there's nothing to edit.
struct ShareSheetView: View {
    @ObservedObject var model: ShareSheetModel
    let onCancel: () -> Void
    let onComplete: () -> Void

    @FocusState private var isNoteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.sembleBorder)
            content
        }
        .background {
            Color.sembleBackground.ignoresSafeArea()
        }
        .task {
            await model.load()
        }
        .onChange(of: model.phase) { _, phase in
            guard phase == .saved else { return }
            // Let the checkmark register, then hand back to the host app.
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                onComplete()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            SembleTitle()
            Spacer()
            Button("Cancel", action: onCancel)
                .font(.body)
                .foregroundStyle(Color.sembleMutedText)
                .disabled(model.phase == .saving || model.phase == .saved)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            status {
                ProgressView()
                Text("Connecting…")
                    .foregroundStyle(Color.sembleMutedText)
            }
        case .notSignedIn:
            status {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(Color.sembleOrange)
                Text("Open the Add to Semble app and log in first.")
                    .multilineTextAlignment(.center)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.semble)
                    .padding(.top, 8)
            }
        case .noURL:
            status {
                Image(systemName: "link.badge.plus")
                    .font(.largeTitle)
                    .foregroundStyle(Color.sembleOrange)
                Text("Nothing shareable here. Share a link to save it to Semble.")
                    .multilineTextAlignment(.center)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.semble)
                    .padding(.top, 8)
            }
        case .failed(let message) where !model.showsForm:
            status {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(Color.sembleOrange)
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await model.retry() }
                }
                .buttonStyle(.semble)
                .padding(.top, 8)
            }
        case .saved:
            status {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.sembleOrange)
                Text("Saved to Semble")
                    .font(.title3.weight(.semibold))
            }
        case .ready, .saving, .failed:
            form
        }
    }

    /// Centred, padded status content for the non-form phases.
    private func status<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) {
            content()
        }
        .foregroundStyle(Color.sembleText)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            URLPreviewCard(domain: model.domain, preview: model.preview)

            CollectionPickerView(model: model)
                .disabled(model.phase == .saving)

            noteField
                .disabled(model.phase == .saving)

            Spacer(minLength: 0)

            bottomBar
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var noteField: some View {
        TextField("Add a note…", text: $model.note, axis: .vertical)
            .lineLimit(2 ... 4)
            .focused($isNoteFocused)
            .padding(12)
            .background(Color.sembleField)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.sembleBorder, lineWidth: 1)
            }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if case .failed(let message) = model.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                isNoteFocused = false
                Task { await model.save() }
            } label: {
                HStack(spacing: 8) {
                    if model.phase == .saving {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(saveButtonTitle)
                }
            }
            .buttonStyle(.semble)
            .disabled(!model.canSave)
        }
    }

    private var saveButtonTitle: String {
        switch model.phase {
        case .saving:
            return "Adding…"
        case .failed:
            return "Retry"
        default:
            return "Add to Semble"
        }
    }
}

// MARK: - URL preview

/// The link being saved: domain, title, description and an optional thumbnail.
/// Falls back to just the domain while (or if) metadata is unavailable.
struct URLPreviewCard: View {
    let domain: String?
    let preview: URLPreview?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let domain {
                    Text(domain)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.sembleText)
                    .lineLimit(2)
                if let description = preview?.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(Color.sembleMutedText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let imageURL = preview?.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.sembleStone200
                    }
                }
                .frame(width: 45, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sembleSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var title: String {
        if let title = preview?.title, !title.isEmpty {
            return title
        }
        return preview?.url.absoluteString ?? domain ?? "Link"
    }
}
