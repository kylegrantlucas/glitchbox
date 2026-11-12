import SwiftUI

/// Simple mode's stack: one card per effect, in render order. Reordering is an Advanced edit.
struct SimpleEffectList: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.studioSheetRequest) private var request
    @State private var showPicker = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.stack) { item in
                    SimpleEffectCard(item: item)
                }
            }
            .padding(12)
        }
        .overlay {
            if model.stack.isEmpty {
                ContentUnavailableView("No Effects Yet", systemImage: "sparkles",
                                       description: Text("Pick a look, or add an effect."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                // The widest labels that fit: full on a wide column, shorter in the Mac and iPad columns and on iPhone.
                ViewThatFits(in: .horizontal) {
                    HStack {
                        addEffect
                        Spacer(minLength: 12)
                        Button("Save as Look…") { saveAsLook() }
                            .disabled(model.stack.isEmpty)
                        Button("Open in Advanced", systemImage: "slider.horizontal.3") { model.openAdvanced() }
                    }
                    HStack {
                        addEffect
                        Spacer(minLength: 12)
                        Button("Save as Look…") { saveAsLook() }
                            .disabled(model.stack.isEmpty)
                        Button("Advanced", systemImage: "slider.horizontal.3") { model.openAdvanced() }
                    }
                    HStack {
                        addEffect
                        Spacer(minLength: 12)
                        Button("Save as Look", systemImage: "square.and.arrow.down") { saveAsLook() }
                            .labelStyle(.iconOnly)
                            .disabled(model.stack.isEmpty)
                        Button("Advanced", systemImage: "slider.horizontal.3") { model.openAdvanced() }
                    }
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
            .background(.bar)
        }
        .sheet(isPresented: $showPicker) {
            EffectPicker()
        }
    }

    private var addEffect: some View {
        Button("Add Effect", systemImage: "plus") { showPicker = true }
    }

    private func saveAsLook() {
        request { model.showSaveChain = true }
    }
}
