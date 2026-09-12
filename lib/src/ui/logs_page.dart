import 'package:flutter/material.dart';

import '../data/host_repository.dart';
import '../models/host_profile.dart';
import '../models/os_info.dart';
import '../session/session_log.dart';
import 'os_icon.dart';

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
  /// The hosts still saved, by id. An entry for any other cannot be opened.
  Map<String, HostProfile> _hosts = {};

  @override
  void initState() {
    super.initState();
    widget.repository.load().then((hosts) {
      if (mounted) setState(() => _hosts = {for (final h in hosts) h.id: h});
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
                  final saved = _hosts[hostId];
                  return _LogRow(
                    entry: entry,
                    wide: wide,
                    // The host as saved now: the copy taken at a first
                    // connect predates its OS. A deleted host has only that.
                    os: saved?.os ?? entry.host.os,
                    onOpen: saved != null
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
    required this.os,
    required this.onOpen,
  });

  final SessionLogEntry entry;
  final bool wide;

  /// What the host runs, for its badge. Null until it has said.
  final OsInfo? os;

  /// Null once the host is deleted.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final host = entry.host;
    final date = MaterialLocalizations.of(context).formatShortDate(entry.start);
    final times = sessionTimes(entry.start, entry.end);

    final icon = OsBadge(os);
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
                  '${sshLine(host.username, os)}'
                  '${onOpen == null ? ' · deleted' : ''}',
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
