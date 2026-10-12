import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/files/folder_plan.dart';

RemoteEntry _e(String dir, String name, RemoteEntryKind kind, [int? size]) =>
    RemoteEntry(name: name, path: '$dir/$name', kind: kind, size: size);

class _Tree extends Fake implements FileBrowser {
  final Map<String, List<RemoteEntry>> tree = {};
  final Set<String> denied = {};
  final List<String> listed = [];

  @override
  Future<List<RemoteEntry>> list(String path) async {
    listed.add(path);
    if (denied.contains(path)) {
      throw const FileBrowserException(
        'Permission denied.',
        fault: FileBrowserFault.permissionDenied,
      );
    }
    return tree[path] ?? const [];
  }
}

void main() {
  test('walks the tree, skips links and special files, and says so', () async {
    final b = _Tree();
    b.tree['/r'] = [
      _e('/r', 'a.txt', RemoteEntryKind.file, 10),
      _e('/r', 'sub', RemoteEntryKind.directory),
      _e('/r', 'loop', RemoteEntryKind.symlink),
      _e('/r', 'pipe', RemoteEntryKind.other),
      _e('/r', 'empty', RemoteEntryKind.directory),
      _e('/r', 'locked', RemoteEntryKind.directory),
    ];
    b.tree['/r/sub'] = [
      _e('/r/sub', 'b.bin', RemoteEntryKind.file, 5),
      _e('/r/sub', 'dirlink', RemoteEntryKind.symlink),
    ];
    b.denied.add('/r/locked');

    final plan = await planFolder(b, '/r');

    expect(plan.files.map((f) => f.rel).toSet(), {'a.txt', 'sub/b.bin'});
    expect(plan.totalBytes, 15);
    expect(plan.folders, ['empty']);
    expect(
      plan.skipped,
      unorderedEquals([
        'loop (link)',
        'pipe (not a regular file)',
        'sub/dirlink (link)',
      ]),
    );
    expect(plan.unreadable.single, contains('locked'));
    expect(plan.unreadable.single, contains('Permission denied'));
    // A link is never listed through, so a loop is never entered.
    expect(b.listed, isNot(contains('/r/loop')));
    expect(b.listed, isNot(contains('/r/sub/dirlink')));
    expect(plan.large, isFalse);
  });

  test('a name that could leave the folder is skipped, not fetched', () async {
    final b = _Tree();
    b.tree['/r'] = [
      const RemoteEntry(
        name: '..',
        path: '/r/..',
        kind: RemoteEntryKind.file,
        size: 1,
      ),
      const RemoteEntry(
        name: 'a/b',
        path: '/r/a/b',
        kind: RemoteEntryKind.file,
        size: 1,
      ),
      const RemoteEntry(
        name: r'a\b',
        path: r'/r/a\b',
        kind: RemoteEntryKind.file,
        size: 1,
      ),
      _e('/r', 'ok', RemoteEntryKind.file, 1),
    ];
    final plan = await planFolder(b, '/r');
    expect(plan.files.map((f) => f.rel), ['ok']);
    expect(plan.skipped, hasLength(3));
  });

  test('asks first above 2000 files or 1 GB', () async {
    final many = _Tree();
    many.tree['/r'] = [
      for (var i = 0; i <= folderWarnFiles; i++)
        _e('/r', 'f$i', RemoteEntryKind.file, 1),
    ];
    expect((await planFolder(many, '/r')).large, isTrue);

    final exactly = _Tree();
    exactly.tree['/r'] = [
      for (var i = 0; i < folderWarnFiles; i++)
        _e('/r', 'f$i', RemoteEntryKind.file, 1),
    ];
    expect((await planFolder(exactly, '/r')).large, isFalse);

    final big = _Tree();
    big.tree['/r'] = [
      _e('/r', 'dump', RemoteEntryKind.file, folderWarnBytes + 1),
    ];
    expect((await planFolder(big, '/r')).large, isTrue);
  });

  test('cancel stops the walk', () async {
    final b = _Tree();
    b.tree['/r'] = [_e('/r', 'd', RemoteEntryKind.directory)];
    final cancel = Completer<void>()..complete();
    await expectLater(
      planFolder(b, '/r', cancel: cancel.future),
      throwsA(
        isA<FileBrowserException>().having(
          (e) => e.fault,
          'fault',
          FileBrowserFault.cancelled,
        ),
      ),
    );
  });
}
