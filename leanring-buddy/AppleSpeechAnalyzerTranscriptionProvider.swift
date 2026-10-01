//
//  AppleSpeechAnalyzerTranscriptionProvider.swift
//  leanring-buddy
//
//  On-device transcription provider backed by Apple's SpeechAnalyzer +
//  SpeechTranscriber (macOS 26+). Faster and more accurate than the older
//  SFSpeechRecognizer path, and audio never leaves the Mac. The language
//  model is a system-shared asset that is downloaded on first use.
//

// SpeechAnalyzer only exists in the macOS 26 SDK (Xcode 26 / Swift 6.2).
// The compiler check keeps older Xcode versions building; they simply
// fall back to AppleSpeechTranscriptionProvider.
#if compiler(>=6.2)

import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class AppleSpeechAnalyzerTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Apple SpeechAnalyzer (on-device)"
    // SpeechTranscriber still requires the user's speech recognition
    // authorization, even though it runs entirely on-device.
    let requiresSpeechRecognitionPermission = true
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let transcriptionLocale = try await Self.resolveSupportedTranscriptionLocale()

        // .volatileResults streams partial text while the user is still talking,
        // which keeps the live transcript in the overlay feeling responsive.
        let speechTranscriber = SpeechTranscriber(
            locale: transcriptionLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        try await Self.ensureLanguageModelAssetIsInstalled(
            for: speechTranscriber,
            transcriptionLocale: transcriptionLocale
        )

        let speechAnalyzer = SpeechAnalyzer(modules: [speechTranscriber])
        let analyzerPreferredAudioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [speechTranscriber]
        )

        let transcriptionSession = AppleSpeechAnalyzerTranscriptionSession(
            speechTranscriber: speechTranscriber,
            speechAnalyzer: speechAnalyzer,
            analyzerPreferredAudioFormat: analyzerPreferredAudioFormat,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        try await transcriptionSession.startAnalyzing()
        return transcriptionSession
    }

    /// Picks the user's current locale when an on-device model exists for it,
    /// otherwise falls back to US English.
    private static func resolveSupportedTranscriptionLocale() async throws -> Locale {
        let preferredLocales = [
            Locale.autoupdatingCurrent,
            Locale(identifier: "en-US")
        ]

        for preferredLocale in preferredLocales {
            if let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale) {
                return supportedLocale
            }
        }

        throw AppleSpeechTranscriptionProviderError(
            message: "on-device transcription doesn't support your language yet."
        )
    }

    /// The on-device language model is a system asset shared across apps.
    /// On first use it has to be downloaded, so the very first push-to-talk
    /// on a fresh Mac waits for that download (and fails if offline).
    private static func ensureLanguageModelAssetIsInstalled(
        for speechTranscriber: SpeechTranscriber,
        transcriptionLocale: Locale
    ) async throws {
        let transcriptionLocaleIdentifier = transcriptionLocale.identifier(.bcp47)

        let installedLocaleIdentifiers = await Set(
            SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        )
        if installedLocaleIdentifiers.contains(transcriptionLocaleIdentifier) {
            return
        }

        print("🎙️ SpeechAnalyzer: downloading on-device language model for \(transcriptionLocaleIdentifier)")

        if let assetInstallationRequest = try await AssetInventory.assetInstallationRequest(
            supporting: [speechTranscriber]
        ) {
            try await assetInstallationRequest.downloadAndInstall()
        }

        let installedLocaleIdentifiersAfterDownload = await Set(
            SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        )
        guard installedLocaleIdentifiersAfterDownload.contains(transcriptionLocaleIdentifier) else {
            throw AppleSpeechTranscriptionProviderError(
                message: "couldn't download the on-device speech model. check your internet connection and try again."
            )
        }
    }
}

@available(macOS 26.0, *)
private final class AppleSpeechAnalyzerTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.8

    private let speechTranscriber: SpeechTranscriber
    private let speechAnalyzer: SpeechAnalyzer
    private let analyzerPreferredAudioFormat: AVAudioFormat?
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let analyzerInputStream: AsyncStream<AnalyzerInput>
    private let analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation

    /// Only touched from the audio tap thread (appendAudioBuffer).
    private let microphoneAudioConverter = AppleSpeechAnalyzerAudioConverter()

    private var resultsListeningTask: Task<Void, Never>?

    /// Guards the request/deliver/cancel flags, which are touched from the
    /// audio tap thread, the main actor, and the results task.
    private let sessionStateLock = NSLock()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var hasBeenCancelled = false

    init(
        speechTranscriber: SpeechTranscriber,
        speechAnalyzer: SpeechAnalyzer,
        analyzerPreferredAudioFormat: AVAudioFormat?,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.speechTranscriber = speechTranscriber
        self.speechAnalyzer = speechAnalyzer
        self.analyzerPreferredAudioFormat = analyzerPreferredAudioFormat
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let (analyzerInputStream, analyzerInputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzerInputStream = analyzerInputStream
        self.analyzerInputContinuation = analyzerInputContinuation
    }

    func startAnalyzing() async throws {
        startListeningForResults()
        try await speechAnalyzer.start(inputSequence: analyzerInputStream)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        let shouldAcceptAudio = sessionStateLock.withLock {
            !hasRequestedFinalTranscript && !hasBeenCancelled
        }
        guard shouldAcceptAudio else { return }

        // The mic format (often 48kHz float) rarely matches what the analyzer
        // wants, and feeding a mismatched format silently produces no text.
        let analyzerReadyBuffer: AVAudioPCMBuffer?
        if let analyzerPreferredAudioFormat {
            analyzerReadyBuffer = microphoneAudioConverter.convert(audioBuffer, to: analyzerPreferredAudioFormat)
        } else {
            analyzerReadyBuffer = microphoneAudioConverter.copy(audioBuffer)
        }

        guard let analyzerReadyBuffer else { return }
        analyzerInputContinuation.yield(AnalyzerInput(buffer: analyzerReadyBuffer))
    }

    func requestFinalTranscript() {
        let isFirstFinalTranscriptRequest = sessionStateLock.withLock { () -> Bool in
            guard !hasRequestedFinalTranscript else { return false }
            hasRequestedFinalTranscript = true
            return true
        }
        guard isFirstFinalTranscriptRequest else { return }

        analyzerInputContinuation.finish()

        // Flushes buffered audio and makes the analyzer emit its final results.
        // When it completes, the results stream ends and the listening task
        // delivers the final transcript.
        Task { [speechAnalyzer] in
            try? await speechAnalyzer.finalizeAndFinishThroughEndOfInput()
        }
    }

    func cancel() {
        sessionStateLock.withLock {
            hasBeenCancelled = true
        }
        analyzerInputContinuation.finish()
        resultsListeningTask?.cancel()
        resultsListeningTask = nil

        Task { [speechAnalyzer] in
            await speechAnalyzer.cancelAndFinishNow()
        }
    }

    private func startListeningForResults() {
        resultsListeningTask = Task { [weak self, speechTranscriber] in
            // Finalized text is appended permanently; volatile text is the
            // in-progress tail that gets rewritten as recognition improves.
            var finalizedTranscriptText = ""
            var volatileTranscriptText = ""

            do {
                for try await transcriptionResult in speechTranscriber.results {
                    let resultText = String(transcriptionResult.text.characters)

                    if transcriptionResult.isFinal {
                        finalizedTranscriptText += resultText
                        volatileTranscriptText = ""
                    } else {
                        volatileTranscriptText = resultText
                    }

                    self?.onTranscriptUpdate(finalizedTranscriptText + volatileTranscriptText)
                }
            } catch {
                guard let self else { return }
                let wasCancelled = self.sessionStateLock.withLock { self.hasBeenCancelled }
                let combinedTranscriptText = finalizedTranscriptText + volatileTranscriptText

                if wasCancelled {
                    return
                }

                // If the user already let go and we have text, prefer delivering
                // what we heard over surfacing an error.
                if combinedTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.onError(error)
                } else {
                    self.deliverFinalTranscriptIfNeeded(combinedTranscriptText)
                }
                return
            }

            // The results stream ends once the analyzer has finalized all input.
            self?.deliverFinalTranscriptIfNeeded(finalizedTranscriptText + volatileTranscriptText)
        }
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        let shouldDeliverFinalTranscript = sessionStateLock.withLock { () -> Bool in
            guard !hasDeliveredFinalTranscript && !hasBeenCancelled else { return false }
            hasDeliveredFinalTranscript = true
            return true
        }
        guard shouldDeliverFinalTranscript else { return }
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        analyzerInputContinuation.finish()
        resultsListeningTask?.cancel()
    }
}

/// Converts live microphone buffers into the format SpeechAnalyzer asked for.
/// Always returns a buffer the analyzer owns, because the audio tap reuses its
/// buffer memory after the callback returns while the analyzer reads ours later.
/// Single-threaded by contract: only call from the audio tap thread.
private final class AppleSpeechAnalyzerAudioConverter {
    private var audioConverter: AVAudioConverter?

    func convert(_ inputBuffer: AVAudioPCMBuffer, to targetAudioFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if inputBuffer.format == targetAudioFormat {
            return copy(inputBuffer)
        }

        let needsNewConverter = audioConverter == nil
            || audioConverter?.inputFormat != inputBuffer.format
            || audioConverter?.outputFormat != targetAudioFormat

        if needsNewConverter {
            audioConverter = AVAudioConverter(from: inputBuffer.format, to: targetAudioFormat)
            // No priming: we're streaming continuous PCM, and priming adds latency.
            audioConverter?.primeMethod = .none
        }

        guard let audioConverter else { return nil }

        let sampleRateRatio = targetAudioFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            (Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetAudioFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var hasProvidedSourceBuffer = false
        var conversionError: NSError?

        let conversionStatus = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if hasProvidedSourceBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }

            hasProvidedSourceBuffer = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionStatus != .error, outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }

    func copy(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        inputBuffer.copy() as? AVAudioPCMBuffer
    }
}

#endif
