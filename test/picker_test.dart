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
    final notifications = <String>[];
    final registers = <String, String>{};
    final keymaps = <String, String>{};
    final cursors = <int, (int, int)>{};
    final bufferLines = <int, List<String>>{};
    final winOptions = <int, Map<String, Object?>>{};
    final winConfigs = <int, Map<String, Object?>>{};
    final bufOptions = <int, Map<String, Object?>>{};
    final winBufs = <int, int>{};
    final validWins = <int>{1};
    final validBufs = <int>{1};
    var mousePos = <String, Object?>{'screencol': 42, 'screenrow': 15};
    var nextHandle = 10;
    var currentWin = 1;
    var currentBuf = 1;
    int? alternateWin;

    setUp(() async {
      commands.clear();
      notifications.clear();
      registers.clear();
      keymaps.clear();
      cursors.clear();
      bufferLines.clear();
      winOptions.clear();
      winConfigs.clear();
      bufOptions.clear();
      winBufs
        ..clear()
        ..[1] = 1;
      validWins
        ..clear()
        ..add(1);
      validBufs
        ..clear()
        ..add(1);
      mousePos = <String, Object?>{'screencol': 42, 'screenrow': 15};
      nextHandle = 10;
      currentWin = 1;
      currentBuf = 1;
      alternateWin = null;

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
            winBufs[id] = params[0] as int;
            winConfigs[id] = (params[2] as Map).cast<String, Object?>();
            if (params[1] == true) {
              currentWin = id;
            }
            return id;
          case 'nvim_win_set_config':
            final w = params[0] as int;
            winConfigs[w] = (params[1] as Map).cast<String, Object?>();
            return null;
          case 'nvim_win_is_valid':
            return validWins.contains(params[0] as int);
          case 'nvim_win_get_buf':
            final w = params[0] as int;
            return winBufs[w] ?? 1;
          case 'nvim_list_wins':
            return validWins.toList();
          case 'nvim_win_get_config':
            final w = params[0] as int;
            return winConfigs[w] ?? <String, Object?>{'relative': ''};
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
            if (opts.containsKey('buf')) {
              final b = opts['buf'] as int;
              bufOptions.putIfAbsent(b, () => {})[name] = value;
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
          case 'nvim_buf_set_keymap':
            final buf = params[0] as int;
            final mode = params[1].toString();
            final lhs = params[2].toString();
            final rhs = params[3].toString();
            keymaps['$buf:$mode:$lhs'] = rhs;
            return null;
          case 'nvim_call_function':
            if (params[0] == 'getcwd') {
              return tempWs.path;
            }
            if (params[0] == 'winnr') {
              return alternateWin != null ? 1 : 0;
            }
            if (params[0] == 'win_getid') {
              return alternateWin ?? 0;
            }
            if (params[0] == 'getmousepos') {
              return mousePos;
            }
            if (params[0] == 'setreg') {
              final args = params[1] as List;
              registers[args[0].toString()] = args[1].toString();
              return 0;
            }
            return null;
          case 'nvim_notify':
            notifications.add(params[0].toString());
            return null;
          case 'nvim_get_option_value':
            if (params[0] == 'columns') return 120;
            if (params[0] == 'lines') return 40;
            final opts = (params[1] as Map).cast<String, Object?>();
            if (opts.containsKey('buf')) {
              final b = opts['buf'] as int;
              return bufOptions[b]?[params[0].toString()] ?? '';
            }
            if (opts.containsKey('win')) {
              final w = opts['win'] as int;
              return winOptions[w]?[params[0].toString()] ?? false;
            }
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
              return mousePos;
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
      expect(cursors[picker.promptWindowId!], (1, 3));

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

    test('copies selected relative path via Ctrl+y while keeping modal open', () async {
      await picker.handleAction('search.files');
      expect(await picker.isOpen(), isTrue);
      expect(picker.items, hasLength(2));

      // Verify <C-y> is bound to search.copy_path in prompt (i and n), results (n), and preview (n)
      expect(
        keymaps.entries.where(
          (e) => e.key.endsWith(':<C-y>') && e.value.contains('search.copy_path'),
        ),
        hasLength(4),
      );

      // First item is nvim/lib/b.dart (sorted alphabetically)
      await picker.handleAction('search.copy_path');
      expect(await picker.isOpen(), isTrue);
      expect(registers['"'], 'nvim/lib/b.dart');
      expect(registers['+'], 'nvim/lib/b.dart');
      expect(registers['*'], 'nvim/lib/b.dart');
      expect(notifications.last, 'Copied path: nvim/lib/b.dart');

      // Move to second item (vivcs/lib/a.dart) and copy
      await picker.handleAction('search.next_item');
      await picker.handleAction('search.copy_path');
      expect(await picker.isOpen(), isTrue);
      expect(registers['"'], 'vivcs/lib/a.dart');
      expect(registers['+'], 'vivcs/lib/a.dart');
      expect(registers['*'], 'vivcs/lib/a.dart');
      expect(notifications.last, 'Copied path: vivcs/lib/a.dart');
    });

    test('opens confirmed file in eligible editor window instead of viworkspace sidebar', () async {
      // Window 1 is an eligible normal editor window; Window 2 is a viworkspace sidebar window.
      validWins.add(2);
      validBufs.add(2);
      winBufs[2] = 2;
      bufOptions[2] = {
        'buftype': 'nofile',
        'filetype': 'viworkspace',
      };
      winOptions[2] = {
        'winfixwidth': true,
      };
      currentWin = 2;
      currentBuf = 2;

      await picker.handleAction('search.files');
      expect(await picker.isOpen(), isTrue);

      await picker.handleAction('search.confirm');
      expect(await picker.isOpen(), isFalse);
      // Should focus eligible editor window 1 instead of sidebar window 2.
      expect(currentWin, 1);
      expect(
        commands.any((c) => c.startsWith('edit ') && c.endsWith('nvim/lib/b.dart')),
        isTrue,
      );
    });

    test('Escape does not close dialog and enters command/normal mode in search text', () async {
      await picker.handleAction('search.files');
      expect(await picker.isOpen(), isTrue);

      // Prompt buffer should not bind <Esc> in insert or normal mode so <Esc>
      // naturally exits insert mode into normal (command) mode without closing.
      expect(
        keymaps.entries.where(
          (e) => e.key.endsWith(':<Esc>') && e.value.contains('search.close'),
        ),
        isEmpty,
      );
      expect(
        keymaps.keys.where((k) => k.endsWith(':i:<Esc>')),
        isEmpty,
      );

      // Results and preview buffers bind <Esc> to search.focus_prompt_normal
      expect(
        keymaps.entries.where(
          (e) =>
              e.key.endsWith(':n:<Esc>') &&
              e.value.contains('search.focus_prompt_normal'),
        ),
        hasLength(2),
      );

      // q and <C-c> still close the dialog
      expect(
        keymaps.entries.where(
          (e) => e.key.endsWith(':n:q') && e.value.contains('search.close'),
        ),
        hasLength(3),
      );
      expect(
        keymaps.entries.where(
          (e) => e.key.endsWith(':<C-c>') && e.value.contains('search.close'),
        ),
        hasLength(4),
      );

      // Triggering search.focus_prompt_normal from another window focuses prompt without startinsert!
      currentWin = picker.resultsWindowId!;
      commands.clear();
      await picker.handleAction('search.focus_prompt_normal');
      expect(await picker.isOpen(), isTrue);
      expect(currentWin, picker.promptWindowId);
      expect(commands, isNot(contains('startinsert!')));
    });

    test('dropdown popups exit insert mode, bind Escape in n/i modes, and close on outside click or toggle', () async {
      await picker.handleAction('search.files');
      commands.clear();

      // Opening target dropdown calls stopinsert and binds <Esc> in both n and i modes
      await picker.handleAction('search.target_dropdown');
      expect(picker.targetDropdown.isOpen, isTrue);
      expect(commands, contains('stopinsert'));
      final tBuf = picker.targetDropdown.bufferId!;
      expect(keymaps['$tBuf:n:<Esc>'], contains('search.target_dropdown.cancel'));
      expect(keymaps['$tBuf:i:<Esc>'], contains('search.target_dropdown.cancel'));
      expect(keymaps['$tBuf:n:<C-c>'], contains('search.target_dropdown.cancel'));
      expect(keymaps['$tBuf:i:<C-c>'], contains('search.target_dropdown.cancel'));

      // Opening scope dropdown closes target dropdown automatically
      await picker.handleAction('search.scope_dropdown');
      expect(picker.targetDropdown.isOpen, isFalse);
      expect(picker.scopeDropdown.isOpen, isTrue);

      // Toggling scope dropdown again closes it and focuses prompt
      await picker.handleAction('search.scope_dropdown');
      expect(picker.scopeDropdown.isOpen, isFalse);
      expect(currentWin, picker.promptWindowId);

      // Re-open target dropdown, then click outside in prompt or results to close it
      await picker.handleAction('search.target_dropdown');
      expect(picker.targetDropdown.isOpen, isTrue);
      await picker.handleAction('search.prompt_click');
      expect(picker.targetDropdown.isOpen, isFalse);

      await picker.handleAction('search.scope_dropdown');
      expect(picker.scopeDropdown.isOpen, isTrue);
      await picker.handleAction('search.results_click');
      expect(picker.scopeDropdown.isOpen, isFalse);
    });

    test('defaults to full-screen geometry with 1-character padding on all sides', () async {
      expect(picker.widthRatio, 1.0);
      expect(picker.heightRatio, 1.0);

      final geom = PickerGeometry.compute(
        editorWidth: 120,
        editorHeight: 40,
        widthRatio: picker.widthRatio,
        heightRatio: picker.heightRatio,
        splitRatio: picker.splitRatio,
        showPreview: true,
      );

      // 1-character padding around the 120x40 grid
      expect(geom.outerRow, 1);
      expect(geom.outerCol, 1);
      expect(geom.totalWidth, 118);
      expect(geom.totalHeight, 38);

      // Prompt spans top of the padded box (with 2 border cols/rows -> 118 cols, 3 rows)
      expect(geom.promptRow, 1);
      expect(geom.promptCol, 1);
      expect(geom.promptWidth, 116);

      // Results + Preview span the remaining height and align cleanly to the right edge
      expect(geom.bodyRow, 4);
      expect(geom.bodyHeight, 33);
      expect(geom.resultsCol, 1);
      expect(geom.previewCol, geom.resultsCol + geom.resultsWidth + 2);
      expect(geom.resultsWidth + 2 + geom.previewWidth + 2, geom.totalWidth);

      // Opening the picker creates an opaque full-grid padding window behind the panes
      await picker.handleAction('search.files');
      final padWin = picker.paddingWindowId;
      expect(padWin, isNotNull);
      expect(validWins, contains(padWin));
      expect(winConfigs[padWin], {
        'relative': 'editor',
        'row': 0,
        'col': 0,
        'width': 120,
        'height': 40,
        'style': 'minimal',
        'border': 'none',
        'focusable': false,
        'zindex': 90,
      });
      expect(winOptions[padWin]?['winblend'], 0);
      expect(
        winOptions[padWin]?['winhighlight'],
        'Normal:VisearchPadding,NormalFloat:VisearchPadding,EndOfBuffer:VisearchPadding',
      );

      await picker.handleAction('search.close');
      expect(picker.paddingWindowId, isNull);
      expect(validWins, isNot(contains(padWin)));
    });

    test('opens selected file in newly active split pane instead of stale first split pane', () async {
      // Set up two editor split panes: win 1 and win 2
      validWins.addAll([1, 2]);
      validBufs.addAll([1, 2]);
      winBufs[1] = 1;
      winBufs[2] = 2;
      bufOptions[1] = {'buftype': '', 'filetype': 'dart'};
      bufOptions[2] = {'buftype': '', 'filetype': 'dart'};

      // 1. Open visearch from split pane win 1 and confirm -> opens in win 1
      currentWin = 1;
      await picker.handleAction('search.files');
      await picker.handleAction('search.confirm');
      expect(currentWin, 1);
      expect(picker.lastActiveEditorWin, 1);

      // 2. Switch active split pane to win 2, re-open visearch, and confirm -> must open in win 2!
      currentWin = 2;
      commands.clear();
      await picker.handleAction('search.files');
      final firstItemOnWin2 = picker.items.first.filePath;
      await picker.handleAction('search.confirm');
      expect(currentWin, 2);
      expect(picker.lastActiveEditorWin, 2);
      expect(commands, contains('edit $firstItemOnWin2'));

      // 3. Open visearch while focused in an excluded sidebar window (win 3),
      //    when lastActiveEditorWin is win 2 (and stale alternateWin is win 1) -> must open in win 2!
      validWins.add(3);
      validBufs.add(3);
      winBufs[3] = 3;
      bufOptions[3] = {'buftype': 'nofile', 'filetype': 'viworkspace'};
      picker.attachWindow(excludedWins: {3}, lastActiveEditorWin: 2);
      currentWin = 3;
      alternateWin = 1;
      commands.clear();

      await picker.handleAction('search.files');
      final firstItemFromWin3 = picker.items.first.filePath;
      await picker.handleAction('search.confirm');
      expect(currentWin, 2);
      expect(picker.lastActiveEditorWin, 2);
      expect(commands, contains('edit $firstItemFromWin3'));

      // 4. Two rapid clicks on row 2 in results window acts as double-click and opens file in win 2
      currentWin = 2;
      commands.clear();
      await picker.handleAction('search.files');
      final secondItem = picker.items[1].filePath;
      final resWin = picker.resultsWindowId!;
      currentWin = resWin;
      cursors[resWin] = (1, 0);
      mousePos = {
        'winid': resWin,
        'winrow': 2,
        'wincol': 4,
        'line': 2,
        'column': 4,
        'screenrow': 10,
        'screencol': 10,
      };
      // First click selects row 2 without closing
      await picker.handleAction('search.results_click');
      expect(await picker.isOpen(), isTrue);
      expect(picker.selectedIndex, 1);
      // Second immediate click on row 2 confirms and opens in win 2
      await picker.handleAction('search.results_click');
      expect(await picker.isOpen(), isFalse);
      expect(currentWin, 2);
      expect(commands, contains('edit $secondItem'));
    });

    test('closes padding window first and refreshes live prompt query on rapid confirm', () async {
      await picker.handleAction('search.files');
      expect(await picker.isOpen(), isTrue);

      final padWin = picker.paddingWindowId!;
      final promptBuf = bufferLines.keys.firstWhere(
        (b) => bufOptions[b]?['filetype'] == 'visearch-prompt',
      );
      // Simulate typing 'a.dart' in prompt buffer and pressing <CR> before TextChangedI notification arrives
      bufferLines[promptBuf] = [' > a.dart'];

      // Also simulate a concurrent search.query_changed + search.confirm race
      final closedOrder = <int>[];
      final origHandler = serverSession.onRequest!;
      serverSession.onRequest = (method, params) async {
        if (method == 'nvim_win_close') {
          closedOrder.add(params[0] as int);
        }
        return origHandler(method, params);
      };

      await Future.wait([
        picker.handleAction('search.query_changed', ['search.query_changed', 'a']),
        picker.handleAction('search.confirm'),
      ]);

      expect(await picker.isOpen(), isFalse);
      expect(picker.paddingWindowId, isNull);
      expect(validWins, isNot(contains(padWin)));
      // Padding backdrop window must be the very first window closed
      expect(closedOrder.first, padWin);
      expect(
        commands.any((c) => c.startsWith('edit ') && c.endsWith('vivcs/lib/a.dart')),
        isTrue,
      );
    });
  });
}
