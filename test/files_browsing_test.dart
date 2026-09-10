import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/file_page.dart';
import 'package:sshbox/src/ui/files_drawer.dart';

void main() {
  group('FilesDrawer.parentOf', () {
    test('walks one directory up', () {
      expect(FilesDrawer.parentOf('/home/me/dev'), '/home/me');
      expect(FilesDrawer.parentOf('/home/me'), '/home');
    });

    test('stops at the root instead of walking past it', () {
      expect(FilesDrawer.parentOf('/home'), '/');
      expect(FilesDrawer.parentOf('/'), isNull);
      expect(FilesDrawer.parentOf(''), isNull);
    });

    test('ignores a trailing slash', () {
      expect(FilesDrawer.parentOf('/home/me/dev/'), '/home/me');
    });
  });

  group('FilesDrawer.readableSize', () {
    test('reads bytes as a person would', () {
      expect(FilesDrawer.readableSize(0), '0 B');
      expect(FilesDrawer.readableSize(512), '512 B');
      expect(FilesDrawer.readableSize(2048), '2.0 KB');
      expect(FilesDrawer.readableSize(20480), '20 KB');
      expect(FilesDrawer.readableSize(5 * 1024 * 1024), '5.0 MB');
    });
  });

  group('FilePage.looksBinary', () {
    test('text is not binary', () {
      expect(
        FilePage.looksBinary(Uint8List.fromList('server {\n  listen 80;\n}\n'
            .codeUnits)),
        isFalse,
      );
    });

    test('a NUL byte marks it binary', () {
      expect(
        FilePage.looksBinary(Uint8List.fromList([0x7f, 0x45, 0x4c, 0x46, 0x00])),
        isTrue,
      );
    });

    test('an empty file is not binary', () {
      expect(FilePage.looksBinary(Uint8List(0)), isFalse);
    });
  });
}
