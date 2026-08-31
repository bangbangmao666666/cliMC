import AVFoundation
import XCTest
@testable import CodexVoiceHotkey

final class AudioSpectrumAnalyzerTests: XCTestCase {
    private let sampleRate = 16_000.0
    private let frameCount = 2_048

    func testSilenceProducesSevenZeros() throws {
        let analyzer = AudioSpectrumAnalyzer()
        analyzer.append(try makeBuffer(channels: [[Float](repeating: 0, count: frameCount)]))

        XCTAssertEqual(analyzer.levels(), [Double](repeating: 0, count: 7))
    }

    func testEachTonePrimarilyActivatesItsLowToHighBand() throws {
        let frequencies = [125.0, 234.375, 468.75, 937.5, 1_875.0, 3_750.0, 6_500.0]

        for (expectedBand, frequency) in frequencies.enumerated() {
            let analyzer = AudioSpectrumAnalyzer()
            analyzer.append(try makeBuffer(channels: [sine(frequency: frequency, amplitude: 0.2)]))
            let levels = analyzer.levels()

            XCTAssertEqual(levels.count, 7)
            XCTAssertEqual(levels.enumerated().max(by: { $0.element < $1.element })?.offset, expectedBand)
            XCTAssertGreaterThan(levels[expectedBand], 0.5)
        }
    }

    func testMixedTonesActivateIndependentBands() throws {
        let low = sine(frequency: 234.375, amplitude: 0.15)
        let high = sine(frequency: 3_750, amplitude: 0.15)
        let mixed = zip(low, high).map { pair in pair.0 + pair.1 }
        let analyzer = AudioSpectrumAnalyzer()

        analyzer.append(try makeBuffer(channels: [mixed]))
        let levels = analyzer.levels()

        XCTAssertGreaterThan(levels[1], 0.4)
        XCTAssertGreaterThan(levels[5], 0.4)
        XCTAssertLessThan(levels[3], levels[1])
        XCTAssertLessThan(levels[3], levels[5])
    }

    func testFrequenciesOutsideNominalRangeAreIgnored() throws {
        let analyzer = AudioSpectrumAnalyzer()
        analyzer.append(try makeBuffer(
            sampleRate: 48_000,
            channels: [
                zip(
                    sine(frequency: 46.875, amplitude: 0.3, sampleRate: 48_000),
                    sine(frequency: 9_375, amplitude: 0.3, sampleRate: 48_000)
                ).map { pair in pair.0 + pair.1 }
            ]
        ))

        XCTAssertEqual(analyzer.levels(), [Double](repeating: 0, count: 7))
    }

    func testBandsAboveNyquistAreZero() throws {
        let analyzer = AudioSpectrumAnalyzer()
        analyzer.append(try makeBuffer(
            sampleRate: 8_000,
            channels: [sine(frequency: 3_000, amplitude: 0.2, sampleRate: 8_000)]
        ))

        let levels = analyzer.levels()
        XCTAssertGreaterThan(levels[5], 0)
        XCTAssertEqual(levels[6], 0)
    }

    func testStereoChannelsAreAveraged() throws {
        let analyzer = AudioSpectrumAnalyzer()
        analyzer.append(try makeBuffer(channels: [
            sine(frequency: 234.375, amplitude: 0.2),
            sine(frequency: 3_750, amplitude: 0.2),
        ]))

        let levels = analyzer.levels()
        XCTAssertGreaterThan(levels[1], 0.3)
        XCTAssertGreaterThan(levels[5], 0.3)
    }

    func testShortBuffersAccumulateAndResetClearsOldSamples() throws {
        let analyzer = AudioSpectrumAnalyzer()
        let half = sine(frequency: 937.5, amplitude: 0.2, count: 1_024)

        analyzer.append(try makeBuffer(channels: [half]))
        XCTAssertEqual(analyzer.levels(), [Double](repeating: 0, count: 7))
        analyzer.append(try makeBuffer(channels: [half]))
        XCTAssertGreaterThan(analyzer.levels()[3], 0.5)

        analyzer.reset()
        XCTAssertEqual(analyzer.levels(), [Double](repeating: 0, count: 7))
    }

    func testOutputIsFiniteClampedAndExactlySevenValues() throws {
        var samples = sine(frequency: 468.75, amplitude: 4)
        samples[0] = .nan
        samples[1] = .infinity
        let analyzer = AudioSpectrumAnalyzer()

        analyzer.append(try makeBuffer(channels: [samples]))

        XCTAssertEqual(analyzer.levels().count, 7)
        XCTAssertTrue(analyzer.levels().allSatisfy { $0.isFinite && (0...1).contains($0) })
    }

    func testEmptyAndUnsupportedBuffersClearTheVisibleSpectrum() throws {
        let analyzer = AudioSpectrumAnalyzer()
        analyzer.append(try makeBuffer(channels: [sine(frequency: 468.75, amplitude: 0.2)]))
        XCTAssertGreaterThan(analyzer.levels()[2], 0)

        let emptyFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let empty = AVAudioPCMBuffer(pcmFormat: emptyFormat, frameCapacity: 1)!
        empty.frameLength = 0
        analyzer.append(empty)
        XCTAssertEqual(analyzer.levels(), [Double](repeating: 0, count: 7))

        let unsupportedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat64,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let unsupported = AVAudioPCMBuffer(
            pcmFormat: unsupportedFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!
        unsupported.frameLength = AVAudioFrameCount(frameCount)
        analyzer.append(unsupported)
        XCTAssertEqual(analyzer.levels(), [Double](repeating: 0, count: 7))
    }

    private func sine(
        frequency: Double,
        amplitude: Float,
        sampleRate: Double? = nil,
        count: Int? = nil
    ) -> [Float] {
        let rate = sampleRate ?? self.sampleRate
        return (0..<(count ?? frameCount)).map {
            amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate))
        }
    }

    private func makeBuffer(
        sampleRate: Double? = nil,
        channels: [[Float]]
    ) throws -> AVAudioPCMBuffer {
        let frames = channels.first?.count ?? 0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate ?? self.sampleRate,
            channels: AVAudioChannelCount(channels.count),
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        )!
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let destination = buffer.floatChannelData else {
            throw NSError(domain: "AudioSpectrumAnalyzerTests", code: 1)
        }
        for channelIndex in channels.indices {
            for frameIndex in 0..<frames {
                destination[channelIndex][frameIndex] = channels[channelIndex][frameIndex]
            }
        }
        return buffer
    }
}
