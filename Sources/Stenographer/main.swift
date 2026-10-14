import AppKit
import AVFoundation
import CoreAudio
import FluidAudio
import Speech
import os

let log = Logger(subsystem: "com.tsangiotis.stenographer", category: "audio")

// ponytail: Greek only; add a language menu when English meetings need it
let meetingLocale = Locale(identifier: "el_GR")

struct Line { let start: Double; let who: String; let text: String }

/// Tells voices apart on one channel (LS-EEND .dihard3, up to 4 speakers), so "Them" becomes "Them 1", "Them 2"…
final class Speakers {
    private let diarizer: LSEENDDiarizer
    // The model runs here, never on the real-time audio thread.
    private let queue = DispatchQueue(label: "com.tsangiotis.stenographer.speakers")
    private var numbers: [Int: Int] = [:]

    init() async throws { diarizer = try await LSEENDDiarizer(variant: .dihard3) }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        let samples = (0..<Int(buffer.frameLength)).map { data[$0 * stride] }
        let rate = buffer.format.sampleRate
        queue.async { [diarizer] in
            do { _ = try diarizer.process(samples: samples, sourceSampleRate: rate) }
            catch { log.error("Diarization failed: \(error, privacy: .public)") }
        }
    }

    /// Number of the speaker talking most in `start...end` seconds, numbered by first appearance.
    // ponytail: labels a line when it's final, using tentative segments too; relabel at stop if labels drift
    func speaker(from start: Double, to end: Double) -> Int? {
        queue.sync {
            let best = diarizer.timeline.speakers.values.map { s in
                (s.index, (s.finalizedSegments + s.tentativeSegments).reduce(0.0) { sum, seg in
                    sum + max(0, min(end, Double(seg.endTime)) - max(start, Double(seg.startTime)))
                })
            }.max { $0.1 < $1.1 }
            guard let best, best.1 > 0 else { return nil }
            if numbers[best.0] == nil { numbers[best.0] = numbers.count + 1 }
            return numbers[best.0]
        }
    }

    func finish() {
        queue.sync { _ = try? diarizer.finalizeSession() }
    }
}

/// One audio source → one on-device transcriber.
final class Channel {
    let who: String
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let results: Task<Void, Error>
    private let speakers: Speakers?
    private var converter: AVAudioConverter?
    private var frames = 0, peak: Float = 0

    init(who: String, speakers: Speakers? = nil, onLine: @escaping (Line) -> Void) async throws {
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: meetingLocale) ?? meetingLocale
        let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                               reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        self.who = who
        self.speakers = speakers
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])!
        analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = continuation
        results = Task {
            for try await r in transcriber.results where r.isFinal {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let n = speakers?.speaker(from: r.range.start.seconds, to: r.range.end.seconds)
                onLine(Line(start: r.range.start.seconds, who: n.map { "\(who) \($0)" } ?? who, text: text))
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Called on the audio thread; converts to the analyzer's format and queues it.
    func feed(_ buffer: AVAudioPCMBuffer) {
        // Logs input level every ~5 s, so silent capture (missing permission) shows in Console.
        if let samples = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) }
        }
        frames += Int(buffer.frameLength)
        if Double(frames) > buffer.format.sampleRate * 5 {
            log.notice("\(self.who, privacy: .public) \(buffer.format, privacy: .public) peak=\(self.peak, privacy: .public)")
            frames = 0
            peak = 0
        }
        speakers?.feed(buffer)
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: format)
            // ponytail: first channel only; voice-processed mic arrives as 9 channels with the voice on 0,
            // and the left channel of system audio is enough for speech
            converter?.channelMap = [0]
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        converter.convert(to: out, error: nil) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    func finish() async {
        // Diarize the tail first, so the transcriber's last lines still get a speaker.
        speakers?.finish()
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        do { try await results.value } catch { log.error("\(self.who, privacy: .public) results failed: \(error, privacy: .public)") }
    }
}

struct CoreAudioError: Error { let status: OSStatus }
func check(_ status: OSStatus) throws { if status != noErr { throw CoreAudioError(status: status) } }

/// Everything the Mac plays (Teams, Zoom, browser) via a Core Audio process tap.
final class SystemAudio {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.isPrivate = true
        try check(AudioHardwareCreateProcessTap(tap, &tapID))

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd))
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CoreAudioError(status: -1) }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Stenographer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID))
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, inputData, _, _, _ in
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) {
                onBuffer(buffer)
            }
        })
        try check(AudioDeviceStart(deviceID, procID))
    }

    func stop() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        AudioHardwareDestroyAggregateDevice(deviceID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}

struct AppleScriptError: LocalizedError { let errorDescription: String? }

/// Runs AppleScript on the main thread (NSAppleScript isn't thread-safe) and returns its string result.
@discardableResult
func appleScript(_ source: String) throws -> String? {
    let run = {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { throw AppleScriptError(errorDescription: error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed") }
        return result?.stringValue
    }
    return try Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
}

func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

/// An AppleScript string literal, so transcript text can't break out of the script.
func quoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

final class Recording {
    private let title = Date().formatted(date: .long, time: .shortened)
    private var noteID: String?
    private let lock = NSLock()
    private var lines: [Line] = []
    private let engine = AVAudioEngine()
    private let system = SystemAudio()
    private var channels: [Channel] = []

    func start() async throws {
        let clock = ContinuousClock.now
        noteID = try appleScript("""
            tell application "Notes"
                if not (exists folder "Stenographer") then make new folder with properties {name:"Stenographer"}
                return id of (make new note at folder "Stenographer" with properties {body:\(quoted("<h1>\(escapeHTML(title))</h1>"))})
            end tell
            """)
        let me = try await Channel(who: "Me", onLine: add)
        // ponytail: only the far side is diarized; "Me" is already one person
        let them = try await Channel(who: "Them", speakers: try await Speakers(), onLine: add)
        channels = [me, them]

        let mic = engine.inputNode
        // Echo cancellation, so the other side playing through speakers isn't transcribed as "Me".
        try? mic.setVoiceProcessingEnabled(true)
        mic.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        mic.installTap(onBus: 0, bufferSize: 4096, format: mic.outputFormat(forBus: 0)) { buffer, _ in me.feed(buffer) }
        try engine.start()
        try system.start { them.feed($0) }
        log.notice("Recording started after \(ContinuousClock.now - clock, privacy: .public)")
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        system.stop()
        for channel in channels { await channel.finish() }
        save()
        if let noteID { _ = try? appleScript("tell application \"Notes\" to show note id \(quoted(noteID))") }
    }

    private func add(_ line: Line) {
        lock.withLock { lines.append(line) }
        save()
    }

    /// Rewrites the whole note on every line, so a crash loses at most the line in flight.
    private func save() {
        guard let noteID else { return }
        let body = lock.withLock { lines.sorted { $0.start < $1.start } }.map { line in
            let t = Int(line.start)
            return String(format: "<div><b>[%02d:%02d:%02d] %@:</b> %@</div>", t / 3600, t / 60 % 60, t % 60, line.who, escapeHTML(line.text))
        }
        let html = "<h1>\(escapeHTML(title))</h1>" + body.joined()
        do {
            try appleScript("tell application \"Notes\" to set body of note id \(quoted(noteID)) to \(quoted(html))")
        } catch {
            log.error("Saving note failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let toggle = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
    private var recording: Recording?
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.addItem(toggle)
        menu.addItem(NSMenuItem(title: "Open Notes", action: #selector(openNotes), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: "q"))
        item.menu = menu
        render()
        // `--record <seconds>`: record unattended, for testing and automation.
        if let i = CommandLine.arguments.firstIndex(of: "--record"), let seconds = Double(CommandLine.arguments[i + 1]) {
            toggleRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.toggleRecording() }
        }
    }

    private func render() {
        let symbol = busy ? "hourglass" : recording == nil ? "waveform" : "stop.circle.fill"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Stenographer")
        toggle.title = recording == nil ? "Start Recording" : "Stop Recording"
        toggle.isEnabled = !busy
    }

    @objc private func toggleRecording() {
        busy = true
        render()
        Task {
            if let recording {
                await recording.stop()
                self.recording = nil
            } else {
                let next = Recording()
                do {
                    try await next.start()
                    recording = next
                } catch {
                    await next.stop()
                    NSApp.activate()
                    NSAlert(error: error).runModal()
                }
            }
            busy = false
            render()
        }
    }

    @objc private func openNotes() {
        _ = try? appleScript("tell application \"Notes\" to activate")
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
