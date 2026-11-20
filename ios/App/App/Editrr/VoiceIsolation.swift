// Voice isolation for a clip's own sound: DeepFilterNet3 (speech enhancement), run on the phone
// with Core ML. The signal processing below (STFT, ERB features, normalization, deep filtering)
// and the .npz reader are adapted from speech-swift (https://github.com/soniqo/speech-swift,
// Apache License 2.0); only its Core ML path is kept. The model (aufklarer/DeepFilterNet3-CoreML
// on Hugging Face, Apache-2.0 / MIT) is about 2 MB and is downloaded once, the first time it's used.

import Foundation
import Accelerate
import CoreML
import AVFoundation

/// A clip's sound with the voice isolated: a sound file in the project's folder. Its time 0 is
/// the video's sound at `start` (seconds in the video file).
struct VoiceTrack {
    let asset: AVAsset
    let track: AVAssetTrack
    let start: Double

    static func open(_ url: URL, start: Double) async -> VoiceTrack? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        return VoiceTrack(asset: asset, track: track, start: start)
    }
}

enum VoiceIsolation {
    enum Failure: LocalizedError {
        case download, model, read, write
        var errorDescription: String? {
            switch self {
            case .download: "Voice isolation couldn't be downloaded. Check you're online, then try again."
            case .model: "Voice isolation couldn't start. Try again."
            case .read: "This clip's sound couldn't be read."
            case .write: "The cleaned-up sound couldn't be saved. Check your phone has room."
            }
        }
    }

    static let modelId = "aufklarer/DeepFilterNet3-CoreML"
    static let sampleRate = 48000

    /// Where the model lives once downloaded.
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VoiceIsolation", isDirectory: true)
    }

    static var isReady: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent("DeepFilterNet3.mlmodelc").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("auxiliary.npz").path)
    }

    /// Downloads the model the first time (about 2 MB). Nothing happens once it's there.
    static func prepare() async throws {
        if isReady { return }
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent("VoiceIsolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            var paths = try await files(in: "DeepFilterNet3.mlmodelc")
            guard !paths.isEmpty else { throw Failure.download }
            paths.append("auxiliary.npz")
            for path in paths {
                let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                guard let url = URL(string: "https://huggingface.co/\(modelId)/resolve/main/\(escaped)") else {
                    throw Failure.download
                }
                let (file, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw Failure.download
                }
                let to = temp.appendingPathComponent(path)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: to)
                try fm.moveItem(at: file, to: to)
            }
            try? fm.removeItem(at: folder)
            try fm.moveItem(at: temp, to: folder)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var kept = folder
            try? kept.setResourceValues(values)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download
        }
    }

    /// Every file under a folder of the model's repository (a Core ML model is a folder of files).
    private static func files(in path: String) async throws -> [String] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(modelId)/tree/main/\(path)?recursive=true") else {
            throw Failure.download
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure.download
        }
        return entries.compactMap { entry in
            guard (entry["type"] as? String) == "file", let path = entry["path"] as? String, !path.isEmpty else {
                return nil
            }
            return path
        }
    }

    /// Writes `track`'s sound with the voice isolated to `url` (48 kHz mono). Its time 0 is the
    /// track's own start.
    static func isolate(_ track: AVAssetTrack, of asset: AVAsset, to url: URL) async throws {
        let folder = self.folder
        try await Task.detached(priority: .userInitiated) {
            let samples = try VoiceIsolation.read(track, of: asset)
            guard !samples.isEmpty else { throw Failure.read }
            let enhancer: Enhancer
            do {
                enhancer = try Enhancer(folder: folder)
            } catch {
                throw Failure.model
            }
            var clean: [Float]
            do {
                clean = try enhancer.enhanceChunked(audio: samples)
            } catch {
                throw Failure.model
            }
            // Same length as the sound it replaces, so it lines up to the end.
            if clean.count < samples.count {
                clean.append(contentsOf: [Float](repeating: 0, count: samples.count - clean.count))
            } else if clean.count > samples.count {
                clean.removeLast(clean.count - samples.count)
            }
            try VoiceIsolation.write(clean, to: url)
        }.value
    }

    /// The track's sound as 48 kHz mono samples, from its first sound to its last.
    private static func read(_ track: AVAssetTrack, of asset: AVAsset) throws -> [Float] {
        guard let reader = try? AVAssetReader(asset: asset) else { throw Failure.read }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.read }
        reader.add(output)
        guard reader.startReading() else { throw Failure.read }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw Failure.read }
            samples.append(contentsOf: chunk)
        }
        guard reader.status == .completed else { throw Failure.read }
        return samples
    }

    /// 16-bit, 48 kHz mono, uncompressed (no encoder delay, so it stays in sync).
    private static func write(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false) else { throw Failure.write }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            let step = sampleRate * 10
            var at = 0
            while at < samples.count {
                let count = min(step, samples.count - at)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0] else { throw Failure.write }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { source in
                    var low: Float = -1, high: Float = 1
                    vDSP_vclip(source.baseAddress! + at, 1, &low, &high, channel, 1, vDSP_Length(count))
                }
                try file.write(from: buffer)
                at += count
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw Failure.write
        }
    }
}

// MARK: - DeepFilterNet3 (Core ML), adapted from speech-swift

/// Runs the DeepFilterNet3 network over 48 kHz mono audio.
private final class Enhancer {
    private let model: MLModel
    private let config = DeepFilterNet3Config.default
    private let stft: STFTProcessor
    private let erbFb: [Float]
    private let erbInvFb: [Float]
    private var meanNormState: [Float]
    private var unitNormState: [Float]
    private let meanNormStateInit: [Float]
    private let unitNormStateInit: [Float]
    private var analysisMem: [Float]
    private var synthesisMem: [Float]

    enum Problem: Error { case missing, prediction }

    init(folder: URL) throws {
        let config = DeepFilterNet3Config.default   // (self isn't ready to read yet)
        let modelURL = folder.appendingPathComponent("DeepFilterNet3.mlmodelc")
        let auxURL = folder.appendingPathComponent("auxiliary.npz")
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let arrays = try NpzReader.read(url: auxURL)
        guard let erbFb = arrays["erb_fb"], let erbInvFb = arrays["erb_inv_fb"], let window = arrays["window"],
              let meanNorm = arrays["mean_norm_state"], let unitNorm = arrays["unit_norm_state"] else {
            throw Problem.missing
        }
        self.erbFb = erbFb
        self.erbInvFb = erbInvFb
        stft = STFTProcessor(fftSize: config.fftSize, hopSize: config.hopSize, window: window)
        meanNormState = meanNorm
        unitNormState = unitNorm
        meanNormStateInit = meanNorm
        unitNormStateInit = unitNorm
        analysisMem = [Float](repeating: 0, count: config.fftSize - config.hopSize)
        synthesisMem = [Float](repeating: 0, count: config.fftSize - config.hopSize)
    }

    func resetState() {
        analysisMem = [Float](repeating: 0, count: config.fftSize - config.hopSize)
        synthesisMem = [Float](repeating: 0, count: config.fftSize - config.hopSize)
        meanNormState = meanNormStateInit
        unitNormState = unitNormStateInit
    }

    private func predict(featErb: MLMultiArray, featSpec: MLMultiArray) throws -> (MLMultiArray, MLMultiArray) {
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "feat_erb": MLFeatureValue(multiArray: featErb),
            "feat_spec": MLFeatureValue(multiArray: featSpec),
        ])
        let output = try model.prediction(from: input)
        guard let erbMask = output.featureValue(for: "erb_mask")?.multiArrayValue,
              let dfCoefs = output.featureValue(for: "df_coefs")?.multiArrayValue else {
            throw Problem.prediction
        }
        return (erbMask, dfCoefs)
    }

    /// Float32 out of an MLMultiArray (Core ML may hand back float16).
    private func flat(_ array: MLMultiArray, into output: inout [Float], count: Int) {
        if array.dataType == .float16 {
            let pointer = array.dataPointer.assumingMemoryBound(to: Float16.self)
            for index in 0..<count { output[index] = Float(pointer[index]) }
        } else {
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            output.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.update(from: pointer, count: count)
            }
        }
    }

    private func enhanceCore(audio48k samples: [Float]) throws -> [Float] {
        let hop = config.hopSize
        let freqBins = config.freqBins  // 481 (960/2 + 1)

        // libdf appends a full FFT window so the real-time STFT/iSTFT delay
        // can be removed without truncating non-hop-aligned input lengths.
        let paddedSamples = samples + [Float](repeating: 0, count: config.fftSize)

        // STFT — 960-point DFT producing 481 frequency bins
        let (specReal, specImag) = stft.forward(audio: paddedSamples, analysisMem: &analysisMem)
        let numFrames = specReal.count / freqBins
        guard numFrames > 0 else { return [] }

        // Compute ERB features
        var erbFeats = computeERBFeatures(
            real: specReal, imag: specImag,
            erbFb: erbFb,
            freqBins: freqBins, erbBands: config.erbBands, numFrames: numFrames)

        // Apply mean normalization
        applyMeanNormalization(
            &erbFeats, state: &meanNormState,
            alpha: config.normAlpha,
            erbBands: config.erbBands, numFrames: numFrames)

        // Extract first dfBins for spec features
        var specFeatReal = [Float](repeating: 0, count: numFrames * config.dfBins)
        var specFeatImag = [Float](repeating: 0, count: numFrames * config.dfBins)
        for t in 0..<numFrames {
            for f in 0..<config.dfBins {
                specFeatReal[t * config.dfBins + f] = specReal[t * freqBins + f]
                specFeatImag[t * config.dfBins + f] = specImag[t * freqBins + f]
            }
        }

        // Apply unit normalization
        applyUnitNormalization(
            real: &specFeatReal, imag: &specFeatImag,
            state: &unitNormState,
            alpha: config.normAlpha,
            dfBins: config.dfBins, numFrames: numFrames)

        // No lookahead padding here — both backends apply it internally

        // Run neural network (single pass — GRU state is sequential, can't be
        // chunked). Both branches produce the same flat layouts:
        // erbMaskFlat [T, 32] and coefsRaw [O, T, F, 2].
        let erbMaskCount = numFrames * config.erbBands
        let dfOrder = config.dfOrder
        let coefsCount = dfOrder * numFrames * config.dfBins * 2
        let erbMaskFlat: [Float]
        let coefsRaw: [Float]

        do {
            // Create Core ML input arrays
            // ERB: [1, 1, T, 32] (NCHW)
            let erbInput = try MLMultiArray(shape: [1, 1, numFrames as NSNumber, config.erbBands as NSNumber], dataType: .float32)
            let erbPtr = erbInput.dataPointer.assumingMemoryBound(to: Float.self)
            erbFeats.withUnsafeBufferPointer { src in
                erbPtr.update(from: src.baseAddress!, count: numFrames * config.erbBands)
            }

            // Spec: [1, 2, T, 96] (NCHW: channel 0=real, channel 1=imag)
            let specInput = try MLMultiArray(shape: [1, 2, numFrames as NSNumber, config.dfBins as NSNumber], dataType: .float32)
            let specPtr = specInput.dataPointer.assumingMemoryBound(to: Float.self)
            let specChannelStride = numFrames * config.dfBins
            specFeatReal.withUnsafeBufferPointer { src in
                specPtr.update(from: src.baseAddress!, count: specChannelStride)
            }
            specFeatImag.withUnsafeBufferPointer { src in
                (specPtr + specChannelStride).update(from: src.baseAddress!, count: specChannelStride)
            }

            let (erbMaskArray, coefsArray) = try predict(featErb: erbInput, featSpec: specInput)

            // Extract ERB mask [1, 1, T, 32] — handle float16 output from Core ML
            var maskBuffer = [Float](repeating: 0, count: erbMaskCount)
            flat(erbMaskArray, into: &maskBuffer, count: erbMaskCount)
            erbMaskFlat = maskBuffer

            // Extract DF coefficients [1, 5, T, 96, 2]
            var coefsBuffer = [Float](repeating: 0, count: coefsCount)
            flat(coefsArray, into: &coefsBuffer, count: coefsCount)
            coefsRaw = coefsBuffer
        }

        // Reshape from network layout [O, T, F, 2] to [T, F, O, 2]
        var coefsFlat = [Float](repeating: 0, count: coefsCount)
        for t in 0..<numFrames {
            for f in 0..<config.dfBins {
                for o in 0..<dfOrder {
                    let srcIdx = ((o * numFrames + t) * config.dfBins + f) * 2
                    let dstIdx = ((t * config.dfBins + f) * dfOrder + o) * 2
                    coefsFlat[dstIdx] = coefsRaw[srcIdx]
                    coefsFlat[dstIdx + 1] = coefsRaw[srcIdx + 1]
                }
            }
        }

        // Apply ERB mask to full spectrum
        var enhancedReal = specReal
        var enhancedImag = specImag
        applyERBMask(
            specReal: &enhancedReal, specImag: &enhancedImag,
            erbMask: erbMaskFlat,
            erbInvFb: erbInvFb,
            erbBands: config.erbBands, freqBins: freqBins, numFrames: numFrames)

        // Apply deep filtering to lowest dfBins
        let (dfReal, dfImag) = applyDeepFiltering(
            specReal: specReal, specImag: specImag,
            coefs: coefsFlat,
            dfBins: config.dfBins, dfOrder: config.dfOrder,
            dfLookahead: config.dfLookahead,
            numFrames: numFrames, freqBins: freqBins)

        // Combine: DF-enhanced for bins 0..<dfBins, ERB-masked for rest
        for t in 0..<numFrames {
            for f in 0..<config.dfBins {
                enhancedReal[t * freqBins + f] = dfReal[t * config.dfBins + f]
                enhancedImag[t * freqBins + f] = dfImag[t * config.dfBins + f]
            }
        }

        // Inverse STFT
        let rawOutput = stft.inverse(real: enhancedReal, imag: enhancedImag, synthesisMem: &synthesisMem)

        // Compensate the algorithmic delay introduced by the streaming STFT.
        let trimStart = config.fftSize - hop
        let trimEnd = min(trimStart + samples.count, rawOutput.count)
        guard trimEnd > trimStart else { return [] }
        return Array(rawOutput[trimStart..<trimEnd])
    }

    /// Enhance long-form audio that exceeds the single-shot 60 s cap by
    /// splitting into overlapping windows, running `enhance` on each, and
    /// stitching with an equal-power (sin/cos) crossfade.
    ///
    /// Inputs at or under `chunkSeconds` go through the existing single-shot
    /// path — `enhance(audio:sampleRate:)` — and are bit-identical to today.
    ///
    /// **State continuity**: between chunks the function preserves the STFT
    /// analysis/synthesis overlap buffers AND the EMA normalization state.
    /// Those are *exact* across the seam (no glitch). The only state that
    /// can't be carried is the GRU hidden state inside the CoreML graph —
    /// it re-initializes per `predict()` call. The first ~100–200 ms of each
    /// non-leading chunk are therefore mildly degraded while the GRUs
    /// re-converge; the crossfade region is sized to mask this for
    /// speech-dominated content. Stationary low-SNR noise may exhibit a
    /// brief noise-floor flicker at boundaries.
    ///
    /// - Parameters:
    ///   - audio: Input audio samples (mono, Float32) at any sample rate
    ///   - sampleRate: Sample rate of input audio (resampled to 48kHz if needed)
    ///   - chunkSeconds: Target window size in seconds. Default 45 s leaves
    ///     15 s of headroom under the model's 60 s cap. Must be > 1 s.
    ///   - overlapMs: Crossfade overlap between adjacent chunks in
    ///     milliseconds. Default 500 ms gives the GRU plenty of warm-up time
    ///     inside the fade region. Must be < chunkSeconds × 1000 / 2.
    /// - Returns: Enhanced audio at 48 kHz, same length as the resampled
    ///   input (±1 sample for rounding).
    func enhanceChunked(
        audio: [Float],
        chunkSeconds: Double = 45.0,
        overlapMs: Int = 500
    ) throws -> [Float] {
        precondition(chunkSeconds > 1.0, "chunkSeconds must be > 1 s")
        precondition(Double(overlapMs) < chunkSeconds * 1000 / 2,
                     "overlapMs must be < chunkSeconds*1000/2")

        let samples = audio
        if samples.isEmpty { return [] }

        let rate = config.sampleRate
        let chunkSamples = Int(chunkSeconds * Double(rate))

        // Short input → single shot through the established path. Bit-identical
        // to enhance(...) on this same input.
        if samples.count <= chunkSamples {
            resetState()
            return try enhanceCore(audio48k: samples)
        }

        let overlapSamples = max(1, overlapMs * rate / 1000)
        let hop = chunkSamples - overlapSamples

        // Equal-division so the tail isn't a tiny fragment (mirrors the
        // OmnilingualMLXModel chunker fix — small tails have unreliable
        // per-window stats and produce worse seams).
        let numChunks = max(2, Int(ceil(Double(samples.count - overlapSamples) / Double(hop))))
        let evenChunkSamples = max(
            overlapSamples + 1,
            (samples.count + overlapSamples * (numChunks - 1) + numChunks - 1) / numChunks
        )
        let evenHop = evenChunkSamples - overlapSamples

        // Reset once; the loop below preserves STFT + norm state across chunks.
        resetState()

        var output = [Float]()
        output.reserveCapacity(samples.count)
        var prevTail: [Float] = []

        var offset = 0
        while offset < samples.count {
            let end = min(offset + evenChunkSamples, samples.count)
            let chunk = Array(samples[offset..<end])
            let enhanced = try enhanceCore(audio48k: chunk)
            // The enhance path returns ≈ chunk.count samples (length preserved).
            // Tail < overlapSamples can happen on the last chunk if rounding
            // shaved it; clamp to keep the math safe.
            let effectiveOverlap = min(overlapSamples, enhanced.count, prevTail.count)

            if prevTail.isEmpty {
                // First chunk — keep everything except the trailing overlap,
                // stash that overlap as the tail to crossfade against next.
                let keepEnd = max(0, enhanced.count - overlapSamples)
                output.append(contentsOf: enhanced[0..<keepEnd])
                prevTail = Array(enhanced[keepEnd..<enhanced.count])
            } else {
                // Equal-power crossfade over `effectiveOverlap` samples.
                // t in [0,1]; fadeOut = cos(t*π/2), fadeIn = sin(t*π/2);
                // |fadeOut|² + |fadeIn|² = 1 so the energy of stationary
                // content stays flat across the seam.
                for i in 0..<effectiveOverlap {
                    let t = Float(i) / Float(max(effectiveOverlap - 1, 1))
                    let fadeOut = cos(t * .pi / 2)
                    let fadeIn = sin(t * .pi / 2)
                    output.append(prevTail[i] * fadeOut + enhanced[i] * fadeIn)
                }
                // Any prevTail past the effectiveOverlap is older content
                // that this chunk doesn't cover — append it raw to avoid
                // dropping samples.
                if prevTail.count > effectiveOverlap {
                    output.append(contentsOf: prevTail[effectiveOverlap..<prevTail.count])
                }
                // Keep the middle of this chunk, stash its trailing overlap.
                let midStart = effectiveOverlap
                let midEnd = max(midStart, enhanced.count - overlapSamples)
                output.append(contentsOf: enhanced[midStart..<midEnd])
                prevTail = Array(enhanced[midEnd..<enhanced.count])
            }

            offset += evenHop
            // If the remaining input is too small for a usable chunk, stop —
            // the unbroken tail of `prevTail` covers the gap.
            if samples.count - offset < overlapSamples * 2 { break }
        }
        // Flush the final tail.
        output.append(contentsOf: prevTail)
        // Length should match samples.count ±1. Clamp if slightly over.
        if output.count > samples.count {
            output.removeLast(output.count - samples.count)
        }
        return output
    }
}

/// Configuration for DeepFilterNet3 speech enhancement model.
fileprivate struct DeepFilterNet3Config {
    /// FFT window size
    let fftSize: Int
    /// Hop size (frame shift) in samples
    let hopSize: Int
    /// Number of ERB frequency bands
    let erbBands: Int
    /// Number of frequency bins for deep filtering (lowest bins)
    let dfBins: Int
    /// Deep filter order (number of taps)
    let dfOrder: Int
    /// Deep filter lookahead in frames
    let dfLookahead: Int
    /// Number of convolution channels
    let convCh: Int
    /// Embedding/GRU hidden dimension
    let embHidden: Int
    /// Number of GRU layers in encoder
    let encGruLayers: Int
    /// Number of GRU layers in ERB decoder
    let erbDecGruLayers: Int
    /// DF decoder hidden dimension
    let dfHidden: Int
    /// Number of GRU layers in DF decoder
    let dfGruLayers: Int
    /// Groups for encoder linear layer
    let encLinGroups: Int
    /// Groups for linear layers in SqueezedGRU
    let linGroups: Int
    /// Sample rate
    let sampleRate: Int
    /// Convolution lookahead in frames
    let convLookahead: Int
    /// LSNR max value
    let lsnrMax: Float
    /// LSNR min value
    let lsnrMin: Float
    /// Exponential normalization time constant
    let normTau: Float

    /// Number of FFT frequency bins (fftSize / 2 + 1)
    var freqBins: Int { fftSize / 2 + 1 }

    /// Normalization alpha (exponential decay), rounded like upstream libdf.
    var normAlpha: Float {
        let unrounded = exp(-Float(hopSize) / Float(sampleRate) / normTau)
        var scale: Float = 1_000

        // DeepFilterNet's `get_norm_alpha` starts at three decimal places and
        // increases precision only if rounding would produce 1.0. The default
        // model was trained and exported with 0.99, not exp(-0.01).
        while scale.isFinite {
            let rounded = (unrounded * scale).rounded() / scale
            if rounded < 1 { return rounded }
            scale *= 10
        }
        return unrounded
    }

    /// Default configuration matching the pretrained DeepFilterNet3 model.
    static let `default` = DeepFilterNet3Config(
        fftSize: 960,
        hopSize: 480,
        erbBands: 32,
        dfBins: 96,
        dfOrder: 5,
        dfLookahead: 2,
        convCh: 64,
        embHidden: 256,
        encGruLayers: 1,
        erbDecGruLayers: 2,
        dfHidden: 256,
        dfGruLayers: 2,
        encLinGroups: 32,
        linGroups: 16,
        sampleRate: 48000,
        convLookahead: 2,
        lsnrMax: 35,
        lsnrMin: -15,
        normTau: 1.0
    )
}

// MARK: - Vorbis Window

/// Compute the Vorbis window used by DeepFilterNet3.
///
/// Formula: `w[n] = sin(pi/2 * sin^2(pi * (n + 0.5) / N))`
fileprivate func computeVorbisWindow(size: Int) -> [Float] {
    var window = [Float](repeating: 0, count: size)
    let n = Float(size)
    for i in 0..<size {
        let x = Float.pi * (Float(i) + 0.5) / n
        let sinSq = sin(x) * sin(x)
        window[i] = sin(Float.pi / 2.0 * sinSq)
    }
    return window
}

// MARK: - ERB Filterbank

/// Compute the ERB (Equivalent Rectangular Bandwidth) filterbank.
///
/// Returns a `[freqBins, erbBands]` matrix mapping FFT bins to ERB bands,
/// and the inverse `[erbBands, freqBins]` matrix for decompression.
fileprivate func computeERBFilterbank(
    config: DeepFilterNet3Config
) -> (forward: [Float], inverse: [Float], widths: [Int]) {
    let sr = Float(config.sampleRate)
    let freqBins = config.freqBins  // 481
    let nBands = config.erbBands    // 32
    let minFreqsPerBand = 2

    // ERB scale conversion
    func freq2erb(_ f: Float) -> Float {
        9.265 * log(1.0 + f / (24.7 * 9.265))
    }
    func erb2freq(_ e: Float) -> Float {
        24.7 * 9.265 * (exp(e / 9.265) - 1.0)
    }

    let nyquist = sr / 2.0
    let erbLow = freq2erb(0)
    let erbHigh = freq2erb(nyquist)
    let step = (erbHigh - erbLow) / Float(nBands)

    // Compute band widths (number of FFT bins per ERB band)
    var widths = [Int](repeating: 0, count: nBands)
    var totalBins = 0

    for band in 0..<nBands {
        let erbCenter = erbLow + (Float(band) + 0.5) * step
        let freqLow = erb2freq(erbLow + Float(band) * step)
        let freqHigh = erb2freq(erbLow + Float(band + 1) * step)
        _ = erbCenter  // used for center frequency reference

        let binLow = Int(round(freqLow * Float(config.fftSize) / sr))
        let binHigh = Int(round(freqHigh * Float(config.fftSize) / sr))
        var width = max(minFreqsPerBand, binHigh - binLow)

        if band == nBands - 1 {
            // Last band gets remaining bins
            width = freqBins - totalBins
        }

        widths[band] = width
        totalBins += width
    }

    // Adjust to ensure total == freqBins
    if totalBins != freqBins {
        widths[nBands - 1] += (freqBins - totalBins)
    }

    // Build forward filterbank [freqBins, nBands]
    // Each column has 1/width for its frequency bins (normalized)
    var forward = [Float](repeating: 0, count: freqBins * nBands)
    var binOffset = 0
    for band in 0..<nBands {
        let w = widths[band]
        let norm = 1.0 / Float(w)
        for bin in binOffset..<(binOffset + w) {
            if bin < freqBins {
                forward[bin * nBands + band] = norm
            }
        }
        binOffset += w
    }

    // Build inverse filterbank [nBands, freqBins]
    // Each row repeats 1.0 across its frequency bins (no normalization)
    var inverse = [Float](repeating: 0, count: nBands * freqBins)
    binOffset = 0
    for band in 0..<nBands {
        let w = widths[band]
        for bin in binOffset..<(binOffset + w) {
            if bin < freqBins {
                inverse[band * freqBins + bin] = 1.0
            }
        }
        binOffset += w
    }

    return (forward, inverse, widths)
}

// MARK: - STFT / iSTFT

/// Forward/inverse STFT using vDSP_DFT (supports non-power-of-2 sizes like 960).
///
/// Uses `vDSP_DFT_zop` for complex-to-complex DFT, handling real signals by
/// setting imaginary input to zero and exploiting conjugate symmetry.
/// This avoids zero-padding to the next power of 2 (1024), which would produce
/// different frequency bin values than the native 960-point DFT that
/// DeepFilterNet3 expects.
fileprivate final class STFTProcessor {
    let fftSize: Int
    let hopSize: Int
    let freqBins: Int
    let window: [Float]
    let forwardSetup: OpaquePointer
    let inverseSetup: OpaquePointer
    /// libdf normalizes the analysis DFT by 1/fftSize.
    let analysisScale: Float

    init(fftSize: Int, hopSize: Int, window: [Float]) {
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.window = window
        self.freqBins = fftSize / 2 + 1  // 481 for 960-point DFT
        self.analysisScale = 1.0 / Float(fftSize)

        guard let fwd = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
            fatalError("Failed to create forward DFT setup for N=\(fftSize)")
        }
        self.forwardSetup = fwd

        guard let inv = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .INVERSE) else {
            fatalError("Failed to create inverse DFT setup for N=\(fftSize)")
        }
        self.inverseSetup = inv
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    /// Analysis STFT: audio → complex spectrum.
    ///
    /// Returns (real, imaginary) arrays each of shape [numFrames * freqBins].
    func forward(audio: [Float], analysisMem: inout [Float]) -> (real: [Float], imag: [Float]) {
        let overlapSize = fftSize - hopSize
        let buffer = analysisMem + audio

        let numFrames = max(0, (buffer.count - fftSize) / hopSize + 1)
        guard numFrames > 0 else {
            analysisMem = Array(buffer.suffix(overlapSize))
            return ([], [])
        }

        var real = [Float](repeating: 0, count: numFrames * freqBins)
        var imag = [Float](repeating: 0, count: numFrames * freqBins)

        var windowedFrame = [Float](repeating: 0, count: fftSize)
        var zeroImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        for frame in 0..<numFrames {
            let start = frame * hopSize

            // Apply window
            buffer.withUnsafeBufferPointer { buf in
                vDSP_vmul(buf.baseAddress! + start, 1, window, 1, &windowedFrame, 1, vDSP_Length(fftSize))
            }

            // Zero imaginary input (real signal)
            vDSP_vclr(&zeroImag, 1, vDSP_Length(fftSize))

            // Complex DFT
            vDSP_DFT_Execute(forwardSetup,
                windowedFrame, zeroImag,
                &outReal, &outImag)

            // vDSP leaves both DFT directions unnormalized. libdf applies
            // 1/N during analysis and expects synthesis to remain unscaled.
            var scale = analysisScale
            vDSP_vsmul(outReal, 1, &scale, &outReal, 1, vDSP_Length(freqBins))
            vDSP_vsmul(outImag, 1, &scale, &outImag, 1, vDSP_Length(freqBins))

            // Copy first freqBins (481) unique bins (conjugate symmetry)
            let baseIdx = frame * freqBins
            for k in 0..<freqBins {
                real[baseIdx + k] = outReal[k]
                imag[baseIdx + k] = outImag[k]
            }
        }

        // Update analysis memory
        let consumed = numFrames * hopSize
        analysisMem = Array(buffer.suffix(buffer.count - consumed))
        if analysisMem.count > overlapSize {
            analysisMem = Array(analysisMem.suffix(overlapSize))
        } else if analysisMem.count < overlapSize {
            analysisMem = [Float](repeating: 0, count: overlapSize - analysisMem.count) + analysisMem
        }

        return (real, imag)
    }

    /// Inverse STFT: complex spectrum → audio via overlap-add.
    func inverse(real: [Float], imag: [Float], synthesisMem: inout [Float]) -> [Float] {
        let numFrames = real.count / freqBins
        guard numFrames > 0 else { return [] }

        let outputLen = numFrames * hopSize
        var output = [Float](repeating: 0, count: outputLen)

        var fullReal = [Float](repeating: 0, count: fftSize)
        var fullImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        for frame in 0..<numFrames {
            let baseIdx = frame * freqBins

            // Fill first freqBins (481) bins
            for k in 0..<freqBins {
                fullReal[k] = real[baseIdx + k]
                fullImag[k] = imag[baseIdx + k]
            }

            // Reconstruct conjugate symmetric part: X[N-k] = conj(X[k])
            for k in 1..<(fftSize / 2) {
                fullReal[fftSize - k] = fullReal[k]
                fullImag[fftSize - k] = -fullImag[k]
            }

            // Inverse DFT
            vDSP_DFT_Execute(inverseSetup,
                fullReal, fullImag,
                &outReal, &outImag)

            // Apply synthesis window
            var windowed = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(outReal, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            // Overlap-add with synthesis memory
            for i in 0..<min(fftSize, synthesisMem.count) {
                windowed[i] += synthesisMem[i]
            }

            // Copy hop-size samples to output
            let outStart = frame * hopSize
            for i in 0..<hopSize {
                if outStart + i < outputLen {
                    output[outStart + i] = windowed[i]
                }
            }

            // Update synthesis memory
            let overlapSize = fftSize - hopSize
            synthesisMem = Array(windowed[hopSize..<fftSize])
            if synthesisMem.count < overlapSize {
                synthesisMem.append(contentsOf: [Float](repeating: 0, count: overlapSize - synthesisMem.count))
            }
        }

        return output
    }
}

// MARK: - Feature Extraction

/// Compute ERB power features from complex spectrum.
///
/// - Parameters:
///   - real: Real parts [numFrames * freqBins]
///   - imag: Imaginary parts [numFrames * freqBins]
///   - erbFb: Forward ERB filterbank [freqBins, erbBands]
///   - freqBins: Number of frequency bins
///   - erbBands: Number of ERB bands
///   - numFrames: Number of time frames
/// - Returns: ERB features [numFrames * erbBands] in dB, not yet normalized
fileprivate func computeERBFeatures(
    real: [Float], imag: [Float],
    erbFb: [Float],
    freqBins: Int, erbBands: Int, numFrames: Int
) -> [Float] {
    // Power spectrum: |X|^2
    var power = [Float](repeating: 0, count: numFrames * freqBins)
    for i in 0..<power.count {
        power[i] = real[i] * real[i] + imag[i] * imag[i]
    }

    // ERB compression: power[T, F] @ erbFb[F, B] → erb[T, B]
    var erb = [Float](repeating: 0, count: numFrames * erbBands)
    vDSP_mmul(power, 1, erbFb, 1, &erb, 1,
              vDSP_Length(numFrames), vDSP_Length(erbBands), vDSP_Length(freqBins))

    // Convert to dB: 10 * log10(erb + 1e-10)
    var count32 = Int32(erb.count)
    var epsilon: Float = 1e-10
    vDSP_vsadd(erb, 1, &epsilon, &erb, 1, vDSP_Length(erb.count))
    vvlog10f(&erb, erb, &count32)
    var scale: Float = 10.0
    vDSP_vsmul(erb, 1, &scale, &erb, 1, vDSP_Length(erb.count))

    return erb
}

/// Apply exponential mean normalization to ERB features.
///
/// For each ERB band: `state = x * (1 - alpha) + state * alpha; x_norm = (x - state) / 40`
///
/// - Parameters:
///   - erb: ERB features [numFrames * erbBands], modified in place
///   - state: Running mean state [erbBands], modified in place
///   - alpha: Exponential decay factor
///   - erbBands: Number of ERB bands
///   - numFrames: Number of time frames
fileprivate func applyMeanNormalization(
    _ erb: inout [Float],
    state: inout [Float],
    alpha: Float,
    erbBands: Int,
    numFrames: Int
) {
    let oneMinusAlpha = 1.0 - alpha
    for t in 0..<numFrames {
        let baseIdx = t * erbBands
        for b in 0..<erbBands {
            let x = erb[baseIdx + b]
            state[b] = x * oneMinusAlpha + state[b] * alpha
            erb[baseIdx + b] = (x - state[b]) / 40.0
        }
    }
}

/// Apply exponential unit normalization to complex spec features.
///
/// For each frequency bin: `state = |x| * (1 - alpha) + state * alpha; x_norm = x / sqrt(state)`
///
/// - Parameters:
///   - real: Real parts [numFrames * dfBins], modified in place
///   - imag: Imaginary parts [numFrames * dfBins], modified in place
///   - state: Running magnitude state [dfBins], modified in place
///   - alpha: Exponential decay factor
///   - dfBins: Number of deep filtering bins
///   - numFrames: Number of time frames
fileprivate func applyUnitNormalization(
    real: inout [Float], imag: inout [Float],
    state: inout [Float],
    alpha: Float,
    dfBins: Int,
    numFrames: Int
) {
    let oneMinusAlpha = 1.0 - alpha
    for t in 0..<numFrames {
        let baseIdx = t * dfBins
        for f in 0..<dfBins {
            let re = real[baseIdx + f]
            let im = imag[baseIdx + f]
            let mag = sqrt(re * re + im * im)
            state[f] = mag * oneMinusAlpha + state[f] * alpha
            let norm = sqrt(max(state[f], 1e-10))
            real[baseIdx + f] = re / norm
            imag[baseIdx + f] = im / norm
        }
    }
}

// MARK: - Deep Filtering

/// Apply deep filtering coefficients to the spectrum.
///
/// For each time `t` and frequency `f` (0..<dfBins):
/// ```
/// Y(t, f) = sum_{n=0}^{order-1} X(t + n - padBefore, f) * W(n, t, f)
/// ```
/// where multiplication is complex.
///
/// - Parameters:
///   - specReal: Full spectrum real [numFrames * freqBins]
///   - specImag: Full spectrum imag [numFrames * freqBins]
///   - coefs: Deep filter coefficients [numFrames * dfBins * dfOrder * 2] (real, imag interleaved per tap)
///   - dfBins: Number of frequency bins to filter
///   - dfOrder: Number of filter taps
///   - dfLookahead: Lookahead in frames
///   - numFrames: Number of time frames
///   - freqBins: Total frequency bins
/// - Returns: Filtered spectrum (real, imag) for the first dfBins, [numFrames * dfBins] each
fileprivate func applyDeepFiltering(
    specReal: [Float], specImag: [Float],
    coefs: [Float],
    dfBins: Int, dfOrder: Int, dfLookahead: Int,
    numFrames: Int, freqBins: Int
) -> (real: [Float], imag: [Float]) {
    let padBefore = dfOrder - 1 - dfLookahead  // 5-1-2 = 2

    var outReal = [Float](repeating: 0, count: numFrames * dfBins)
    var outImag = [Float](repeating: 0, count: numFrames * dfBins)

    for t in 0..<numFrames {
        for f in 0..<dfBins {
            var sumRe: Float = 0
            var sumIm: Float = 0

            for n in 0..<dfOrder {
                let srcT = t + n - padBefore
                let coefIdx = (t * dfBins * dfOrder + f * dfOrder + n) * 2

                let wRe = coefs[coefIdx]
                let wIm = coefs[coefIdx + 1]

                // libdf pads the time axis with zeros before unfolding.
                // Out-of-range taps therefore contribute nothing; repeating
                // the edge frame changes the first/last filtered frames.
                guard srcT >= 0, srcT < numFrames else { continue }
                let srcIdx = srcT * freqBins + f

                let xRe = specReal[srcIdx]
                let xIm = specImag[srcIdx]

                // Complex multiply: (xRe + j*xIm) * (wRe + j*wIm)
                sumRe += xRe * wRe - xIm * wIm
                sumIm += xIm * wRe + xRe * wIm
            }

            let outIdx = t * dfBins + f
            outReal[outIdx] = sumRe
            outImag[outIdx] = sumIm
        }
    }

    return (outReal, outImag)
}

// MARK: - ERB Mask Application

/// Apply ERB mask to the full spectrum.
///
/// Expands the 32-band ERB mask to 481 frequency bins using the inverse filterbank,
/// then multiplies the spectrum by the mask.
///
/// - Parameters:
///   - specReal: Spectrum real [numFrames * freqBins], modified in place
///   - specImag: Spectrum imag [numFrames * freqBins], modified in place
///   - erbMask: ERB mask [numFrames * erbBands] (sigmoid output, 0..1)
///   - erbInvFb: Inverse ERB filterbank [erbBands, freqBins]
///   - erbBands: Number of ERB bands
///   - freqBins: Number of frequency bins
///   - numFrames: Number of time frames
fileprivate func applyERBMask(
    specReal: inout [Float], specImag: inout [Float],
    erbMask: [Float],
    erbInvFb: [Float],
    erbBands: Int, freqBins: Int, numFrames: Int
) {
    // Expand mask: mask[T, B] @ invFb[B, F] → fullMask[T, F]
    var fullMask = [Float](repeating: 0, count: numFrames * freqBins)
    vDSP_mmul(erbMask, 1, erbInvFb, 1, &fullMask, 1,
              vDSP_Length(numFrames), vDSP_Length(freqBins), vDSP_Length(erbBands))

    // Apply mask to spectrum
    vDSP_vmul(specReal, 1, fullMask, 1, &specReal, 1, vDSP_Length(specReal.count))
    vDSP_vmul(specImag, 1, fullMask, 1, &specImag, 1, vDSP_Length(specImag.count))
}

// MARK: - Lookahead Padding

/// Apply lookahead padding: trim `lookahead` frames from start, add `lookahead` zero frames at end.
///
/// This shifts features forward in time to provide the model with future context.
fileprivate func applyLookaheadPad<T: Numeric>(
    _ data: [T],
    featuresPerFrame: Int,
    numFrames: Int,
    lookahead: Int
) -> [T] {
    guard lookahead > 0, numFrames > lookahead else { return data }

    // Trim `lookahead` frames from start
    let trimmedStart = lookahead * featuresPerFrame
    var result = Array(data[trimmedStart...])

    // Add `lookahead` zero frames at end
    result.append(contentsOf: [T](repeating: 0, count: lookahead * featuresPerFrame))

    return result
}

/// Minimal reader for NumPy .npz files (uncompressed, float32 only).
fileprivate enum NpzReader {

    static func read(url: URL) throws -> [String: [Float]] {
        let data = try Data(contentsOf: url)
        var result = [String: [Float]]()

        // NPZ is a ZIP archive of .npy files
        var offset = 0
        while offset + 30 <= data.count {
            // ZIP local file header signature
            let b0 = data[offset], b1 = data[offset+1], b2 = data[offset+2], b3 = data[offset+3]
            guard b0 == 0x50 && b1 == 0x4b && b2 == 0x03 && b3 == 0x04 else { break }

            var compressedSize = Int(readUInt32(data, at: offset + 18))
            var uncompressedSize = Int(readUInt32(data, at: offset + 22))
            let nameLen = Int(readUInt16(data, at: offset + 26))
            let extraLen = Int(readUInt16(data, at: offset + 28))

            let nameStart = offset + 30
            guard nameStart + nameLen <= data.count else { break }
            let nameData = data.subdata(in: nameStart..<nameStart + nameLen)
            var name = String(data: nameData, encoding: .utf8) ?? ""

            // Strip .npy extension
            if name.hasSuffix(".npy") {
                name = String(name.dropLast(4))
            }

            // Handle ZIP64 extra field (sizes stored as UInt64 when 0xFFFFFFFF)
            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF {
                let extraStart = nameStart + nameLen
                if extraLen >= 4 {
                    let tag = readUInt16(data, at: extraStart)
                    if tag == 0x0001 {  // ZIP64 extended information
                        var extraOffset = extraStart + 4
                        if uncompressedSize == 0xFFFFFFFF {
                            uncompressedSize = Int(readUInt64(data, at: extraOffset))
                            extraOffset += 8
                        }
                        if compressedSize == 0xFFFFFFFF {
                            compressedSize = Int(readUInt64(data, at: extraOffset))
                        }
                    }
                }
            }

            let dataStart = nameStart + nameLen + extraLen
            let dataSize = max(compressedSize, uncompressedSize)
            guard dataStart + dataSize <= data.count else { break }

            if let floats = parseNpy(data, npyOffset: dataStart, npySize: uncompressedSize) {
                result[name] = floats
            }

            offset = dataStart + dataSize
        }

        return result
    }

    /// Parse a .npy record at the given offset in the data buffer.
    private static func parseNpy(_ data: Data, npyOffset: Int, npySize: Int) -> [Float]? {
        // Magic: \x93NUMPY
        guard npyOffset >= 0,
              npySize >= 10,
              npyOffset + npySize <= data.count,
              data[npyOffset] == 0x93,
              data[npyOffset + 1] == 0x4E else { return nil }

        let majorVersion = data[npyOffset + 6]
        let headerLen: Int
        switch majorVersion {
        case 1:
            headerLen = Int(readUInt16(data, at: npyOffset + 8))
        case 2, 3:
            guard npySize >= 12 else { return nil }
            headerLen = Int(readUInt32(data, at: npyOffset + 8))
        default:
            return nil
        }

        let headerSize = (majorVersion == 1) ? 10 : 12
        let headerStart = npyOffset + headerSize
        let floatStart = headerStart + headerLen
        let numBytes = npySize - headerSize - headerLen

        guard headerLen > 0,
              floatStart <= npyOffset + npySize,
              numBytes > 0,
              numBytes.isMultiple(of: MemoryLayout<Float>.size),
              floatStart + numBytes <= data.count,
              let header = String(
                data: data[headerStart..<floatStart], encoding: .ascii)
        else { return nil }
        let numFloats = numBytes / 4

        var raw = [Float](repeating: 0, count: numFloats)
        _ = raw.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst, from: floatStart..<floatStart + numFloats * 4)
        }

        // NumPy stores transposed/non-contiguous arrays in column-major order
        // and records that layout in the .npy header. The published DFN3
        // auxiliary bundle does this for erb_inv_fb [32, 481]. Returning its
        // bytes unchanged makes callers interpret columns as rows and expands
        // the predicted ERB mask onto the wrong FFT bins.
        let fortranOrder = header.contains("'fortran_order': True")
            || header.contains("\"fortran_order\": True")
        guard fortranOrder else { return raw }
        guard let shape = parseShape(fromNpyHeader: header),
              shape.count > 1,
              elementCount(of: shape, limit: numFloats) == numFloats
        else { return nil }

        return fortranToRowMajor(raw, shape: shape)
    }

    /// Validate the shape while avoiding integer overflow on malformed input.
    private static func elementCount(of shape: [Int], limit: Int) -> Int? {
        var count = 1
        for dimension in shape {
            guard dimension > 0, count <= limit / dimension else { return nil }
            count *= dimension
        }
        return count
    }

    /// Extract the tuple following `shape` from a NumPy header dictionary.
    private static func parseShape(fromNpyHeader header: String) -> [Int]? {
        guard let shapeKey = header.range(of: "shape"),
              let open = header[shapeKey.upperBound...].firstIndex(of: "("),
              let close = header[open...].firstIndex(of: ")")
        else { return nil }

        let contents = header[header.index(after: open)..<close]
        var dimensions = [Int]()
        for part in contents.split(separator: ",") {
            let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let dimension = Int(value) else { return nil }
            dimensions.append(dimension)
        }
        return dimensions.isEmpty ? nil : dimensions
    }

    /// Convert a NumPy Fortran-order flat buffer to conventional row-major
    /// order while preserving the declared N-dimensional shape.
    private static func fortranToRowMajor(_ input: [Float], shape: [Int]) -> [Float] {
        var rowMajorStrides = [Int](repeating: 1, count: shape.count)
        if shape.count > 1 {
            for dimension in stride(from: shape.count - 2, through: 0, by: -1) {
                rowMajorStrides[dimension] = rowMajorStrides[dimension + 1]
                    * shape[dimension + 1]
            }
        }

        var output = [Float](repeating: 0, count: input.count)
        for rowMajorIndex in output.indices {
            var remainder = rowMajorIndex
            var fortranIndex = 0
            var fortranStride = 1
            for dimension in shape.indices {
                let coordinate = remainder / rowMajorStrides[dimension]
                remainder %= rowMajorStrides[dimension]
                fortranIndex += coordinate * fortranStride
                fortranStride *= shape[dimension]
            }
            output[rowMajorIndex] = input[fortranIndex]
        }
        return output
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset - data.startIndex, as: UInt16.self)
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset - data.startIndex, as: UInt32.self)
        }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset - data.startIndex, as: UInt64.self)
        }
    }
}
