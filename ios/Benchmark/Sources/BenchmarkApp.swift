import SwiftUI

@main
struct BenchmarkApp: App {
    var body: some Scene {
        WindowGroup {
            BenchmarkView()
        }
    }
}

struct BenchmarkView: View {
    @State private var lines: [String] = []
    @State private var running = false
    @State private var device = BenchmarkRunner.deviceInfo()

    private var files: [URL] { BenchmarkRunner.inputFiles() }

    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    Text("\(device.machine), \(device.system)")
                    Text("Memory \(Int(device.physicalMemoryMB)) MB, app limit about \(Int(device.limitEstimateMB)) MB")
                }
                Section("Files") {
                    ForEach(files, id: \.self) { Text($0.lastPathComponent) }
                    Text("Add DNG or CR2 files to this app's folder in Files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Results") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.footnote, design: .monospaced))
                    }
                }
            }
            .navigationTitle("CKD Benchmark")
            .toolbar {
                Button(running ? "Running…" : "Run") { start() }
                    .disabled(running)
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--run-benchmark") { start() }
        }
    }

    private func start() {
        running = true
        lines = []
        UIApplication.shared.isIdleTimerDisabled = true
        let modes: [BenchmarkMode] = ProcessInfo.processInfo.arguments.contains("--lean-only") ? [.lean] : [.lean, .qdaq]
        Thread.detachNewThread {
            let runner = BenchmarkRunner { line in
                print(line)
                fflush(stdout)
                let shown = line.replacingOccurrences(of: "CKDBENCH ", with: "")
                DispatchQueue.main.async { lines.append(shown) }
            }
            runner.run(modes: modes)
            DispatchQueue.main.async {
                running = false
                device = BenchmarkRunner.deviceInfo()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}
