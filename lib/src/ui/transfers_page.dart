import 'package:flutter/material.dart';

import '../files/file_browser.dart';
import '../files/transfers.dart';
import 'file_download.dart';
import 'toast.dart';
import 'tui.dart';

/// Every download and upload since the app started, newest first, like a
/// browser's downloads page: one tab for the whole app. A running one can be
/// cancelled, and a finished download opened in whatever app the phone has
/// for it. Closing the tab leaves them all running.
///
/// Opening where it was saved is not offered: Android's save dialog hands
/// back a document, and no folder to show it in.
class TransfersPage extends StatelessWidget {
  const TransfersPage({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: transfers,
    builder: (context, _) {
      final items = transfers.items;
      return Scaffold(
        appBar: AppBar(
          toolbarHeight: 44,
          automaticallyImplyLeading: false,
          title: const Text('Transfers'),
          actions: [
            if (items.any((item) => item.state != TransferState.running))
              TextButton(
                onPressed: transfers.clearFinished,
                child: const Text('Clear finished'),
              ),
          ],
        ),
        body: items.isEmpty
            ? const TuiEmptyState(
                icon: Icons.swap_vert,
                title: 'No transfers yet',
                body:
                    'Files you download or upload show up here, with their '
                    'progress.',
              )
            : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) => _TransferRow(items[index]),
              ),
      );
    },
  );
}

class _TransferRow extends StatelessWidget {
  const _TransferRow(this.transfer);

  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final running = transfer.state == TransferState.running;
    final saved = transfer.saved;
    return ListTile(
      leading: Icon(
        transfer.direction == TransferDirection.download
            ? Icons.download
            : Icons.upload,
      ),
      title: Text(
        transfer.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status(transfer), maxLines: 2, overflow: TextOverflow.ellipsis),
          if (running)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: transfer.fraction),
            ),
        ],
      ),
      trailing: running
          ? IconButton(
              tooltip: 'Cancel',
              onPressed: transfer.cancelling
                  ? null
                  : () => transfers.cancel(transfer),
              icon: const Icon(Icons.close),
            )
          : saved == null
          ? null
          : TextButton(
              onPressed: () => _open(context, saved),
              child: const Text('Open'),
            ),
    );
  }

  Future<void> _open(BuildContext context, String saved) async {
    if (await openDownload(saved, transfer.name) || !context.mounted) return;
    showToast(
      context,
      'No app on this phone opens ${transfer.name}',
      type: ToastificationType.warning,
    );
  }
}

/// What a transfer's row says under its name: which way, the host, then how
/// far along it is or how it went.
@visibleForTesting
String status(Transfer transfer) {
  final down = transfer.direction == TransferDirection.download;
  final host = transfer.host.isEmpty
      ? ''
      : ' ${down ? 'from' : 'to'} ${transfer.host}';
  final total = transfer.total;
  final speed = '${formatBytes(transfer.speed.round())}/s';
  return switch (transfer.state) {
    TransferState.running when transfer.cancelling => 'Cancelling…',
    TransferState.running =>
      '${down ? 'Downloading' : 'Uploading'}$host · '
          '${formatBytes(transfer.done)}'
          '${total > 0 ? ' of ${formatBytes(total)}' : ''} · $speed',
    TransferState.done =>
      '${down ? 'Downloaded' : 'Uploaded'}$host · '
          '${formatBytes(total > 0 ? total : transfer.done)} · $speed',
    TransferState.failed =>
      '${down ? 'Download' : 'Upload'}$host failed: ${transfer.error}',
    TransferState.cancelled =>
      '${down ? 'Download' : 'Upload'}$host cancelled',
  };
}
