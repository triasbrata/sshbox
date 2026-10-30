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
      // The folder itself unread is nothing to download, not a part of it.
      if (rel.isEmpty) {
        throw FileBrowserException(
          'Could not read ${RemotePath.basename(folder)}: ${error.message}',
          fault: error.fault,
        );
      }
      plan.unreadable.add('$rel: ${error.message}');
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

/// Reserved device names on Windows, whatever extension follows them.
final _windowsDevice = RegExp(
  r'^(?:con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(?:\..*)?$',
  caseSensitive: false,
);

/// Why [name] cannot be a file or folder on Windows as it is, or null.
String? _windowsRefuses(String name) {
  if (RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(name)) {
    return 'a character Windows does not allow';
  }
  if (name.endsWith('.') || name.endsWith(' ')) {
    return 'Windows drops its last dot or space';
  }
  if (_windowsDevice.hasMatch(name)) return 'a name Windows keeps for a device';
  return null;
}

/// Moves to [FolderPlan.skipped] every file and folder in [plan] that this
/// computer cannot hold as named, each with why, so nothing is lost without a
/// word. Where names are compared without case ([foldCase], as macOS and
/// Windows compare them by default) the second of two names that differ only
/// in case would overwrite the first. On [windows], a name holding `:` would
/// go into a hidden stream of another file, and one ending in a dot or a
/// space, or naming a device, is not the file it says.
void fitLocalNames(
  FolderPlan plan, {
  required bool foldCase,
  required bool windows,
}) {
  if (!foldCase && !windows) return;
  // A name is refused by any of its parts, so a file under a folder Windows
  // cannot make goes with it.
  String? refuses(String rel) {
    if (!windows) return null;
    for (final part in rel.split('/')) {
      final why = _windowsRefuses(part);
      if (why != null) return why;
    }
    return null;
  }

  final folders = [...plan.folders];
  plan.folders.clear();
  for (final folder in folders) {
    final why = refuses(folder);
    if (why == null) {
      plan.folders.add(folder);
    } else {
      plan.skipped.add('$folder ($why)');
    }
  }
  final taken = <String, String>{};
  final files = [...plan.files];
  plan.files.clear();
  for (final file in files) {
    final why = refuses(file.rel);
    if (why != null) {
      plan.skipped.add('${file.rel} ($why)');
      continue;
    }
    final key = foldCase ? file.rel.toLowerCase() : file.rel;
    final first = taken[key];
    if (first != null) {
      plan.skipped.add('${file.rel} (would overwrite $first on this computer)');
      continue;
    }
    taken[key] = file.rel;
    plan.files.add(file);
  }
}
