import AVFoundation
import Foundation

enum AudioLevelMeter {
    private static let noiseFloorDecibels = -50.0
    private static let speechCeilingDecibels = -10.0

    static func normalizedLevel(in buffer: AVAudioPCMBuffer) -> Double {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        var squareSum = 0.0
        var sampleCount = 0

        if let channels = buffer.floatChannelData {
            for channelIndex in 0..<channelCount {
                let channel = channels[channelIndex]
                for frameIndex in 0..<frameCount {
                    let sample = Double(channel[frameIndex])
                    guard sample.isFinite else { continue }
                    squareSum += sample * sample
                    sampleCount += 1
                }
            }
        } else if let channels = buffer.int16ChannelData {
            for channelIndex in 0..<channelCount {
                let channel = channels[channelIndex]
                for frameIndex in 0..<frameCount {
                    let sample = Double(channel[frameIndex]) / 32_768.0
                    squareSum += sample * sample
                    sampleCount += 1
                }
            }
        } else {
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(squareSum / Double(sampleCount))
        guard rms.isFinite, rms > 0 else { return 0 }

        let decibels = 20 * log10(rms)
        let range = speechCeilingDecibels - noiseFloorDecibels
        let normalized = (decibels - noiseFloorDecibels) / range
        return min(max(normalized, 0), 1)
    }
}

struct AudioLevelThrottle {
    private let intervalNanoseconds: UInt64
    private var lastPublicationNanoseconds: UInt64?

    init(maxUpdatesPerSecond: UInt64) {
        precondition(maxUpdatesPerSecond > 0)
        intervalNanoseconds = 1_000_000_000 / maxUpdatesPerSecond
    }

    mutating func shouldPublish(atNanoseconds now: UInt64) -> Bool {
        guard let last = lastPublicationNanoseconds else {
            lastPublicationNanoseconds = now
            return true
        }
        guard now < last || now - last >= intervalNanoseconds else {
            return false
        }
        lastPublicationNanoseconds = now
        return true
    }

    mutating func reset() {
        lastPublicationNanoseconds = nil
    }
}
