import AVFoundation
import Foundation

/// Tiny square-wave synth so alerts are distinct from every other macOS chime,
/// and so the app ships no audio assets. Cues are chiptune-short by design.
final class SoundEngine {
    static let shared = SoundEngine()

    enum Cue {
        case start, done, attention, allow, deny

        /// (frequency Hz, duration seconds) steps.
        var notes: [(Double, Double)] {
            switch self {
            case .start:     return [(660, 0.055), (880, 0.075)]
            case .done:      return [(880, 0.055), (1174, 0.055), (1568, 0.11)]
            case .attention: return [(1046, 0.07), (784, 0.07), (1046, 0.12)]
            case .allow:     return [(1318, 0.05), (1760, 0.09)]
            case .deny:      return [(392, 0.06), (294, 0.12)]
            }
        }
        var gain: Float {
            switch self {
            case .attention: return 0.16
            default: return 0.10
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var started = false
    private let queue = DispatchQueue(label: "app.perch.audio")

    private init() {}

    func play(_ cue: Cue) {
        guard Prefs.sounds else { return }
        queue.async { [self] in
            guard ensureRunning(), let buffer = render(cue) else { return }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            if !player.isPlaying { player.play() }
        }
    }

    private func ensureRunning() -> Bool {
        if started { return engine.isRunning || (try? engine.start()) != nil }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        do { try engine.start() } catch { NSLog("Perch: audio start failed \(error)"); return false }
        started = true
        return true
    }

    private func render(_ cue: Cue) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let total = cue.notes.reduce(0.0) { $0 + $1.1 }
        let frames = AVAudioFrameCount(total * sr)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let out = buffer.floatChannelData?[0] else { return nil }

        var index = 0
        for (freq, duration) in cue.notes {
            let count = Int(duration * sr)
            let period = sr / freq
            for i in 0..<count where index < Int(frames) {
                // Square wave with a short attack/decay so it doesn't click.
                let phase = Double(i).truncatingRemainder(dividingBy: period) / period
                let square: Float = phase < 0.5 ? 1 : -1
                let t = Double(i) / Double(max(count - 1, 1))
                let envelope = Float(min(1, t / 0.08) * min(1, (1 - t) / 0.25))
                out[index] = square * envelope * cue.gain
                index += 1
            }
        }
        while index < Int(frames) { out[index] = 0; index += 1 }
        return buffer
    }
}
