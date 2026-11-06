import AVFoundation
import Speech
import SwiftUI

/// Hold-to-talk (or tap to toggle) dictation into a text field, transcribed
/// on-device so client audio never leaves the iPad.
/// Pinned voice notes (the audio itself, with Pencil pointing) may come later.
struct VoiceButton: View {
    @Binding var text: String
    var size: CGFloat = 22
    @State private var dictation = Dictation()

    var body: some View {
        Button {
            dictation.isRecording ? dictation.stop() : dictation.start(appendingTo: text) { text = $0 }
        } label: {
            VoiceGlyph(recording: dictation.isRecording, level: dictation.level, size: size)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
        .alert("Dictation unavailable", isPresented: Binding(
            get: { dictation.error != nil }, set: { if !$0 { dictation.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(dictation.error ?? "") }
    }
}

/// The one look for "speak": a waveform that turns red and pulses with your
/// voice while it listens (the same in the reply box, notes and markups).
struct VoiceGlyph: View {
    let recording: Bool
    var level: Float = 0
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            if recording {
                Circle().fill(Color.red.opacity(0.18))
                    .frame(width: size * (1.25 + CGFloat(level) * 0.8), height: size * (1.25 + CGFloat(level) * 0.8))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
            Image(systemName: recording ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: size))
                .foregroundStyle(recording ? Color.red : Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: recording)
        }
        .frame(width: size * 1.6, height: size * 1.6)
    }
}

@MainActor
@Observable
final class Dictation {
    var isRecording = false
    var error: String?
    /// Microphone level, 0…1, so you can see it's hearing you.
    var level: Float = 0

    /// Only one dictation holds the microphone; starting another stops it.
    private static weak var active: Dictation?

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var taskStarted = Date()
    @ObservationIgnored private var lastAudio: Date?
    @ObservationIgnored private var onDevice = true
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)

    func start(appendingTo base: String, update: @escaping (String) -> Void) {
        if let other = Self.active, other !== self { other.stop() }
        Self.active = self
        Task {
            guard await Self.authorize() else {
                error = "Allow Speech Recognition and Microphone access in Settings → Margin."
                return
            }
            if #available(iOS 26.0, *), await LiveTranscriber.supported() {
                await startModern(base: base, update: update)
                return
            }
            guard let recognizer, recognizer.isAvailable else {
                error = "Speech recognition isn't available right now."
                return
            }
            do {
                try begin(recognizer: recognizer, base: base, update: update)
            } catch {
                self.error = error.localizedDescription
                stop()
            }
        }
    }

    /// iPadOS 26 and later: SpeechAnalyzer (see LiveTranscriber). Kept as
    /// `AnyObject` since a stored property can't be limited to an OS version.
    @ObservationIgnored private var modern: AnyObject?

    @available(iOS 26.0, *)
    private func startModern(base: String, update: @escaping (String) -> Void) async {
        let lead = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? base : base + " "
        let t = LiveTranscriber()
        modern = t
        do {
            try activateSession()
            isRecording = true
            try await t.start(level: { [weak self] rms in self?.level = min(1, rms * 12) },
                              update: { update(lead + $0) })
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    /// Speech recognition finishes a stretch of speech when you pause (and
    /// recent iOS then starts a fresh transcript), so keep each finished
    /// stretch and start listening again until you tap stop.
    @ObservationIgnored private var committed = ""
    @ObservationIgnored private var current = ""
    @ObservationIgnored private var base = ""
    @ObservationIgnored private var update: ((String) -> Void)?
    @ObservationIgnored private var recognizerInUse: SFSpeechRecognizer?

    private func begin(recognizer: SFSpeechRecognizer, base: String, update: @escaping (String) -> Void) throws {
        self.base = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? base : base + " "
        self.update = update
        committed = ""
        current = ""
        recognizerInUse = recognizer
        restarts = 0
        lastAudio = nil
        try activateSession()
        isRecording = true
        observe()
        try listen()
        watchForSilence()
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// One recognition task; called again after each pause while recording.
    private func listen() throws {
        guard let recognizer = recognizerInUse else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if onDevice, recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        request = req

        let input = engine.inputNode
        var format = input.outputFormat(forBus: 0)
        if format.sampleRate == 0 || format.channelCount == 0 {
            // The mic isn't ready (the audio route just changed): a fresh engine usually is.
            engine.stop()
            engine = AVAudioEngine()
            try activateSession()
            format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "Margin", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "The microphone isn't available. Another app may be using it."])
            }
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format,
                                    block: Self.tapBlock(req) { [weak self] rms in
            self?.level = min(1, rms * 12)
            self?.lastAudio = Date()
        })
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        taskStarted = Date()
        task = recognizer.recognitionTask(with: req, resultHandler: Self.resultHandler { [weak self] text, done, failed in
            self?.heard(text, done: done, failed: failed, from: req)
        })
    }

    /// No audio arriving: restart the engine (once or twice) before giving up.
    private func watchForSilence() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.isRecording else { return }
            if let last = self.lastAudio, Date().timeIntervalSince(last) < 1.5 {
                self.watchForSilence()
                return
            }
            if self.restarts >= 2 {
                self.error = "Not hearing the microphone. Another app may be using it; try again."
                self.stop()
                return
            }
            self.restarts += 1
            self.restartEngine()
            self.watchForSilence()
        }
    }

    private func restartEngine() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine = AVAudioEngine()
        request?.endAudio()
        task?.cancel()
        commit()
        task = nil
        request = nil
        do {
            try activateSession()
            try listen()
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    /// A call, Siri or new headphones stop the audio; pick up again after.
    private func observe() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let ended = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            if ended { Task { @MainActor in self?.restartEngine() } }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
                Task { @MainActor in self?.restartEngine() }
            }
        })
    }

    private func heard(_ text: String?, done: Bool, failed: Bool, from req: SFSpeechAudioBufferRecognitionRequest) {
        // Late results from an earlier stretch were already kept.
        guard req === request || request == nil else { return }
        if let text, !text.isEmpty {
            // A transcript that suddenly restarts (not a revision of what we had) means
            // the last stretch was finalized: keep it.
            if !current.isEmpty, text.count < current.count / 2, !current.hasPrefix(text.prefix(4)) {
                commit()
            }
            current = text
        }
        update?(base + joined)
        guard done else { return }
        // On-device recognition that fails straight away (model not ready) → use Apple's servers.
        if failed, onDevice, current.isEmpty, Date().timeIntervalSince(taskStarted) < 1.5 { onDevice = false }
        commit()
        update?(base + joined)
        if isRecording {
            task = nil
            request = nil
            do { try listen() } catch { self.error = error.localizedDescription; stop() }
        }
    }

    private var joined: String {
        [committed, current].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func commit() {
        guard !current.isEmpty else { return }
        committed = committed.isEmpty ? current : committed + " " + current
        current = ""
    }

    // Audio and speech callbacks arrive on background queues. Building them in a
    // nonisolated context keeps Swift from treating them as main-actor closures.
    nonisolated private static func tapBlock(_ req: SFSpeechAudioBufferRecognitionRequest,
                                             level: @escaping @MainActor (Float) -> Void) -> AVAudioNodeTapBlock {
        var n = 0
        return { [weak req] buffer, _ in
            req?.append(buffer)
            n += 1
            guard n % 4 == 0, let ch = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += ch[i] * ch[i] }
            let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
            Task { @MainActor in level(rms) }
        }
    }

    nonisolated private static func resultHandler(
        _ onMain: @escaping @MainActor (String?, Bool, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, err in
            let text = result?.bestTranscription.formattedString
            let done = err != nil || result?.isFinal == true
            Task { @MainActor in onMain(text, done, err != nil) }
        }
    }

    func stop() {
        isRecording = false          // first, so a final result doesn't start listening again
        level = 0
        if #available(iOS 26.0, *), let t = modern as? LiveTranscriber {
            modern = nil
            if Self.active === self { Self.active = nil }
            Task {
                await t.stop()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            return
        }
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if Self.active === self { Self.active = nil }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }
}
