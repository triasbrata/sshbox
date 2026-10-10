import 'dart:async';

import 'file_browser.dart';

/// Above either of these, a plain download of a folder asks first.
const folderWarnFiles = 2000;
const folderWarnBytes = 1024 * 1024 * 1024;

/// What a plain download of a folder would fetch: every regular file under
/// it, with where each goes, and what was left out and why.
class FolderPlan {
  /// Files to fetch: [remote] path, [rel]ative to the folder, [size].
  final List<({String remote, String rel, int size})> files = [];

  /// Folders to make, relative, so an empty one comes down too.
  final List<String> folders = [];

  /// Links and special files, which are never followed or fetched.
  final List<String> skipped = [];

  /// Folders that could not be read, with why.
  final List<String> unreadable = [];

  int get totalBytes => files.fold(0, (sum, file) => sum + file.size);

  bool get large =>
      files.length > folderWarnFiles || totalBytes > folderWarnBytes;
}

/// Lists [folder] and everything under it through [browser], in a plain walk
/// that never follows a link: a link is listed as skipped, so a loop or a
/// link out of the tree costs nothing and fetches nothing.
Future<FolderPlan> planFolder(
  FileBrowser browser,
  String folder, {
  Future<void>? cancel,
}) async {
  final plan = FolderPlan();
  var stopped = false;
  unawaited(cancel?.then((_) => stopped = true));
  final pending = <(String remote, String rel)>[(folder, '')];
  while (pending.isNotEmpty) {
    if (stopped) throw FileBrowserException.cancelled;
    final (remote, rel) = pending.removeLast();
    final List<RemoteEntry> entries;
    try {
      entries = await browser.list(remote);
    } on FileBrowserException catch (error) {
      if (error.fault == FileBrowserFault.cancelled) rethrow;
      plan.unreadable.add('${rel.isEmpty ? '.' : rel}: ${error.message}');
      continue;
    }
    if (entries.isEmpty && rel.isNotEmpty) plan.folders.add(rel);
    for (final entry in entries) {
      final name = entry.name;
      final child = rel.isEmpty ? name : '$rel/$name';
      if (name == '.' ||
          name == '..' ||
          name.contains('/') ||
          name.contains('\\') ||
          name.contains('\u0000')) {
        plan.skipped.add('$child (unsafe name)');
        continue;
      }
      switch (entry.kind) {
        case RemoteEntryKind.file:
          plan.files.add((
            remote: entry.path,
            rel: child,
            size: entry.size ?? 0,
          ));
        case RemoteEntryKind.directory:
          pending.add((entry.path, child));
        case RemoteEntryKind.symlink:
          plan.skipped.add('$child (link)');
        case RemoteEntryKind.other:
          plan.skipped.add('$child (not a regular file)');
      }
    }
  }
  return plan;
}
