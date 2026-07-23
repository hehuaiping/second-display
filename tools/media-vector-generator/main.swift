import CapturePipeline
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import CryptoKit
import Darwin
import Foundation
import SecondDisplayCore

private struct VectorMetadata: Codable {
    let name: String
    let path: String
    let codec: String
    let profile: String
    let width: Int
    let height: Int
    let fps: Int
    let frameCount: Int
    let sha256: String
    let bytes: Int
}

@main
private enum MediaVectorGenerator {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            let outputPath: String
            if let index = arguments.firstIndex(of: "--output"), arguments.indices.contains(index + 1) {
                outputPath = arguments[index + 1]
            } else {
                outputPath = "shared/test-vectors/media"
            }
            let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            var metadata: [VectorMetadata] = []
            for (width, height) in [(1280, 800), (1920, 1200)] {
                metadata.append(try await generate(width: width, height: height, outputURL: outputURL))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var manifest = try encoder.encode(metadata)
            manifest.append(0x0a)
            try manifest.write(to: outputURL.appendingPathComponent("media_vectors.json"), options: .atomic)
            print("Generated \(metadata.count) media vectors in \(outputURL.path)")
        } catch {
            FileHandle.standardError.write(Data("Media vector generation failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func generate(width: Int, height: Int, outputURL: URL) async throws -> VectorMetadata {
        let fps = 60
        let frameCount = 30
        let encoder = H264EncoderService()
        try await encoder.configure(
            EncoderSpec(
                width: width, height: height, framesPerSecond: fps, bitrate: 8_000_000, profile: .high)
        )
        var bitstream = Data()
        for index in 0..<frameCount {
            let pixelBuffer = try makePixelBuffer(width: width, height: height, frameIndex: index)
            let pts = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            let frame = CapturedFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                captureTimestampUs: UInt64(index) * 1_000_000 / UInt64(fps),
                callbackTimestampUs: DispatchTime.now().uptimeNanoseconds / 1_000,
                contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                generation: 1
            )
            guard let encoded = try await encoder.encode(frame, forceKeyFrame: index == 0) else {
                throw SessionError(code: .encBackpressure, detail: "Encoder dropped vector frame \(index)")
            }
            bitstream.append(encoded.payload)
        }
        await encoder.invalidate()

        let fileName = "h264_\(width)x\(height)_60.h264"
        try bitstream.write(to: outputURL.appendingPathComponent(fileName), options: .atomic)
        let digest = SHA256.hash(data: bitstream).map { String(format: "%02x", $0) }.joined()
        return VectorMetadata(
            name: "h264-\(width)x\(height)-60",
            path: fileName,
            codec: "h264",
            profile: "high",
            width: width,
            height: height,
            fps: fps,
            frameCount: frameCount,
            sha256: digest,
            bytes: bitstream.count
        )
    }

    private static func makePixelBuffer(width: Int, height: Int, frameIndex: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes =
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw SessionError(code: .encCreateFailed, detail: "CVPixelBufferCreate failed: \(status)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard
            CVPixelBufferGetPlaneCount(buffer) == 2,
            let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
            let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else {
            throw SessionError(code: .encCreateFailed, detail: "NV12 pixel buffer has invalid planes")
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let yRows = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let yPointer = yBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<yRows {
            for column in 0..<width {
                let movingBar = ((column + frameIndex * 24) / max(1, width / 8)) & 7
                yPointer[row * yStride + column] = UInt8(24 + movingBar * 28)
            }
        }
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let uvRows = CVPixelBufferGetHeightOfPlane(buffer, 1)
        memset(uvBase, 128, uvStride * uvRows)
        return buffer
    }
}
