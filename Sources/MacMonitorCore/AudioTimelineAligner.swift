import Foundation

/// Keeps the raw PCM written to FFmpeg aligned with the raw video that `ConstantRateFramePacer`
/// writes. Neither raw input carries timestamps, so FFmpeg places audio by sample count and
/// video by frame count: sample `n` plays at `n / sampleRate` and frame `k` shows at `k / fps`.
/// The two stay in sync only while the audio written so far covers exactly the time the emitted
/// frames cover.
///
/// Three things break that on their own. The camera often delivers its first frame later than
/// the microphone, so audio captured before the first video frame belongs to time the stream
/// never contains. The microphone's clock drifts from the pacer's wall clock by tens of parts
/// per million, which is seconds over a day. And a stalled device leaves a hole. This aligner
/// drops audio before the first frame, pads silence when audio falls behind the video and trims
/// when it runs ahead, with a tolerance wider than one video frame plus one audio chunk so that
/// ordinary jitter between the two arrival rhythms is never corrected.
public struct AudioTimelineAligner {
    public struct Plan: Equatable {
        /// Zero samples to write before the chunk.
        public let padSamples: Int
        /// Samples of the chunk to write, taken from its end so the output stays current.
        public let keepSamples: Int

        public init(padSamples: Int, keepSamples: Int) {
            self.padSamples = padSamples
            self.keepSamples = keepSamples
        }
    }

    public let sampleRate: Int
    public let framesPerSecond: Int
    public let toleranceSamples: Int
    /// Samples delivered to FFmpeg so far, including silence.
    public private(set) var samplesWritten: Int64 = 0
    public private(set) var paddedSamples: Int64 = 0
    public private(set) var trimmedSamples: Int64 = 0
    public private(set) var droppedSamples: Int64 = 0

    public init(sampleRate: Int = 48_000, framesPerSecond: Int = 15, toleranceSeconds: Double = 0.15) {
        self.sampleRate = max(sampleRate, 1)
        self.framesPerSecond = max(framesPerSecond, 1)
        toleranceSamples = max(Int(Double(self.sampleRate) * toleranceSeconds), 1)
    }

    /// The samples the emitted video covers.
    public func targetSamples(videoFramesEmitted frames: Int64) -> Int64 {
        frames * Int64(sampleRate) / Int64(framesPerSecond)
    }

    /// Decides what to write for a chunk of `count` samples that just arrived while the pacer
    /// has emitted `frames` video frames.
    public mutating func plan(incomingSamples count: Int, videoFramesEmitted frames: Int64) -> Plan {
        guard count > 0 else { return Plan(padSamples: 0, keepSamples: 0) }
        guard frames > 0 else {
            // No video yet: this audio belongs to time the encoded stream will never contain.
            trimmedSamples += Int64(count)
            return Plan(padSamples: 0, keepSamples: 0)
        }
        let target = targetSamples(videoFramesEmitted: frames)
        let afterWrite = samplesWritten + Int64(count)
        if afterWrite > target + Int64(toleranceSamples) {
            // Ahead: keep only the newest samples that bring the stream to the target.
            let keep = max(0, min(Int64(count), target - samplesWritten))
            trimmedSamples += Int64(count) - keep
            samplesWritten += keep
            return Plan(padSamples: 0, keepSamples: Int(keep))
        }
        var pad: Int64 = 0
        if target - afterWrite > Int64(toleranceSamples) {
            // Behind: fill the hole with silence so what follows lands at its real time.
            pad = target - afterWrite
            paddedSamples += pad
        }
        samplesWritten += pad + Int64(count)
        return Plan(padSamples: Int(pad), keepSamples: count)
    }

    /// Samples a plan asked for that the pipe refused (it was full). They count as missing, so
    /// the next chunk pads the hole instead of leaving audio permanently behind the video.
    public mutating func noteUnwritten(samples: Int) {
        guard samples > 0 else { return }
        samplesWritten -= Int64(samples)
        droppedSamples += Int64(samples)
    }

    public mutating func reset() {
        samplesWritten = 0
        paddedSamples = 0
        trimmedSamples = 0
        droppedSamples = 0
    }
}
