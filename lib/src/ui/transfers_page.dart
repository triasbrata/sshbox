import 'package:flutter/material.dart';

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
            // TODO(termul): empty state, until termul has one.
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('No transfers yet'),
                      SizedBox(height: 8),
                      Text(
                        'Files you download or upload show up here, with '
                        'their progress.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const TuiDivider(),
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
    return TuiTransferRow(
      name: transfer.name,
      direction: _direction(transfer),
      status: _status(transfer),
      host: transfer.host,
      doneBytes: transfer.done,
      totalBytes: transfer.total,
      speedBytesPerSec: transfer.speed,
      progress: transfer.fraction,
      error: transfer.error,
      cancelling: transfer.cancelling,
      onCancel: running && !transfer.cancelling
          ? () => transfers.cancel(transfer)
          : null,
      onOpen: saved == null ? null : () => _open(context, saved),
    );
  }

  Future<void> _open(BuildContext context, String saved) async {
    if (await openDownload(saved, transfer.name) || !context.mounted) return;
    showToast(
      context,
      'No app on this phone opens ${transfer.name}',
      type: TuiToastType.warning,
    );
  }
}

TuiTransferDirection _direction(Transfer transfer) =>
    transfer.direction == TransferDirection.download
    ? TuiTransferDirection.download
    : TuiTransferDirection.upload;

TuiTransferStatus _status(Transfer transfer) => switch (transfer.state) {
  TransferState.running => TuiTransferStatus.running,
  TransferState.done => TuiTransferStatus.done,
  TransferState.failed => TuiTransferStatus.failed,
  TransferState.cancelled => TuiTransferStatus.cancelled,
};

/// What a transfer's row says under its name, as termul's row writes it:
/// which way, the host, then how far along it is or how it went.
@visibleForTesting
String status(Transfer transfer) => tuiTransferStatusLine(
  direction: _direction(transfer),
  status: _status(transfer),
  host: transfer.host,
  doneBytes: transfer.done,
  totalBytes: transfer.total,
  speedBytesPerSec: transfer.speed,
  error: transfer.error,
  cancelling: transfer.cancelling,
);
