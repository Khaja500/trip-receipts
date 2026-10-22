import SwiftUI

/// "Add to trip anyway". One tap: no reason demanded, no password — just room
/// for a note the claim will carry.
struct AddAnywaySheet: View {
    let result: VerificationResult
    /// The trip it will be filed under, when one covers the payment's date.
    let tripName: String?
    var onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("What doesn't match") {
                    ForEach(result.differences, id: \.self) { difference in
                        Label(VerificationText.capitalised(difference), systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.callout)
                    }
                }

                Section {
                    TextField("e.g. Second night paid at the desk", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Note for the claim (optional)")
                } footer: {
                    Text("The expense is filed\(tripName.map { " under \($0)" } ?? "") with a ⚠ badge. "
                         + "What differs, and this note, go into the proof and the export.")
                }
            }
            .navigationTitle("Add anyway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to trip") {
                        onConfirm(note)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
