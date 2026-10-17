import SwiftUI

struct NoticesView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        if !model.notices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Notices", systemImage: "info.circle").font(.caption.bold())
                    Spacer()
                    Button("Clear") { model.notices.removeAll() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.notices.indices, id: \.self) { i in
                            Text(model.notices[i]).font(.caption).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            .padding(10)
            .background(.yellow.opacity(0.12))
        }
    }
}
