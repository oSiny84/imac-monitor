import Foundation

/// Only requested live profiles are transcoded. The base live path and recording
/// tee are untouched, so a viewer's selection never restarts capture/recording.
struct RemoteStreamProfiles {
    static let ffmpegEnvironmentKey = "MACMONITOR_FFMPEG_EXECUTABLE"

    static func environment(ffmpegURL: URL, inheriting environment: [String: String]) throws -> [String: String] {
        var result = environment
        result[ffmpegEnvironmentKey] = try validatedExecutablePath(ffmpegURL)
        return result
    }

    static func paths(ffmpegURL: URL) throws -> String {
        _ = try validatedExecutablePath(ffmpegURL)
        // MediaMTX v1.21.1 parses command tokens, then expands environment variables
        // once in each token. Embedding even a shell-quoted path here corrupts any
        // literal '$' in it. Keep the path entirely in the process environment:
        // the replacement is neither tokenized nor recursively expanded.
        let executable = "${\(ffmpegEnvironmentKey)}"
        var result = "  live:\n    source: publisher\n"
        for (name, width, height, fps, bitrate) in [("live-balanced", 854, 480, 10, 700), ("live-low", 640, 360, 8, 300)] {
            let arguments = [executable, "-hide_banner", "-loglevel", "warning", "-nostdin",
                "-threads", "1", "-filter_threads", "1", "-rtsp_transport", "tcp", "-i", "rtsp://127.0.0.1:8554/live",
                "-map", "0:v:0", "-an", "-vf", "fps=\(fps),scale=\(width):\(height)",
                "-c:v", "h264_videotoolbox", "-realtime", "true", "-allow_sw", "1", "-profile:v", "baseline",
                "-b:v", "\(bitrate)k", "-maxrate", "\(bitrate * 5 / 4)k", "-bufsize", "\(bitrate * 2)k",
                "-g", "\(fps * 2)", "-bf", "0", "-f", "rtsp", "-rtsp_transport", "tcp", "rtsp://127.0.0.1:8554/\(name)"]
            let command = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            // JSON strings are valid YAML double-quoted scalars, including escaped paths.
            let quoted = String(data: try JSONEncoder().encode(command), encoding: .utf8)!
            result += "  \(name):\n    source: publisher\n    runOnDemand: \(quoted)\n    runOnDemandRestart: true\n    runOnDemandStartTimeout: 15s\n    runOnDemandCloseAfter: 5s\n"
        }
        return result
    }

    private static func validatedExecutablePath(_ url: URL) throws -> String {
        let path = url.path
        guard !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else {
            throw AppConfigurationError.invalid("FFmpeg executable path")
        }
        return path
    }
}
