import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../files/file_browser.dart';
import '../session/pane_record.dart';
import 'settings_page.dart' show terminalSettings;

/// A tmux pane's record, as the host kept it: the text the pane showed, in
/// order, the newest at the bottom — see [PaneRecord].
///
/// It opens on the record's last page; Load earlier reaches back a page at a
/// time, and Refresh reads the end again.
class PaneRecordPage extends StatefulWidget {
  const PaneRecordPage({
    super.key,
    required this.reader,
    required this.columns,
    required this.rows,
  });

  final PaneRecordReader reader;

  /// The pane's size, which is what its programs drew for.
  final int columns;
  final int rows;

  @override
  State<PaneRecordPage> createState() => _PaneRecordPageState();
}

class _PaneRecordPageState extends State<PaneRecordPage> {
  List<String> _lines = const [];
  bool _loading = true;
  bool _missing = false;
  String? _error;

  /// Bumped by each read, so a refresh overtakes one still on its way.
  int _read = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() => _load(() async {
    final bytes = await widget.reader.tail();
    _missing = bytes == null;
    return bytes == null ? const <String>[] : await _render(bytes);
  });

  Future<void> _earlier() => _load(
    () async => [...await _render(await widget.reader.earlier()), ..._lines],
  );

  Future<void> _load(Future<List<String>> Function() read) async {
    final mine = ++_read;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lines = await read();
      if (!mounted || mine != _read) return;
      setState(() => _lines = lines);
    } on FileBrowserException catch (error) {
      if (!mounted || mine != _read) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted && mine == _read) setState(() => _loading = false);
    }
  }

  /// Off the UI isolate: half a megabyte takes a third of a second.
  Future<List<String>> _render(Uint8List bytes) {
    final (columns, rows) = (widget.columns, widget.rows);
    return Isolate.run(() => renderRecord(bytes, columns: columns, rows: rows));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _error;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pane record'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                error,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (_missing && !_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'This pane has no record yet. A record starts when the host '
                'is set to keep one and the tab attaches, and goes on from '
                'there.',
              ),
            ),
          Expanded(child: _record(theme)),
        ],
      ),
    );
  }

  Widget _record(ThemeData theme) {
    final style = terminalSettings.value.toTextStyle().copyWith(
      color: theme.colorScheme.onSurface,
    );
    final more = widget.reader.start > 0;
    return SelectionArea(
      child: ListView.builder(
        // Newest at the bottom, where the list opens.
        reverse: true,
        padding: const EdgeInsets.all(8),
        itemCount: _lines.length + 1,
        itemBuilder: (context, index) {
          if (index < _lines.length) {
            return Text(_lines[_lines.length - 1 - index], style: style);
          }
          if (_lines.isEmpty) return const SizedBox.shrink();
          return Center(
            child: more
                ? TextButton(
                    onPressed: _loading ? null : _earlier,
                    child: const Text('Load earlier'),
                  )
                : Text('Start of the record', style: theme.textTheme.bodySmall),
          );
        },
      ),
    );
  }
}
