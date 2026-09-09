import 'dart:async';

import 'package:flutter/material.dart';

import '../files/file_browser.dart';

/// Finds text inside files under one directory.
///
/// Pops the path of whatever the user picked, or nothing if they backed out.
///
/// It runs on submit rather than on every keystroke. Searching as you type is
/// the nicer feeling, but over SFTP each run is a process on the far end
/// walking a directory tree, and firing one per character would flood a link
/// that a phone is already sharing with a live shell.
class FileSearchPage extends StatefulWidget {
  const FileSearchPage({
    super.key,
    required this.searcher,
    required this.root,
    this.initialQuery = '',
  });

  final FileSearchCapable searcher;

  /// The directory the search is confined to.
  final String root;

  final String initialQuery;

  @override
  State<FileSearchPage> createState() => _FileSearchPageState();
}

class _FileSearchPageState extends State<FileSearchPage> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery);

  StreamSubscription<SearchHit>? _subscription;
  final List<SearchHit> _hits = [];
  String? _error;
  bool _running = false;

  /// Null until a search has actually been run, which is what separates
  /// "nothing found" from "nothing asked for yet".
  String? _ranFor;

  @override
  void dispose() {
    // Cancelling is what stops the grep on the host, not just the listening
    // here — the implementation kills the remote process when its subscriber
    // goes away.
    _subscription?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _run() {
    final query = _controller.text.trim();
    if (query.isEmpty) return;

    _subscription?.cancel();
    setState(() {
      _hits.clear();
      _error = null;
      _running = true;
      _ranFor = query;
    });

    _subscription = widget.searcher
        .search(root: widget.root, query: query)
        .listen(
      (hit) {
        if (!mounted) return;
        setState(() => _hits.add(hit));
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _error = error is FileBrowserException
              ? error.message
              : 'Search failed: $error';
          _running = false;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _running = false);
      },
      cancelOnError: true,
    );
  }

  void _stop() {
    _subscription?.cancel();
    _subscription = null;
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: widget.initialQuery.isEmpty,
          textInputAction: TextInputAction.search,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            hintText: 'Text to find',
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _run(),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _status(),
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: _running ? 'Stop' : 'Search',
            onPressed: _running ? _stop : _run,
            icon: Icon(_running ? Icons.stop : Icons.search),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  String _status() {
    if (_running) {
      return _hits.isEmpty
          ? 'Searching ${widget.root}'
          : '${_hits.length} so far in ${widget.root}';
    }
    if (_ranFor == null) return 'In ${widget.root}';
    return '${_hits.length} ${_hits.length == 1 ? 'match' : 'matches'} '
        'in ${widget.root}';
  }

  Widget _buildBody() {
    final error = _error;
    if (error != null) {
      return _SearchMessage(icon: Icons.error_outline, message: error);
    }

    if (_hits.isEmpty) {
      if (_running) return const Center(child: CircularProgressIndicator());
      return _SearchMessage(
        icon: _ranFor == null ? Icons.travel_explore_outlined : Icons.search_off,
        message: _ranFor == null
            ? 'Type what to look for, then search.'
            : 'Nothing under here contains "$_ranFor".',
      );
    }

    return ListView.builder(
      itemCount: _hits.length,
      itemBuilder: (context, index) {
        final hit = _hits[index];
        // Shown relative to where the search started: the common prefix is the
        // same on every row and would push the useful part off the screen.
        final relative = hit.path.startsWith('${widget.root}/')
            ? hit.path.substring(widget.root.length + 1)
            : hit.path;

        return ListTile(
          dense: true,
          title: Text('$relative:${hit.line}', overflow: TextOverflow.ellipsis),
          subtitle: Text(
            hit.preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          onTap: () => Navigator.of(context).pop(hit.path),
        );
      },
    );
  }
}

class _SearchMessage extends StatelessWidget {
  const _SearchMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
