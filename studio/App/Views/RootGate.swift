import SwiftUI

/// Shows the studio once a videobed checkout is known, else asks for one.
struct RootGate: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let model = store.model {
            MainView()
                .environment(model)
                .id(model.workspace.root)
        } else {
            RootPickerView()
        }
    }
}
