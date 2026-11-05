import AppKit
import Vision

/// The text found in a photo, with a box for every character, so a drag over
/// the picture picks out the words under it, the way Live Text does. Vision
/// hands back whole lines; the per-character boxes come from it too, so a
/// partly picked line reads and copies exactly as far as it was picked.
final class PhotoText {
    struct Line {
        /// The line as Vision read it.
        let text: String
        /// Where the whole line sits, in the picture's own coordinates
        /// (0…1, origin at the bottom left), for the standing highlight.
        let box: CGRect
        /// One box per character, and the character it belongs to.
        let characters: [(range: Range<String.Index>, box: CGRect)]
    }

    let lines: [Line]

    init(lines: [Line]) {
        self.lines = lines
    }

    /// Reads the text in the picture, off the main thread. Nil when there is
    /// none, so nothing is highlighted over a photo of a beach.
    static func read(_ image: NSImage, then: @escaping @MainActor (PhotoText?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = scan(image)
            DispatchQueue.main.async { MainActor.assumeIsolated { then(text) } }
        }
    }

    private static func scan(_ image: NSImage) -> PhotoText? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        // Reading order: top to bottom, and left to right within a line.
        let observations = (request.results ?? []).sorted { a, b in
            if abs(a.boundingBox.maxY - b.boundingBox.maxY) > 0.01 {
                return a.boundingBox.maxY > b.boundingBox.maxY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        var lines: [Line] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            var characters: [(Range<String.Index>, CGRect)] = []
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(after: index)
                if let box = try? candidate.boundingBox(for: index..<next) {
                    characters.append((index..<next, box.boundingBox))
                }
                index = next
            }
            guard !characters.isEmpty else { continue }
            lines.append(Line(text: text, box: observation.boundingBox, characters: characters))
        }
        return lines.isEmpty ? nil : PhotoText(lines: lines)
    }

    /// The text inside a pick, in the picture's coordinates, and the boxes of
    /// the characters to draw over it. Characters that touched the pick are
    /// joined along each line, and separate lines go on separate rows.
    func pick(in rect: CGRect) -> (text: String, boxes: [CGRect]) {
        var picked: [String] = []
        var boxes: [CGRect] = []
        for line in lines {
            var words: [String] = []
            var run: Range<String.Index>?
            for character in line.characters where character.box.intersects(rect) {
                if let current = run, current.upperBound == character.range.lowerBound {
                    run = current.lowerBound..<character.range.upperBound
                } else {
                    if let current = run { words.append(String(line.text[current])) }
                    run = character.range
                }
                boxes.append(character.box)
            }
            if let current = run { words.append(String(line.text[current])) }
            if !words.isEmpty { picked.append(words.joined(separator: " ")) }
        }
        return (picked.joined(separator: "\n"), boxes)
    }

    /// Whether a point in the picture's coordinates lands on a line of text,
    /// with a little room around it so the ends of a line are easy to catch.
    func hasText(at point: CGPoint) -> Bool {
        lines.contains { $0.box.insetBy(dx: -0.004, dy: -0.006).contains(point) }
    }
}
