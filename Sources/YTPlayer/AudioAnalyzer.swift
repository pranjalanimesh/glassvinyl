import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Listens to the Mac's audio output through a Core Audio process tap and turns it into
/// spectrum bands, a waveform, a loudness level and beat ticks for the visualizers.
///
/// macOS asks once for "System Audio Recording" permission. A tap started before that is
/// answered stays silent, so the analyzer keeps restarting until it hears something (up to a minute).
final class AudioAnalyzer: @unchecked Sendable {
    static let bandCount = 48
    static let waveCount = 96

    struct Frame {
        var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)  // 0...1, low to high
        var wave = [Float](repeating: 0, count: AudioAnalyzer.waveCount)   // -1...1
        var level: Float = 0                                               // 0...1
        var beats = 0                                                      // increments on each bass hit
    }

    /// Latest analysis. Read from the UI at display rate; written from the audio queue.
    var frame: Frame {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    private(set) var isRunning = false

    private let lock = NSLock()
    private var latest = Frame()

    private let audioQueue = DispatchQueue(label: "ytplayer.audio")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sampleRate: Double = 48_000

    // Silence watchdog (audioQueue).
    private var silentFrames = 0
    private var heardAudio = false
    private var retries = 0

    // Analysis state (audioQueue).
    private let fftSize = 2048
    private let log2n = vDSP_Length(11)
    private lazy var fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    private lazy var window: [Float] = {
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        return w
    }()
    private var samples: [Float] = []
    private var smoothed = Frame()
    private var ceilingDb: Float = -30   // loudest recent band; the scale follows it
    private var bassAverage: Float = 0
    private var framesSinceBeat = 0

    func start() {
        guard !isRunning else { return }
        do {
            try createTap()
            isRunning = true
        } catch {
            NSLog("YTPlayer visualizer: \(error)")
            stop()
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
        lock.lock(); latest = Frame(); lock.unlock()
    }

    // MARK: - Core Audio setup

    private struct CoreAudioError: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (\(status))" }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw CoreAudioError(step: step, status: status) }
    }

    private func createTap() throws {
        // A stereo mix of everything the Mac plays, minus nothing.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create tap")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "Read tap format")
        sampleRate = format.mSampleRate
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw CoreAudioError(step: "Tap format is not float", status: -1)
        }

        // The tap is read through a private aggregate device built on the current output.
        let outputUID = try defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "YTPlayer Visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Create aggregate device")

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, audioQueue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }, "Create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "Start device")
    }

    private func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
                  "Read default output")

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "Read output UID")
        guard let uid else { throw CoreAudioError(step: "Output has no UID", status: -1) }
        return uid.takeRetainedValue() as String
    }

    // MARK: - Analysis (audioQueue)

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        // Interleaved: one buffer with N channels. Non-interleaved: first buffer is the left channel.
        let channels = Int(max(buffer.mNumberChannels, 1))
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        let pcm = data.assumingMemoryBound(to: Float.self)

        var peak: Float = 0
        vDSP_maxmgv(pcm, 1, &peak, vDSP_Length(frames * channels))
        watchForSilence(peak: peak, frames: frames)

        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += pcm[i * channels + c] }
            samples.append(sum / Float(channels))
        }
        if samples.count > fftSize { samples.removeFirst(samples.count - fftSize) }
        guard samples.count == fftSize else { return }
        analyze()
    }

    /// Restarts the tap every 4 s while it has produced only digital silence since launch.
    private func watchForSilence(peak: Float, frames: Int) {
        if peak > 0 { heardAudio = true; return }
        guard !heardAudio, retries < 15 else { return }
        silentFrames += frames
        if silentFrames > Int(sampleRate * 4) {
            silentFrames = 0
            retries += 1
            DispatchQueue.main.async { [weak self] in
                self?.stop()
                self?.start()
            }
        }
    }

    private func analyze() {
        let half = fftSize / 2
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // Log-spaced bands from 40 Hz to 16 kHz in dB, with a gentle lift for the highs.
        let binHz = sampleRate / Double(fftSize)
        let low = 40.0, high = min(16_000, sampleRate / 2)
        var db = [Float](repeating: -180, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let f0 = low * pow(high / low, Double(b) / Double(Self.bandCount))
            let f1 = low * pow(high / low, Double(b + 1) / Double(Self.bandCount))
            let lo = max(1, Int(f0 / binHz))
            let hi = min(half - 1, max(lo + 1, Int(f1 / binHz)))
            var sum: Float = 0
            for i in lo..<hi { sum += magnitudes[i] }
            let amplitude = sum / Float(hi - lo) / Float(fftSize)
            db[b] = 20 * log10(max(amplitude, 1e-9)) + 1.5 * Float(log2((f0 + f1) / 2 / 1000))
        }

        // Auto-gain: the top of the scale follows the loudest recent band, so quiet and loud
        // songs both use the full height. A power curve adds contrast between bands.
        ceilingDb = max(db.max() ?? -60, ceilingDb - 0.08, -60)
        let range: Float = 36
        for b in 0..<Self.bandCount {
            let value = pow(min(max((db[b] - (ceilingDb - range)) / range, 0), 1), 1.4)
            let old = smoothed.bands[b]
            // Quick rise, slower fall.
            smoothed.bands[b] = value > old ? old + (value - old) * 0.65 : old * 0.9
        }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(fftSize))
        let level = min(max((20 * log10(max(rms, 1e-9)) + 45) / 40, 0), 1)
        smoothed.level = max(level, smoothed.level * 0.92)

        // Beat: bass jumps well above its recent average.
        let bass = smoothed.bands.prefix(6).reduce(0, +) / 6
        framesSinceBeat += 1
        if bass > bassAverage * 1.3, bass > 0.35, framesSinceBeat > 20 {
            smoothed.beats &+= 1
            framesSinceBeat = 0
        }
        bassAverage = bassAverage * 0.97 + bass * 0.03

        let step = fftSize / Self.waveCount
        for i in 0..<Self.waveCount {
            smoothed.wave[i] = min(max(samples[i * step] * 3, -1), 1)
        }

        lock.lock(); latest = smoothed; lock.unlock()
    }
}
