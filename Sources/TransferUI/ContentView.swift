import SwiftUI

public struct ContentView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            Text("Hello, world")
                .font(.title2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Transfer")
        }
    }
}
