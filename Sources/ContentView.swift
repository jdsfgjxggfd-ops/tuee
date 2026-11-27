import SwiftUI

struct ContentView: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 20) {
            Text("App iOS đầu tiên của tôi")
                .font(.title2.bold())

            Text("Số lần bấm: \(count)")
                .font(.largeTitle)

            Button("Bấm tăng +1") {
                count += 1
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
