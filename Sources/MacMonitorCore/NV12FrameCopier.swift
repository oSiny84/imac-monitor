import CoreVideo
import Darwin
import Foundation

enum NV12FrameCopier {
    static func copy(pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> Data? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return nil
        }

        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        var data = Data(count: width * height * 3 / 2)
        data.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    target.advanced(by: row * width),
                    yBase.advanced(by: row * yStride),
                    width
                )
            }
            let chromaTarget = target.advanced(by: width * height)
            for row in 0..<(height / 2) {
                memcpy(
                    chromaTarget.advanced(by: row * width),
                    uvBase.advanced(by: row * uvStride),
                    width
                )
            }
        }
        return data
    }
}
