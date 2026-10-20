import AppKit

/// Short interface sounds, synthesised at first use so the app ships no audio files.
enum UISound: CaseIterable {
    /// Selecting a folder or worktree, or copying something.
    case tap
    /// Opening GitHub or the editor.
    case open
    /// Deleting a worktree.
    case delete
    /// A rescan the user started has finished.
    case refreshed
    /// Something failed.
    case error

    fileprivate struct Tone {
        let frequency: Double
        let start: Double
        let duration: Double
        let gain: Double
        /// Decay time constant in seconds; smaller is snappier.
        let decay: Double
        /// Strength of the 2nd and 3rd harmonics, for a rounder or buzzier timbre.
        var overtones: (Double, Double) = (0.15, 0.04)
    }

    fileprivate var tones: [Tone] {
        switch self {
        case .tap:
            [Tone(frequency: 1760, start: 0, duration: 0.04, gain: 0.16, decay: 0.008, overtones: (0.25, 0.05))]
        case .open:
            [Tone(frequency: 880, start: 0, duration: 0.09, gain: 0.14, decay: 0.03),
             Tone(frequency: 1319, start: 0.055, duration: 0.11, gain: 0.14, decay: 0.035)]
        case .delete:
            [Tone(frequency: 784, start: 0, duration: 0.09, gain: 0.14, decay: 0.03),
             Tone(frequency: 523, start: 0.06, duration: 0.14, gain: 0.14, decay: 0.045)]
        case .refreshed:
            [Tone(frequency: 1047, start: 0, duration: 0.18, gain: 0.10, decay: 0.06),
             Tone(frequency: 1568, start: 0.07, duration: 0.24, gain: 0.10, decay: 0.08)]
        case .error:
            [Tone(frequency: 233, start: 0, duration: 0.1, gain: 0.16, decay: 0.04, overtones: (0.3, 0.25)),
             Tone(frequency: 220, start: 0.13, duration: 0.12, gain: 0.16, decay: 0.045, overtones: (0.3, 0.25))]
        }
    }

    /// A short filtered-noise sweep layered under the delete sound.
    fileprivate var swoosh: (duration: Double, gain: Double)? {
        self == .delete ? (0.16, 0.05) : nil
    }

    /// Renders the sound as a 16-bit mono WAV.
    func wav(sampleRate: Double = 44_100) -> Data {
        let length = (tones.map { $0.start + $0.duration } + [swoosh?.duration ?? 0]).max() ?? 0
        let count = Int(length * sampleRate) + 1
        var samples = [Double](repeating: 0, count: count)

        for tone in tones {
            let first = Int(tone.start * sampleRate)
            let frames = Int(tone.duration * sampleRate)
            let attack = 0.003 * sampleRate
            for i in 0..<frames where first + i < count {
                let t = Double(i) / sampleRate
                let envelope = min(1, Double(i) / attack) * exp(-t / tone.decay)
                    * min(1, Double(frames - i) / (0.004 * sampleRate)) // fade out, no click at the end
                let phase = 2 * Double.pi * tone.frequency * t
                let wave = sin(phase) + tone.overtones.0 * sin(2 * phase) + tone.overtones.1 * sin(3 * phase)
                samples[first + i] += tone.gain * envelope * wave
            }
        }

        if let swoosh {
            // White noise through a one-pole low-pass whose cutoff falls over time.
            var state = 0.0
            var seed: UInt64 = 0x9E3779B97F4A7C15
            let frames = Int(swoosh.duration * sampleRate)
            for i in 0..<min(frames, count) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Double(Int64(bitPattern: seed >> 11) % 2000) / 1000 - 1
                let progress = Double(i) / Double(frames)
                let alpha = 0.35 * (1 - progress) + 0.02
                state += alpha * (noise - state)
                let envelope = sin(Double.pi * progress)
                samples[i] += swoosh.gain * envelope * state
            }
        }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Double(Int16.max)))
        }
        return data
    }
}

@MainActor
enum Sounds {
    static let enabledKey = "soundsEnabled"
    private static var cache: [UISound: NSSound] = [:]

    /// Off when the user turned sounds off in the app, or turned off
    /// "Play user interface sound effects" in System Settings.
    static var isOn: Bool {
        let app = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        return app && systemAllows
    }

    /// System Settings > Sound > "Play user interface sound effects".
    static var systemAllows: Bool {
        (UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int ?? 1) != 0
    }

    static func play(_ sound: UISound) {
        guard isOn else { return }
        let player = cache[sound] ?? {
            let made = NSSound(data: sound.wav())
            cache[sound] = made
            return made
        }()
        player?.stop()
        player?.play()
    }
}
