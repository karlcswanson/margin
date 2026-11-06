import AVFoundation
import Speech

/// Dictation with iPadOS 26's SpeechAnalyzer: on-device, made for long-form
/// speech (no restarts at every pause), with fast provisional words that
/// settle into final text as you go.
@available(iOS 26.0, *)
@MainActor
final class LiveTranscriber {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""

    /// Whether this iPad can transcribe your language this way.
    static func supported() async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) != nil
    }

    func start(level: @escaping @MainActor (Float) -> Void,
               update: @escaping @MainActor (String) -> Void) async throws {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        // The language model downloads once, the first time.
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "Margin", code: 2, userInfo: [NSLocalizedDescriptionKey: "No audio format for transcription."])
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try? await analyzer.prepareToAnalyze(in: format)     // load the model before the first words arrive
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        input = cont

        results = Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    guard let self else { return }
                    self.heard(String(r.text.characters), final: r.isFinal)
                    update(self.text)
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)

        let mic = engine.inputNode.outputFormat(forBus: 0)
        guard mic.sampleRate > 0, mic.channelCount > 0, let converter = AVAudioConverter(from: mic, to: format) else {
            throw NSError(domain: "Margin", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The microphone isn't available. Another app may be using it."])
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: mic,
                                    block: Self.tap(converter: converter, to: format, into: cont, level: level))
        engine.prepare()
        try engine.start()
    }

    var text: String { join(finalized, volatile) }

    private func heard(_ words: String, final: Bool) {
        if final {
            finalized = join(finalized, words)
            volatile = ""
        } else {
            volatile = words
        }
    }

    private func join(_ a: String, _ b: String) -> String {
        let b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty || b.isEmpty { return a + b }
        return a.hasSuffix(" ") || a.hasSuffix("\n") ? a + b : a + " " + b
    }

    /// Stop listening; what was still provisional is finished first.
    func stop() async {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
    }

    // Runs on the audio thread: convert the mic's buffers to what the analyzer wants.
    nonisolated private static func tap(converter: AVAudioConverter, to format: AVAudioFormat,
                                        into cont: AsyncStream<AnalyzerInput>.Continuation,
                                        level: @escaping @MainActor (Float) -> Void) -> AVAudioNodeTapBlock {
        var n = 0
        return { buffer, _ in
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            if let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) {
                var fed = false
                var err: NSError?
                converter.convert(to: out, error: &err) { _, status in
                    if fed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                if err == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
            }
            n += 1
            guard n % 6 == 0, let ch = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += ch[i] * ch[i] }
            let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
            Task { @MainActor in level(rms) }
        }
    }
}
