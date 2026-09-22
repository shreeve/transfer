import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            Text("Hello, world")
                .font(.title2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Transfer")
        }
    }
}
