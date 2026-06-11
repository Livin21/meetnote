import AppKit
import MeetnoteCore
import ServiceManagement
import SwiftUI

@main
struct MeetNoteApp: App {
    @StateObject private var controller = RecordingController()

    var body: some Scene {
        MenuBarExtra {
            PanelView(controller: controller)
        } label: {
            Image(systemName: controller.symbolName)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class RecordingController: ObservableObject {
    enum Phase: Equatable { case idle, recording, summarizing }

    @Published var phase: Phase = .idle
    @Published var startedAt: Date?
    @Published var segmentCount = 0
    @Published var lastLine = ""
    @Published var statusMessage = ""
    @Published var lastNotesURL: URL?
    @Published var lastTranscriptURL: URL?

    private var recorder: Recorder?
    private var topic = "meeting"
    private var participants: [String] = []

    var symbolName: String {
        switch phase {
        case .idle: return "text.bubble"
        case .recording: return "record.circle.fill"
        case .summarizing: return "hourglass"
        }
    }

    func start(topicText: String, withText: String = "") {
        guard phase == .idle else { return }
        topic = slugify(topicText.split(separator: " ").map(String.init))
        participants = withText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        segmentCount = 0
        lastLine = ""
        statusMessage = "Starting capture…"
        phase = .recording
        let recorder = Recorder()
        recorder.collector.live = false
        recorder.collector.onAdd = { [weak self] segment in
            DispatchQueue.main.async {
                self?.segmentCount += 1
                self?.lastLine = "\(segment.label): \(segment.text)"
            }
        }
        self.recorder = recorder
        Task {
            do {
                try await recorder.start(locale: Locale(identifier: "en_IN"))
                self.startedAt = recorder.startedAt
                self.statusMessage = "Transcribing on-device."
            } catch {
                self.recorder = nil
                self.phase = .idle
                self.statusMessage = "Couldn't start: \(error)"
            }
        }
    }

    func stop() {
        guard phase == .recording, let recorder else { return }
        phase = .summarizing
        statusMessage = "Finalizing transcription…"
        let topic = self.topic
        let startedAt = self.startedAt ?? Date()
        self.startedAt = nil
        Task {
            let segments = await recorder.stop()
            self.recorder = nil
            guard !segments.isEmpty else {
                self.phase = .idle
                self.statusMessage = "Stopped — no speech transcribed, nothing saved."
                return
            }
            do {
                let store = Store()
                try store.prepare()
                let transcriptURL = try store.writeTranscript(topic: topic, startedAt: startedAt, segments: segments, participants: participants)
                self.lastTranscriptURL = transcriptURL
                self.lastNotesURL = nil
                await self.summarize(transcriptURL: transcriptURL, topic: topic, startedAt: startedAt)
            } catch {
                self.phase = .idle
                self.statusMessage = "Failed to save transcript: \(error)"
            }
        }
    }

    func summarizeLastTranscript() {
        guard phase == .idle, let url = lastTranscriptURL else { return }
        phase = .summarizing
        Task {
            await summarize(transcriptURL: url, topic: topicFromTranscriptName(url), startedAt: Date())
        }
    }

    private func summarize(transcriptURL: URL, topic: String, startedAt: Date) async {
        statusMessage = "Summarizing with the local model…"
        let preferred = Config.preferredModel
        do {
            let (notesURL, model) = try await Task.detached(priority: .userInitiated) { () -> (URL, String) in
                let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
                let store = Store()
                try store.prepare()
                let lmstudio = LMStudio()
                let model = try lmstudio.pickModel(preferred: preferred)
                let body = try Summarizer.notes(transcript: transcript, lmstudio: lmstudio, model: model)
                return (try store.writeNotes(topic: topic, startedAt: startedAt, body: body, transcriptURL: transcriptURL, model: model), model)
            }.value
            lastNotesURL = notesURL
            statusMessage = "Notes saved (\(model))."
            phase = .idle
            NSWorkspace.shared.open(notesURL)
        } catch {
            phase = .idle
            statusMessage = "Transcript is safe; summary failed (is LM Studio's server running? `lms server start`): \(error)"
        }
    }
}

struct PanelView: View {
    @ObservedObject var controller: RecordingController
    @State private var topicText = ""
    @State private var withText = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var tapCheck: String?
    @AppStorage("modelID", store: Config.shared) private var modelID = ""
    @AppStorage("ownerName", store: Config.shared) private var ownerName = NSFullUserName()
    @AppStorage("knownNames", store: Config.shared) private var knownNames = ""
    @State private var availableModels: [String] = []
    @State private var modelsNote: String?
    @State private var outputDirDisplay = Config.outputDir.path

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch controller.phase {
            case .idle: idle
            case .recording: recording
            case .summarizing: summarizing
            }
            if !controller.statusMessage.isEmpty {
                Text(controller.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MeetNote").font(.headline)
            TextField("Topic (e.g. weekly sync)", text: $topicText)
                .textFieldStyle(.roundedBorder)
            TextField("With (e.g. Asha, Ben) — optional", text: $withText)
                .textFieldStyle(.roundedBorder)
            Button {
                controller.start(topicText: topicText, withText: withText)
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            if let notes = controller.lastNotesURL {
                Button("Open last notes") { NSWorkspace.shared.open(notes) }
                    .buttonStyle(.link)
            } else if controller.lastTranscriptURL != nil {
                Button("Summarize last transcript") { controller.summarizeLastTranscript() }
                    .buttonStyle(.link)
            }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                Text("Recording").font(.headline)
                Spacer()
                if let start = controller.startedAt {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .font(.headline.monospacedDigit())
                }
            }
            Text("\(controller.segmentCount) segments")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !controller.lastLine.isEmpty {
                Text(controller.lastLine)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            Button {
                controller.stop()
            } label: {
                Label("Stop & make notes", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var summarizing: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…").font(.headline)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Model", selection: $modelID) {
                Text("Auto").tag("")
                ForEach(pickerModels, id: \.self) { id in
                    Text(id).tag(id)
                }
            }
            .font(.caption)
            .onAppear { refreshModels() }
            if let modelsNote {
                Text(modelsNote).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("My name").font(.caption)
                TextField("Used as \"Me\" in notes", text: $ownerName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            HStack {
                Text("Teammates").font(.caption)
                TextField("Comma-separated; fixes misheard names", text: $knownNames)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            HStack {
                Text(abbreviatedPath(outputDirDisplay))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…") { chooseOutputFolder() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Button("Open meetings folder") {
                NSWorkspace.shared.open(Store().meetingsDir)
            }
            .buttonStyle(.link)
            Button("Test system audio") {
                tapCheck = "…"
                Task {
                    do {
                        let peak = try await SetupCheck.tapTestPeak()
                        tapCheck = peak > 0.001
                            ? "✓ tap hears audio (peak \(String(format: "%.2f", peak)))"
                            : "✗ silence — grant System Audio Recording to MeetNote"
                        if peak <= 0.001 { NSWorkspace.shared.open(SetupCheck.settingsPaneURL) }
                    } catch {
                        tapCheck = "✗ \(error)"
                    }
                }
            }
            .buttonStyle(.link)
            if let tapCheck {
                Text(tapCheck).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Start at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            HStack {
                Spacer()
                Button("Quit MeetNote") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    /// Keep the stored choice selectable even when LM Studio is offline or
    /// the model was removed — otherwise the Picker silently resets.
    private var pickerModels: [String] {
        if modelID.isEmpty || availableModels.contains(modelID) {
            return availableModels
        }
        return availableModels + [modelID]
    }

    private func abbreviatedPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Config.outputDir
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            Config.shared.set(url.path, forKey: "outputDir")
            outputDirDisplay = url.path
        }
    }

    private func refreshModels() {
        Task.detached {
            let result: ([String], String?)
            do {
                let models = try LMStudio().listModels().filter { !$0.lowercased().contains("embed") }
                result = (models, models.isEmpty ? "No chat models in LM Studio." : nil)
            } catch {
                result = ([], "LM Studio offline — model list unavailable.")
            }
            await MainActor.run {
                availableModels = result.0
                modelsNote = result.1
            }
        }
    }
}
