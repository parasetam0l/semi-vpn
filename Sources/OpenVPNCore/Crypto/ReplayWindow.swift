import Foundation

/// Sliding-window replay filter for the data channel, following OpenVPN's
/// `packet_id.c`: the highest accepted packet-id is tracked together with a
/// bitmap of the `windowSize` ids below it.
///
/// - A new highest id shifts the window and is accepted.
/// - An id inside the window is accepted once; duplicates are rejected.
/// - An id older than the window is rejected outright.
public struct ReplayWindow: Sendable, Equatable {
    public let windowSize: Int
    private var words: [UInt64]
    private var highest: UInt64?

    /// - Parameter windowSize: number of past ids remembered (OpenVPN's
    ///   default `replay-window 64`, clamped to the protocol's 8..32768).
    public init(windowSize: Int = 64) {
        let size = max(8, min(windowSize, 32768))
        self.windowSize = size
        self.words = [UInt64](repeating: 0, count: (size + 63) / 64)
    }

    /// Returns true when the packet-id is new and marks it as seen.
    public mutating func accept(_ packetID: UInt64) -> Bool {
        guard let high = highest else {
            highest = packetID
            set(age: 0)
            return true
        }
        if packetID > high {
            let shift = packetID - high
            if shift >= UInt64(windowSize) {
                words = [UInt64](repeating: 0, count: words.count)
            } else {
                shiftRight(by: shift)
            }
            highest = packetID
            set(age: 0)
            return true
        }
        // packetID <= high: age 0 is a duplicate of the current highest.
        let age = high - packetID
        guard age < UInt64(windowSize) else { return false }
        guard !test(age: age) else { return false }
        set(age: age)
        return true
    }

    /// Clears all state (used when the data-channel keys are replaced).
    public mutating func reset() {
        words = [UInt64](repeating: 0, count: words.count)
        highest = nil
    }

    // MARK: - Bitmap (bit i of the bit array represents `highest - i`)

    private func contains(age: UInt64) -> (word: Int, bit: Int) {
        (Int(age / 64), Int(age % 64))
    }

    private func test(age: UInt64) -> Bool {
        let (word, bit) = contains(age: age)
        guard word < words.count else { return false }
        return words[word] & (1 << UInt64(bit)) != 0
    }

    private mutating func set(age: UInt64) {
        let (word, bit) = contains(age: age)
        guard word < words.count else { return }
        words[word] |= 1 << UInt64(bit)
    }

    /// Moves every recorded id `shift` slots deeper into the window
    /// (the ids that fall past the window edge are forgotten).
    private mutating func shiftRight(by shift: UInt64) {
        let wordShift = Int(shift / 64)
        let bitShift = Int(shift % 64)
        guard wordShift < words.count else {
            words = [UInt64](repeating: 0, count: words.count)
            return
        }
        // Ages grow, so bits move toward higher bit positions: the bit
        // array as a big-endian-age number is shifted left by `shift`.
        var newWords = [UInt64](repeating: 0, count: words.count)
        for index in 0..<words.count {
            let source = index - wordShift
            var value: UInt64 = 0
            if source >= 0 {
                value = words[source] << bitShift
            }
            if bitShift > 0, source > 0 {
                value |= words[source - 1] >> (64 - UInt64(bitShift))
            }
            newWords[index] = value
        }
        words = newWords
    }
}
