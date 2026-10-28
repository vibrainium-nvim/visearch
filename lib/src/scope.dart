import 'dart:io';

import 'package:visettings/visettings.dart';

/// Kind of search scope active in the `visearch` picker.
enum ScopeKind {
  workspace,
  currentBuffer,
  subproject,
  customGlob,
}

/// Compiles comma-separated relative paths and wildcard/glob patterns
/// (supporting `*`, `**`, `?`, and leading `!` negation) for both in-memory
/// filtering and `rg -g` arguments.
class GlobMatcher {
  final String rawSpec;
  final List<WildcardPattern> includePatterns;
  final List<WildcardPattern> excludePatterns;
  final List<String> rgGlobs;

  GlobMatcher._({
    required this.rawSpec,
    required this.includePatterns,
    required this.excludePatterns,
    required this.rgGlobs,
  });

  factory GlobMatcher(String rawSpec) {
    final includes = <WildcardPattern>[];
    final excludes = <WildcardPattern>[];
    final rgGlobs = <String>[];

    final parts = rawSpec
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);

    for (var part in parts) {
      var isNegated = false;
      if (part.startsWith('!')) {
        isNegated = true;
        part = part.substring(1).trim();
        if (part.isEmpty) continue;
      }

      var norm = part.replaceAll(r'\', '/');
      while (norm.startsWith('./')) {
        norm = norm.substring(2);
      }
      while (norm.startsWith('/')) {
        norm = norm.substring(1);
      }

      final hasGlobChars =
          norm.contains('*') || norm.contains('?') || norm.contains('[');

      if (!hasGlobChars) {
        var clean = norm;
        while (clean.endsWith('/') && clean.length > 1) {
          clean = clean.substring(0, clean.length - 1);
        }
        // Match exact file or anything under that directory prefix
        final exactPattern = WildcardPattern('./$clean');
        final dirPrefixPattern = WildcardPattern('./$clean/**');
        if (isNegated) {
          excludes.add(exactPattern);
          excludes.add(dirPrefixPattern);
          rgGlobs.add('!$clean');
          rgGlobs.add('!$clean/**');
        } else {
          includes.add(exactPattern);
          includes.add(dirPrefixPattern);
          rgGlobs.add(clean);
          rgGlobs.add('$clean/**');
        }
      } else {
        final pattern = WildcardPattern(norm);
        if (isNegated) {
          excludes.add(pattern);
          rgGlobs.add('!$norm');
        } else {
          includes.add(pattern);
          rgGlobs.add(norm);
        }
      }
    }

    return GlobMatcher._(
      rawSpec: rawSpec.trim(),
      includePatterns: List.unmodifiable(includes),
      excludePatterns: List.unmodifiable(excludes),
      rgGlobs: List.unmodifiable(rgGlobs),
    );
  }

  bool get isEmpty => includePatterns.isEmpty && excludePatterns.isEmpty;

  /// Returns `true` if a workspace-relative path matches this glob specification.
  bool matches(String relativePath) {
    var norm = relativePath.replaceAll(r'\', '/');
    while (norm.startsWith('./')) {
      norm = norm.substring(2);
    }
    while (norm.startsWith('/')) {
      norm = norm.substring(1);
    }
    if (norm.isEmpty) return false;

    final slashIdx = norm.lastIndexOf('/');
    final name = slashIdx == -1 ? norm : norm.substring(slashIdx + 1);

    for (final ex in excludePatterns) {
      if (ex.matches(norm, name: name)) {
        return false;
      }
    }

    if (includePatterns.isEmpty) {
      return true;
    }

    for (final inc in includePatterns) {
      if (inc.matches(norm, name: name)) {
        return true;
      }
    }
    return false;
  }
}

/// Represents the active search scope in `visearch`.
class SearchScope {
  final ScopeKind kind;
  final String label;
  final String? subprojectPath;
  final String? currentBufferPath;
  final GlobMatcher? customMatcher;

  const SearchScope._({
    required this.kind,
    required this.label,
    this.subprojectPath,
    this.currentBufferPath,
    this.customMatcher,
  });

  const SearchScope.workspace()
      : this._(
          kind: ScopeKind.workspace,
          label: 'Workspace',
        );

  factory SearchScope.currentBuffer(String? bufferPath) {
    return SearchScope._(
      kind: ScopeKind.currentBuffer,
      label: 'Current Buffer',
      currentBufferPath: bufferPath,
    );
  }

  factory SearchScope.subproject(String relativePath) {
    var clean = relativePath.replaceAll(r'\', '/');
    while (clean.startsWith('./')) {
      clean = clean.substring(2);
    }
    while (clean.endsWith('/') && clean.length > 1) {
      clean = clean.substring(0, clean.length - 1);
    }
    return SearchScope._(
      kind: ScopeKind.subproject,
      label: clean,
      subprojectPath: clean,
    );
  }

  factory SearchScope.customGlob(String spec) {
    final trimmed = spec.trim();
    return SearchScope._(
      kind: ScopeKind.customGlob,
      label: trimmed.length > 22 ? '${trimmed.substring(0, 19)}…' : trimmed,
      customMatcher: GlobMatcher(trimmed),
    );
  }

  /// Normalizes [filePath] relative to [workspaceRoot] using forward slashes.
  static String toRelativePath(String workspaceRoot, String filePath) {
    var root = workspaceRoot.replaceAll(r'\', '/');
    while (root.endsWith('/') && root.length > 1) {
      root = root.substring(0, root.length - 1);
    }
    var norm = filePath.replaceAll(r'\', '/');
    if (norm == root) return '';
    if (norm.startsWith('$root/')) {
      norm = norm.substring(root.length + 1);
    }
    while (norm.startsWith('./')) {
      norm = norm.substring(2);
    }
    return norm;
  }

  /// Checks whether [filePath] (absolute or relative to [workspaceRoot]) is
  /// included in this scope and not excluded by [settings].
  bool matchesPath(
    String workspaceRoot,
    String filePath, {
    VibrainiumSettings settings = const VibrainiumSettings(),
  }) {
    final rel = toRelativePath(workspaceRoot, filePath);
    if (rel.isEmpty) return false;

    // Check workspace.exclude settings on each path segment and full path
    if (settings.workspaceExclude.isNotEmpty) {
      final segments = rel.split('/');
      var accum = '';
      for (var i = 0; i < segments.length; i++) {
        final seg = segments[i];
        accum = i == 0 ? seg : '$accum/$seg';
        final isDir = i < segments.length - 1;
        if (settings.isWorkspaceExcluded(
          accum,
          name: seg,
          isDirectory: isDir,
        )) {
          return false;
        }
      }
    }

    switch (kind) {
      case ScopeKind.workspace:
        return true;
      case ScopeKind.currentBuffer:
        final bufPath = currentBufferPath;
        if (bufPath == null || bufPath.isEmpty) return false;
        final relBuf = toRelativePath(workspaceRoot, bufPath);
        return rel == relBuf || filePath == bufPath;
      case ScopeKind.subproject:
        final sub = subprojectPath;
        if (sub == null || sub.isEmpty) return true;
        return rel == sub || rel.startsWith('$sub/');
      case ScopeKind.customGlob:
        final matcher = customMatcher;
        if (matcher == null || matcher.isEmpty) return true;
        return matcher.matches(rel);
    }
  }

  /// Builds `-g` glob arguments for `rg` corresponding to this scope and [settings].
  List<String> buildRgArgs({
    VibrainiumSettings settings = const VibrainiumSettings(),
  }) {
    final args = <String>[];
    for (final ex in settings.workspaceExclude) {
      var clean = ex.trim().replaceAll(r'\', '/');
      if (clean.isEmpty) continue;
      if (clean.endsWith('/') && clean.length > 1) {
        clean = clean.substring(0, clean.length - 1);
      }
      args.addAll(['-g', '!$clean', '-g', '!$clean/**']);
    }

    switch (kind) {
      case ScopeKind.workspace:
        break;
      case ScopeKind.currentBuffer:
        break;
      case ScopeKind.subproject:
        final sub = subprojectPath;
        if (sub != null && sub.isNotEmpty) {
          args.addAll(['-g', '$sub/**']);
        }
      case ScopeKind.customGlob:
        final matcher = customMatcher;
        if (matcher != null) {
          for (final g in matcher.rgGlobs) {
            args.addAll(['-g', g]);
          }
        }
    }
    return args;
  }

  @override
  bool operator ==(Object other) =>
      other is SearchScope &&
      other.kind == kind &&
      other.subprojectPath == subprojectPath &&
      other.currentBufferPath == currentBufferPath &&
      other.customMatcher?.rawSpec == customMatcher?.rawSpec;

  @override
  int get hashCode => Object.hash(
        kind,
        subprojectPath,
        currentBufferPath,
        customMatcher?.rawSpec,
      );
}

const Set<String> _projectMarkers = {
  'pubspec.yaml',
  'package.json',
  'Cargo.toml',
  'go.mod',
  'pyproject.toml',
  'CMakeLists.txt',
  'build.gradle',
  'pom.xml',
  '.git',
  '.svn',
};

const Set<String> _ignoredDirs = {
  '.git',
  '.svn',
  '.hg',
  '.dart_tool',
  '.vibrainium',
  'node_modules',
  'build',
  'target',
  'dist',
  '.idea',
  '.vscode',
};

/// Discovers subprojects inside [workspaceRoot] (up to 2 directory levels deep)
/// by checking for project marker files/directories.
Future<List<String>> discoverSubprojects(
  Directory workspaceRoot, {
  VibrainiumSettings? settings,
}) async {
  if (!await workspaceRoot.exists()) return const [];
  final rootPath = workspaceRoot.path;
  final loadedSettings = settings ?? await VibrainiumSettings.load(rootPath);
  final found = <String>{};

  Future<bool> hasMarker(Directory dir) async {
    for (final marker in _projectMarkers) {
      final entityPath = '${dir.path}/$marker';
      final type = await FileSystemEntity.type(entityPath, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        return true;
      }
    }
    return false;
  }

  Future<void> scanLevel(Directory parent, int depth) async {
    if (depth > 2) return;
    List<FileSystemEntity> children;
    try {
      children = await parent.list(followLinks: false).toList();
    } catch (_) {
      return;
    }

    for (final entity in children) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .lastOrNull;
      if (name == null || name.startsWith('.') || _ignoredDirs.contains(name)) {
        continue;
      }
      final rel = SearchScope.toRelativePath(rootPath, entity.path);
      if (rel.isEmpty) continue;
      if (loadedSettings.isWorkspaceExcluded(
        rel,
        name: name,
        isDirectory: true,
      )) {
        continue;
      }

      if (await hasMarker(entity)) {
        found.add(rel);
      } else if (depth < 2) {
        await scanLevel(entity, depth + 1);
      }
    }
  }

  await scanLevel(workspaceRoot, 1);
  final sorted = found.toList()..sort();
  return sorted;
}
