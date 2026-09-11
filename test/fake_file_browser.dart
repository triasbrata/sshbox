import 'package:sshbox/src/files/file_browser.dart';

/// A filesystem in a map.
///
/// The second implementation of [FileBrowser], written before the daemon that
/// motivated the interface. It exists to test the pages without a server, and
/// it doubles as the proof that the seam is real: the pages cannot tell this
/// apart from SFTP, so a third implementation will not surprise them either.
class FakeFileBrowser implements FileBrowser {
  final Map<String, List<RemoteEntry>> _tree = {
    '/home/me': [
      const RemoteEntry(
        name: 'dev',
        path: '/home/me/dev',
        kind: RemoteEntryKind.directory,
      ),
      const RemoteEntry(
        name: 'dangling',
        path: '/home/me/dangling',
        kind: RemoteEntryKind.symlink,
      ),
      const RemoteEntry(
        name: 'notes.txt',
        path: '/home/me/notes.txt',
        kind: RemoteEntryKind.file,
        size: 1024,
      ),
      const RemoteEntry(
        name: '.bashrc',
        path: '/home/me/.bashrc',
        kind: RemoteEntryKind.file,
        size: 220,
      ),
    ],
    '/home/me/dev': [
      const RemoteEntry(
        name: 'main.dart',
        path: '/home/me/dev/main.dart',
        kind: RemoteEntryKind.file,
        size: 4096,
      ),
    ],
  };

  final Map<String, String> contents = {
    '/home/me/notes.txt': 'first line\nsecond line\n',
    '/home/me/dev/main.dart': 'void main() {}\n',
  };

  final List<String> deleted = [];
  final List<String> recursiveDeletes = [];
  final List<(String from, String to)> renames = [];
  final List<String> madeDirectories = [];
  bool closed = false;

  /// Set to make the next [list] fail, standing in for a directory the login
  /// cannot read.
  FileBrowserException? failListWith;

  /// Set to make the next [readText] fail — too large, binary, and so on.
  FileBrowserException? failReadWith;

  @override
  Future<String> resolveHome() async => '/home/me';

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final failure = failListWith;
    if (failure != null) throw failure;
    return List.of(_tree[path] ?? const []);
  }

  /// Bumped by every write, standing in for the host's mtime.
  final Map<String, int> _versions = {};

  FileStamp _stamp(String path) => (
        // Local, like SFTP's: a stamp kept as milliseconds comes back local,
        // and DateTime equality tells the two zones apart.
        modified: DateTime(2026).add(Duration(seconds: _versions[path] ?? 0)),
        size: contents[path]?.length,
      );

  /// Someone else saving the file on the host while it is open here.
  void externalEdit(String path, String content) {
    contents[path] = content;
    _versions[path] = (_versions[path] ?? 0) + 1;
  }

  @override
  Future<RemoteText> readText(
    String path, {
    int maxBytes = FileBrowser.defaultReadLimit,
  }) async {
    final failure = failReadWith;
    if (failure != null) throw failure;
    final text = contents[path];
    if (text == null) {
      throw const FileBrowserException(
        'Could not open: it is no longer there.',
        fault: FileBrowserFault.notFound,
      );
    }
    return (text: text, stamp: _stamp(path));
  }

  @override
  Future<FileStamp> writeText(
    String path,
    String content, {
    FileStamp? expected,
  }) async {
    if (expected != null &&
        (!contents.containsKey(path) || _stamp(path) != expected)) {
      throw const FileBrowserException(
        'Changed on the host since it was opened.',
        fault: FileBrowserFault.changed,
      );
    }
    externalEdit(path, content);
    final parent = RemotePath.parent(path);
    final siblings = _tree.putIfAbsent(parent, () => []);
    if (!siblings.any((entry) => entry.path == path)) {
      siblings.add(RemoteEntry(
        name: RemotePath.basename(path),
        path: path,
        kind: RemoteEntryKind.file,
        size: content.length,
      ));
    }
    return _stamp(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    renames.add((from, to));
    final parent = RemotePath.parent(from);
    final siblings = _tree[parent];
    if (siblings == null) return;
    final index = siblings.indexWhere((entry) => entry.path == from);
    if (index < 0) return;
    final old = siblings[index];
    siblings[index] = RemoteEntry(
      name: RemotePath.basename(to),
      path: to,
      kind: old.kind,
      size: old.size,
      modified: old.modified,
      targetIsDirectory: old.targetIsDirectory,
    );
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    deleted.add(path);
    if (recursive) recursiveDeletes.add(path);
    _tree[RemotePath.parent(path)]?.removeWhere((entry) => entry.path == path);
    _tree.remove(path);
    contents.remove(path);
  }

  @override
  Future<void> makeDirectory(String path) async {
    madeDirectories.add(path);
    _tree.putIfAbsent(path, () => []);
    _tree[RemotePath.parent(path)]?.add(RemoteEntry(
      name: RemotePath.basename(path),
      path: path,
      kind: RemoteEntryKind.directory,
    ));
  }

  @override
  Future<void> close() async => closed = true;
}

/// The same filesystem, by a transport that can also search it.
///
/// Two fakes rather than a flag, because that is how the real pair works: the
/// UI decides what to offer by asking what the object is, not by reading a
/// boolean off it.
class SearchingFakeFileBrowser extends FakeFileBrowser
    implements FileSearchCapable {
  @override
  Stream<SearchHit> search({
    required String root,
    required String query,
  }) async* {
    for (final entry in contents.entries) {
      if (!entry.key.startsWith(root)) continue;
      final lines = entry.value.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains(query)) {
          yield SearchHit(path: entry.key, line: i + 1, preview: lines[i]);
        }
      }
    }
  }
}
