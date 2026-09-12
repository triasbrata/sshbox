import 'package:flutter/material.dart';

import '../data/host_repository.dart';
import '../session/session_log.dart';

/// When a session ran, on a 24-hour clock: "05:56 – 10:38", "16:12 – 11:14
/// (+1d)" once it ran past midnight, or its start alone when the app was
/// killed under it.
String sessionTimes(DateTime start, DateTime? end) {
  String clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
  if (end == null) return clock(start);
  // Calendar days, counted in UTC so a DST change cannot make one 23 hours.
  DateTime day(DateTime t) => DateTime.utc(t.year, t.month, t.day);
  final days = day(end).difference(day(start)).inDays;
  return '${clock(start)} – ${clock(end)}${days > 0 ? ' (+${days}d)' : ''}';
}

/// Date, Host and Saved, in the widths the header and every wide row share.
Widget _columns(Widget date, Widget host, Widget saved) => Row(
  children: [
    Expanded(flex: 2, child: date),
    Expanded(flex: 3, child: host),
    Expanded(
      flex: 2,
      child: Align(alignment: AlignmentDirectional.centerStart, child: saved),
    ),
  ],
);

/// Past sessions, newest first, as Termius's Logs lists them: when, on which
/// host, and a bookmark that keeps an entry for good. A tap opens another
/// session on the host, as a tap in the host list does.
class LogsPage extends StatefulWidget {
  const LogsPage({
    super.key,
    required this.repository,
    required this.onOpenHost,
  });

  final HostRepository repository;
  final Future<void> Function(String hostId) onOpenHost;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  /// The hosts still saved. An entry for any other cannot be opened.
  Set<String> _hostIds = {};

  @override
  void initState() {
    super.initState();
    widget.repository.load().then((hosts) {
      if (mounted) setState(() => _hostIds = {for (final h in hosts) h.id});
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget label(String text) => Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Logs')),
      body: ListenableBuilder(
        listenable: sessionLog,
        builder: (context, _) {
          final entries = sessionLog.entries;
          if (entries.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.history,
                    size: 48,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text('No sessions yet', style: theme.textTheme.titleMedium),
                ],
              ),
            );
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              // Columns from Material's medium width up, as the host cards
              // switch there; two-line tiles on a phone.
              final wide = constraints.maxWidth >= 600;
              final header = wide ? 1 : 0;
              return ListView.separated(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: entries.length + header,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (index < header) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
                      child: _columns(
                        label('Date'),
                        label('Host'),
                        label('Saved'),
                      ),
                    );
                  }
                  final entry = entries[index - header];
                  final hostId = entry.host.id;
                  return _LogRow(
                    entry: entry,
                    wide: wide,
                    onOpen: _hostIds.contains(hostId)
                        ? () {
                            Navigator.of(context).pop();
                            widget.onOpenHost(hostId);
                          }
                        : null,
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({
    required this.entry,
    required this.wide,
    required this.onOpen,
  });

  final SessionLogEntry entry;
  final bool wide;

  /// Null once the host is deleted.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final host = entry.host;
    final date = MaterialLocalizations.of(context).formatShortDate(entry.start);
    final times = sessionTimes(entry.start, entry.end);

    // ponytail: the host list's generic icon and "ssh, user" with no OS:
    // hosts don't carry their distro yet. Swap in its icon and id once they do.
    final icon = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(Icons.dns_outlined, color: colors.onPrimaryContainer),
    );
    final bookmark = IconButton.filledTonal(
      tooltip: entry.saved ? 'Unsave' : 'Save',
      isSelected: entry.saved,
      icon: const Icon(Icons.bookmark_border),
      selectedIcon: const Icon(Icons.bookmark),
      onPressed: () => sessionLog.toggleSaved(entry),
    );

    if (!wide) {
      return ListTile(
        enabled: onOpen != null,
        leading: icon,
        title: Text(
          host.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text('$date · $times'),
        trailing: bookmark,
        onTap: onOpen,
      );
    }

    Widget lines(String top, String bottom) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          top,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge,
        ),
        Text(
          bottom,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: _columns(
          lines(date, times),
          Row(
            children: [
              icon,
              const SizedBox(width: 12),
              Expanded(
                child: lines(
                  host.displayName,
                  'ssh, ${host.username}${onOpen == null ? ' · deleted' : ''}',
                ),
              ),
            ],
          ),
          bookmark,
        ),
      ),
    );
  }
}
