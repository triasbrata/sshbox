import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/models/os_info.dart';
import 'package:sshbox/src/ui/os_icon.dart';

/// What the Unix command prints: the host's os-release, then our lines.
List<String> _unix(
  String osRelease, {
  String kernel = 'Linux',
  String arch = 'x86_64',
}) => [
  ...osRelease.trim().split('\n'),
  'SSHBOX_KERNEL=$kernel',
  'SSHBOX_ARCH=$arch',
];

void main() {
  group('reads the host and picks its logo:', () {
    final samples = <String, (List<String>, OsInfo, int)>{
      'Ubuntu': (
        _unix('''
PRETTY_NAME="Ubuntu 24.04.1 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04.1 LTS (Noble Numbat)"
VERSION_CODENAME=noble
ID=ubuntu
ID_LIKE=debian
HOME_URL="https://www.ubuntu.com/"
UBUNTU_CODENAME=noble
'''),
        const OsInfo(
          id: 'ubuntu',
          idLike: 'debian',
          prettyName: 'Ubuntu 24.04.1 LTS',
          versionId: '24.04',
          kernel: 'Linux',
          arch: 'x86_64',
        ),
        0xf31b,
      ),
      // With a login shell's greeting in front, which is skipped.
      'Debian': (
        [
          'Welcome to box!',
          'Last login: Sat Sep 12 05:56:01 2026 from 100.101.228.69',
          ..._unix('''
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION="12 (bookworm)"
ID=debian
'''),
        ],
        const OsInfo(
          id: 'debian',
          prettyName: 'Debian GNU/Linux 12 (bookworm)',
          versionId: '12',
          kernel: 'Linux',
          arch: 'x86_64',
        ),
        0xf306,
      ),
      'Arch': (
        _unix('''
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
ID=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
'''),
        const OsInfo(
          id: 'arch',
          prettyName: 'Arch Linux',
          kernel: 'Linux',
          arch: 'x86_64',
        ),
        0xf303,
      ),
      'Alpine': (
        _unix('''
NAME="Alpine Linux"
ID=alpine
VERSION_ID=3.20.3
PRETTY_NAME="Alpine Linux v3.20"
''', arch: 'aarch64'),
        const OsInfo(
          id: 'alpine',
          prettyName: 'Alpine Linux v3.20',
          versionId: '3.20.3',
          kernel: 'Linux',
          arch: 'aarch64',
        ),
        0xf300,
      ),
      'Fedora': (
        _unix('''
NAME="Fedora Linux"
VERSION="40 (Workstation Edition)"
ID=fedora
VERSION_ID=40
PRETTY_NAME="Fedora Linux 40 (Workstation Edition)"
'''),
        const OsInfo(
          id: 'fedora',
          prettyName: 'Fedora Linux 40 (Workstation Edition)',
          versionId: '40',
          kernel: 'Linux',
          arch: 'x86_64',
        ),
        0xf30a,
      ),
      // No logo of its own: Red Hat's, the first of those it derives from.
      'Rocky, by ID_LIKE': (
        _unix('''
NAME="Rocky Linux"
ID="rocky"
ID_LIKE="rhel centos fedora"
VERSION_ID="9.4"
PRETTY_NAME="Rocky Linux 9.4 (Blue Onyx)"
'''),
        const OsInfo(
          id: 'rocky',
          idLike: 'rhel centos fedora',
          prettyName: 'Rocky Linux 9.4 (Blue Onyx)',
          versionId: '9.4',
          kernel: 'Linux',
          arch: 'x86_64',
        ),
        0xf316,
      ),
      'macOS': (
        [
          'SSHBOX_KERNEL=Darwin',
          'SSHBOX_ARCH=arm64',
          'ProductName:\t\tmacOS',
          'ProductVersion:\t\t14.5',
          'BuildVersion:\t\t23F79',
        ],
        const OsInfo(
          id: 'macos',
          prettyName: 'macOS 14.5',
          versionId: '14.5',
          kernel: 'Darwin',
          arch: 'arm64',
        ),
        0xf302,
      ),
      "Windows' ver": (
        [
          '',
          'Microsoft Windows [Version 10.0.22631.4602]',
          'SSHBOX_ARCH=AMD64',
        ],
        const OsInfo(
          id: 'windows',
          prettyName: 'Windows 10.0.22631.4602',
          versionId: '10.0.22631.4602',
          arch: 'AMD64',
        ),
        0xf17a,
      ),
    };

    samples.forEach((name, sample) {
      final (lines, os, glyph) = sample;
      test(name, () {
        expect(OsInfo.parse(lines), os);
        expect(osLogo(os)?.glyph, glyph);
      });
    });
  });

  test("the host list's line", () {
    const ubuntu = OsInfo(prettyName: 'Ubuntu 24.04.1 LTS', arch: 'x86_64');
    expect(ubuntu.summary, 'Ubuntu 24.04.1 LTS · x86_64');
    expect(
      const OsInfo(kernel: 'FreeBSD', arch: 'amd64').summary,
      'FreeBSD · amd64',
    );
  });

  test('Tux for another Linux, the generic badge for the unknown', () {
    expect(osLogo(const OsInfo(id: 'someos', kernel: 'Linux'))?.glyph, 0xf31a);
    expect(osLogo(const OsInfo(kernel: 'SunOS')), isNull);
    expect(osLogo(null), isNull);
  });

  test('nothing said is no OS info', () {
    expect(OsInfo.parse([]), isNull);
    expect(
      OsInfo.parse(['', 'Welcome!', 'SSHBOX_KERNEL=', 'SSHBOX_ARCH=']),
      isNull,
    );
  });

  test(
    'a host with no sh is asked as Windows; a failure is no answer',
    () async {
      final asked = <String>[];
      final os = await OsInfo.detect((command) {
        asked.add(command);
        // cmd says it has no `sh` on stderr, which is not read.
        return command.startsWith('cmd ')
            ? Stream.fromIterable([
                'Microsoft Windows [Version 10.0.22631.4602]',
                'SSHBOX_ARCH=AMD64',
              ])
            : const Stream.empty();
      });
      expect(os?.id, 'windows');
      expect(asked, hasLength(2));

      expect(
        await OsInfo.detect((_) => Stream.error(StateError('dropped'))),
        isNull,
      );
    },
  );

  test('a profile saved before OS info loads, and saves back unchanged', () {
    const saved = {
      'id': 'host-1',
      'label': 'box',
      'host': '10.0.2.2',
      'username': 'me',
      'port': 22,
      'authMethod': 'password',
      'fileRoot': '',
      'forwardPorts': false,
      'useTmux': false,
      'jumpHostId': '',
    };
    HostProfile roundTrip(Map<String, dynamic> json) => HostProfile.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );

    final host = roundTrip(saved);
    expect(host.os, isNull);
    final json = host.toJson();
    expect(json, isNot(contains('os')));
    expect({for (final key in saved.keys) key: json[key]}, saved);

    const os = OsInfo(id: 'ubuntu', prettyName: 'Ubuntu 24.04.1 LTS');
    expect(roundTrip(host.copyWith(os: os).toJson()).os, os);
  });

  test('a reconnect saying the same thing writes nothing', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = HostRepository(InMemorySecretStore());
    await repository.upsert(
      const HostProfile(
        id: 'h',
        label: 'box',
        host: '10.0.2.2',
        username: 'me',
      ),
    );
    const os = OsInfo(id: 'ubuntu', kernel: 'Linux');

    expect(await repository.saveOs('h', os), isTrue);
    expect(await repository.saveOs('h', os), isFalse);
    expect((await repository.load()).single.os, os);
  });
}
