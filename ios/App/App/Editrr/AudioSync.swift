import AVFoundation
import Accelerate

/// A light copy of a sound: how loud it is (100 times a second, for drawing) and the sound
/// itself at 2,000 samples a second (for lining videos up to the song).
struct SoundPrint: Sendable {
    /// Loudness values a second.
    static let rate: Double = 100
    /// Samples a second kept for lining up.
    static let lineRate: Double = 2000

    /// Asset time (seconds) of the first sample, which is where the audio track starts.
    let start: Double
    /// Loudness from 0 to 1.
    let loudness: [Float]
    /// The sound at 2 kHz.
    let line: [Float]
    /// Where new sound starts, in 16 pitch bands, 100 times a second (band after band).
    /// Used as a second opinion when lining up.
    let flux: [Float]
    let fluxFrames: Int

    var duration: Double { Double(loudness.count) / Self.rate }

    /// The same sound made `factor` times longer (2: twice as long), as if it had been recorded at
    /// that speed. A take shot to the song played fast, stretched back, lines up with the song.
    func stretched(by factor: Double) -> SoundPrint {
        guard factor > 0, abs(factor - 1) > 0.001 else { return self }
        func stretch(_ values: ArraySlice<Float>) -> [Float] {
            let count = values.count
            guard count > 1 else { return Array(values) }
            let made = max(2, Int((Double(count) * factor).rounded()))
            let base = values.startIndex
            var result = [Float](repeating: 0, count: made)
            let step = Double(count - 1) / Double(made - 1)
            for index in 0..<made {
                let at = Double(index) * step
                let low = Int(at)
                let high = min(low + 1, count - 1)
                let mix = Float(at - Double(low))
                result[index] = values[base + low] * (1 - mix) + values[base + high] * mix
            }
            return result
        }
        // Each pitch band's onsets, stretched band by band.
        var flux: [Float] = []
        var frames = 0
        let bands = SoundReader.fluxBands
        if fluxFrames > 1, self.flux.count == fluxFrames * bands {
            for band in 0..<bands {
                let row = stretch(self.flux[(band * fluxFrames)..<((band + 1) * fluxFrames)])
                frames = row.count
                flux.append(contentsOf: row)
            }
        }
        return SoundPrint(start: start * factor, loudness: stretch(loudness[...]), line: stretch(line[...]),
                          flux: flux, fluxFrames: frames)
    }
}

/// Reads a sound into a SoundPrint, asking for a small 8 kHz mono copy of the audio.
enum SoundReader {
    static let sampleRate = 8000
    static let hop = 80           // 8000 / 80 = 100 loudness values a second
    static let shrink = 4         // 8000 / 4 = 2000 samples a second for lining up

    static func read(_ asset: AVAsset) async throws -> SoundPrint? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let range = try await track.load(.timeRange)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditorError.noSound }

        var samples: [Float] = []
        samples.reserveCapacity(Int(range.duration.seconds * Double(sampleRate)) + sampleRate)
        var chunk: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if chunk.count != count { chunk = [Float](repeating: 0, count: count) }
            let copied = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                           dataLength: count * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress!)
            }
            if copied == kCMBlockBufferNoErr { samples.append(contentsOf: chunk) }
        }
        if reader.status == .failed { throw reader.error ?? EditorError.noSound }
        return analyze(samples, start: range.start.seconds)
    }

    static func analyze(_ samples: [Float], start: Double) -> SoundPrint? {
        let frames = samples.count / hop
        guard frames > 20 else { return nil }

        var meanSquares = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { all in
            guard let first = all.baseAddress else { return }
            for frame in 0..<frames {
                var energy: Float = 0
                vDSP_measqv(first + frame * hop, 1, &energy, vDSP_Length(hop))
                meanSquares[frame] = energy
            }
        }
        let peak = max(meanSquares.max() ?? 1, 1e-9)
        let loudness = meanSquares.map { min(1, sqrt($0 / peak)) }

        // Average every 4 samples: a 2 kHz copy for lining up.
        let lineCount = samples.count / shrink
        var line = [Float](repeating: 0, count: lineCount)
        for index in 0..<lineCount {
            let base = index * shrink
            line[index] = (samples[base] + samples[base + 1] + samples[base + 2] + samples[base + 3]) * 0.25
        }
        let (flux, fluxFrames) = bandFlux(samples)
        return SoundPrint(start: start, loudness: loudness, line: line, flux: flux, fluxFrames: fluxFrames)
    }

    static let fluxBands = 16

    /// For each of 16 pitch bands (250 Hz wide), how much it jumps up each hundredth of a second,
    /// evened out band by band so no one band (crowd rumble, a whistle) drowns out the rest.
    private static func bandFlux(_ samples: [Float]) -> ([Float], Int) {
        let window = 256, log2n = 8, half = 128, bands = fluxBands, binsPerBand = half / bands
        guard samples.count > window else { return ([], 0) }
        let frames = (samples.count - window) / hop + 1
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return ([], 0) }
        defer { vDSP_destroy_fftsetup(setup) }
        let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: window, isHalfWindow: false)

        var levels = [Float](repeating: 0, count: frames * bands)      // frame after frame
        var windowed = [Float](repeating: 0, count: window)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        samples.withUnsafeBufferPointer { all in
            guard let first = all.baseAddress else { return }
            for frame in 0..<frames {
                vDSP_vmul(first + frame * hop, 1, hann, 1, &windowed, 1, vDSP_Length(window))
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        windowed.withUnsafeBytes { raw in
                            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                        ip[0] = 0
                        power.withUnsafeMutableBufferPointer { pp in
                            vDSP_zvmags(&split, 1, pp.baseAddress!, 1, vDSP_Length(half))
                        }
                    }
                }
                for band in 0..<bands {
                    var sum: Float = 0
                    for bin in (band * binsPerBand)..<((band + 1) * binsPerBand) { sum += power[bin] }
                    levels[frame * bands + band] = log10(sum + 1e-9)
                }
            }
        }

        var flux = [Float](repeating: 0, count: frames * bands)        // band after band
        for band in 0..<bands {
            let row = band * frames
            for frame in 1..<max(frames, 1) {
                let rise = levels[frame * bands + band] - levels[(frame - 1) * bands + band]
                flux[row + frame] = max(0, rise)
            }
            var mean: Float = 0
            for frame in 0..<frames { mean += flux[row + frame] }
            mean /= Float(frames)
            var spread: Float = 0
            for frame in 0..<frames { spread += (flux[row + frame] - mean) * (flux[row + frame] - mean) }
            let deviation = max(sqrt(spread / Float(frames)), 1e-6)
            for frame in 0..<frames { flux[row + frame] = (flux[row + frame] - mean) / deviation }
        }
        return (flux, frames)
    }
}

/// Where a video's sound best lines up with the reference sound (the song).
struct SoundMatch: Sendable {
    /// Seconds into the reference where the video's first sound sits. Can be negative
    /// (the video started before the song).
    let lag: Double
    /// False when the match was weak or the song has a twin spot (a repeated part),
    /// so the clip is worth a look. It's still placed at the best guess.
    let sure: Bool
    /// Other spots that fit almost as well (usually a repeated chorus), best first.
    var others: [Double] = []
    /// How much the best spot stands out from the usual level (12 is the least that counts).
    var strength: Double = 0

    /// Puts the two ways of lining up together. When they agree, the place is solid. When they
    /// don't, the main answer stays and the second one is offered as another spot.
    static func combine(_ primary: SoundMatch?, _ backup: Double?) -> SoundMatch? {
        switch (primary, backup) {
        case (nil, nil):
            return nil
        case (nil, let lag?):
            return SoundMatch(lag: lag, sure: false)
        case (let match?, nil):
            return match
        case (let match?, let lag?):
            if abs(match.lag - lag) <= 0.1 {
                return SoundMatch(lag: match.lag, sure: match.others.isEmpty, others: match.others,
                                  strength: match.strength)
            }
            var others = match.others
            if !others.contains(where: { abs($0 - lag) <= 0.5 }) { others.insert(lag, at: 0) }
            return SoundMatch(lag: match.lag, sure: false, others: Array(others.prefix(3)), strength: match.strength)
        }
    }
}

/// Lines a video up to the song by GCC-PHAT, the standard way to find the delay between two
/// recordings of the same sound. It compares the two sounds across every pitch with each pitch
/// weighted equally, so crowd noise, room echo and a phone mic's tinny sound don't throw it off.
/// The song is prepared once and shared by every video.
enum LineUp {
    /// Biggest FFT used: about a million samples (8.7 minutes at 2 kHz).
    static let maxLog2 = 20
    /// Only the first 4 minutes of a video are used to find its place.
    static let clipSeconds: Double = 240

    struct Reference: Sendable {
        let real: [Float]
        let imag: [Float]
        let log2n: Int
        /// 1: compare at 2 kHz. 2: at 1 kHz (long songs, so the FFT stays in bounds).
        let step: Int
        let rate: Double
        let count: Int
        let clipCap: Int
    }

    static func prepare(_ sound: SoundPrint) -> Reference? {
        let maxSize = 1 << maxLog2
        var step = 1
        var rate = SoundPrint.lineRate
        var samples = sound.line
        if samples.count + Int(clipSeconds * rate) > maxSize {
            step = 2
            rate /= 2
            samples = halve(samples)
        }
        let shortest = Int(2 * rate)
        if samples.count > maxSize - shortest { samples = Array(samples.prefix(maxSize - shortest)) }
        guard samples.count > shortest else { return nil }
        let clipCap = min(Int(clipSeconds * rate), maxSize - samples.count)
        var log2n = 4
        while (1 << log2n) < samples.count + clipCap { log2n += 1 }
        guard let spectrum = Spectrum.forward(samples, log2n: log2n) else { return nil }
        return Reference(real: spectrum.real, imag: spectrum.imag, log2n: log2n, step: step,
                         rate: rate, count: samples.count, clipCap: clipCap)
    }

    static func match(_ clip: SoundPrint, to reference: Reference) -> SoundMatch? {
        var samples = reference.step == 2 ? halve(clip.line) : clip.line
        if samples.count > reference.clipCap { samples = Array(samples.prefix(reference.clipCap)) }
        let m = samples.count
        let n = reference.count
        guard m >= Int(reference.rate) else { return nil }          // at least a second of sound
        let log2n = reference.log2n
        let size = 1 << log2n
        let half = size / 2
        guard let spectrum = Spectrum.forward(samples, log2n: log2n) else { return nil }
        var real = spectrum.real
        var imag = spectrum.imag

        // Song times the video's mirror image, every pitch scaled to the same strength.
        // Rumble under 100 Hz (wind, handling) is left out.
        let lowCut = max(1, Int(100 / reference.rate * Double(size)))
        for bin in 0..<half {
            if bin < lowCut {
                real[bin] = 0
                imag[bin] = 0
                continue
            }
            let a = reference.real[bin], b = reference.imag[bin], c = real[bin], d = imag[bin]
            let x = a * c + b * d
            let y = b * c - a * d
            let strength = sqrt(x * x + y * y) + 1e-20
            real[bin] = x / strength
            imag[bin] = y / strength
        }

        guard let out = Spectrum.inverse(real: &real, imag: &imag, log2n: log2n) else { return nil }
        let scores = Spectrum.shifts(out, clipCount: m, referenceCount: n)
        guard let found = Spectrum.winner(scores) else { return nil }
        let best = found.best, top = found.top, typical = found.typical
        let standout = top / typical

        guard standout >= 12 else { return nil }                    // the song isn't in this video

        // Other spots almost as good (a repeated chorus): up to 3, each at least a second from
        // the others, scoring at least 60% of the best and clearly above the usual level.
        let apart = Int(reference.rate)
        var taken = [best]
        var others: [Double] = []
        var runnerUp: Float = 0
        for pass in 0..<3 {
            var next = -1
            for index in scores.indices where scores[index] > (next < 0 ? 0 : scores[next]) {
                if taken.allSatisfy({ abs($0 - index) > apart }) { next = index }
            }
            guard next >= 0 else { break }
            if pass == 0 { runnerUp = scores[next] }
            guard scores[next] >= top * 0.6, scores[next] / typical >= 12 else { break }
            taken.append(next)
            others.append(Double(next - (m - 1)) / reference.rate)
        }

        let lag = Double(best - (m - 1)) / reference.rate
        return SoundMatch(lag: lag, sure: standout >= 25 && others.isEmpty && top >= runnerUp * 1.5, others: others,
                          strength: Double(standout))
    }

    private static func halve(_ samples: [Float]) -> [Float] {
        let count = samples.count / 2
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count { result[index] = (samples[2 * index] + samples[2 * index + 1]) * 0.5 }
        return result
    }
}

/// Uses the videos to place each other. Phone videos of the same take hear the same room, so they
/// line up to each other much more clearly than to the studio song. Every video's place is put to a
/// vote: its own match to the song, plus each other video's place shifted by how the two line up.
/// A video the song match got wrong is pulled to where the others agree it goes.
enum Consensus {
    /// How video i sits against video j: i's first sound is `lag` seconds into j's sound.
    struct Link: Sendable {
        let lag: Double
        let weight: Double
    }

    /// Lines every pair of videos up with each other. links[i][j] is i against j.
    /// One video's sound is prepared at a time, so memory stays low.
    static func links(_ sounds: [SoundPrint?]) -> [[Link?]] {
        let count = sounds.count
        var links = Array(repeating: [Link?](repeating: nil, count: count), count: count)
        for j in 1..<max(count, 1) {
            guard let soundJ = sounds[j], (0..<j).contains(where: { sounds[$0] != nil }),
                  let reference = LineUp.prepare(soundJ) else { continue }
            for i in 0..<j {
                guard let soundI = sounds[i], let match = LineUp.match(soundI, to: reference),
                      match.strength >= 15 else { continue }
                // A pair that also fits a twin spot (both filmed a repeated chorus) counts for less.
                let weight = min(match.strength / 15, 4) * (match.others.isEmpty ? 1 : 0.4)
                links[i][j] = Link(lag: match.lag, weight: weight)
                links[j][i] = Link(lag: -match.lag, weight: weight)
            }
        }
        return links
    }

    /// Each video's place in the reference, decided by every match that bears on it.
    /// `direct` is each video's own match to the reference. `fixed` is the video that is the
    /// reference (no song picked): its place is 0 and never moves.
    static func vote(direct: [SoundMatch?], fixed: Int?, links: [[Link?]]) -> [Int: SoundMatch] {
        let count = direct.count
        var place: [Double?] = direct.map { $0?.lag }
        var trust: [Double] = direct.map { match in match.map { $0.sure ? 1 : 0.5 } ?? 0 }
        if let fixed, fixed < count {
            place[fixed] = 0
            trust[fixed] = 1
        }
        var result: [Int: SoundMatch] = [:]
        for _ in 0..<4 {
            var nextPlace = place
            var nextTrust = trust
            for i in 0..<count where i != fixed {
                var votes: [(at: Double, weight: Double)] = []
                if let match = direct[i] {
                    let weight = match.sure ? 3 : max(1, min(match.strength / 12, 2))
                    votes.append((match.lag, weight))
                    for other in match.others { votes.append((other, 0.6)) }
                }
                for j in 0..<count where j != i {
                    guard let link = links[i][j], let placeJ = place[j], trust[j] > 0 else { continue }
                    votes.append((placeJ + link.lag, link.weight * trust[j]))
                }
                guard let tallied = tally(votes) else { continue }
                let (best, bestScore, spots) = tallied
                let total = votes.reduce(0) { $0 + $1.weight }
                nextPlace[i] = best
                nextTrust[i] = min(1, bestScore / 3) * (bestScore / max(total, 1e-9))
                let runnerUp = spots.first?.score ?? 0
                result[i] = SoundMatch(lag: best, sure: bestScore >= 3 && runnerUp < bestScore * 0.5,
                                       others: spots.filter { $0.score >= bestScore * 0.5 }.map { $0.at },
                                       strength: direct[i]?.strength ?? 0)
            }
            place = nextPlace
            trust = nextTrust
        }
        return result
    }

    /// The spot most votes agree on (within 60 ms), its score, and up to 3 other spots at least
    /// half a second away, best first.
    private static func tally(_ votes: [(at: Double, weight: Double)])
        -> (Double, Double, [(at: Double, score: Double)])? {
        var left = votes
        var found: [(at: Double, score: Double)] = []
        while found.count < 4, !left.isEmpty {
            var bestIndex = 0
            var bestScore = -1.0
            for (index, vote) in left.enumerated() {
                let score = left.reduce(0) { abs($1.at - vote.at) <= 0.06 ? $0 + $1.weight : $0 }
                if score > bestScore || (score == bestScore && vote.weight > left[bestIndex].weight) {
                    bestScore = score
                    bestIndex = index
                }
            }
            let center = left[bestIndex].at
            let near = left.filter { abs($0.at - center) <= 0.06 }
            let weight = near.reduce(0) { $0 + $1.weight }
            let at = near.reduce(0) { $0 + $1.at * $1.weight } / max(weight, 1e-9)
            found.append((at, bestScore))
            left.removeAll { abs($0.at - center) <= 0.5 }
        }
        guard let first = found.first else { return nil }
        return (first.at, first.score, Array(found.dropFirst()))
    }
}

/// FFT helpers shared by both ways of lining up.
enum Spectrum {
    /// Real FFT of the samples, zero-padded to 2^log2n, in Accelerate's packed form.
    static func forward(_ samples: [Float], log2n: Int) -> (real: [Float], imag: [Float])? {
        let size = 1 << log2n
        let half = size / 2
        guard samples.count <= size, let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var padded = [Float](repeating: 0, count: size)
        padded.replaceSubrange(0..<samples.count, with: samples)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                padded.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
            }
        }
        return (real, imag)
    }

    /// Back from the packed spectrum to 2^log2n real values (unscaled).
    static func inverse(real: inout [Float], imag: inout [Float], log2n: Int) -> [Float]? {
        let size = 1 << log2n
        let half = size / 2
        guard real.count == half, imag.count == half,
              let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var out = [Float](repeating: 0, count: size)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                }
            }
        }
        return out
    }

    /// Scores for every shift, from the clip starting clipCount-1 steps before the reference to
    /// starting at the reference's last step. Shift = index - (clipCount - 1).
    static func shifts(_ out: [Float], clipCount m: Int, referenceCount n: Int) -> [Float] {
        let size = out.count
        var scores = [Float]()
        scores.reserveCapacity(n + m - 1)
        if m > 1 { scores.append(contentsOf: out[(size - m + 1)..<size]) }
        scores.append(contentsOf: out[0..<min(n, size)])
        return scores
    }

    /// The best shift, its score, and the usual level (median of the scores' size).
    static func winner(_ scores: [Float]) -> (best: Int, top: Float, typical: Float)? {
        guard !scores.isEmpty else { return nil }
        var best = 0
        for index in 1..<scores.count where scores[index] > scores[best] { best = index }
        let top = scores[best]
        guard top > 0 else { return nil }
        var sample: [Float] = []
        sample.reserveCapacity(scores.count / 16 + 1)
        var index = 0
        while index < scores.count {
            sample.append(abs(scores[index]))
            index += 16
        }
        sample.sort()
        return (best, top, max(sample[sample.count / 2], 1e-20))
    }
}

/// A second opinion: lines up where new sounds start (hits, words, chord changes) across
/// 16 pitch bands. It works from a different part of the sound than LineUp, so when the two
/// agree the place is solid, and when they don't, both spots are offered.
enum FluxLineUp {
    static let clipFrames = 24000       // first 4 minutes of a video

    struct Reference: Sendable {
        /// One packed spectrum per band (bands 1...15; band 0, the lowest, is left out).
        let real: [[Float]]
        let imag: [[Float]]
        let log2n: Int
        let count: Int
    }

    static func prepare(_ sound: SoundPrint) -> Reference? {
        let n = sound.fluxFrames
        guard n > 200, sound.flux.count == n * SoundReader.fluxBands else { return nil }
        var log2n = 4
        while (1 << log2n) < n + clipFrames { log2n += 1 }
        guard log2n <= 20 else { return nil }
        var real: [[Float]] = []
        var imag: [[Float]] = []
        for band in 1..<SoundReader.fluxBands {
            guard let spectrum = Spectrum.forward(Array(sound.flux[(band * n)..<((band + 1) * n)]), log2n: log2n) else { return nil }
            real.append(spectrum.real)
            imag.append(spectrum.imag)
        }
        return Reference(real: real, imag: imag, log2n: log2n, count: n)
    }

    /// The best shift in seconds, if it stands out clearly.
    static func match(_ clip: SoundPrint, to reference: Reference) -> Double? {
        scored(clip, to: reference)?.lag
    }

    /// The best shift in seconds and how much it stands out (11 is the least that counts).
    static func scored(_ clip: SoundPrint, to reference: Reference) -> (lag: Double, standout: Double)? {
        let frames = clip.fluxFrames
        guard frames > 100, clip.flux.count == frames * SoundReader.fluxBands else { return nil }
        let m = min(frames, clipFrames)
        let half = (1 << reference.log2n) / 2
        var sumReal = [Float](repeating: 0, count: half)
        var sumImag = [Float](repeating: 0, count: half)
        for band in 1..<SoundReader.fluxBands {
            let start = band * frames
            guard let spectrum = Spectrum.forward(Array(clip.flux[start..<(start + m)]), log2n: reference.log2n) else { return nil }
            let rr = reference.real[band - 1], ri = reference.imag[band - 1]
            let cr = spectrum.real, ci = spectrum.imag
            // Packed bin 0 holds two real values (lowest and highest bin).
            sumReal[0] += rr[0] * cr[0]
            sumImag[0] += ri[0] * ci[0]
            for bin in 1..<half {
                sumReal[bin] += rr[bin] * cr[bin] + ri[bin] * ci[bin]
                sumImag[bin] += ri[bin] * cr[bin] - rr[bin] * ci[bin]
            }
        }
        guard let out = Spectrum.inverse(real: &sumReal, imag: &sumImag, log2n: reference.log2n) else { return nil }
        let scores = Spectrum.shifts(out, clipCount: m, referenceCount: reference.count)
        guard let found = Spectrum.winner(scores), found.top / found.typical >= 11 else { return nil }
        return (Double(found.best - (m - 1)) / SoundPrint.rate, Double(found.top / found.typical))
    }
}

/// Takes shot to the song played faster or slower: artists play the song at double speed and
/// slow the video down for slow motion, or the other way round for a sped-up look. The video's
/// sound then holds the song at that speed. When a video doesn't fit the song at normal speed,
/// its sound is stretched to each usual speed and tried again.
enum TakeSpeed {
    /// How many times longer the take plays than it was shot: 2 plays it at half speed (shot to
    /// the song at double speed), 0.5 at double speed.
    static let tried: [Double] = [2, 0.5, 1.5, 0.75, 4, 0.25]

    /// How clearly a place stood out, on LineUp's scale (25 is solid).
    private static func score(_ primary: SoundMatch?, _ backup: (lag: Double, standout: Double)?) -> Double {
        max(primary?.strength ?? 0, (backup?.standout ?? 0) * 2)
    }

    /// The best place for a video's sound and the speed it plays at. Other speeds are only tried
    /// when the song can't really be found at normal speed (no match, or only a weak one the two
    /// ways of lining up disagree on). A repeated chorus alone never sends a take looking for
    /// another speed. Another speed only wins when both ways agree on its place, it stands out
    /// clearly, and the take doesn't start before the song.
    static func best(_ clip: SoundPrint, main: LineUp.Reference?, second: FluxLineUp.Reference?,
                     tryOthers: Bool) -> (speed: Double, match: SoundMatch?) {
        let primary = main.flatMap { LineUp.match(clip, to: $0) }
        let backup = second.flatMap { FluxLineUp.scored(clip, to: $0) }
        let normal = SoundMatch.combine(primary, backup?.lag)
        let agree: Bool = {
            guard let primary, let backup else { return false }
            return abs(primary.lag - backup.lag) <= 0.1
        }()
        let weak = normal == nil || (!agree && (primary?.strength ?? 0) < 20)
        guard tryOthers, weak else { return (1, normal) }
        let normalScore = score(primary, backup)
        var winner: (speed: Double, match: SoundMatch?, score: Double) = (1, normal, normalScore)
        for speed in tried {
            let stretched = clip.stretched(by: speed)
            guard let fast = main.flatMap({ LineUp.match(stretched, to: $0) }),
                  let onsets = second.flatMap({ FluxLineUp.scored(stretched, to: $0) }),
                  abs(fast.lag - onsets.lag) <= 0.15,
                  fast.lag >= -SongFirst.leadIn else { continue }
            let found = score(fast, onsets)
            // Only a clearly better fit counts, so a normal take never gets a speed by chance.
            if fast.strength >= 25, found >= normalScore * 1.6, found > winner.score {
                winner = (speed, SoundMatch.combine(fast, onsets.lag), found)
            }
        }
        return (winner.speed, winner.match)
    }
}

/// The song comes first: a take is filmed while the song plays, so it shouldn't sit long before
/// the song starts. A place that does is usually a wrong match, so another likely spot that
/// starts with the song or after it is used instead.
enum SongFirst {
    /// How far before the song a take may start (the second or two between hitting record and
    /// the song starting).
    static let leadIn: Double = 2

    /// `start`: how far the take's first picture is from its first sound frame (added to a lag
    /// to get where the take starts).
    static func fix(_ match: SoundMatch, start: Double) -> SoundMatch {
        guard match.lag + start < -leadIn else { return match }
        if let better = match.others.first(where: { $0 + start >= -leadIn }) {
            var others = match.others.filter { $0 != better }
            others.append(match.lag)
            return SoundMatch(lag: better, sure: false, others: Array(others.prefix(3)), strength: match.strength)
        }
        // No other spot fits: it stays at the best guess, marked to check.
        return SoundMatch(lag: match.lag, sure: false, others: match.others, strength: match.strength)
    }
}
