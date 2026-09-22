// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_transfer_row.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_button.dart';
import 'tui_progress.dart';
import 'tui_tooltip.dart';

/// Upload vs download — shown as a mono glyph, not a colour wash.
enum TuiTransferDirection { download, upload }

/// Lifecycle of one transfer row.
enum TuiTransferStatus { running, done, failed, cancelled }

extension TuiTransferDirectionX on TuiTransferDirection {
  String get glyph => switch (this) {
    TuiTransferDirection.download => '↓',
    TuiTransferDirection.upload => '↑',
  };

  String get verb => switch (this) {
    TuiTransferDirection.download => 'Downloading',
    TuiTransferDirection.upload => 'Uploading',
  };

  String get pastVerb => switch (this) {
    TuiTransferDirection.download => 'Downloaded',
    TuiTransferDirection.upload => 'Uploaded',
  };

  String get noun => switch (this) {
    TuiTransferDirection.download => 'Download',
    TuiTransferDirection.upload => 'Upload',
  };
}

/// Formats a byte count the way transfer rows show sizes (`1.2 MB`).
String formatTuiBytes(num bytes) {
  final b = bytes.toDouble().abs();
  if (b < 1024) return '${b.round()} B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Status line under the file name — host, size, speed, or failure reason.
String tuiTransferStatusLine({
  required TuiTransferDirection direction,
  required TuiTransferStatus status,
  String? host,
  int doneBytes = 0,
  int totalBytes = 0,
  double speedBytesPerSec = 0,
  String? error,
  bool cancelling = false,
}) {
  final hostBit = (host == null || host.isEmpty)
      ? ''
      : ' ${direction == TuiTransferDirection.download ? 'from' : 'to'} $host';
  final speed = '${formatTuiBytes(speedBytesPerSec)}/s';

  return switch (status) {
    TuiTransferStatus.running when cancelling => 'Cancelling…',
    TuiTransferStatus.running =>
      '${direction.verb}$hostBit · ${formatTuiBytes(doneBytes)}'
          '${totalBytes > 0 ? ' of ${formatTuiBytes(totalBytes)}' : ''} · $speed',
    TuiTransferStatus.done =>
      '${direction.pastVerb}$hostBit · '
          '${formatTuiBytes(totalBytes > 0 ? totalBytes : doneBytes)} · $speed',
    TuiTransferStatus.failed =>
      '${direction.noun}$hostBit failed'
          '${error == null || error.isEmpty ? '' : ': $error'}',
    TuiTransferStatus.cancelled => '${direction.noun}$hostBit cancelled',
  };
}

/// One row in a Transfers list — name, host, direction, size, speed, bar, action.
///
/// Presentation-only: pass plain fields from whatever owns the transfer model
/// (Jeansh `Transfer`, a mock, …).
class TuiTransferRow extends StatelessWidget {
  const TuiTransferRow({
    super.key,
    required this.name,
    required this.direction,
    required this.status,
    this.host,
    this.doneBytes = 0,
    this.totalBytes = 0,
    this.speedBytesPerSec = 0,
    this.progress,
    this.error,
    this.cancelling = false,
    this.onCancel,
    this.onOpen,
    this.onRetry,
    this.dense = false,
  });

  final String name;
  final TuiTransferDirection direction;
  final TuiTransferStatus status;
  final String? host;
  final int doneBytes;
  final int totalBytes;
  final double speedBytesPerSec;

  /// 0–1 while [status] is running; `null` = indeterminate.
  final double? progress;
  final String? error;
  final bool cancelling;
  final VoidCallback? onCancel;
  final VoidCallback? onOpen;
  final VoidCallback? onRetry;
  final bool dense;

  bool get _running => status == TuiTransferStatus.running;

  String get statusLine => tuiTransferStatusLine(
    direction: direction,
    status: status,
    host: host,
    doneBytes: doneBytes,
    totalBytes: totalBytes,
    speedBytesPerSec: speedBytesPerSec,
    error: error,
    cancelling: cancelling,
  );

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final theme = Theme.of(context);
    final failed = status == TuiTransferStatus.failed;

    return Semantics(
      label: '$name. $statusLine',
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 12 : 16,
          vertical: dense ? 8 : 12,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                direction.glyph,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 16,
                  height: 1,
                  color: failed ? (p.isLight ? p.deep : p.red) : p.accent,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium!.copyWith(
                      color: p.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    statusLine,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: failed ? (p.isLight ? p.deep : p.red) : p.muted,
                      height: 1.35,
                    ),
                  ),
                  if (_running) ...[
                    const SizedBox(height: 6),
                    TuiProgressBar(
                      value: progress,
                      height: 2,
                      tone: cancelling
                          ? TuiProgressTone.muted
                          : TuiProgressTone.accent,
                    ),
                  ],
                  if (failed) ...[
                    const SizedBox(height: 6),
                    const TuiProgressBar(
                      value: 1,
                      height: 2,
                      tone: TuiProgressTone.danger,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            _TransferAction(
              status: status,
              cancelling: cancelling,
              onCancel: onCancel,
              onOpen: onOpen,
              onRetry: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _TransferAction extends StatelessWidget {
  const _TransferAction({
    required this.status,
    required this.cancelling,
    this.onCancel,
    this.onOpen,
    this.onRetry,
  });

  final TuiTransferStatus status;
  final bool cancelling;
  final VoidCallback? onCancel;
  final VoidCallback? onOpen;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case TuiTransferStatus.running:
        if (onCancel == null) return const SizedBox(width: 36, height: 36);
        return TuiIconButton(
          icon: '×',
          tooltip: cancelling ? 'Cancelling…' : 'Cancel',
          onPressed: cancelling ? null : onCancel,
        );
      case TuiTransferStatus.done:
        if (onOpen == null) return const SizedBox.shrink();
        return TuiButton(
          label: 'open',
          variant: TuiButtonVariant.ghost,
          onPressed: onOpen,
        );
      case TuiTransferStatus.failed:
        if (onRetry == null) return const SizedBox.shrink();
        return TuiButton(
          label: 'retry',
          variant: TuiButtonVariant.ghost,
          onPressed: onRetry,
        );
      case TuiTransferStatus.cancelled:
        if (onRetry == null) return const SizedBox.shrink();
        return TuiButton(
          label: 'retry',
          variant: TuiButtonVariant.ghost,
          onPressed: onRetry,
        );
    }
  }
}
