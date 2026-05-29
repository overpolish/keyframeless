/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

/// VSCode/Git-style two-stage diff:
/// 1. Word-level LCS (tokens = runs of word chars vs runs of non-word chars).
/// 2. Within each adjacent remove+insert "change block", refine with
///    character-level diff IF the two sides share a meaningful longest common
///    substring; otherwise emit the whole block as removed+inserted.
/// Highlighting is background-only, like VSCode's inline diff.
enum AIWordDiff {
	struct Result {
		let originalAttributed: Text
		let resultAttributed: Text
	}

	private static let removedBG = Color.kkError.opacity(0.25)
	private static let insertedBG = Color.kkSuccess.opacity(0.25)

	static func counts(original: String, result: String) -> (added: Int, removed: Int) {
		let ops = lcs(Array(original).map { String($0) }, Array(result).map { String($0) })
		var added = 0
		var removed = 0
		for op in ops {
			switch op {
			case .equal: break
			case .insert(let s): added += s.count
			case .remove(let s): removed += s.count
			}
		}
		return (added, removed)
	}

	static func diff(original: String, result: String) -> Result {
		let aTokens = tokenize(original)
		let bTokens = tokenize(result)
		let ops = lcs(aTokens, bTokens)

		var orig = AttributedString()
		var res = AttributedString()

		var i = 0
		while i < ops.count {
			switch ops[i] {
			case .equal(let t):
				orig.append(span(t, background: nil))
				res.append(span(t, background: nil))
				i += 1
			case .remove, .insert:
				var removed = ""
				var inserted = ""
				loop: while i < ops.count {
					switch ops[i] {
					case .remove(let t):
						removed += t
						i += 1
					case .insert(let t):
						inserted += t
						i += 1
					case .equal: break loop
					}
				}
				refine(removed: removed, inserted: inserted, orig: &orig, res: &res)
			}
		}

		return Result(originalAttributed: Text(orig), resultAttributed: Text(res))
	}

	private static func refine(
		removed: String, inserted: String, orig: inout AttributedString,
		res: inout AttributedString
	) {
		let aChars = Array(removed)
		let bChars = Array(inserted)
		let lcsLen = longestCommonSubstring(aChars, bChars)
		let minLen = min(aChars.count, bChars.count)
		let shouldCharDiff = minLen >= 2 && lcsLen >= 2 && Double(lcsLen) / Double(minLen) >= 0.4

		if !shouldCharDiff {
			if !removed.isEmpty { orig.append(span(removed, background: removedBG)) }
			if !inserted.isEmpty { res.append(span(inserted, background: insertedBG)) }
			return
		}

		let charOps = lcs(aChars.map { String($0) }, bChars.map { String($0) })
		for op in charOps {
			switch op {
			case .equal(let c):
				orig.append(span(c, background: nil))
				res.append(span(c, background: nil))
			case .remove(let c):
				orig.append(span(c, background: removedBG))
			case .insert(let c):
				res.append(span(c, background: insertedBG))
			}
		}
	}

	private static func span(_ s: String, background: Color?) -> AttributedString {
		var a = AttributedString(s)
		a.foregroundColor = .primary
		if let background { a.backgroundColor = background }
		return a
	}

	private static func tokenize(_ s: String) -> [String] {
		var tokens: [String] = []
		var current = ""
		var currentIsWord: Bool? = nil
		for ch in s {
			let isWord = ch.isLetter || ch.isNumber
			if currentIsWord == nil || currentIsWord == isWord {
				current.append(ch)
				currentIsWord = isWord
			} else {
				tokens.append(current)
				current = String(ch)
				currentIsWord = isWord
			}
		}
		if !current.isEmpty { tokens.append(current) }
		return tokens
	}

	private enum Op {
		case equal(String)
		case remove(String)
		case insert(String)
	}

	private static func lcs(_ a: [String], _ b: [String]) -> [Op] {
		let n = a.count
		let m = b.count
		if n == 0 && m == 0 { return [] }
		var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
		for i in stride(from: n - 1, through: 0, by: -1) {
			for j in stride(from: m - 1, through: 0, by: -1) {
				if a[i] == b[j] {
					dp[i][j] = dp[i + 1][j + 1] + 1
				} else {
					dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
				}
			}
		}
		var ops: [Op] = []
		var i = 0
		var j = 0
		while i < n && j < m {
			if a[i] == b[j] {
				ops.append(.equal(a[i]))
				i += 1
				j += 1
			} else if dp[i + 1][j] >= dp[i][j + 1] {
				ops.append(.remove(a[i]))
				i += 1
			} else {
				ops.append(.insert(b[j]))
				j += 1
			}
		}
		while i < n {
			ops.append(.remove(a[i]))
			i += 1
		}
		while j < m {
			ops.append(.insert(b[j]))
			j += 1
		}
		return ops
	}

	private static func longestCommonSubstring(_ a: [Character], _ b: [Character]) -> Int {
		if a.isEmpty || b.isEmpty { return 0 }
		var prev = [Int](repeating: 0, count: b.count + 1)
		var curr = [Int](repeating: 0, count: b.count + 1)
		var best = 0
		for i in 1...a.count {
			for j in 1...b.count {
				if a[i - 1] == b[j - 1] {
					curr[j] = prev[j - 1] + 1
					if curr[j] > best { best = curr[j] }
				} else {
					curr[j] = 0
				}
			}
			swap(&prev, &curr)
			for k in 0..<curr.count { curr[k] = 0 }
		}
		return best
	}
}
