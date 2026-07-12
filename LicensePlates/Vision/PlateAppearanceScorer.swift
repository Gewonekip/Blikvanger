import CoreGraphics
import Foundation

struct PlateAppearanceScore: Equatable, Sendable {
    let yellowFraction: CGFloat
    let darkFraction: CGFloat
    let darkBandCoverage: CGFloat
    let darkRowCoverage: CGFloat
    let luminanceDeviation: CGFloat

    /// The common Dutch plate is a yellow retroreflective field with black
    /// characters and a black border. Geometry alone cannot distinguish it
    /// from windows, grilles, signs, or indoor picture frames.
    var isPlausibleCommonDutchPlate: Bool {
        yellowFraction >= 0.22
            && darkFraction >= 0.025
            && darkBandCoverage >= 0.34
            && darkRowCoverage >= 0.75
            && luminanceDeviation >= 0.055
    }

    var rankingBonus: CGFloat {
        yellowFraction * 0.72
            + darkBandCoverage * 0.18
            + darkRowCoverage * 0.10
            + min(luminanceDeviation, 0.25) * 0.40
    }
}

protocol PlateAppearanceScoring: Sendable {
    func score(_ image: CGImage) -> PlateAppearanceScore?
}

struct PlateAppearanceScorer: PlateAppearanceScoring {
    private let sampleWidth = 72
    private let sampleHeight = 32
    private let horizontalBands = 6
    private let verticalBands = 4

    func score(_ image: CGImage) -> PlateAppearanceScore? {
        guard image.width > 0, image.height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: sampleWidth,
                    height: sampleHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: sampleWidth * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard rendered else { return nil }

        // Exclude the outer edge: the plate's black border is useful geometry,
        // but it must not masquerade as the distributed dark character pattern.
        let minimumX = max(1, Int(CGFloat(sampleWidth) * 0.06))
        let maximumX = min(sampleWidth - 1, Int(CGFloat(sampleWidth) * 0.94))
        let minimumY = max(1, Int(CGFloat(sampleHeight) * 0.12))
        let maximumY = min(sampleHeight - 1, Int(CGFloat(sampleHeight) * 0.88))
        guard maximumX > minimumX, maximumY > minimumY else { return nil }

        var yellowPixels = 0
        var darkPixels = 0
        var sampleCount = 0
        var luminanceSum: CGFloat = 0
        var luminanceSquaredSum: CGFloat = 0
        var luminanceSamples: [(value: CGFloat, horizontalBand: Int, verticalBand: Int)] = []
        var samplesPerBand = [Int](repeating: 0, count: horizontalBands)
        var samplesPerRowBand = [Int](repeating: 0, count: verticalBands)

        for y in minimumY..<maximumY {
            for x in minimumX..<maximumX {
                let offset = (y * sampleWidth + x) * 4
                let red = CGFloat(pixels[offset]) / 255
                let green = CGFloat(pixels[offset + 1]) / 255
                let blue = CGFloat(pixels[offset + 2]) / 255
                let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
                let band = min(
                    horizontalBands - 1,
                    (x - minimumX) * horizontalBands / max(maximumX - minimumX, 1)
                )
                let rowBand = min(
                    verticalBands - 1,
                    (y - minimumY) * verticalBands / max(maximumY - minimumY, 1)
                )

                sampleCount += 1
                samplesPerBand[band] += 1
                samplesPerRowBand[rowBand] += 1
                luminanceSum += luminance
                luminanceSquaredSum += luminance * luminance
                luminanceSamples.append((luminance, band, rowBand))
                if isYellow(red: red, green: green, blue: blue) {
                    yellowPixels += 1
                }
            }
        }
        guard sampleCount > 0 else { return nil }

        let count = CGFloat(sampleCount)
        let mean = luminanceSum / count
        let variance = max(0, luminanceSquaredSum / count - mean * mean)
        // Measure glyph darkness relative to the crop exposure. This remains
        // useful in shade and avoids an absolute-black assumption while the
        // yellow chroma gate independently rejects gray indoor rectangles.
        let darkThreshold = min(0.42, max(0.10, mean * 0.55))
        var darkPerBand = [Int](repeating: 0, count: horizontalBands)
        var darkPerRowBand = [Int](repeating: 0, count: verticalBands)
        for sample in luminanceSamples where sample.value < darkThreshold {
            darkPixels += 1
            darkPerBand[sample.horizontalBand] += 1
            darkPerRowBand[sample.verticalBand] += 1
        }
        let coveredBands = darkPerBand.indices.count { index in
            samplesPerBand[index] > 0
                && CGFloat(darkPerBand[index]) / CGFloat(samplesPerBand[index]) >= 0.025
        }
        let coveredRowBands = darkPerRowBand.indices.count { index in
            samplesPerRowBand[index] > 0
                && CGFloat(darkPerRowBand[index]) / CGFloat(samplesPerRowBand[index]) >= 0.02
        }
        return PlateAppearanceScore(
            yellowFraction: CGFloat(yellowPixels) / count,
            darkFraction: CGFloat(darkPixels) / count,
            darkBandCoverage: CGFloat(coveredBands) / CGFloat(horizontalBands),
            darkRowCoverage: CGFloat(coveredRowBands) / CGFloat(verticalBands),
            luminanceDeviation: sqrt(variance)
        )
    }

    private func isYellow(red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let greenRedBalance = green / max(red, 0.001)
        guard maximum >= 0.34,
              delta / max(maximum, 0.001) >= 0.20,
              (0.65...1.30).contains(greenRedBalance),
              blue <= min(red, green) * 0.68 else { return false }

        let rawHue: CGFloat
        if maximum == red {
            rawHue = 60 * ((green - blue) / max(delta, 0.001)).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            rawHue = 60 * ((blue - red) / max(delta, 0.001) + 2)
        } else {
            rawHue = 60 * ((red - green) / max(delta, 0.001) + 4)
        }
        let hue = rawHue < 0 ? rawHue + 360 : rawHue
        return (28...75).contains(hue)
    }
}
