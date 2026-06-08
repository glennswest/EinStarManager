import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var client: ScannerClient
    @State private var commandText = "{\"cmd\":\"start\"}"
    @State private var selected: FrameRecord.ID?

    // Candidate commands to try against the :8081 WebSocket while reverse-
    // engineering the protocol. Wrong commands make the server close the socket.
    private let candidates = [
        "{\"cmd\":\"start\"}",
        "{\"method\":\"getDeviceInfo\",\"id\":1}",
        "{\"type\":\"subscribe\",\"channel\":\"preview\"}",
        "{\"cmd\":\"capture\"}",
        "{\"cmd\":\"export\",\"format\":\"stl\"}",
        "{\"cmd\":\"listFiles\"}"
    ]

    var body: some View {
        HSplitView {
            controlColumn
                .frame(minWidth: 360, maxWidth: 460)
            frameColumn
                .frame(minWidth: 520)
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                HStack(spacing: 6) {
                    Circle().fill(client.connected ? .green : .secondary).frame(width: 9, height: 9)
                    Text(client.status).font(.caption).lineLimit(1)
                }
            }
        }
    }

    // MARK: Left column

    private var controlColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Auto-discover Einstar") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Subnets (e.g. 192.168.8, 192.168.9)", text: $client.scanPrefixes)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                Task { await client.discover() }
                            } label: {
                                if client.discovering {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Scan")
                                }
                            }
                            .disabled(client.discovering)
                        }
                        if !client.discoveryProgress.isEmpty {
                            Text(client.discoveryProgress)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(client.discovered) { dev in
                            HStack(spacing: 6) {
                                Image(systemName: dev.confirmed ? "checkmark.seal.fill" : "questionmark.circle")
                                    .foregroundStyle(dev.confirmed ? .green : .secondary)
                                Text(dev.ip).font(.system(.body, design: .monospaced))
                                Text(dev.confirmed ? "Einstar" : ":8081")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Use") {
                                    client.host = dev.ip
                                    client.wsPort = "8081"; client.httpPort = "8080"
                                }
                                Button("Connect") {
                                    client.host = dev.ip
                                    client.wsPort = "8081"; client.httpPort = "8080"
                                    client.connect()
                                }.disabled(!dev.confirmed)
                            }
                        }
                    }.padding(6)
                }

                GroupBox("Scanner") {
                    VStack(alignment: .leading, spacing: 8) {
                        labeledField("Host", text: $client.host)
                        HStack {
                            labeledField("WS port", text: $client.wsPort)
                            labeledField("HTTP port", text: $client.httpPort)
                        }
                        HStack {
                            Button(client.connected ? "Reconnect" : "Connect") { client.connect() }
                                .keyboardShortcut(.return)
                            Button("Disconnect") { client.disconnect() }
                                .disabled(!client.connected)
                        }
                    }.padding(6)
                }

                GroupBox("WebSocket command (:\(client.wsPort))") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Try", selection: $commandText) {
                            ForEach(candidates, id: \.self) { Text($0).tag($0) }
                        }
                        TextEditor(text: $commandText)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                        HStack {
                            Button("Send text") { client.send(text: commandText) }
                                .disabled(!client.connected)
                            Button("Send as binary") {
                                client.send(binary: Data(commandText.utf8))
                            }.disabled(!client.connected)
                        }
                        Text("A wrong command makes the Rigil close the socket (code 1000). Reconnect and try another.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(6)
                }

                GroupBox("HTTP fetch (:\(client.httpPort))") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("/path", text: $client.httpPath)
                                .textFieldStyle(.roundedBorder)
                            Button("GET") { client.httpGet() }
                        }
                        if !client.httpStatus.isEmpty {
                            Text(client.httpStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        if let body = client.httpBody, !body.isEmpty {
                            Button("Save response…") {
                                save(body, kind: PayloadKind.classify(body), suggested: "response")
                            }
                        }
                    }.padding(6)
                }
            }
            .padding()
        }
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Right column — frame log + detail

    private var frameColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Frames (\(client.frames.count))").font(.headline)
                Spacer()
                Button("Clear") { client.clearFrames() }
            }.padding(8)
            Divider()
            Table(client.frames, selection: $selected) {
                TableColumn("") { f in
                    Image(systemName: f.direction == .incoming ? "arrow.down" : "arrow.up")
                        .foregroundStyle(f.direction == .incoming ? .green : .blue)
                }.width(20)
                TableColumn("Time") { f in Text(f.time, format: .dateTime.hour().minute().second()) }
                    .width(70)
                TableColumn("Kind") { f in Text(f.kind.rawValue) }.width(110)
                TableColumn("Bytes") { f in Text("\(f.size)") }.width(70)
                TableColumn("Preview") { f in
                    Text(f.textPreview).font(.system(.caption, design: .monospaced)).lineLimit(1)
                }
            }
            Divider()
            detailPane.frame(height: 200)
        }
    }

    @ViewBuilder private var detailPane: some View {
        if let id = selected, let f = client.frames.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(f.kind.rawValue) · \(f.size) bytes · \(f.isText ? "text" : "binary")")
                        .font(.headline)
                    Spacer()
                    Button("Save…") { save(f.data, kind: f.kind, suggested: "frame") }
                }
                ScrollView {
                    Text(f.isText ? f.textPreview : f.data.hexPreview(limit: 1024))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(8)
        } else {
            Text("Select a frame to inspect / save").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Save

    private func save(_ data: Data, kind: PayloadKind, suggested: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggested).\(kind.fileExtension)"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }
}
