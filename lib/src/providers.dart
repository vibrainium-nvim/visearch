import 'dart:io';

import 'package:nvim/nvim.dart';
import 'package:visettings/visettings.dart';

import 'fuzzy.dart';
import 'scope.dart';

/// Search target mode in the unified `visearch` picker.
enum SearchTarget {
  files('Files', '󰈔'),
  text('Text', '󰊄'),
  symbols('Symbols', '󰌗');

  final String label;
  final String icon;
  const SearchTarget(this.label, this.icon);
}

/// A single result row displayed in the `visearch` Results pane.
class SearchItem {
  final String title;
  final String? subtitle;
  final String? badge;
  final String filePath;
  final String relativePath;
  final int line; // 1-based
  final int col; // 0-based
  final String? symbolKind;
  final List<int> matchIndices;
  final int score;

  const SearchItem({
    required this.title,
    this.subtitle,
    this.badge,
    required this.filePath,
    required this.relativePath,
    this.line = 1,
    this.col = 0,
    this.symbolKind,
    this.matchIndices = const [],
    this.score = 0,
  });
}

/// Signature for running an external command, injectable for testing.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

Future<ProcessResult> _defaultProcessRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) {
  return Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
}

/// Provides file search results using `rg --files` cached per workspace root.
class FilesProvider {
  final ProcessRunner runProcess;
  final Map<String, List<String>> _cache = {};

  FilesProvider({this.runProcess = _defaultProcessRunner});

  void clearCache([String? workspaceRoot]) {
    if (workspaceRoot == null) {
      _cache.clear();
    } else {
      _cache.remove(workspaceRoot);
    }
  }

  /// Loads and caches relative file paths for [workspaceRoot] via `rg --files`.
  Future<List<String>> listWorkspaceFiles(
    String workspaceRoot, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _cache.containsKey(workspaceRoot)) {
      return _cache[workspaceRoot]!;
    }

    try {
      final res = await runProcess(
        'rg',
        const [
          '--files',
          '--hidden',
          '-g',
          '!.git',
          '-g',
          '!.svn',
          '-g',
          '!.dart_tool',
        ],
        workingDirectory: workspaceRoot,
      );
      if (res.exitCode != 0 && (res.stdout as String).trim().isEmpty) {
        return const [];
      }
      final files = (res.stdout as String)
          .split('\n')
          .map((line) => line.trim().replaceAll(r'\', '/'))
          .where((line) => line.isNotEmpty)
          .map((line) => line.startsWith('./') ? line.substring(2) : line)
          .toList()
        ..sort();
      _cache[workspaceRoot] = List.unmodifiable(files);
      return _cache[workspaceRoot]!;
    } catch (_) {
      return const [];
    }
  }

  /// Searches workspace files filtered by [scope] and [settings], scored against [query].
  Future<(List<SearchItem> items, int totalScoped)> search({
    required String workspaceRoot,
    required String query,
    required SearchScope scope,
    VibrainiumSettings settings = const VibrainiumSettings(),
    int maxResults = 250,
  }) async {
    List<String> candidates;
    if (scope.kind == ScopeKind.currentBuffer) {
      final bufPath = scope.currentBufferPath;
      if (bufPath == null || bufPath.isEmpty) {
        return (const <SearchItem>[], 0);
      }
      final rel = SearchScope.toRelativePath(workspaceRoot, bufPath);
      candidates = rel.isEmpty ? const [] : [rel];
    } else {
      final allFiles = await listWorkspaceFiles(workspaceRoot);
      candidates = allFiles
          .where(
            (rel) => scope.matchesPath(
              workspaceRoot,
              rel,
              settings: settings,
            ),
          )
          .toList();
    }

    final totalScoped = candidates.length;
    final trimmed = query.trim();

    if (trimmed.isEmpty) {
      final items = candidates.take(maxResults).map((rel) {
        return SearchItem(
          title: rel,
          filePath: '$workspaceRoot/$rel',
          relativePath: rel,
        );
      }).toList();
      return (items, totalScoped);
    }

    final matched = <SearchItem>[];
    for (final rel in candidates) {
      final m = FuzzyMatcher.match(trimmed, rel);
      if (m != null) {
        matched.add(
          SearchItem(
            title: rel,
            filePath: '$workspaceRoot/$rel',
            relativePath: rel,
            matchIndices: m.matchIndices,
            score: m.score,
          ),
        );
      }
    }

    matched.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      return a.relativePath.compareTo(b.relativePath);
    });

    final capped =
        matched.length > maxResults ? matched.sublist(0, maxResults) : matched;
    return (capped, totalScoped);
  }
}

/// Provides live text search results using `rg --vimgrep`.
class TextProvider {
  final ProcessRunner runProcess;

  const TextProvider({this.runProcess = _defaultProcessRunner});

  Future<List<SearchItem>> search({
    required String workspaceRoot,
    required String query,
    required SearchScope scope,
    VibrainiumSettings settings = const VibrainiumSettings(),
    List<String>? currentBufferLines,
    int maxResults = 200,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const [];
    }

    // If scoped to Current Buffer and buffer lines are available in-memory,
    // search them directly (or run rg on the current buffer file).
    if (scope.kind == ScopeKind.currentBuffer && currentBufferLines != null) {
      final bufPath = scope.currentBufferPath ?? '';
      final rel = SearchScope.toRelativePath(workspaceRoot, bufPath);
      final displayRel = rel.isEmpty ? bufPath : rel;
      final qLower = trimmed.toLowerCase();
      final results = <SearchItem>[];

      for (var i = 0; i < currentBufferLines.length; i++) {
        final lineText = currentBufferLines[i];
        final col = lineText.toLowerCase().indexOf(qLower);
        if (col != -1) {
          final snippet = lineText.trim();
          final title = '$displayRel:${i + 1}: $snippet';
          final prefixLen = '$displayRel:${i + 1}: '.length;
          final snippetCol = snippet.toLowerCase().indexOf(qLower);
          final indices = snippetCol == -1
              ? const <int>[]
              : List<int>.generate(
                  trimmed.length,
                  (k) => prefixLen + snippetCol + k,
                );
          results.add(
            SearchItem(
              title: title,
              badge: '${i + 1}:${col + 1}',
              filePath: bufPath,
              relativePath: displayRel,
              line: i + 1,
              col: col,
              matchIndices: indices,
            ),
          );
          if (results.length >= maxResults) break;
        }
      }
      return results;
    }

    final args = <String>[
      '--vimgrep',
      '--smart-case',
      '--hidden',
      '--max-columns',
      '240',
      '--max- columns-preview'.replaceAll(' ', ''),
      '-g',
      '!.git',
      '-g',
      '!.svn',
      '-g',
      '!.dart_tool',
      ...scope.buildRgArgs(settings: settings),
      '--',
      trimmed,
    ];

    if (scope.kind == ScopeKind.currentBuffer) {
      final bufPath = scope.currentBufferPath;
      if (bufPath == null || bufPath.isEmpty) return const [];
      args.add(bufPath);
    }

    try {
      final res = await runProcess(
        'rg',
        args,
        workingDirectory: workspaceRoot,
      );
      final stdoutStr = (res.stdout as String?) ?? '';
      if (stdoutStr.trim().isEmpty) return const [];

      final items = <SearchItem>[];
      final qLower = trimmed.toLowerCase();
      final lines = stdoutStr.split('\n');

      for (final rawLine in lines) {
        if (rawLine.isEmpty) continue;
        final parsed = _parseVimgrepLine(rawLine);
        if (parsed == null) continue;
        final (rawFile, lineNum, col1Based, text) = parsed;
        final rel = SearchScope.toRelativePath(workspaceRoot, rawFile);
        if (!scope.matchesPath(workspaceRoot, rel, settings: settings)) {
          continue;
        }

        final fullPath =
            rawFile.startsWith('/') ? rawFile : '$workspaceRoot/$rel';
        final snippet = text.trim();
        final title = '$rel:$lineNum: $snippet';
        final prefixLen = '$rel:$lineNum: '.length;
        final snippetIdx = snippet.toLowerCase().indexOf(qLower);
        final matchIndices = snippetIdx == -1
            ? const <int>[]
            : List<int>.generate(
                trimmed.length,
                (i) => prefixLen + snippetIdx + i,
              );

        items.add(
          SearchItem(
            title: title,
            badge: '$lineNum:$col1Based',
            filePath: fullPath,
            relativePath: rel,
            line: lineNum,
            col: (col1Based - 1).clamp(0, 10000),
            matchIndices: matchIndices,
          ),
        );
        if (items.length >= maxResults) break;
      }
      return items;
    } catch (_) {
      return const [];
    }
  }

  static (String file, int line, int col, String text)? _parseVimgrepLine(
    String raw,
  ) {
    // Format: path:line:col:text
    final match = RegExp(r'^(.+?):(\d+):(\d+):(.*)$').firstMatch(raw);
    if (match == null) return null;
    final file = match.group(1)!.replaceAll(r'\', '/');
    final line = int.tryParse(match.group(2)!) ?? 1;
    final col = int.tryParse(match.group(3)!) ?? 1;
    final text = match.group(4) ?? '';
    return (file, line, col, text);
  }
}

/// Provides LSP symbol search results using Neovim's built-in `vim.lsp`
/// (`workspace/symbol` and `textDocument/documentSymbol`).
class SymbolsProvider {
  static const String _luaQuerySymbols = r'''
local mode, query, origin_buf = ...
local results = {}
local kind_names = {
  [1] = 'File', [2] = 'Module', [3] = 'Namespace', [4] = 'Package',
  [5] = 'Class', [6] = 'Method', [7] = 'Property', [8] = 'Field',
  [9] = 'Constructor', [10] = 'Enum', [11] = 'Interface', [12] = 'Function',
  [13] = 'Variable', [14] = 'Constant', [15] = 'String', [16] = 'Number',
  [17] = 'Boolean', [18] = 'Array', [19] = 'Object', [20] = 'Key',
  [21] = 'Null', [22] = 'EnumMember', [23] = 'Struct', [24] = 'Event',
  [25] = 'Operator', [26] = 'TypeParameter',
}

local function add_doc_symbols(items, file_path, container)
  if type(items) ~= 'table' then return end
  for _, sym in ipairs(items) do
    local name = sym.name or ''
    local kind = kind_names[sym.kind] or 'Symbol'
    local range = sym.selectionRange or sym.range or (sym.location and sym.location.range)
    local lnum = 1
    local col = 0
    if range and range.start then
      lnum = (range.start.line or 0) + 1
      col = range.start.character or 0
    end
    local fpath = file_path
    if sym.location and sym.location.uri then
      fpath = vim.uri_to_fname(sym.location.uri)
    end
    if name ~= '' and fpath and fpath ~= '' then
      table.insert(results, {
        name = name,
        kind = kind,
        container = container or sym.containerName or '',
        file = fpath,
        line = lnum,
        col = col,
      })
    end
    if sym.children then
      local next_container = container and (container .. '.' .. name) or name
      add_doc_symbols(sym.children, fpath, next_container)
    end
  end
end

local function fetch_doc_symbols(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not fname or fname == '' then return end
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local res = vim.lsp.buf_request_sync(bufnr, 'textDocument/documentSymbol', params, 800)
  if type(res) == 'table' then
    for _, client_res in pairs(res) do
      if client_res and type(client_res.result) == 'table' then
        add_doc_symbols(client_res.result, fname, nil)
      end
    end
  end
end

if mode == 'buffer' then
  fetch_doc_symbols(origin_buf)
else
  local target_buf = (origin_buf and vim.api.nvim_buf_is_valid(origin_buf)) and origin_buf or 0
  local ws_res = vim.lsp.buf_request_sync(target_buf, 'workspace/symbol', { query = query or '' }, 1000)
  if type(ws_res) == 'table' then
    for _, client_res in pairs(ws_res) do
      if client_res and type(client_res.result) == 'table' then
        add_doc_symbols(client_res.result, nil, nil)
      end
    end
  end
  if #results == 0 then
    if origin_buf and vim.api.nvim_buf_is_valid(origin_buf) then
      fetch_doc_symbols(origin_buf)
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= origin_buf and vim.api.nvim_buf_is_loaded(b) then
        local bt = vim.bo[b].buftype
        if bt == '' then
          fetch_doc_symbols(b)
        end
      end
    end
  end
end

return results
''';

  const SymbolsProvider();

  Future<List<SearchItem>> search({
    required Nvim nvim,
    required String workspaceRoot,
    required String query,
    required SearchScope scope,
    required int? originBuf,
    VibrainiumSettings settings = const VibrainiumSettings(),
    int maxResults = 250,
  }) async {
    final mode = scope.kind == ScopeKind.currentBuffer ? 'buffer' : 'workspace';
    Object? raw;
    try {
      raw = await nvim.execLua(_luaQuerySymbols, [
        mode,
        query.trim(),
        originBuf ?? 0,
      ]);
    } catch (_) {
      return const [];
    }

    if (raw is! List) return const [];

    final trimmed = query.trim();
    final matched = <SearchItem>[];

    for (final entry in raw) {
      if (entry is! Map) continue;
      final name = entry['name']?.toString() ?? '';
      final kind = entry['kind']?.toString() ?? 'Symbol';
      final file = (entry['file']?.toString() ?? '').replaceAll(r'\', '/');
      final line = (entry['line'] as num?)?.toInt() ?? 1;
      final col = (entry['col'] as num?)?.toInt() ?? 0;
      if (name.isEmpty || file.isEmpty) continue;

      if (!scope.matchesPath(workspaceRoot, file, settings: settings)) {
        continue;
      }

      final rel = SearchScope.toRelativePath(workspaceRoot, file);
      final displayRel = rel.isEmpty ? file : rel;
      final title = '$name  $displayRel:$line';

      if (trimmed.isEmpty) {
        matched.add(
          SearchItem(
            title: title,
            badge: '[$kind]',
            filePath: file,
            relativePath: displayRel,
            line: line,
            col: col,
            symbolKind: kind,
          ),
        );
      } else {
        final m = FuzzyMatcher.match(trimmed, name) ??
            FuzzyMatcher.match(trimmed, '$name $kind');
        if (m != null) {
          final indices =
              m.matchIndices.where((idx) => idx < name.length).toList();
          matched.add(
            SearchItem(
              title: title,
              badge: '[$kind]',
              filePath: file,
              relativePath: displayRel,
              line: line,
              col: col,
              symbolKind: kind,
              matchIndices: indices,
              score: m.score,
            ),
          );
        }
      }
    }

    if (trimmed.isNotEmpty) {
      matched.sort((a, b) {
        final cmp = b.score.compareTo(a.score);
        if (cmp != 0) return cmp;
        return a.title.compareTo(b.title);
      });
    }

    return matched.length > maxResults
        ? matched.sublist(0, maxResults)
        : matched;
  }
}
