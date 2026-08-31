import Accelerate
import AVFoundation
import Foundation

final class AudioSpectrumAnalyzer {
    static let bandCount = 7

    private static let fftSize = 2_048
    private static let bands: [(lower: Double, upper: Double)] = [
        (80, 160),
        (160, 315),
        (315, 630),
        (630, 1_250),
        (1_250, 2_500),
        (2_500, 5_000),
        (5_000, 8_000),
    ]
    private static let noiseFloorDecibels = -65.0
    private static let speechCeilingDecibels = -20.0

    private let transform: vDSP.DiscreteFourierTransform<Float>?
    private let window: [Float]
    private let windowPowerGain: Double
    private var ring = [Float](repeating: 0, count: fftSize)
    private var writeIndex = 0
    private var retainedSampleCount = 0
    private var orderedSamples = [Float](repeating: 0, count: fftSize)
    private var windowedSamples = [Float](repeating: 0, count: fftSize)
    private let zeroImaginary = [Float](repeating: 0, count: fftSize)
    private var outputReal = [Float](repeating: 0, count: fftSize)
    private var outputImaginary = [Float](repeating: 0, count: fftSize)
    private var sampleRate = 0.0

    init() {
        transform = try? vDSP.DiscreteFourierTransform(
            count: Self.fftSize,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Float.self
        )
        let generatedWindow = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: Self.fftSize,
            isHalfWindow: false
        )
        window = generatedWindow
        windowPowerGain = Double(vDSP.sumOfSquares(generatedWindow)) / Double(Self.fftSize)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            reset()
            return
        }

        if sampleRate != buffer.format.sampleRate {
            reset()
            sampleRate = buffer.format.sampleRate
        }

        if let channels = buffer.floatChannelData {
            append(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                let value = channels[channel][frame]
                return value.isFinite ? value : 0
            }
        } else if let channels = buffer.int16ChannelData {
            append(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                Float(channels[channel][frame]) / 32_768
            }
        } else {
            reset()
        }
    }

    func levels() -> [Double] {
        guard retainedSampleCount == Self.fftSize,
              sampleRate > 0,
              let transform
        else {
            return [Double](repeating: 0, count: Self.bandCount)
        }

        for offset in 0..<Self.fftSize {
            let sourceIndex = (writeIndex + offset) % Self.fftSize
            orderedSamples[offset] = ring[sourceIndex]
        }
        vDSP.multiply(orderedSamples, window, result: &windowedSamples)
        transform.transform(
            inputReal: windowedSamples,
            inputImaginary: zeroImaginary,
            outputReal: &outputReal,
            outputImaginary: &outputImaginary
        )

        let nyquist = sampleRate / 2
        let binWidth = sampleRate / Double(Self.fftSize)
        let scale = Double(Self.fftSize * Self.fftSize) * windowPowerGain

        return Self.bands.map { band in
            guard band.lower < nyquist else { return 0 }
            let upper = min(band.upper, nyquist)
            var power = 0.0
            for bin in 1..<(Self.fftSize / 2) {
                let frequency = Double(bin) * binWidth
                guard frequency >= band.lower, frequency < upper else { continue }
                let real = Double(outputReal[bin])
                let imaginary = Double(outputImaginary[bin])
                power += 2 * (real * real + imaginary * imaginary)
            }
            guard power > 0, scale > 0 else { return 0 }
            let rms = sqrt(power / scale)
            guard rms.isFinite, rms > 0 else { return 0 }
            let decibels = 20 * log10(rms)
            let normalized = (decibels - Self.noiseFloorDecibels)
                / (Self.speechCeilingDecibels - Self.noiseFloorDecibels)
            return min(max(normalized, 0), 1)
        }
    }

    func reset() {
        for index in ring.indices {
            ring[index] = 0
        }
        writeIndex = 0
        retainedSampleCount = 0
        sampleRate = 0
    }

    private func append(
        frameCount: Int,
        channelCount: Int,
        sampleAt: (_ channel: Int, _ frame: Int) -> Float
    ) {
        for frame in 0..<frameCount {
            var mono: Float = 0
            for channel in 0..<channelCount {
                mono += sampleAt(channel, frame)
            }
            ring[writeIndex] = mono / Float(channelCount)
            writeIndex = (writeIndex + 1) % Self.fftSize
            retainedSampleCount = min(retainedSampleCount + 1, Self.fftSize)
        }
    }
}
