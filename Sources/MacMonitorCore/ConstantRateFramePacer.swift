import Foundation

/// Turns the camera's variable arrival rate into the constant frame rate that the FFmpeg
/// `rawvideo` input is configured with.
///
/// A raw pipe carries no timestamps, so FFmpeg places every frame it reads exactly `1/fps`
/// apart. Writing one frame per captured frame therefore makes encoded content shorter than the
/// wall-clock time it covers whenever the camera runs below its nominal rate or a frame is
/// dropped under load. The error accumulates: recordings play back fast, each segment file
/// spans more wall-clock time than its nominal duration — which is what the retention policy
/// assumes when it picks pre-roll and post-roll segments — and the live stream falls
/// progressively further behind real time.
///
/// Asking this pacer how many frames are due keeps emitted content aligned with elapsed time.
/// A late frame is repeated instead of leaving a hole in the timeline, and the count is always
/// derived from the clock rather than from how many frames the camera happened to deliver, so
/// the error cannot accumulate.
struct ConstantRateFramePacer {
    /// Backlog beyond which the timeline is resynchronised instead of being filled in.
    ///
    /// A stall longer than this produced no frames at all, so repeating hundreds of copies of
    /// one stale frame would cost far more than accepting the discontinuity. Resynchronising
    /// leaves a one-off gap rather than the continuous drift this type exists to remove.
    static let defaultMaximumBacklogSeconds: Double = 2

    let framesPerSecond: Double
    let maximumBacklogSeconds: Double

    private var baseline: TimeInterval?
    private var framesEmitted: Int64 = 0
    private(set) var resynchronisationCount = 0

    init(framesPerSecond: Int, maximumBacklogSeconds: Double = Self.defaultMaximumBacklogSeconds) {
        self.framesPerSecond = Double(max(framesPerSecond, 1))
        self.maximumBacklogSeconds = max(maximumBacklogSeconds, 1 / Double(max(framesPerSecond, 1)))
    }

    /// How many copies of the newest frame to write so that emitted content covers the time
    /// elapsed since the first frame. Returns 0 when the next frame is not due yet.
    mutating func framesDue(at uptime: TimeInterval) -> Int {
        guard let baseline else {
            self.baseline = uptime
            framesEmitted = 1
            return 1
        }

        let due = Int64(((uptime - baseline) * framesPerSecond).rounded(.down)) + 1
        var deficit = due - framesEmitted
        guard deficit > 0 else { return 0 }

        let maximumBacklog = max(Int64((maximumBacklogSeconds * framesPerSecond).rounded(.down)), 1)
        if deficit > maximumBacklog {
            resynchronisationCount += 1
            framesEmitted = due - 1
            deficit = 1
        }
        framesEmitted += deficit
        return Int(deficit)
    }

    /// Number of frames handed out so far. Content duration is `framesEmitted / framesPerSecond`.
    var emittedFrameCount: Int64 { framesEmitted }

    mutating func reset() {
        baseline = nil
        framesEmitted = 0
        resynchronisationCount = 0
    }
}
