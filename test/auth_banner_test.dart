import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/session/session_manager.dart';

void main() {
  group('LiveSession.extractAuthUrl', () {
    test('finds the link in a Tailscale SSH check banner', () {
      // The shape tailscaled sends when its policy asks for a check.
      const banner = '''
# Tailscale SSH requires an additional check.
# To authenticate, visit: https://login.tailscale.com/a/1a2b3c4d5e6f
''';

      expect(
        LiveSession.extractAuthUrl(banner).toString(),
        'https://login.tailscale.com/a/1a2b3c4d5e6f',
      );
    });

    test('strips punctuation when the link ends a sentence', () {
      const banner = 'Visit https://login.tailscale.com/a/abc123, then retry.';

      expect(
        LiveSession.extractAuthUrl(banner).toString(),
        'https://login.tailscale.com/a/abc123',
      );
    });

    test('returns null for a banner with no link', () {
      expect(LiveSession.extractAuthUrl('Welcome to the machine'), isNull);
    });

    test('returns null for empty text', () {
      expect(LiveSession.extractAuthUrl(''), isNull);
    });

    test('takes the first link when several appear', () {
      const banner = 'see https://first.example/x or https://second.example/y';

      expect(
        LiveSession.extractAuthUrl(banner).toString(),
        'https://first.example/x',
      );
    });
  });
}
