import 'dart:io';

import 'package:test/test.dart';
import 'package:visearch/visearch.dart';

void main() {
  group('GlobMatcher & SearchScope', () {
    test('matches comma-separated relative paths, wildcards, and negations', () {
      final scope = SearchScope.customGlob(
        'vivcs/lib, **/test/*_test.dart, !vivcs/lib/generated/**',
      );

      expect(
        scope.matchesPath('/ws', '/ws/vivcs/lib/src/ui/sidebar.dart'),
        isTrue,
      );
      expect(
        scope.matchesPath('/ws', '/ws/vivcs/lib/generated/foo.dart'),
        isFalse,
      );
      expect(
        scope.matchesPath('/ws', '/ws/nvim/test/rpc_session_test.dart'),
        isTrue,
      );
      expect(
        scope.matchesPath('/ws', '/ws/nvim/lib/src/nvim_client.dart'),
        isFalse,
      );
    });

    test('honors VibrainiumSettings workspace.exclude', () {
      final settings = VibrainiumSettings.fromExcludeList([
        '**/generated/**',
        '*.g.dart',
      ]);
      const scope = SearchScope.workspace();

      expect(
        scope.matchesPath(
          '/ws',
          '/ws/vivcs/lib/vivcs.dart',
          settings: settings,
        ),
        isTrue,
      );
      expect(
        scope.matchesPath(
          '/ws',
          '/ws/vivcs/lib/generated/model.dart',
          settings: settings,
        ),
        isFalse,
      );
      expect(
        scope.matchesPath(
          '/ws',
          '/ws/vivcs/lib/user.g.dart',
          settings: settings,
        ),
        isFalse,
      );
    });

    test('buildRgArgs produces -g arguments for subproject and customGlob', () {
      final subScope = SearchScope.subproject('vivcs');
      expect(subScope.buildRgArgs(), equals(['-g', 'vivcs/**']));

      final customScope = SearchScope.customGlob('nvim/lib, !**/test/**');
      expect(
        customScope.buildRgArgs(),
        equals(['-g', 'nvim/lib', '-g', 'nvim/lib/**', '-g', '!**/test/**']),
      );
    });

    test('discoverSubprojects finds nested packages in monorepo', () async {
      final tempDir = await Directory.systemTemp.createTemp('visearch_scope_');
      try {
        await Directory('${tempDir.path}/pkg_a').create(recursive: true);
        await File('${tempDir.path}/pkg_a/pubspec.yaml').writeAsString('name: a');

        await Directory('${tempDir.path}/packages/pkg_b').create(recursive: true);
        await File('${tempDir.path}/packages/pkg_b/package.json')
            .writeAsString('{}');

        await Directory('${tempDir.path}/.git').create(recursive: true);
        await Directory('${tempDir.path}/plain_folder').create(recursive: true);

        final subs = await discoverSubprojects(tempDir);
        expect(subs, equals(['packages/pkg_b', 'pkg_a']));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
