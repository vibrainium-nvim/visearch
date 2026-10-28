/// Result of matching a fuzzy query against a candidate text.
class FuzzyMatch {
  final int score;
  final List<int> matchIndices;

  const FuzzyMatch({
    required this.score,
    required this.matchIndices,
  });
}

/// Fast fzy/fzf-inspired subsequence scorer with word-boundary, camelCase,
/// consecutive-character, and filename bonuses.
class FuzzyMatcher {
  /// Matches [query] against [candidate].
  /// Returns `null` if [query] is not a subsequence of [candidate].
  static FuzzyMatch? match(String query, String candidate) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const FuzzyMatch(score: 0, matchIndices: []);
    }

    // Support space-separated tokens: all tokens must match as subsequences.
    final tokens = trimmed
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) {
      return const FuzzyMatch(score: 0, matchIndices: []);
    }

    var totalScore = 0;
    final matchedSet = <int>{};

    for (final token in tokens) {
      final sub = _matchSingleToken(token, candidate);
      if (sub == null) return null;
      totalScore += sub.score;
      matchedSet.addAll(sub.matchIndices);
    }

    final indices = matchedSet.toList()..sort();
    return FuzzyMatch(score: totalScore, matchIndices: indices);
  }

  static FuzzyMatch? _matchSingleToken(String token, String candidate) {
    final qLen = token.length;
    final cLen = candidate.length;
    if (qLen == 0) return const FuzzyMatch(score: 0, matchIndices: []);
    if (qLen > cLen) return null;

    final qLower = token.toLowerCase();
    final cLower = candidate.toLowerCase();

    // Fast subsequence pre-check and forward match
    var qi = 0;
    for (var ci = 0; ci < cLen && qi < qLen; ci++) {
      if (cLower.codeUnitAt(ci) == qLower.codeUnitAt(qi)) {
        qi++;
      }
    }
    if (qi < qLen) return null;

    final lastSlash = candidate.lastIndexOf('/');
    final filenameStart = lastSlash + 1;

    // Prefer matching inside the filename portion if the whole token fits there
    List<int>? bestIndices;
    if (filenameStart > 0 && cLen - filenameStart >= qLen) {
      bestIndices = _findBestAlignment(
        qLower,
        cLower,
        candidate,
        startOffset: filenameStart,
      );
    }
    bestIndices ??= _findBestAlignment(
      qLower,
      cLower,
      candidate,
      startOffset: 0,
    );
    if (bestIndices == null) return null;

    final score = _scoreIndices(
      token,
      candidate,
      bestIndices,
      filenameStart: filenameStart,
    );
    return FuzzyMatch(score: score, matchIndices: bestIndices);
  }

  static List<int>? _findBestAlignment(
    String qLower,
    String cLower,
    String candidate, {
    required int startOffset,
  }) {
    final qLen = qLower.length;
    final cLen = cLower.length;

    // Check if subsequence exists starting at startOffset
    var qi = 0;
    var lastMatchEnd = -1;
    for (var ci = startOffset; ci < cLen; ci++) {
      if (cLower.codeUnitAt(ci) == qLower.codeUnitAt(qi)) {
        qi++;
        if (qi == qLen) {
          lastMatchEnd = ci;
          break;
        }
      }
    }
    if (qi < qLen) return null;

    // Walk backwards from lastMatchEnd to tighten the match span, while
    // preferring boundary positions when equally tight.
    final forwardIndices = List<int>.filled(qLen, 0);
    qi = 0;
    for (var ci = startOffset; ci < cLen && qi < qLen; ci++) {
      if (cLower.codeUnitAt(ci) == qLower.codeUnitAt(qi)) {
        // If we haven't matched this qi yet, or if a later position is a boundary
        forwardIndices[qi] = ci;
        qi++;
      }
    }

    final backwardIndices = List<int>.filled(qLen, 0);
    qi = qLen - 1;
    for (var ci = lastMatchEnd; ci >= startOffset && qi >= 0; ci--) {
      if (cLower.codeUnitAt(ci) == qLower.codeUnitAt(qi)) {
        backwardIndices[qi] = ci;
        qi--;
      }
    }

    final filenameStart = candidate.lastIndexOf('/') + 1;
    final fScore = _scoreIndices(
      qLower,
      candidate,
      forwardIndices,
      filenameStart: filenameStart,
    );
    final bScore = _scoreIndices(
      qLower,
      candidate,
      backwardIndices,
      filenameStart: filenameStart,
    );

    return bScore >= fScore ? backwardIndices : forwardIndices;
  }

  static int _scoreIndices(
    String token,
    String candidate,
    List<int> indices, {
    required int filenameStart,
  }) {
    var score = 100;
    for (var i = 0; i < indices.length; i++) {
      final idx = indices[i];
      score += 10;

      // Exact case bonus
      if (token.codeUnitAt(i) == candidate.codeUnitAt(idx)) {
        score += 4;
      }

      // Filename bonus
      if (idx >= filenameStart) {
        score += 18;
        if (idx == filenameStart) {
          score += 30;
        }
      }

      // Word boundary / camelCase bonus
      if (_isBoundary(candidate, idx)) {
        score += 24;
      }

      // Consecutive match bonus
      if (i > 0) {
        final prev = indices[i - 1];
        if (idx == prev + 1) {
          score += 32;
        } else {
          final gap = idx - prev - 1;
          score -= gap.clamp(1, 15) * 2;
        }
      }
    }

    // Prefer shorter candidates overall
    score -= (candidate.length ~/ 4);
    return score;
  }

  static bool _isBoundary(String text, int index) {
    if (index == 0) return true;
    final prev = text.codeUnitAt(index - 1);
    final curr = text.codeUnitAt(index);

    // After '/', '\', '_', '-', '.', ' ', ':'
    if (prev == 0x2F ||
        prev == 0x5C ||
        prev == 0x5F ||
        prev == 0x2D ||
        prev == 0x2E ||
        prev == 0x20 ||
        prev == 0x3A) {
      return true;
    }

    // camelCase transition: lower -> UPPER
    final prevIsLower = prev >= 0x61 && prev <= 0x7A;
    final currIsUpper = curr >= 0x41 && curr <= 0x5A;
    return prevIsLower && currIsUpper;
  }
}
