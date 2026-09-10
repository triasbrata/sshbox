import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/files/file_browser.dart';

/// Path arithmetic, which every page leans on and no server is needed to
/// check. The live test proves the transport; this proves the edges that a
/// happy-path session never reaches — root, trailing slashes, absolute names.
void main() {
  group('join', () {
    test('puts a name under a directory', () {
      expect(RemotePath.join('/home/me', 'notes.txt'), '/home/me/notes.txt');
    });

    test('does not double the separator', () {
      expect(RemotePath.join('/home/me/', 'notes.txt'), '/home/me/notes.txt');
    });

    test('works at the root', () {
      expect(RemotePath.join('/', 'etc'), '/etc');
    });

    test('leaves an already absolute name alone', () {
      // Guards the search page, where a hit arrives with a full path of its
      // own and must not be pasted onto the directory it was found under.
      expect(RemotePath.join('/home/me', '/etc/hosts'), '/etc/hosts');
    });
  });

  group('parent', () {
    test('climbs one level', () {
      expect(RemotePath.parent('/home/me/dev'), '/home/me');
    });

    test('stops at the root rather than going above it', () {
      expect(RemotePath.parent('/etc'), '/');
      expect(RemotePath.parent('/'), '/');
    });

    test('ignores a trailing slash', () {
      expect(RemotePath.parent('/home/me/dev/'), '/home/me');
    });
  });

  group('basename', () {
    test('is the last segment', () {
      expect(RemotePath.basename('/home/me/notes.txt'), 'notes.txt');
    });

    test('ignores a trailing slash', () {
      expect(RemotePath.basename('/home/me/dev/'), 'dev');
    });

    test('names the root something showable', () {
      // The title bar shows this, so an empty string would leave it blank.
      expect(RemotePath.basename('/'), '/');
    });
  });

  group('crumbs', () {
    test('walks from the root down to the path', () {
      expect(
        RemotePath.crumbs('/home/me/dev').map((crumb) => crumb.path).toList(),
        ['/', '/home', '/home/me', '/home/me/dev'],
      );
      expect(
        RemotePath.crumbs('/home/me/dev').map((crumb) => crumb.name).toList(),
        ['/', 'home', 'me', 'dev'],
      );
    });

    test('at the root is just the root', () {
      expect(RemotePath.crumbs('/'), hasLength(1));
      expect(RemotePath.crumbs('/').single.path, '/');
    });

    test('ignores a trailing slash', () {
      expect(RemotePath.crumbs('/home/').last.path, '/home');
    });
  });

  group('resolve', () {
    // A host's saved file-tree root is typed by hand, and SFTP expands none of
    // the shell's shorthand — `~/src` sent as-is is a directory named `~`.
    test('blank and ~ mean home', () {
      expect(RemotePath.resolve('', '/home/me'), '/home/me');
      expect(RemotePath.resolve('  ', '/home/me'), '/home/me');
      expect(RemotePath.resolve('~', '/home/me'), '/home/me');
    });

    test('~/ and a bare relative path are taken from home', () {
      expect(RemotePath.resolve('~/src', '/home/me'), '/home/me/src');
      expect(RemotePath.resolve('src/app/', '/home/me'), '/home/me/src/app');
    });

    test('an absolute path is kept', () {
      expect(RemotePath.resolve('/var/www/', '/home/me'), '/var/www');
      expect(RemotePath.resolve('/', '/home/me'), '/');
    });
  });

  group('isWithin', () {
    test('is the path itself or anything beneath it', () {
      expect(RemotePath.isWithin('/home/me', '/home/me'), isTrue);
      expect(RemotePath.isWithin('/home/me/dev/x', '/home/me'), isTrue);
      expect(RemotePath.isWithin('/etc', '/'), isTrue);
    });

    test('a sibling sharing a prefix is not inside', () {
      expect(RemotePath.isWithin('/home/meg', '/home/me'), isFalse);
      expect(RemotePath.isWithin('/home', '/home/me'), isFalse);
    });
  });

  group('RemoteEntry', () {
    test('a directory is traversable', () {
      const entry = RemoteEntry(
        name: 'dev',
        path: '/home/me/dev',
        kind: RemoteEntryKind.directory,
      );
      expect(entry.isTraversable, isTrue);
    });

    test('a link to a directory is traversable, a link to a file is not', () {
      const toDirectory = RemoteEntry(
        name: 'current',
        path: '/opt/current',
        kind: RemoteEntryKind.symlink,
        targetIsDirectory: true,
      );
      const toFile = RemoteEntry(
        name: 'latest.log',
        path: '/var/log/latest.log',
        kind: RemoteEntryKind.symlink,
        targetIsDirectory: false,
      );
      expect(toDirectory.isTraversable, isTrue);
      expect(toFile.isTraversable, isFalse);
    });

    test('a broken link is not traversable', () {
      // targetIsDirectory stays null when the stat failed. Tapping such a row
      // has to do nothing rather than navigate into a directory that is not
      // there.
      const broken = RemoteEntry(
        name: 'gone',
        path: '/opt/gone',
        kind: RemoteEntryKind.symlink,
      );
      expect(broken.isTraversable, isFalse);
    });

    test('dotfiles are the hidden ones', () {
      const hidden = RemoteEntry(
        name: '.bashrc',
        path: '/home/me/.bashrc',
        kind: RemoteEntryKind.file,
      );
      expect(hidden.isHidden, isTrue);
    });
  });
}
