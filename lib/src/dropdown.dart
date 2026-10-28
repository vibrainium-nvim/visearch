import 'package:nvim/nvim.dart';

/// Item in a floating dropdown menu.
class DropdownItem<T> {
  final String label;
  final T value;
  final bool isActive;

  const DropdownItem({
    required this.label,
    required this.value,
    this.isActive = false,
  });
}

/// Reusable floating dropdown menu anchored near the search prompt header.
class DropdownMenu<T> {
  final Nvim nvim;
  final String luaModule;
  final String actionPrefix;

  int? _buf;
  int? _win;
  List<DropdownItem<T>> _items = const [];
  Future<void> Function(T value)? _onSelect;
  Future<void> Function()? _onCancel;

  DropdownMenu(
    this.nvim, {
    this.luaModule = 'vibrainium',
    required this.actionPrefix,
  });

  bool get isOpen => _win != null;
  int? get windowId => _win;
  int? get bufferId => _buf;

  Future<void> open({
    required String title,
    required List<DropdownItem<T>> items,
    required int row,
    required int col,
    required Future<void> Function(T value) onSelect,
    Future<void> Function()? onCancel,
  }) async {
    await close();
    if (items.isEmpty) return;

    _items = items;
    _onSelect = onSelect;
    _onCancel = onCancel;

    final buf = await nvim.createBuf(listed: false, scratch: true);
    _buf = buf;

    final lines = <String>[];
    var maxWidth = title.length + 4;
    var activeIndex = 0;

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.isActive) {
        activeIndex = i;
      }
      final prefix = item.isActive ? ' ● ' : '   ';
      final line = '$prefix${item.label} ';
      lines.add(line);
      if (line.runes.length > maxWidth) {
        maxWidth = line.runes.length;
      }
    }

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetLines(buf, lines: lines);
    await nvim.bufSetOption(buf, 'modifiable', false);
    await nvim.bufSetOption(buf, 'buftype', 'nofile');
    await nvim.bufSetOption(buf, 'bufhidden', 'wipe');
    await nvim.bufSetOption(buf, 'filetype', 'visearch-dropdown');

    final width = maxWidth.clamp(20, 56);
    final height = lines.length.clamp(1, 14);

    final win = await nvim.openWin(buf, true, {
      'relative': 'editor',
      'row': row,
      'col': col,
      'width': width,
      'height': height,
      'style': 'minimal',
      'border': 'rounded',
      'title': ' $title ',
      'title_pos': 'center',
      'zindex': 150,
    });
    _win = win;

    await nvim.winSetOption(win, 'cursorline', true);
    await nvim.winSetOption(win, 'wrap', false);
    await nvim.winSetCursor(win, activeIndex + 1, 0);

    await nvim.bufSetKeymap(
      buf,
      'n',
      '<CR>',
      "<Cmd>lua require('$luaModule').action('$actionPrefix.confirm')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<LeftRelease>',
      "<LeftMouse><Cmd>lua require('$luaModule').action('$actionPrefix.confirm')<CR>",
    );
    for (final cancelKey in ['q', '<Esc>']) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        cancelKey,
        "<Cmd>lua require('$luaModule').action('$actionPrefix.cancel')<CR>",
      );
    }
  }

  Future<void> confirm() async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) {
      await close();
      return;
    }
    final (row, _) = await nvim.winGetCursor(win);
    final idx = row - 1;
    final items = _items;
    final callback = _onSelect;
    await close();
    if (callback != null && idx >= 0 && idx < items.length) {
      await callback(items[idx].value);
    }
  }

  Future<void> cancel() async {
    final callback = _onCancel;
    await close();
    if (callback != null) {
      await callback();
    }
  }

  Future<void> close() async {
    final win = _win;
    _win = null;
    _buf = null;
    if (win != null) {
      try {
        if (await nvim.winIsValid(win)) {
          await nvim.winClose(win, force: true);
        }
      } catch (_) {}
    }
  }
}

/// Floating single-line input prompt for entering custom comma-separated
/// paths or wildcard globs (e.g. `vivcs/lib, **/test/*_test.dart`).
class GlobInputPrompt {
  final Nvim nvim;
  final String luaModule;
  int? _buf;
  int? _win;
  Future<void> Function(String value)? _onSubmit;
  Future<void> Function()? _onCancel;

  GlobInputPrompt(this.nvim, {this.luaModule = 'vibrainium'});

  bool get isOpen => _win != null;
  int? get windowId => _win;
  int? get bufferId => _buf;

  Future<void> open({
    String initialValue = '',
    required Future<void> Function(String value) onSubmit,
    Future<void> Function()? onCancel,
  }) async {
    await close();
    _onSubmit = onSubmit;
    _onCancel = onCancel;

    final buf = await nvim.createBuf(listed: false, scratch: true);
    _buf = buf;

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetOption(buf, 'buftype', 'nofile');
    await nvim.bufSetOption(buf, 'bufhidden', 'wipe');
    await nvim.bufSetOption(buf, 'filetype', 'visearch-glob-prompt');
    await nvim.bufSetLines(buf, lines: [initialValue]);

    final editorWidth = await nvim.getEditorWidth();
    final editorHeight = await nvim.getEditorHeight();
    final width = (editorWidth * 0.5).round().clamp(44, 72);
    const height = 1;
    final row = ((editorHeight - height) / 2).floor().clamp(1, editorHeight);
    final col = ((editorWidth - width) / 2).floor().clamp(1, editorWidth);

    final win = await nvim.openWin(buf, true, {
      'relative': 'editor',
      'row': row,
      'col': col,
      'width': width,
      'height': height,
      'style': 'minimal',
      'border': 'rounded',
      'title': ' Custom Scope Paths/Globs (comma-separated, * / ** / ! supported) ',
      'title_pos': 'center',
      'zindex': 160,
    });
    _win = win;

    if (initialValue.isNotEmpty) {
      await nvim.winSetCursor(win, 1, initialValue.length);
    }

    await nvim.bufSetKeymap(
      buf,
      'n',
      '<CR>',
      "<Cmd>lua require('$luaModule').action('search.glob_submit')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'i',
      '<CR>',
      "<Esc><Cmd>lua require('$luaModule').action('search.glob_submit')<CR>",
    );
    for (final key in ['q', '<Esc>']) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        key,
        "<Cmd>lua require('$luaModule').action('search.glob_cancel')<CR>",
      );
    }
    await nvim.bufSetKeymap(
      buf,
      'i',
      '<Esc>',
      "<Esc><Cmd>lua require('$luaModule').action('search.glob_cancel')<CR>",
    );

    await nvim.command('startinsert!');
  }

  Future<void> submit() async {
    final buf = _buf;
    if (buf == null || !await nvim.bufIsValid(buf)) {
      await close();
      return;
    }
    final lines = await nvim.bufGetLines(buf);
    final val = lines.isEmpty ? '' : lines.first.trim();
    final callback = _onSubmit;
    await close();
    if (callback != null) {
      await callback(val);
    }
  }

  Future<void> cancel() async {
    final callback = _onCancel;
    await close();
    if (callback != null) {
      await callback();
    }
  }

  Future<void> close() async {
    final win = _win;
    _win = null;
    _buf = null;
    if (win != null) {
      try {
        if (await nvim.winIsValid(win)) {
          await nvim.winClose(win, force: true);
        }
      } catch (_) {}
    }
  }
}
