/// The palette's fuzzy match (UX §10): the query's characters in order, ignoring case. A prefix beats a
/// word start, which beats a scattered subsequence; within a tier, tighter and earlier matches score higher.
nonisolated struct FuzzyMatch: Equatable, Sendable {
    let score: Int
    /// Offsets of the matched characters in the text, for highlighting.
    let indices: [Int]

    private static let prefixTier = 3000
    private static let wordStartTier = 2000
    private static let subsequenceTier = 1000

    /// The match of `query` in `text`, or nil when the characters don't all appear in order. An empty query
    /// matches everything with score 0.
    static func match(_ query: String, in text: String) -> FuzzyMatch? {
        let needle = query.lowercased().filter { !$0.isWhitespace }.map { $0 }
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, indices: []) }
        let characters = Array(text)
        let haystack = characters.map { Character($0.lowercased()) }
        guard needle.count <= haystack.count else { return nil }

        if haystack.starts(with: needle) {
            return FuzzyMatch(
                score: prefixTier - haystack.count, indices: Array(0..<needle.count))
        }
        let starts = wordStarts(characters)
        for start in starts where haystack[start...].starts(with: needle) {
            return FuzzyMatch(
                score: wordStartTier - start * 4 - haystack.count, indices: Array(start..<start + needle.count))
        }
        return subsequence(needle, haystack, starts: Set(starts))
    }

    /// Greedy left to right, preferring a word start over an earlier plain character when both lie before
    /// the next needed character.
    private static func subsequence(_ needle: [Character], _ haystack: [Character], starts: Set<Int>) -> FuzzyMatch? {
        var indices: [Int] = []
        var position = 0
        for (offset, wanted) in needle.enumerated() {
            let remaining = needle.count - offset - 1
            let limit = haystack.count - remaining
            guard position < limit else { return nil }
            var found: Int?
            for index in position..<limit where haystack[index] == wanted {
                if found == nil { found = index }
                if starts.contains(index) {
                    found = index
                    break
                }
                // Keep a contiguous run rather than jumping to a later word start.
                if index == position, offset > 0 { break }
            }
            guard let index = found else { return nil }
            indices.append(index)
            position = index + 1
        }
        var score = subsequenceTier
        for (offset, index) in indices.enumerated() {
            if starts.contains(index) { score += 12 }
            if offset > 0, indices[offset - 1] == index - 1 { score += 8 }
        }
        score -= (indices.last ?? 0) - (indices.first ?? 0)
        score -= indices.first ?? 0
        return FuzzyMatch(score: score, indices: indices)
    }

    /// Offsets that start a word: the first character, one after a separator, and an uppercase letter after
    /// a lowercase one (camelCase).
    private static func wordStarts(_ characters: [Character]) -> [Int] {
        var result: [Int] = []
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else { continue }
            if index == 0 {
                result.append(index)
                continue
            }
            let previous = characters[index - 1]
            if !(previous.isLetter || previous.isNumber) || (previous.isLowercase && character.isUppercase) {
                result.append(index)
            }
        }
        return result
    }
}
