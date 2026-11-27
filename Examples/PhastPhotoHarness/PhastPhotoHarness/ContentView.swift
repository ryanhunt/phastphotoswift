import PhastPhotoProtocol
import PhastPhotoScanner
import SwiftUI

struct ContentView: View {
    @Environment(HarnessModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Build", value: HarnessModel.buildConfiguration)
                    Text(HarnessModel.deviceDescription).font(.footnote).foregroundStyle(.secondary)
                }

                discoverySection

                Section("Scanner") {
                    HStack {
                        Button("Info") { model.readInfo() }
                        Spacer()
                        Button("Status") { model.readStatus() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                    if let running = model.queryRunning { ProgressView("Reading \(running)…") }
                    if let status = model.statusText { LabeledContent("Status", value: status) }
                    ForEach(model.infoFields) { field in
                        LabeledContent(field.key, value: field.value).font(.footnote)
                    }
                }

                scanSection

                Section {
                    HStack {
                        Button("Process sample") { model.processSample() }
                        Spacer()
                        Button("Same sample again") { model.processSample(again: true) }
                    }
                    .buttonStyle(.bordered)
                    Button("Time Vision warm-up") { model.warmUpVision() }
                } header: {
                    Text("Without a scanner")
                } footer: {
                    Text("Runs the pipeline on a synthetic print and back at the resolution above. Repeating the "
                        + "same sample should be flagged as a duplicate. The simulator reads the sample's back, but its "
                        + "face and scene results are fake: check rotation, and real backs, on a device.")
                }
                .disabled(model.isBusy)

                Section("Results (\(model.records.count))") {
                    if model.records.isEmpty { Text("No prints yet").foregroundStyle(.secondary) }
                    ForEach(model.records) { record in
                        NavigationLink(value: record.id) { PrintRow(record: record) }
                    }
                }

                Section {
                    NavigationLink("Log (\(model.logLines.count) lines)") { LogView() }
                    ForEach(model.logLines.suffix(4).reversed()) { line in
                        Text(line.text).font(.caption.monospaced()).lineLimit(3)
                    }
                    Button("Delete all files", role: .destructive) { confirmDelete = true }
                        .disabled(model.isBusy)
                } header: {
                    Text("Log and files")
                } footer: {
                    Text("Raw scans, results, timings.csv and the log are in the app's Documents folder: open "
                        + "them in Files, or copy them to a Mac from Finder's Files tab for the device.")
                }
            }
            .navigationTitle("PhastPhoto Harness")
            .navigationDestination(for: UUID.self) { id in
                if let record = model.records.first(where: { $0.id == id }) { PrintDetailView(record: record) }
            }
            .confirmationDialog("Delete every raw scan, result and log in Documents?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { model.deleteAllFiles() }
            }
        }
    }

    @ViewBuilder private var discoverySection: some View {
        @Bindable var model = model
        Section {
            HStack {
                if model.discovery == .browsing {
                    Button("Stop browsing") { model.stopBrowsing() }
                    Spacer()
                    ProgressView()
                } else {
                    Button("Find scanners") { model.startBrowsing() }
                }
            }
            Toggle("List every _scanner._tcp service", isOn: $model.allModels)
                .disabled(model.discovery == .browsing)
            discoveryStatus
            ForEach(model.scanners, id: \.self) { scanner in
                Button {
                    model.selected = scanner
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(scanner.name)
                            Text("model \(scanner.model ?? "?"), available \(scanner.isAvailable.map(String.init) ?? "?")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.selected == scanner { Image(systemName: "checkmark") }
                    }
                }
                .tint(.primary)
            }
            TextField("Address (optional, skips Bonjour)", text: $model.manualHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        } header: {
            Text("Discovery")
        } footer: {
            Text("The first search shows the local network prompt. Refusing it, or turning access off in "
                + "Settings, should show \"local network access denied\".")
        }
    }

    @ViewBuilder private var discoveryStatus: some View {
        switch model.discovery {
        case .idle: EmptyView()
        case .browsing:
            Text(model.scanners.isEmpty ? "Browsing… nothing found yet" : "Browsing…").foregroundStyle(.secondary)
        case .stopped:
            Text(model.scanners.isEmpty ? "Stopped; nothing found" : "Stopped").foregroundStyle(.secondary)
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Label("Local network access denied", systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                Text("DiscoveryError.localNetworkDenied. Allow it in Settings > Privacy & Security > Local Network.")
                    .font(.footnote)
                Button("Open Settings") { model.openSettings() }
            }
        case .waiting(let reason):
            Label("Waiting: \(reason)", systemImage: "hourglass").foregroundStyle(.orange)
        case .failed(let reason):
            Label("Failed: \(reason)", systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var scanSection: some View {
        @Bindable var model = model
        Section {
            Picker("Resolution", selection: $model.dpi) {
                ForEach(HarnessModel.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
            }
            Picker("Sides", selection: $model.sideMode) {
                ForEach(SideMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            TextField("Album (metadata, optional)", text: $model.album)
            Toggle("Enhanced copy", isOn: $model.enhance)
            Toggle("Auto-rotate", isOn: $model.autoRotate)
            if model.isScanning {
                Button("Stop after this print") { model.stopAfterCurrentPrint() }
                Button("Cancel now (may jam)", role: .destructive) { model.cancelScan() }
            } else {
                Button("Scan the loaded stack") { model.startScan() }
                    .disabled(model.isBusy)
            }
            if let progress = model.scanProgress {
                HStack {
                    ProgressView()
                    Text(progress).font(.footnote)
                }
            }
        } header: {
            Text("Scan")
        } footer: {
            Text("ffscan's defaults (deskew, double-feed level 1). Load prints face up: side B is the picture. "
                + "The screen stays on while scanning and processing.")
        }
        .disabled(model.queryRunning != nil)
    }
}

struct PrintRow: View {
    let record: PrintRecord

    var body: some View {
        HStack(spacing: 12) {
            if let url = record.sides.last(where: { $0.url != nil })?.url {
                Thumbnail(url: url, maxPixelSize: 160)
                    .frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.label).font(.headline)
                Text(record.summary).font(.footnote)
                if !record.backText.isEmpty {
                    Text("back: " + record.backText.replacingOccurrences(of: "\n", with: " / "))
                        .font(.footnote).foregroundStyle(.blue)
                }
                Text("\(record.run) · \(record.timing)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct LogView: View {
    @Environment(HarnessModel.self) private var model

    var body: some View {
        List(model.logLines.reversed()) { line in
            VStack(alignment: .leading) {
                Text(line.time.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                Text(line.text).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle("Log")
        .toolbar {
            ShareLink(item: Storage.logFile)
        }
    }
}
