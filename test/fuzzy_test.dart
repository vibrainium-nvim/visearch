import 'package:test/test.dart';
import 'package:visearch/visearch.dart';

void main() {
  group('FuzzyMatcher', () {
    test('returns null when query is not a subsequence', () {
      expect(FuzzyMatcher.match('xyz', 'nvim/lib/src/nvim_client.dart'), isNull);
    });

    test('matches subsequence and returns sorted match indices', () {
      final res = FuzzyMatcher.match('nvc', 'nvim/lib/src/nvim_client.dart');
      expect(res, isNotNull);
      expect(res!.matchIndices, hasLength(3));
      expect(res.score, greaterThan(0));
    });

    test('ranks filename match higher than directory-only match', () {
      final fileMatch =
          FuzzyMatcher.match('sidebar', 'vivcs/lib/src/ui/sidebar.dart');
      final dirMatch =
          FuzzyMatcher.match('sidebar', 'sidebar_tools/lib/src/helper.dart');
      expect(fileMatch, isNotNull);
      expect(dirMatch, isNotNull);
      expect(fileMatch!.score, greaterThan(dirMatch!.score));
    });

    test('supports multi-token space-separated queries', () {
      final match =
          FuzzyMatcher.match('vivcs side', 'vivcs/lib/src/ui/sidebar.dart');
      final nonMatch =
          FuzzyMatcher.match('vivcs nope', 'vivcs/lib/src/ui/sidebar.dart');
      expect(match, isNotNull);
      expect(nonMatch, isNull);
    });
  });
}
