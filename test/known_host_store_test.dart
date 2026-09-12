import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/known_host_store.dart';
import 'package:sshbox/src/models/host_profile.dart';

void main() {
  const host = HostProfile(id: 'h', label: '', host: 'box', username: 'me');

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a key is pinned only once the user trusts it', () async {
    final store = KnownHostStore();
    final asked = <HostKeyCheck>[];
    Future<bool> Function(HostKeyCheck) answer(bool yes) => (check) async {
          asked.add(check);
          return yes;
        };

    // Nobody to ask, or a no: refused, and nothing pinned.
    expect(await store.trust(host, 'SHA256:a', null), isFalse);
    expect(await store.trust(host, 'SHA256:a', answer(false)), isFalse);
    expect(await store.pinnedKey('box', 22), isNull);

    expect(await store.trust(host, 'SHA256:a', answer(true)), isTrue);
    expect(asked.last.pinned, isNull);
    expect(await store.pinnedKey('box', 22), 'SHA256:a');

    // The pinned key goes through without asking.
    asked.clear();
    expect(await store.trust(host, 'SHA256:a', answer(false)), isTrue);
    expect(asked, isEmpty);

    // A changed key is shown with the old one, and refusing keeps the old pin.
    expect(await store.trust(host, 'SHA256:b', answer(false)), isFalse);
    expect(asked.single.pinned, 'SHA256:a');
    expect(await store.pinnedKey('box', 22), 'SHA256:a');

    expect(await store.trust(host, 'SHA256:b', answer(true)), isTrue);
    expect(await store.pinnedKey('box', 22), 'SHA256:b');
  });

  test('pins made at once are all kept', () async {
    final stores = [KnownHostStore(), KnownHostStore()];
    await Future.wait([
      for (var i = 0; i < 6; i++)
        stores[i % 2].trust(
          host.copyWith(host: 'box$i'),
          'SHA256:$i',
          (_) async => true,
        ),
    ]);
    for (var i = 0; i < 6; i++) {
      expect(await stores[0].pinnedKey('box$i', 22), 'SHA256:$i');
    }
  });

  test('lists every pin, and a forgotten one is asked about again', () async {
    final store = KnownHostStore();
    // Full of colons: only the last one starts the port.
    const v6 = HostProfile(
      id: 'v6',
      label: '',
      host: 'fe80::1',
      port: 2222,
      username: 'me',
    );
    await store.trust(host, 'SHA256:a', (_) async => true);
    await store.trust(v6, 'SHA256:b', (_) async => true);
    expect(await store.pins(), [
      (host: 'box', port: 22, fingerprint: 'SHA256:a'),
      (host: 'fe80::1', port: 2222, fingerprint: 'SHA256:b'),
    ]);

    await store.forget('fe80::1', 2222);
    expect(await store.pins(), [
      (host: 'box', port: 22, fingerprint: 'SHA256:a'),
    ]);

    // Forgetting trusts nothing: the same key is asked about as a new one.
    final asked = <HostKeyCheck>[];
    expect(
      await store.trust(v6, 'SHA256:b', (check) async {
        asked.add(check);
        return false;
      }),
      isFalse,
    );
    expect(asked.single.pinned, isNull);
    expect(await store.pinnedKey('fe80::1', 2222), isNull);
  });
}
