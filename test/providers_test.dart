import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:visearch/visearch.dart';

void main() {
  group('FilesProvider', () {
    test('uses rg --files, caches file list, and filters by scope & query', () async {
      var calls = 0;
      final provider = FilesProvider(
        runProcess: (exe, args, {workingDirectory}) async {
          calls++;
          expect(exe, 'rg');
          expect(args, contains('--files'));
          return ProcessResult(
            1,
            0,
            'nvim/lib/src/nvim_client.dart\n'
            'vivcs/lib/src/ui/sidebar.dart\n'
            'vivcs/test/sidebar_test.dart\n',
            '',
          );
        },
      );

      final (allItems, totalAll) = await provider.search(
        workspaceRoot: '/ws',
        query: '',
        scope: const SearchScope.workspace(),
      );
      expect(totalAll, 3);
      expect(allItems, hasLength(3));
      expect(calls, 1);

      // Subsequent search uses cached file list without spawning rg again
      final (subItems, totalSub) = await provider.search(
        workspaceRoot: '/ws',
        query: 'test',
        scope: SearchScope.subproject('vivcs'),
      );
      expect(calls, 1);
      expect(totalSub, 2);
      expect(subItems, hasLength(1));
      expect(subItems.first.relativePath, 'vivcs/test/sidebar_test.dart');
    });
  });

  group('TextProvider', () {
    test('runs rg --vimgrep with scope globs and parses results', () async {
      List<String>? capturedArgs;
      final provider = TextProvider(
        runProcess: (exe, args, {workingDirectory}) async {
          capturedArgs = args;
          return ProcessResult(
            1,
            0,
            'vivcs/lib/src/ui/sidebar.dart:50:18:  Future<Object?> handleAction(String action) async {\n'
            'nvim/lib/src/nvim_client.dart:12:5:  void ignoredByScope() {}\n',
            '',
          );
        },
      );

      final results = await provider.search(
        workspaceRoot: '/ws',
        query: 'handleAction',
        scope: SearchScope.subproject('vivcs'),
      );

      expect(capturedArgs, isNotNull);
      expect(capturedArgs, contains('--vimgrep'));
      expect(capturedArgs, contains('vivcs/**'));
      expect(results, hasLength(1));
      expect(results.first.relativePath, 'vivcs/lib/src/ui/sidebar.dart');
      expect(results.first.line, 50);
      expect(results.first.col, 17);
      expect(results.first.badge, '50:18');
    });

    test('searches currentBufferLines in memory when scope is currentBuffer', () async {
      final provider = TextProvider(
        runProcess: (exe, args, {workingDirectory}) async {
          fail('Should not spawn rg when currentBufferLines is provided');
        },
      );

      final results = await provider.search(
        workspaceRoot: '/ws',
        query: 'hello',
        scope: SearchScope.currentBuffer('/ws/vivcs/lib/a.dart'),
        currentBufferLines: const [
          'void main() {',
          '  print("hello world");',
          '}',
        ],
      );

      expect(results, hasLength(1));
      expect(results.first.line, 2);
      expect(results.first.col, 9);
    });
  });

  group('SymbolsProvider', () {
    test('queries Neovim LSP via execLua and filters by scope and fuzzy query', () async {
      final toClient = StreamController<List<int>>();
      final fromClient = StreamController<List<int>>();
      final server = RpcSession(
        input: fromClient.stream,
        output: (Uint8List b) => toClient.add(b),
      );
      final client = RpcSession(
        input: toClient.stream,
        output: (Uint8List b) => fromClient.add(b),
      );

      server.onRequest = (method, params) async {
        if (method == 'nvim_exec_lua') {
          return [
            {
              'name': 'ViffSidebar',
              'kind': 'Class',
              'file': '/ws/vivcs/lib/src/ui/sidebar.dart',
              'line': 10,
              'col': 6,
            },
            {
              'name': 'Nvim',
              'kind': 'Class',
              'file': '/ws/nvim/lib/src/nvim_client.dart',
              'line': 5,
              'col': 6,
            },
          ];
        }
        return null;
      };

      const provider = SymbolsProvider();
      final results = await provider.search(
        nvim: Nvim(client),
        workspaceRoot: '/ws',
        query: 'Sidebar',
        scope: SearchScope.subproject('vivcs'),
        originBuf: 1,
      );

      expect(results, hasLength(1));
      expect(results.first.symbolKind, 'Class');
      expect(results.first.badge, '[Class]');
      expect(results.first.line, 10);

      await client.close();
      await server.close();
      await toClient.close();
      await fromClient.close();
    });
  });
}
