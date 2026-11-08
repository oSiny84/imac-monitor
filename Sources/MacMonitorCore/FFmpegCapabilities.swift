import Foundation

/// What the installed FFmpeg can do for audio, asked once per executable and remembered for
/// the rest of the run. Audio is optional: a build without `libopus` or `aac`, or one that
/// rejects the two-encoder tee command, means the camera runs video-only with the reason in
/// the status, never a failed start. The dry run uses the production input and output shape
/// against `/dev/zero`, so a command that works here works for the camera too.
public struct FFmpegCapabilities: Equatable {
    public let encoders: Set<String>
    /// Nil when audio can be used; otherwise why not, in the owner's language.
    public let audioProblem: String?

    public var supportsAudio: Bool { audioProblem == nil }

    public init(encoders: Set<String>, audioProblem: String?) {
        self.encoders = encoders
        self.audioProblem = audioProblem
    }

    /// `ffmpeg -encoders` prints one encoder per line after a legend, e.g.
    /// ` A....D libopus              libopus Opus (codec opus)`. The name is the second field.
    public static func parseEncoders(_ output: String) -> Set<String> {
        var names = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[0].count == 6,
                  fields[0].first.map({ "VAS".contains($0) }) == true,
                  fields[0] != "------" else { continue }
            names.insert(String(fields[1]))
        }
        return names
    }

    public static func missingAudioEncoders(in encoders: Set<String>) -> [String] {
        ["libopus", "aac"].filter { !encoders.contains($0) }
    }

    /// A 0.2 s encode of black frames and silence through the production command shape: two
    /// raw inputs, VideoToolbox video, Opus for the live stream, AAC for the files, and a tee
    /// that gives each output only its own audio stream.
    public static func audioDryRunArguments() -> [String] {
        [
            "-hide_banner", "-loglevel", "error", "-nostdin",
            "-f", "rawvideo", "-pixel_format", "nv12", "-video_size", "320x240", "-framerate", "15", "-i", "/dev/zero",
            "-f", "s16le", "-ar", "48000", "-ac", "1", "-i", "/dev/zero",
            "-t", "0.2",
            "-map", "0:v:0", "-c:v", "h264_videotoolbox", "-realtime:v", "true", "-allow_sw:v", "1", "-b:v", "300k",
            "-map", "1:a:0", "-c:a:0", "libopus", "-b:a:0", "48k",
            "-map", "1:a:0", "-c:a:1", "aac", "-b:a:1", "64k",
            "-flags", "+global_header",
            "-f", "tee", "[f=null:select='v:0,a:0']-|[f=null:select='v:0,a:1']-"
        ]
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: FFmpegCapabilities] = [:]

    /// Probes once per executable path. Later calls return the remembered answer.
    public static func cached(for executableURL: URL, probe: (URL) -> FFmpegCapabilities = { probe(executableURL: $0) }) -> FFmpegCapabilities {
        cacheLock.lock()
        if let known = cache[executableURL.path] {
            cacheLock.unlock()
            return known
        }
        cacheLock.unlock()
        let result = probe(executableURL)
        cacheLock.lock()
        cache[executableURL.path] = result
        cacheLock.unlock()
        return result
    }

    public static func probe(executableURL: URL, timeout: TimeInterval = 20) -> FFmpegCapabilities {
        guard let listing = run(executableURL, ["-hide_banner", "-encoders"], timeout: timeout) else {
            return FFmpegCapabilities(encoders: [], audioProblem: "FFmpeg 인코더 목록을 읽지 못했습니다")
        }
        let encoders = parseEncoders(listing.output)
        let missing = missingAudioEncoders(in: encoders)
        if !missing.isEmpty {
            return FFmpegCapabilities(encoders: encoders, audioProblem: "FFmpeg에 \(missing.joined(separator: ", ")) 인코더가 없습니다")
        }
        guard let dryRun = run(executableURL, audioDryRunArguments(), timeout: timeout) else {
            return FFmpegCapabilities(encoders: encoders, audioProblem: "FFmpeg 소리 시험 인코딩이 끝나지 않았습니다")
        }
        guard dryRun.status == 0 else {
            let firstLine = dryRun.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "상태 \(dryRun.status)"
            return FFmpegCapabilities(encoders: encoders, audioProblem: "FFmpeg 소리 시험 인코딩 실패: \(firstLine)")
        }
        return FFmpegCapabilities(encoders: encoders, audioProblem: nil)
    }

    private static func run(_ executableURL: URL, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting: a full pipe would otherwise block FFmpeg forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            return nil
        }
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
