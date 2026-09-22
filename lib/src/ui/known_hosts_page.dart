import 'package:flutter/material.dart';

import '../data/host_repository.dart';
import '../data/known_host_store.dart';
import '../models/host_profile.dart';
import 'tui.dart';

/// The host keys the user has trusted, each with the saved hosts that use it,
/// and a way to forget one.
///
/// Keys are not added or edited here. A key is pinned only when the user
/// trusts it while connecting, when its fingerprint is the one the server
/// actually offered; a key typed in would be trusted on nobody's word.
/// Forgetting one only makes the next connection ask again.
class KnownHostsPage extends StatefulWidget {
  const KnownHostsPage({super.key, required this.repository});

  /// Read for the names of the saved hosts behind each key, nothing more.
  final HostRepository repository;

  @override
  State<KnownHostsPage> createState() => _KnownHostsPageState();
}

class _KnownHostsPageState extends State<KnownHostsPage> {
  final _store = KnownHostStore();
  List<KnownHost>? _pins;
  List<HostProfile> _hosts = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final pins = await _store.pins();
    final hosts = await widget.repository.load();
    if (!mounted) return;
    setState(() {
      _pins = pins;
      _hosts = hosts;
    });
  }

  Future<void> _forget(KnownHost pin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this key?'),
        content: Text(
          'The next connection to ${_address(pin)} asks you to trust it '
          'again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await _store.forget(pin.host, pin.port);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Known hosts')),
      body: switch (_pins) {
        null => const Center(child: CircularProgressIndicator()),
        [] => const TuiEmptyState(
          icon: Icons.fingerprint,
          title: 'Nothing trusted yet',
          body:
              'When you trust a server\'s fingerprint on first connect, it\'s '
              'kept here. Jeansh warns you if that key ever changes.',
        ),
        final pins => ListView.separated(
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: pins.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final pin = pins[index];
            final names = [
              for (final host in _hosts)
                // Either address: a key trusted over the alternative one is
                // pinned under it, and still belongs to this saved host.
                if (host.addresses.contains(pin.host) && host.port == pin.port)
                  host.displayName,
            ];
            return ListTile(
              title: Text(_address(pin)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (names.isNotEmpty) Text(names.join(', ')),
                  // As the trust prompt shows it, to hold the two side by side.
                  SelectableText(
                    pin.fingerprint,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              trailing: IconButton(
                tooltip: 'Forget',
                onPressed: () => _forget(pin),
                icon: const Icon(Icons.delete_outline),
              ),
            );
          },
        ),
      },
    );
  }
}

/// The host, and its port when it is not SSH's own. An IPv6 host is
/// bracketed as OpenSSH writes it, or `fe80::1:2222` would read as one
/// address.
String _address(KnownHost pin) => pin.port == 22
    ? pin.host
    : pin.host.contains(':')
    ? '[${pin.host}]:${pin.port}'
    : '${pin.host}:${pin.port}';
