import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            DetailView()
        }
        .alert("Something went wrong",
               isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) {} },
               message: { Text(model.errorMessage ?? "") })
    }
}
