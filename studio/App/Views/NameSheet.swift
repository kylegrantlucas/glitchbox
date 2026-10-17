import SwiftUI

/// Asks for a name, optionally confirming replacement of an existing item.
struct NameSheet: View {
    let title: String
    let actionTitle: String
    var existsMessage = ""
    var exists: ((String) -> Bool)?
    let commit: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var confirmReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .confirmationDialog(existsMessage, isPresented: $confirmReplace) {
            Button("Replace", role: .destructive, action: save)
        }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let exists, exists(trimmed) { confirmReplace = true } else { save() }
    }

    private func save() {
        do {
            try commit(name.trimmingCharacters(in: .whitespaces))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
