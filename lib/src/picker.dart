import 'dart:convert';
import 'dart:io';

import 'package:nvim/nvim.dart';
import 'package:visettings/visettings.dart';

import 'dropdown.dart';
import 'providers.dart';
import 'scope.dart';

const String _customGlobSentinel = '__CUSTOM_GLOB__';

/// Computed geometry for the 3-pane `VisearchPicker` layout.
class PickerGeometry {
  final int editorWidth;
  final int editorHeight;
  final int outerRow;
  final int outerCol;
  final int totalWidth;
  final int totalHeight;
  final int promptRow;
  final int promptCol;
  final int promptWidth;
  final int bodyRow;
  final int bodyHeight;
  final int resultsCol;
  final int resultsWidth;
  final int previewCol;
  final int previewWidth;
  final bool showPreview;

  const PickerGeometry({
    required this.editorWidth,
    required this.editorHeight,
    required this.outerRow,
    required this.outerCol,
    required this.totalWidth,
    required this.totalHeight,
    required this.promptRow,
    required this.promptCol,
    required this.promptWidth,
    required this.bodyRow,
    required this.bodyHeight,
    required this.resultsCol,
    required this.resultsWidth,
    required this.previewCol,
    required this.previewWidth,
    required this.showPreview,
  });

  factory PickerGeometry.compute({
    required int editorWidth,
    required int editorHeight,
    required double widthRatio,
    required double heightRatio,
    required double splitRatio,
    required bool showPreview,
  }) {
    final safeEditorW = editorWidth.clamp(40, 1000);
    final safeEditorH = editorHeight.clamp(12, 500);

    final totalW = (safeEditorW * widthRatio.clamp(0.50, 0.98))
        .round()
        .clamp(38, safeEditorW - 2);
    final totalH = (safeEditorH * heightRatio.clamp(0.45, 0.96))
        .round()
        .clamp(8, safeEditorH - 2);

    final outerRow = ((safeEditorH - totalH) ~/ 2).clamp(0, safeEditorH - 4);
    final outerCol = ((safeEditorW - totalW) ~/ 2).clamp(0, safeEditorW - 4);

    // Prompt window uses a rounded border (takes 3 rows total: top border + 1 line + bottom border)
    final promptRow = outerRow;
    final promptCol = outerCol;
    final promptWidth = (totalW - 2).clamp(20, safeEditorW - 4);

    final bodyRow = promptRow + 3;
    final bodyHeight = (totalH - 5).clamp(3, safeEditorH - 6);

    final canShowPreview = showPreview && totalW >= 64;
    if (!canShowPreview) {
      return PickerGeometry(
        editorWidth: safeEditorW,
        editorHeight: safeEditorH,
        outerRow: outerRow,
        outerCol: outerCol,
        totalWidth: totalW,
        totalHeight: totalH,
        promptRow: promptRow,
        promptCol: promptCol,
        promptWidth: promptWidth,
        bodyRow: bodyRow,
        bodyHeight: bodyHeight,
        resultsCol: outerCol,
        resultsWidth: promptWidth,
        previewCol: outerCol,
        previewWidth: 0,
        showPreview: false,
      );
    }

    // Two side-by-side windows, each with a 2-column border (`left` + `right`).
    // Total inner width across both panes = totalW - 4.
    final availableInner = (totalW - 4).clamp(30, safeEditorW);
    final clampedSplit = splitRatio.clamp(0.25, 0.75);
    final resultsW = (availableInner * clampedSplit)
        .round()
        .clamp(16, availableInner - 14);
    final previewW = (availableInner - resultsW).clamp(14, availableInner - 16);
    final previewCol = outerCol + resultsW + 2;

    return PickerGeometry(
      editorWidth: safeEditorW,
      editorHeight: safeEditorH,
      outerRow: outerRow,
      outerCol: outerCol,
      totalWidth: totalW,
      totalHeight: totalH,
      promptRow: promptRow,
      promptCol: promptCol,
      promptWidth: promptWidth,
      bodyRow: bodyRow,
      bodyHeight: bodyHeight,
      resultsCol: outerCol,
      resultsWidth: resultsW,
      previewCol: previewCol,
      previewWidth: previewW,
      showPreview: true,
    );
  }
}

/// Resizable 3-pane floating search picker for Files, Text, and LSP Symbols.
class VisearchPicker {
  final Nvim nvim;
  final String luaModule;
  final FilesProvider filesProvider;
  final TextProvider textProvider;
  final SymbolsProvider symbolsProvider;

  late final DropdownMenu<SearchTarget> _targetDropdown;
  late final DropdownMenu<Object> _scopeDropdown;
  late final GlobInputPrompt _globPrompt;

  int? _nsId;
  bool _highlightsInitialized = false;

  int? _promptBuf;
  int? _promptWin;
  int? _resultsBuf;
  int? _resultsWin;
  int? _previewBuf;
  int? _previewWin;

  int? _originWin;
  int? _originBuf;
  String? _originBufPath;
  List<String>? _originBufLines;

  String _workspaceRoot = '';
  VibrainiumSettings _settings = const VibrainiumSettings();
  List<String> _subprojects = const [];
  final List<String> _recentCustomGlobs = [];

  SearchTarget _target = SearchTarget.files;
  SearchScope _scope = const SearchScope.workspace();
  String _query = '';
  List<SearchItem> _items = const [];
  int _totalScopedCount = 0;
  int _selectedIndex = 0;
  int _searchGeneration = 0;

  double _widthRatio = 0.84;
  double _heightRatio = 0.80;
  double _splitRatio = 0.48;
  bool _showPreview = true;
  PickerGeometry? _lastGeometry;

  VisearchPicker({
    required this.nvim,
    this.luaModule = 'vibrainium',
    FilesProvider? filesProvider,
    TextProvider? textProvider,
    SymbolsProvider? symbolsProvider,
  })  : filesProvider = filesProvider ?? FilesProvider(),
        textProvider = textProvider ?? const TextProvider(),
        symbolsProvider = symbolsProvider ?? const SymbolsProvider() {
    _targetDropdown = DropdownMenu<SearchTarget>(
      nvim,
      luaModule: luaModule,
      actionPrefix: 'search.target_dropdown',
    );
    _scopeDropdown = DropdownMenu<Object>(
      nvim,
      luaModule: luaModule,
      actionPrefix: 'search.scope_dropdown',
    );
    _globPrompt = GlobInputPrompt(nvim, luaModule: luaModule);
  }

  SearchTarget get target => _target;
  SearchScope get scope => _scope;
  String get query => _query;
  List<SearchItem> get items => List.unmodifiable(_items);
  int get selectedIndex => _selectedIndex;
  double get widthRatio => _widthRatio;
  double get heightRatio => _heightRatio;
  double get splitRatio => _splitRatio;
  bool get showPreview => _showPreview;
  int? get promptWindowId => _promptWin;
  int? get resultsWindowId => _resultsWin;
  int? get previewWindowId => _previewWin;
  DropdownMenu<SearchTarget> get targetDropdown => _targetDropdown;
  DropdownMenu<Object> get scopeDropdown => _scopeDropdown;
  GlobInputPrompt get globPrompt => _globPrompt;

  Future<bool> isOpen() async {
    final win = _promptWin;
    if (win == null) return false;
    return nvim.winIsValid(win);
  }

  /// Opens the unified picker in [initialTarget] mode (`files`, `text`, or `symbols`).
  Future<void> open({
    SearchTarget initialTarget = SearchTarget.files,
    SearchScope? initialScope,
  }) async {
    final alreadyOpen = await isOpen();
    if (!alreadyOpen) {
      await _captureOriginContext();
    }

    _target = initialTarget;
    if (initialScope != null) {
      _scope = initialScope;
    } else if (_scope.kind == ScopeKind.currentBuffer) {
      _scope = SearchScope.currentBuffer(_originBufPath);
    }

    _workspaceRoot = await nvim.getCwd();
    _settings = await VibrainiumSettings.load(_workspaceRoot);
    _subprojects = await discoverSubprojects(
      Directory(_workspaceRoot),
      settings: _settings,
    );

    await _ensureHighlights();
    await _ensureWindows();
    await _runSearch();
    await _focusPrompt(startInsert: true);
  }

  /// Closes the picker and any open dropdowns/prompts.
  Future<void> close() async {
    await _targetDropdown.close();
    await _scopeDropdown.close();
    await _globPrompt.close();

    try {
      await nvim.execLua(
        "pcall(vim.api.nvim_del_augroup_by_name, 'VisearchPicker')",
      );
    } catch (_) {}

    for (final win in [_previewWin, _resultsWin, _promptWin]) {
      if (win != null) {
        try {
          if (await nvim.winIsValid(win)) {
            await nvim.winClose(win, force: true);
          }
        } catch (_) {}
      }
    }
    _promptWin = null;
    _resultsWin = null;
    _previewWin = null;
    _promptBuf = null;
    _resultsBuf = null;
    _previewBuf = null;

    final origWin = _originWin;
    if (origWin != null) {
      try {
        if (await nvim.winIsValid(origWin)) {
          await nvim.setCurrentWin(origWin);
        }
      } catch (_) {}
    }
  }

  /// Handles `search.*` RPC actions and notifications.
  Future<Object?> handleAction(
    String action, [
    List<Object?> params = const [],
  ]) async {
    switch (action) {
      case 'search.files':
        await open(initialTarget: SearchTarget.files);
        return true;
      case 'search.text':
      case 'search.grep':
        await open(initialTarget: SearchTarget.text);
        return true;
      case 'search.symbols':
        await open(initialTarget: SearchTarget.symbols);
        return true;
      case 'search.close':
        await close();
        return true;
      case 'search.query_changed':
        final newQuery = params.length > 1
            ? params[1]?.toString() ?? ''
            : await _readPromptQuery();
        await onQueryChanged(newQuery);
        return true;
      case 'search.next_item':
        await moveSelection(1);
        return true;
      case 'search.prev_item':
        await moveSelection(-1);
        return true;
      case 'search.confirm':
        await confirmSelection();
        return true;
      case 'search.target_next':
        await cycleTarget(1);
        return true;
      case 'search.target_prev':
        await cycleTarget(-1);
        return true;
      case 'search.target_dropdown':
        await openTargetDropdown();
        return true;
      case 'search.target_dropdown.confirm':
        await _targetDropdown.confirm();
        return true;
      case 'search.target_dropdown.cancel':
        await _targetDropdown.cancel();
        return true;
      case 'search.scope_dropdown':
        await openScopeDropdown();
        return true;
      case 'search.scope_dropdown.confirm':
        await _scopeDropdown.confirm();
        return true;
      case 'search.scope_dropdown.cancel':
        await _scopeDropdown.cancel();
        return true;
      case 'search.custom_glob':
        await openCustomGlobPrompt();
        return true;
      case 'search.glob_submit':
        await _globPrompt.submit();
        return true;
      case 'search.glob_cancel':
        await _globPrompt.cancel();
        return true;
      case 'search.toggle_preview':
        await togglePreview();
        return true;
      case 'search.preview_down':
        await scrollPreview(8);
        return true;
      case 'search.preview_up':
        await scrollPreview(-8);
        return true;
      case 'search.vim_resized':
        await relayout();
        return true;
      case 'search.mouse_drag':
        await handleMouseDrag();
        return true;
      case 'search.prompt_click':
        await handlePromptClick();
        return true;
      case 'search.results_click':
        await handleResultsClick(openFile: false);
        return true;
      case 'search.results_double_click':
        await handleResultsClick(openFile: true);
        return true;
    }
    return false;
  }

  Future<void> onHotReloaded() async {
    _highlightsInitialized = false;
    if (await isOpen()) {
      await _ensureHighlights();
      await relayout();
      await _renderPromptPills();
      await _renderResults();
      await _renderPreview();
    }
  }

  /// Updates the search query and refreshes results + preview.
  Future<void> onQueryChanged(String newQuery) async {
    if (_query == newQuery) return;
    _query = newQuery;
    _selectedIndex = 0;
    await _runSearch();
  }

  /// Cycles through `Files` -> `Text` -> `Symbols` while keeping query and scope.
  Future<void> cycleTarget(int delta) async {
    const values = SearchTarget.values;
    final nextIdx = (_target.index + delta) % values.length;
    final resolvedIdx = nextIdx < 0 ? nextIdx + values.length : nextIdx;
    await setTarget(values[resolvedIdx]);
  }

  Future<void> setTarget(SearchTarget nextTarget) async {
    if (_target == nextTarget && _items.isNotEmpty) {
      await _renderPromptPills();
      return;
    }
    _target = nextTarget;
    _selectedIndex = 0;
    await _renderPromptPills();
    await _runSearch();
  }

  Future<void> setScope(SearchScope nextScope) async {
    _scope = nextScope;
    _selectedIndex = 0;
    await _renderPromptPills();
    await _runSearch();
  }

  /// Moves selection in the Results pane by [delta] rows and updates the Preview pane.
  Future<void> moveSelection(int delta) async {
    if (_items.isEmpty) return;
    final next = (_selectedIndex + delta).clamp(0, _items.length - 1);
    if (next == _selectedIndex) return;
    _selectedIndex = next;
    final resWin = _resultsWin;
    if (resWin != null && await nvim.winIsValid(resWin)) {
      await nvim.winSetCursor(resWin, _selectedIndex + 1, 0);
    }
    await _renderPreview();
  }

  /// Toggles visibility of the right-hand Preview pane.
  Future<void> togglePreview() async {
    _showPreview = !_showPreview;
    await relayout();
    await _renderPreview();
  }

  /// Scrolls the Preview pane by [deltaLines] lines.
  Future<void> scrollPreview(int deltaLines) async {
    final prevWin = _previewWin;
    final prevBuf = _previewBuf;
    if (prevWin == null ||
        prevBuf == null ||
        !await nvim.winIsValid(prevWin) ||
        !await nvim.bufIsValid(prevBuf)) {
      return;
    }
    final lines = await nvim.bufGetLines(prevBuf);
    if (lines.isEmpty) return;
    final (row, col) = await nvim.winGetCursor(prevWin);
    final targetRow = (row + deltaLines).clamp(1, lines.length);
    await nvim.winSetCursor(prevWin, targetRow, col);
  }

  /// Opens the Target mode dropdown (`Files`, `Text`, `Symbols`).
  Future<void> openTargetDropdown() async {
    if (!await isOpen()) return;
    final geom = _lastGeometry ?? await _computeCurrentGeometry();
    final items = SearchTarget.values
        .map(
          (t) => DropdownItem<SearchTarget>(
            label: '${t.icon} ${t.label}',
            value: t,
            isActive: t == _target,
          ),
        )
        .toList();

    final dropdownCol =
        (geom.promptCol + geom.promptWidth - 22).clamp(1, geom.editorWidth - 22);
    final dropdownRow = geom.promptRow + 2;

    await _targetDropdown.open(
      title: 'Search Target',
      items: items,
      row: dropdownRow,
      col: dropdownCol,
      onSelect: (selected) async {
        await setTarget(selected);
        await _focusPrompt(startInsert: true);
      },
      onCancel: () async {
        await _focusPrompt(startInsert: true);
      },
    );
  }

  /// Opens the Scope dropdown (`Workspace`, `Current Buffer`, discovered subprojects,
  /// recent custom globs, and `Custom Path/Glob…`).
  Future<void> openScopeDropdown() async {
    if (!await isOpen()) return;
    final geom = _lastGeometry ?? await _computeCurrentGeometry();

    final wsScope = const SearchScope.workspace();
    final bufScope = SearchScope.currentBuffer(_originBufPath);

    final dropdownItems = <DropdownItem<Object>>[
      DropdownItem<Object>(
        label: '󰉋 Workspace (all)',
        value: wsScope,
        isActive: _scope.kind == ScopeKind.workspace,
      ),
      if (_originBufPath != null && _originBufPath!.isNotEmpty)
        DropdownItem<Object>(
          label: '󰈙 Current Buffer',
          value: bufScope,
          isActive: _scope.kind == ScopeKind.currentBuffer,
        ),
      for (final sub in _subprojects)
        DropdownItem<Object>(
          label: '󰏖 $sub',
          value: SearchScope.subproject(sub),
          isActive: _scope.kind == ScopeKind.subproject &&
              _scope.subprojectPath == sub,
        ),
      for (final custom in _recentCustomGlobs)
        DropdownItem<Object>(
          label: ' Filter: $custom',
          value: SearchScope.customGlob(custom),
          isActive: _scope.kind == ScopeKind.customGlob &&
              _scope.customMatcher?.rawSpec == custom,
        ),
      const DropdownItem<Object>(
        label: 'Edit Custom Path/Glob…',
        value: _customGlobSentinel,
      ),
    ];

    final dropdownCol =
        (geom.promptCol + geom.promptWidth - 46).clamp(1, geom.editorWidth - 30);
    final dropdownRow = geom.promptRow + 2;

    await _scopeDropdown.open(
      title: 'Search Scope',
      items: dropdownItems,
      row: dropdownRow,
      col: dropdownCol,
      onSelect: (selected) async {
        if (selected == _customGlobSentinel) {
          await openCustomGlobPrompt();
          return;
        }
        if (selected is SearchScope) {
          await setScope(selected);
        }
        await _focusPrompt(startInsert: true);
      },
      onCancel: () async {
        await _focusPrompt(startInsert: true);
      },
    );
  }

  /// Opens the single-line input prompt for custom comma-separated paths/globs.
  Future<void> openCustomGlobPrompt() async {
    final initial = _scope.kind == ScopeKind.customGlob
        ? (_scope.customMatcher?.rawSpec ?? '')
        : '';
    await _globPrompt.open(
      initialValue: initial,
      onSubmit: (val) async {
        final trimmed = val.trim();
        if (trimmed.isEmpty) {
          await setScope(const SearchScope.workspace());
        } else {
          _recentCustomGlobs.remove(trimmed);
          _recentCustomGlobs.insert(0, trimmed);
          if (_recentCustomGlobs.length > 5) {
            _recentCustomGlobs.removeLast();
          }
          await setScope(SearchScope.customGlob(trimmed));
        }
        await _focusPrompt(startInsert: true);
      },
      onCancel: () async {
        await _focusPrompt(startInsert: true);
      },
    );
  }

  /// Opens the currently selected item in the origin window and jumps to `(line, col)`.
  Future<void> confirmSelection() async {
    if (_items.isEmpty) {
      await close();
      return;
    }
    final idx = _selectedIndex.clamp(0, _items.length - 1);
    final item = _items[idx];
    await close();

    final escaped = item.filePath.replaceAll(' ', r'\ ');
    await nvim.command('edit $escaped');
    final curWin = await nvim.getCurrentWin();
    try {
      await nvim.winSetCursor(curWin, item.line.clamp(1, 1000000), item.col);
      await nvim.command('normal! zz');
    } catch (_) {}
  }

  /// Recomputes and applies floating window geometry (e.g. on `VimResized` or mouse drag).
  Future<void> relayout() async {
    if (!await isOpen()) return;
    final geom = await _computeCurrentGeometry();
    _lastGeometry = geom;

    final pWin = _promptWin;
    if (pWin != null && await nvim.winIsValid(pWin)) {
      await nvim.winSetConfig(pWin, _promptWinConfig(geom));
    }

    final rWin = _resultsWin;
    if (rWin != null && await nvim.winIsValid(rWin)) {
      await nvim.winSetConfig(rWin, _resultsWinConfig(geom));
    }

    final prevWin = _previewWin;
    if (geom.showPreview) {
      if (prevWin != null && await nvim.winIsValid(prevWin)) {
        await nvim.winSetConfig(prevWin, _previewWinConfig(geom));
      } else if (_previewBuf != null && await nvim.bufIsValid(_previewBuf!)) {
        final newPrevWin = await nvim.openWin(
          _previewBuf!,
          false,
          _previewWinConfig(geom),
        );
        _previewWin = newPrevWin;
        await _configurePreviewWin(newPrevWin);
      }
    } else if (prevWin != null && await nvim.winIsValid(prevWin)) {
      await nvim.winClose(prevWin, force: true);
      _previewWin = null;
    }

    await _renderPromptPills();
    await _renderResults();
  }

  /// Handles mouse drag (`<LeftDrag>`) to resize the center split divider or outer frame.
  Future<void> handleMouseDrag() async {
    if (!await isOpen()) return;
    final geom = _lastGeometry ?? await _computeCurrentGeometry();
    Object? rawPos;
    try {
      rawPos = await nvim.execLua('return vim.fn.getmousepos()');
    } catch (_) {
      return;
    }
    if (rawPos is! Map) return;
    final screenCol = (rawPos['screencol'] as num?)?.toInt() ?? 0;
    final screenRow = (rawPos['screenrow'] as num?)?.toInt() ?? 0;
    if (screenCol <= 0 || screenRow <= 0) return;

    // Check if dragging inside the body area (between Results and Preview) to adjust split ratio
    if (geom.showPreview &&
        screenRow >= geom.bodyRow &&
        screenRow <= geom.bodyRow + geom.bodyHeight + 1 &&
        screenCol > geom.outerCol + 4 &&
        screenCol < geom.outerCol + geom.totalWidth - 4) {
      final relX = screenCol - geom.outerCol;
      final newSplit = (relX / geom.totalWidth).clamp(0.25, 0.75);
      if ((newSplit - _splitRatio).abs() >= 0.01) {
        _splitRatio = newSplit;
        await relayout();
      }
      return;
    }

    // Dragging outer right/left/bottom border resizes overall modal width/height ratios
    final centerCol = geom.editorWidth / 2.0;
    final centerRow = geom.editorHeight / 2.0;
    final halfSpanW = (screenCol - centerCol).abs() * 2.0;
    final halfSpanH = (screenRow - centerRow).abs() * 2.0;

    var changed = false;
    if (screenCol <= geom.outerCol + 2 ||
        screenCol >= geom.outerCol + geom.totalWidth - 2) {
      final nextW = (halfSpanW / geom.editorWidth).clamp(0.50, 0.98);
      if ((nextW - _widthRatio).abs() >= 0.01) {
        _widthRatio = nextW;
        changed = true;
      }
    }
    if (screenRow >= geom.bodyRow + geom.bodyHeight) {
      final nextH = (halfSpanH / geom.editorHeight).clamp(0.45, 0.96);
      if ((nextH - _heightRatio).abs() >= 0.01) {
        _heightRatio = nextH;
        changed = true;
      }
    }
    if (changed) {
      await relayout();
    }
  }

  /// Handles clicking on the right-aligned `[ Scope ▾ ]` or `[ Target ▾ ]` pills in the prompt.
  Future<void> handlePromptClick() async {
    if (!await isOpen()) return;
    final geom = _lastGeometry ?? await _computeCurrentGeometry();
    Object? rawPos;
    try {
      rawPos = await nvim.execLua('return vim.fn.getmousepos()');
    } catch (_) {
      return;
    }
    if (rawPos is! Map) return;
    final screenCol = (rawPos['screencol'] as num?)?.toInt() ?? 0;

    final targetPillText = ' [ ${_target.icon} ${_target.label} ▾ ] ';
    final scopePillText = ' [ 󰉋 Scope: ${_scope.label} ▾ ] ';
    final rightEdge = geom.promptCol + geom.promptWidth;
    final targetStart = rightEdge - targetPillText.runes.length;
    final scopeStart = targetStart - scopePillText.runes.length;

    if (screenCol >= targetStart && screenCol <= rightEdge) {
      await openTargetDropdown();
    } else if (screenCol >= scopeStart && screenCol < targetStart) {
      await openScopeDropdown();
    }
  }

  /// Handles clicking or double-clicking a row in the Results window.
  Future<void> handleResultsClick({required bool openFile}) async {
    final rWin = _resultsWin;
    if (rWin == null || !await nvim.winIsValid(rWin)) return;
    final (row, _) = await nvim.winGetCursor(rWin);
    final idx = (row - 1).clamp(0, _items.isEmpty ? 0 : _items.length - 1);
    if (_items.isNotEmpty) {
      _selectedIndex = idx;
      await _renderPreview();
      if (openFile) {
        await confirmSelection();
        return;
      }
    }
    await _focusPrompt(startInsert: false);
  }

  Future<void> _captureOriginContext() async {
    try {
      _originWin = await nvim.getCurrentWin();
      _originBuf = await nvim.getCurrentBuf();
      if (_originBuf != null && await nvim.bufIsValid(_originBuf!)) {
        final name = await nvim.bufGetName(_originBuf!);
        _originBufPath = name.isEmpty ? null : name;
        _originBufLines = await nvim.bufGetLines(_originBuf!);
      }
    } catch (_) {
      _originWin = null;
      _originBuf = null;
      _originBufPath = null;
      _originBufLines = null;
    }
  }

  Future<String> _readPromptQuery() async {
    final buf = _promptBuf;
    if (buf == null || !await nvim.bufIsValid(buf)) return '';
    final lines = await nvim.bufGetLines(buf, start: 0, end: 1);
    return lines.isEmpty ? '' : lines.first;
  }

  Future<PickerGeometry> _computeCurrentGeometry() async {
    final editorW = await nvim.getEditorWidth();
    final editorH = await nvim.getEditorHeight();
    return PickerGeometry.compute(
      editorWidth: editorW,
      editorHeight: editorH,
      widthRatio: _widthRatio,
      heightRatio: _heightRatio,
      splitRatio: _splitRatio,
      showPreview: _showPreview,
    );
  }

  Map<String, Object?> _promptWinConfig(PickerGeometry geom) {
    final countStr = _target == SearchTarget.files && _totalScopedCount > 0
        ? '${_items.length}/$_totalScopedCount'
        : '${_items.length}';
    return {
      'relative': 'editor',
      'row': geom.promptRow,
      'col': geom.promptCol,
      'width': geom.promptWidth,
      'height': 1,
      'style': 'minimal',
      'border': 'rounded',
      'title': ' Vibrainium Search ($countStr) ',
      'title_pos': 'center',
      'zindex': 100,
    };
  }

  Map<String, Object?> _resultsWinConfig(PickerGeometry geom) {
    return {
      'relative': 'editor',
      'row': geom.bodyRow,
      'col': geom.resultsCol,
      'width': geom.resultsWidth,
      'height': geom.bodyHeight,
      'style': 'minimal',
      'border': 'rounded',
      'title': ' Results (${_target.label}) ',
      'title_pos': 'center',
      'footer':
          ' <Tab> target • <C-t> mode • <C-s> scope • <M-p> preview • q quit ',
      'footer_pos': 'center',
      'zindex': 100,
    };
  }

  Map<String, Object?> _previewWinConfig(PickerGeometry geom) {
    final selected = (_items.isNotEmpty && _selectedIndex < _items.length)
        ? _items[_selectedIndex]
        : null;
    final titleLabel = selected == null
        ? ' Preview '
        : ' ${selected.relativePath}:${selected.line} ';
    return {
      'relative': 'editor',
      'row': geom.bodyRow,
      'col': geom.previewCol,
      'width': geom.previewWidth,
      'height': geom.bodyHeight,
      'style': 'minimal',
      'border': 'rounded',
      'title': titleLabel,
      'title_pos': 'center',
      'zindex': 100,
    };
  }

  Future<void> _ensureHighlights() async {
    _nsId ??= await nvim.createNamespace('visearch_picker');
    if (_highlightsInitialized) return;
    _highlightsInitialized = true;

    const groups = <String, Map<String, Object?>>{
      'VisearchPillTarget': {'bold': true, 'link': 'DiagnosticInfo'},
      'VisearchPillScope': {'bold': true, 'link': 'Special'},
      'VisearchMatch': {'bold': true, 'link': 'IncSearch'},
      'VisearchMuted': {'link': 'Comment'},
      'VisearchBadge': {'link': 'Number'},
      'VisearchPreviewTargetLine': {'link': 'Visual'},
    };

    for (final entry in groups.entries) {
      await nvim.setHl(0, entry.key, entry.value);
    }
  }

  Future<void> _ensureWindows() async {
    final geom = await _computeCurrentGeometry();
    _lastGeometry = geom;

    if (_promptBuf == null || !await nvim.bufIsValid(_promptBuf!)) {
      final pBuf = await nvim.createBuf(listed: false, scratch: true);
      _promptBuf = pBuf;
      await nvim.bufSetOption(pBuf, 'modifiable', true);
      await nvim.bufSetOption(pBuf, 'buftype', 'nofile');
      await nvim.bufSetOption(pBuf, 'bufhidden', 'wipe');
      await nvim.bufSetOption(pBuf, 'swapfile', false);
      await nvim.bufSetOption(pBuf, 'filetype', 'visearch-prompt');
      await nvim.bufSetLines(pBuf, lines: [_query]);
      await _bindPromptKeys(pBuf);
    }

    if (_resultsBuf == null || !await nvim.bufIsValid(_resultsBuf!)) {
      final rBuf = await nvim.createBuf(listed: false, scratch: true);
      _resultsBuf = rBuf;
      await nvim.bufSetOption(rBuf, 'modifiable', false);
      await nvim.bufSetOption(rBuf, 'buftype', 'nofile');
      await nvim.bufSetOption(rBuf, 'bufhidden', 'wipe');
      await nvim.bufSetOption(rBuf, 'swapfile', false);
      await nvim.bufSetOption(rBuf, 'filetype', 'visearch-results');
      await _bindResultsKeys(rBuf);
    }

    if (_previewBuf == null || !await nvim.bufIsValid(_previewBuf!)) {
      final prevBuf = await nvim.createBuf(listed: false, scratch: true);
      _previewBuf = prevBuf;
      await nvim.bufSetOption(prevBuf, 'modifiable', false);
      await nvim.bufSetOption(prevBuf, 'buftype', 'nofile');
      await nvim.bufSetOption(prevBuf, 'bufhidden', 'wipe');
      await nvim.bufSetOption(prevBuf, 'swapfile', false);
      await _bindPreviewKeys(prevBuf);
    }

    if (_promptWin == null || !await nvim.winIsValid(_promptWin!)) {
      _promptWin = await nvim.openWin(
        _promptBuf!,
        true,
        _promptWinConfig(geom),
      );
      await _configurePromptWin(_promptWin!);
    } else {
      await nvim.winSetConfig(_promptWin!, _promptWinConfig(geom));
    }

    if (_resultsWin == null || !await nvim.winIsValid(_resultsWin!)) {
      _resultsWin = await nvim.openWin(
        _resultsBuf!,
        false,
        _resultsWinConfig(geom),
      );
      await _configureResultsWin(_resultsWin!);
    } else {
      await nvim.winSetConfig(_resultsWin!, _resultsWinConfig(geom));
    }

    if (geom.showPreview) {
      if (_previewWin == null || !await nvim.winIsValid(_previewWin!)) {
        _previewWin = await nvim.openWin(
          _previewBuf!,
          false,
          _previewWinConfig(geom),
        );
        await _configurePreviewWin(_previewWin!);
      } else {
        await nvim.winSetConfig(_previewWin!, _previewWinConfig(geom));
      }
    }

    await _attachAutocmds(_promptBuf!);
  }

  Future<void> _configurePromptWin(int win) async {
    await nvim.winSetOption(win, 'number', false);
    await nvim.winSetOption(win, 'relativenumber', false);
    await nvim.winSetOption(win, 'signcolumn', 'no');
    await nvim.winSetOption(win, 'foldcolumn', '0');
    await nvim.winSetOption(win, 'statuscolumn', '%#VisearchPillTarget# > %*');
    await nvim.winSetOption(win, 'wrap', false);
    await nvim.winSetOption(win, 'cursorline', false);
  }

  Future<void> _configureResultsWin(int win) async {
    await nvim.winSetOption(win, 'number', false);
    await nvim.winSetOption(win, 'relativenumber', false);
    await nvim.winSetOption(win, 'signcolumn', 'no');
    await nvim.winSetOption(win, 'wrap', false);
    await nvim.winSetOption(win, 'cursorline', true);
  }

  Future<void> _configurePreviewWin(int win) async {
    await nvim.winSetOption(win, 'number', true);
    await nvim.winSetOption(win, 'relativenumber', false);
    await nvim.winSetOption(win, 'signcolumn', 'no');
    await nvim.winSetOption(win, 'wrap', false);
    await nvim.winSetOption(win, 'cursorline', true);
  }

  Future<void> _bindPromptKeys(int buf) async {
    const bothModeMappings = <String, String>{
      '<Tab>': 'search.target_next',
      '<S-Tab>': 'search.target_prev',
      '<C-t>': 'search.target_dropdown',
      '<C-s>': 'search.scope_dropdown',
      '<C-g>': 'search.custom_glob',
      '<Down>': 'search.next_item',
      '<Up>': 'search.prev_item',
      '<C-n>': 'search.next_item',
      '<C-p>': 'search.prev_item',
      '<C-d>': 'search.preview_down',
      '<C-u>': 'search.preview_up',
      '<M-p>': 'search.toggle_preview',
      '<CR>': 'search.confirm',
      '<LeftDrag>': 'search.mouse_drag',
    };

    for (final entry in bothModeMappings.entries) {
      for (final mode in ['i', 'n']) {
        await nvim.bufSetKeymap(
          buf,
          mode,
          entry.key,
          "<Cmd>lua require('$luaModule').action('${entry.value}')<CR>",
        );
      }
    }

    // Normal mode navigation & close
    const normalMappings = <String, String>{
      'j': 'search.next_item',
      'k': 'search.prev_item',
      'q': 'search.close',
      '<Esc>': 'search.close',
      '<C-c>': 'search.close',
    };
    for (final entry in normalMappings.entries) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        entry.key,
        "<Cmd>lua require('$luaModule').action('${entry.value}')<CR>",
      );
    }

    // Insert mode <Esc> and <C-c> close the picker directly
    for (final key in ['<Esc>', '<C-c>']) {
      await nvim.bufSetKeymap(
        buf,
        'i',
        key,
        "<Esc><Cmd>lua require('$luaModule').action('search.close')<CR>",
      );
    }

    // Mouse click on prompt pills
    for (final mode in ['n', 'i']) {
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<LeftRelease>',
        "<LeftMouse><Cmd>lua require('$luaModule').action('search.prompt_click')<CR>",
      );
    }
  }

  Future<void> _bindResultsKeys(int buf) async {
    const mappings = <String, String>{
      'j': 'search.next_item',
      'k': 'search.prev_item',
      '<Down>': 'search.next_item',
      '<Up>': 'search.prev_item',
      '<C-n>': 'search.next_item',
      '<C-p>': 'search.prev_item',
      '<Tab>': 'search.target_next',
      '<S-Tab>': 'search.target_prev',
      '<C-t>': 'search.target_dropdown',
      '<C-s>': 'search.scope_dropdown',
      '<C-g>': 'search.custom_glob',
      '<C-d>': 'search.preview_down',
      '<C-u>': 'search.preview_up',
      '<M-p>': 'search.toggle_preview',
      '<CR>': 'search.confirm',
      'q': 'search.close',
      '<Esc>': 'search.close',
      '<C-c>': 'search.close',
      '<LeftDrag>': 'search.mouse_drag',
    };
    for (final entry in mappings.entries) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        entry.key,
        "<Cmd>lua require('$luaModule').action('${entry.value}')<CR>",
      );
    }
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<LeftRelease>',
      "<LeftMouse><Cmd>lua require('$luaModule').action('search.results_click')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<2-LeftMouse>',
      "<LeftMouse><Cmd>lua require('$luaModule').action('search.results_double_click')<CR>",
    );
  }

  Future<void> _bindPreviewKeys(int buf) async {
    const mappings = <String, String>{
      'q': 'search.close',
      '<Esc>': 'search.close',
      '<C-c>': 'search.close',
      '<CR>': 'search.confirm',
      '<Tab>': 'search.target_next',
      '<S-Tab>': 'search.target_prev',
      '<C-t>': 'search.target_dropdown',
      '<C-s>': 'search.scope_dropdown',
      '<C-g>': 'search.custom_glob',
      '<M-p>': 'search.toggle_preview',
      '<LeftDrag>': 'search.mouse_drag',
    };
    for (final entry in mappings.entries) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        entry.key,
        "<Cmd>lua require('$luaModule').action('${entry.value}')<CR>",
      );
    }
  }

  Future<void> _attachAutocmds(int promptBuf) async {
    final luaCode = '''
local buf = ...
local grp = vim.api.nvim_create_augroup('VisearchPicker', { clear = true })
vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
  group = grp,
  buffer = buf,
  callback = function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
    local q = lines[1] or ''
    require('$luaModule').action('search.query_changed', q)
  end,
})
vim.api.nvim_create_autocmd('VimResized', {
  group = grp,
  callback = function()
    require('$luaModule').action('search.vim_resized')
  end,
})
''';
    try {
      await nvim.execLua(luaCode, [promptBuf]);
    } catch (_) {}
  }

  Future<void> _focusPrompt({required bool startInsert}) async {
    final pWin = _promptWin;
    if (pWin == null || !await nvim.winIsValid(pWin)) return;
    await nvim.setCurrentWin(pWin);
    await nvim.winSetCursor(pWin, 1, _query.length);
    if (startInsert) {
      await nvim.command('startinsert!');
    }
  }

  Future<void> _runSearch() async {
    final gen = ++_searchGeneration;

    List<SearchItem> found;
    var totalScoped = 0;

    switch (_target) {
      case SearchTarget.files:
        final (items, total) = await filesProvider.search(
          workspaceRoot: _workspaceRoot,
          query: _query,
          scope: _scope,
          settings: _settings,
        );
        found = items;
        totalScoped = total;
      case SearchTarget.text:
        found = await textProvider.search(
          workspaceRoot: _workspaceRoot,
          query: _query,
          scope: _scope,
          settings: _settings,
          currentBufferLines: _originBufLines,
        );
        totalScoped = found.length;
      case SearchTarget.symbols:
        found = await symbolsProvider.search(
          nvim: nvim,
          workspaceRoot: _workspaceRoot,
          query: _query,
          scope: _scope,
          originBuf: _originBuf,
          settings: _settings,
        );
        totalScoped = found.length;
    }

    if (gen != _searchGeneration) return;
    if (!await isOpen()) return;

    _items = found;
    _totalScopedCount = totalScoped;
    if (_selectedIndex >= _items.length) {
      _selectedIndex = 0;
    }

    await _renderPromptPills();
    await _renderResults();
    await _renderPreview();
  }

  Future<void> _renderPromptPills() async {
    final pBuf = _promptBuf;
    final pWin = _promptWin;
    final nsId = _nsId;
    if (pBuf == null ||
        nsId == null ||
        !await nvim.bufIsValid(pBuf)) {
      return;
    }

    await nvim.bufClearNamespace(pBuf, nsId);
    await nvim.bufSetExtmark(pBuf, nsId, 0, 0, {
      'virt_text': [
        [' [ 󰉋 Scope: ${_scope.label} ▾ ] ', 'VisearchPillScope'],
        [' ', 'Normal'],
        [' [ ${_target.icon} ${_target.label} ▾ ] ', 'VisearchPillTarget'],
      ],
      'virt_text_pos': 'right_align',
    });

    if (pWin != null && await nvim.winIsValid(pWin) && _lastGeometry != null) {
      await nvim.winSetConfig(pWin, _promptWinConfig(_lastGeometry!));
    }
  }

  Future<void> _renderResults() async {
    final rBuf = _resultsBuf;
    final rWin = _resultsWin;
    final nsId = _nsId;
    if (rBuf == null || nsId == null || !await nvim.bufIsValid(rBuf)) return;

    await nvim.bufSetOption(rBuf, 'modifiable', true);
    await nvim.bufClearNamespace(rBuf, nsId);

    if (_items.isEmpty) {
      final emptyMsg = _target == SearchTarget.text && _query.trim().isEmpty
          ? '  Type a search query to run ripgrep (rg)…'
          : '  No matching ${_target.label.toLowerCase()} found in ${_scope.label}';
      await nvim.bufSetLines(rBuf, lines: [emptyMsg]);
      await nvim.bufSetOption(rBuf, 'modifiable', false);
      await nvim.bufSetExtmark(rBuf, nsId, 0, 0, {
        'end_col': utf8.encode(emptyMsg).length,
        'hl_group': 'VisearchMuted',
      });
      if (rWin != null && await nvim.winIsValid(rWin) && _lastGeometry != null) {
        await nvim.winSetConfig(rWin, _resultsWinConfig(_lastGeometry!));
      }
      return;
    }

    const rowPrefix = '  ';
    final prefixBytes = utf8.encode(rowPrefix).length;
    final lines = _items.map((item) => '$rowPrefix${item.title}').toList();

    await nvim.bufSetLines(rBuf, lines: lines);
    await nvim.bufSetOption(rBuf, 'modifiable', false);

    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      // Highlight matched character indices
      for (final charIdx in item.matchIndices) {
        if (charIdx >= 0 && charIdx < item.title.length) {
          final byteStart =
              prefixBytes + utf8.encode(item.title.substring(0, charIdx)).length;
          final charByteLen =
              utf8.encode(item.title.substring(charIdx, charIdx + 1)).length;
          await nvim.bufSetExtmark(rBuf, nsId, i, byteStart, {
            'end_col': byteStart + charByteLen,
            'hl_group': 'VisearchMatch',
          });
        }
      }

      if (item.badge != null && item.badge!.isNotEmpty) {
        await nvim.bufSetExtmark(rBuf, nsId, i, 0, {
          'virt_text': [
            [' ${item.badge!} ', 'VisearchBadge'],
          ],
          'virt_text_pos': 'right_align',
        });
      }
    }

    if (rWin != null && await nvim.winIsValid(rWin)) {
      final targetRow = (_selectedIndex + 1).clamp(1, lines.length);
      await nvim.winSetCursor(rWin, targetRow, 0);
      if (_lastGeometry != null) {
        await nvim.winSetConfig(rWin, _resultsWinConfig(_lastGeometry!));
      }
    }
  }

  Future<void> _renderPreview() async {
    final prevBuf = _previewBuf;
    final prevWin = _previewWin;
    final nsId = _nsId;
    if (prevBuf == null ||
        prevWin == null ||
        nsId == null ||
        !await nvim.bufIsValid(prevBuf) ||
        !await nvim.winIsValid(prevWin)) {
      return;
    }

    await nvim.bufClearNamespace(prevBuf, nsId);

    if (_items.isEmpty || _selectedIndex >= _items.length) {
      await nvim.bufSetOption(prevBuf, 'modifiable', true);
      await nvim.bufSetLines(prevBuf, lines: const ['']);
      await nvim.bufSetOption(prevBuf, 'modifiable', false);
      if (_lastGeometry != null) {
        await nvim.winSetConfig(prevWin, _previewWinConfig(_lastGeometry!));
      }
      return;
    }

    final item = _items[_selectedIndex];
    List<String> fileLines;
    try {
      final file = File(item.filePath);
      if (await file.exists()) {
        final raw = await file.readAsString();
        fileLines = raw.split('\n');
        if (fileLines.length > 800) {
          fileLines = fileLines.sublist(0, 800);
        }
      } else {
        fileLines = const ['  [File not found on disk]'];
      }
    } catch (_) {
      fileLines = const ['  [Binary or unreadable file]'];
    }

    if (fileLines.isEmpty) {
      fileLines = const [''];
    }

    await nvim.bufSetOption(prevBuf, 'modifiable', true);
    await nvim.bufSetLines(prevBuf, lines: fileLines);
    await nvim.bufSetOption(prevBuf, 'modifiable', false);

    // Apply Neovim filetype / Treesitter syntax highlighting
    try {
      await nvim.execLua(
        r'''
local buf, fname = ...
if vim.api.nvim_buf_is_valid(buf) then
  local ft = vim.filetype.match({ filename = fname, buf = buf })
  if ft and ft ~= '' then
    vim.bo[buf].filetype = ft
    pcall(vim.treesitter.start, buf)
  end
end
''',
        [prevBuf, item.filePath],
      );
    } catch (_) {}

    final targetLine1Based = item.line.clamp(1, fileLines.length);
    final lineIdx0 = targetLine1Based - 1;
    final lineBytes = utf8.encode(fileLines[lineIdx0]).length;

    await nvim.bufSetExtmark(prevBuf, nsId, lineIdx0, 0, {
      'end_col': lineBytes,
      'hl_group': 'VisearchPreviewTargetLine',
      'hl_eol': true,
    });

    await nvim.winSetCursor(
      prevWin,
      targetLine1Based,
      item.col.clamp(0, lineBytes),
    );

    if (_lastGeometry != null) {
      await nvim.winSetConfig(prevWin, _previewWinConfig(_lastGeometry!));
    }
  }
}
