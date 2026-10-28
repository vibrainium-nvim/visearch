import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:visearch/visearch.dart';

void main() {
  group('VisearchPicker', () {
    late StreamController<List<int>> toClient;
    late StreamController<List<int>> fromClient;
    late RpcSession serverSession;
    late RpcSession clientSession;
    late Nvim nvim;
    late Directory tempWs;
    late VisearchPicker picker;

    final commands = <String>[];
    final cursors = <int, (int, int)>{};
    final bufferLines = <int, List<String>>{};
    final winOptions = <int, Map<String, Object?>>{};
    final validWins = <int>{1};
    final validBufs = <int>{1};
    var nextHandle = 10;
    var currentWin = 1;
    var currentBuf = 1;

    setUp(() async {
      commands.clear();
      cursors.clear();
      bufferLines.clear();
      winOptions.clear();
      validWins
        ..clear()
        ..add(1);
      validBufs
        ..clear()
        ..add(1);
      nextHandle = 10;
      currentWin = 1;
      currentBuf = 1;

      tempWs = await Directory.systemTemp.createTemp('visearch_picker_test_');
      await Directory('${tempWs.path}/vivcs/lib').create(recursive: true);
      await File('${tempWs.path}/vivcs/pubspec.yaml')
          .writeAsString('name: vivcs\n');
      await File('${tempWs.path}/vivcs/lib/a.dart')
          .writeAsString('class Alpha {\n  void run() {}\n}\n');
      await Directory('${tempWs.path}/nvim/lib').create(recursive: true);
      await File('${tempWs.path}/nvim/pubspec.yaml')
          .writeAsString('name: nvim\n');
      await File('${tempWs.path}/nvim/lib/b.dart')
          .writeAsString('class Beta {}\n');

      bufferLines[1] = ['class Alpha {', '  void run() {}', '}'];

      toClient = StreamController<List<int>>();
      fromClient = StreamController<List<int>>();
      serverSession = RpcSession(
        input: fromClient.stream,
        output: (Uint8List b) => toClient.add(b),
      );
      clientSession = RpcSession(
        input: toClient.stream,
        output: (Uint8List b) => fromClient.add(b),
      );
      nvim = Nvim(clientSession);

      serverSession.onRequest = (method, params) async {
        switch (method) {
          case 'nvim_create_namespace':
            return 1;
          case 'nvim_buf_set_extmark':
            return 1;
          case 'nvim_create_buf':
            final id = ++nextHandle;
            validBufs.add(id);
            bufferLines[id] = [''];
            return id;
          case 'nvim_buf_is_valid':
            return validBufs.contains(params[0] as int);
          case 'nvim_buf_set_lines':
            final b = params[0] as int;
            final lines =
                (params[4] as List).map((e) => e.toString()).toList();
            bufferLines[b] = lines;
            return null;
          case 'nvim_buf_get_lines':
            final b = params[0] as int;
            return bufferLines[b] ?? <String>[''];
          case 'nvim_buf_get_name':
            final b = params[0] as int;
            return b == 1 ? '${tempWs.path}/vivcs/lib/a.dart' : '';
          case 'nvim_open_win':
            final id = ++nextHandle;
            validWins.add(id);
            cursors[id] = (1, 0);
            if (params[1] == true) {
              currentWin = id;
            }
            return id;
          case 'nvim_win_is_valid':
            return validWins.contains(params[0] as int);
          case 'nvim_win_close':
            validWins.remove(params[0] as int);
            return null;
          case 'nvim_set_option_value':
            final name = params[0].toString();
            final value = params[1];
            final opts = (params[2] as Map).cast<String, Object?>();
            if (opts.containsKey('win')) {
              final w = opts['win'] as int;
              winOptions.putIfAbsent(w, () => {})[name] = value;
            }
            return null;
          case 'nvim_win_get_cursor':
            final w = params[0] as int;
            final c = cursors[w] ?? (1, 0);
            return [c.$1, c.$2];
          case 'nvim_win_set_cursor':
            final w = params[0] as int;
            final pos = params[1] as List;
            cursors[w] = (pos[0] as int, pos[1] as int);
            return null;
          case 'nvim_get_current_win':
            return currentWin;
          case 'nvim_set_current_win':
            currentWin = params[0] as int;
            return null;
          case 'nvim_get_current_buf':
            return currentBuf;
          case 'nvim_call_function':
            if (params[0] == 'getcwd') {
              return tempWs.path;
            }
            return null;
          case 'nvim_get_option_value':
            if (params[0] == 'columns') return 120;
            if (params[0] == 'lines') return 40;
            return null;
          case 'nvim_command':
            commands.add(params[0].toString());
            return null;
          case 'nvim_exec_lua':
            final code = params[0].toString();
            if (code.contains('textDocument/documentSymbol')) {
              return [
                {
                  'name': 'Alpha',
                  'kind': 'Class',
                  'file': '${tempWs.path}/vivcs/lib/a.dart',
                  'line': 1,
                  'col': 6,
                },
                {
                  'name': 'Beta',
                  'kind': 'Class',
                  'file': '${tempWs.path}/nvim/lib/b.dart',
                  'line': 1,
                  'col': 6,
                },
              ];
            }
            if (code.contains('getmousepos')) {
              return {'screencol': 42, 'screenrow': 15};
            }
            return null;
          default:
            return null;
        }
      };

      picker = VisearchPicker(
        nvim: nvim,
        filesProvider: FilesProvider(
          runProcess: (exe, args, {workingDirectory}) async {
            return ProcessResult(
              1,
              0,
              'vivcs/lib/a.dart\nnvim/lib/b.dart\n',
              '',
            );
          },
        ),
        textProvider: TextProvider(
          runProcess: (exe, args, {workingDirectory}) async {
            return ProcessResult(
              1,
              0,
              'vivcs/lib/a.dart:2:8:  void run() {}\n',
              '',
            );
          },
        ),
      );
    });

    tearDown(() async {
      await clientSession.close();
      await serverSession.close();
      await toClient.close();
      await fromClient.close();
      if (await tempWs.exists()) {
        await tempWs.delete(recursive: true);
      }
    });

    test('opens 3 floating windows, cycles targets, and confirms selection', () async {
      await picker.handleAction('search.files');
      expect(await picker.isOpen(), isTrue);
      expect(picker.target, SearchTarget.files);
      expect(picker.items, hasLength(2));
      expect(picker.previewWindowId, isNotNull);
      expect(
        winOptions[picker.promptWindowId!]!['statuscolumn'],
        '%#VisearchPillTarget# > %*',
      );

      // Cycle target: Files -> Text -> Symbols
      await picker.handleAction('search.target_next');
      expect(picker.target, SearchTarget.text);

      await picker.handleAction(
        'search.query_changed',
        ['search.query_changed', 'run'],
      );
      expect(picker.items, hasLength(1));
      expect(picker.items.first.line, 2);

      await picker.handleAction('search.target_next');
      expect(picker.target, SearchTarget.symbols);
      await picker.handleAction(
        'search.query_changed',
        ['search.query_changed', 'Alpha'],
      );
      expect(picker.items, hasLength(1));
      expect(picker.items.first.symbolKind, 'Class');

      // Confirm selection opens file and jumps cursor
      await picker.handleAction('search.confirm');
      expect(await picker.isOpen(), isFalse);
      expect(
        commands.any((c) => c.startsWith('edit ') && c.endsWith('vivcs/lib/a.dart')),
        isTrue,
      );
    });

    test('opens Target and Scope dropdowns and applies subproject/custom glob scopes', () async {
      await picker.handleAction('search.files');
      expect(picker.items, hasLength(2));

      // Open Target dropdown and select Symbols (row 3)
      await picker.handleAction('search.target_dropdown');
      expect(picker.targetDropdown.isOpen, isTrue);
      final tWin = picker.targetDropdown.windowId!;
      cursors[tWin] = (3, 0);
      await picker.handleAction('search.target_dropdown.confirm');
      expect(picker.targetDropdown.isOpen, isFalse);
      expect(picker.target, SearchTarget.symbols);

      // Open Scope dropdown and select discovered subproject 'vivcs'
      // Items: 1=Workspace, 2=Current Buffer, 3=nvim, 4=vivcs, 5=Edit Custom Path/Glob...
      await picker.handleAction('search.scope_dropdown');
      expect(picker.scopeDropdown.isOpen, isTrue);
      final sWin = picker.scopeDropdown.windowId!;
      cursors[sWin] = (4, 0);
      await picker.handleAction('search.scope_dropdown.confirm');
      expect(picker.scope.kind, ScopeKind.subproject);
      expect(picker.scope.subprojectPath, 'vivcs');
      expect(picker.items, hasLength(1));

      // Open custom glob prompt directly via search.custom_glob
      await picker.handleAction('search.custom_glob');
      expect(picker.globPrompt.isOpen, isTrue);
      final gBuf = picker.globPrompt.bufferId!;
      bufferLines[gBuf] = ['nvim/**'];
      await picker.handleAction('search.glob_submit');
      expect(picker.globPrompt.isOpen, isFalse);
      expect(picker.scope.kind, ScopeKind.customGlob);
      expect(picker.items, hasLength(1));
      expect(picker.items.first.relativePath, 'nvim/lib/b.dart');
    });

    test('supports preview toggle, mouse drag split resize, and VimResized', () async {
      await picker.handleAction('search.files');
      expect(picker.showPreview, isTrue);

      await picker.handleAction('search.toggle_preview');
      expect(picker.showPreview, isFalse);
      expect(picker.previewWindowId, isNull);

      await picker.handleAction('search.toggle_preview');
      expect(picker.showPreview, isTrue);
      expect(picker.previewWindowId, isNotNull);

      final initialSplit = picker.splitRatio;
      await picker.handleAction('search.mouse_drag');
      expect(picker.splitRatio, isNot(equals(initialSplit)));

      await picker.handleAction('search.vim_resized');
      expect(await picker.isOpen(), isTrue);
    });
  });
}
