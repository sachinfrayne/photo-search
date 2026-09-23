// CLIP byte-level BPE tokenizer.
//
// Adapted from Hugging Face's swift-coreml-transformers (Apache-2.0), as
// shipped in Apple's ml-mobileclip demo app (MIT):
// https://github.com/apple/ml-mobileclip/tree/main/ios_app/MobileCLIPExplore/Tokenizer

import Foundation

final class CLIPTokenizer: @unchecked Sendable {
    private struct Pair: Hashable {
        let a: String
        let b: String
    }

    static let contextLength = 77

    private let ranks: [Pair: Int]
    private let vocab: [String: Int]
    private let startToken: Int
    private let endToken: Int
    private let byteEncoder: [UInt8: String] = CLIPTokenizer.makeByteEncoder()
    private let pattern = try! NSRegularExpression(
        pattern: "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
    )
    private var cache: [String: [String]] = [:]
    private let lock = NSLock()

    init(vocabURL: URL, mergesURL: URL) throws {
        vocab = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocabURL))
        let lines = try String(contentsOf: mergesURL, encoding: .utf8).split(separator: "\n")
        var ranks: [Pair: Int] = [:]
        // First line is a "#version" header.
        for (i, line) in lines.dropFirst().enumerated() {
            let parts = line.split(separator: " ")
            if parts.count == 2 { ranks[Pair(a: String(parts[0]), b: String(parts[1]))] = i }
        }
        self.ranks = ranks
        startToken = vocab["<|startoftext|>"]!
        endToken = vocab["<|endoftext|>"]!
    }

    /// Token ids padded (with zeros) to the model's 77-token context.
    func encode(_ text: String) -> [Int32] {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let ns = cleaned as NSString
        var ids: [Int] = []
        for match in pattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range)
            let encoded = word.utf8.map { byteEncoder[$0]! }.joined()
            ids += bpe(encoded).compactMap { vocab[$0] }
        }
        ids = Array(ids.prefix(Self.contextLength - 2))

        var out = [Int32](repeating: 0, count: Self.contextLength)
        out[0] = Int32(startToken)
        for (i, id) in ids.enumerated() { out[i + 1] = Int32(id) }
        out[ids.count + 1] = Int32(endToken)
        return out
    }

    private func bpe(_ token: String) -> [String] {
        if let hit = lock.withLock({ cache[token] }) { return hit }

        var word = token.map { String($0) }
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(word.count - 1) {
                if let r = ranks[Pair(a: word[i], b: word[i + 1])], r < (best?.rank ?? .max) {
                    best = (r, i)
                }
            }
            guard let best else { break }
            let first = word[best.index], second = word[best.index + 1]
            // Merge every occurrence of the winning pair in one pass.
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == first && word[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }
        lock.withLock { cache[token] = word }
        return word
    }

    /// GPT-2's reversible byte → printable-unicode mapping.
    private static func makeByteEncoder() -> [UInt8: String] {
        var printable = Array(33...126) + Array(161...172) + Array(174...255)
        var codepoints = printable
        var n = 0
        for b in 0...255 where !printable.contains(b) {
            printable.append(b)
            codepoints.append(256 + n)
            n += 1
        }
        var out: [UInt8: String] = [:]
        for (b, c) in zip(printable, codepoints) {
            out[UInt8(b)] = String(Character(Unicode.Scalar(c)!))
        }
        return out
    }
}
