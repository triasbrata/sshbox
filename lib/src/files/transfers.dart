import 'dart:async';

import 'package:flutter/foundation.dart';

import 'file_browser.dart';

/// Which way a [Transfer] goes: down to the phone, or up to a host.
enum TransferDirection { download, upload }

/// Where a [Transfer] has got to.
enum TransferState { running, done, failed, cancelled }

/// One download or upload, as the Transfers tab lists it and its
/// notification follows it.
class Transfer {
  Transfer._(this._owner, this.name, this.host, this.direction);

  final Transfers _owner;

  /// Names it while the app runs: its notification, and what that
  /// notification's Cancel finds it by.
  final int id = _nextId++;
  static int _nextId = 1;

  /// The file's own name, without its folder.
  final String name;

  /// The host it comes from or goes to, as the tabs name it.
  final String host;
  final TransferDirection direction;

  final _clock = Stopwatch()..start();
  final _cancel = Completer<void>();
  TransferState _state = TransferState.running;
  int _done = 0;
  int _total = 0;
  String? _error;

  TransferState get state => _state;

  /// Bytes moved so far, of [total].
  int get done => _done;

  /// Nought until it is known.
  int get total => _total;

  /// How far along, from 0 to 1; null while [total] is not known.
  double? get fraction => _total > 0 ? (_done / _total).clamp(0, 1) : null;

  /// When the work last said how far along it was, from its start.
  Duration _at = Duration.zero;

  /// Bytes a second, from the start to the last word of how far along it
  /// was: a download's wait in the save dialog is not the link's.
  double get speed {
    final seconds = _at.inMicroseconds / Duration.microsecondsPerSecond;
    return seconds > 0 ? _done / seconds : 0;
  }

  /// Why it failed, in a line fit to show.
  String? get error => _error;

  /// The document a finished download was saved as, which Open opens.
  String? saved;

  /// Completes when Cancel is tapped: what the transfer's work stops on.
  Future<void> get cancelled => _cancel.future;

  /// Cancel was tapped, and the work has not stopped yet.
  bool get cancelling => _cancel.isCompleted && _state == TransferState.running;

  /// Where the work says how far along it is: see [FileBrowser.download].
  void report(int done, int total) => _owner._report(this, done, total);
}

/// Every download and upload since the app started, newest first: what the
/// Transfers tab lists and the notifications follow. One for the whole app,
/// as a browser has one downloads page.
///
/// A change of state is told at once, progress no more often than [_tick]:
/// a transfer is thousands of packets, and whatever listens redraws a few
/// times a second rather than for each. Kept only while the app runs: a
/// transfer does not outlive the connection it runs over.
class Transfers extends ChangeNotifier {
  final List<Transfer> _items = [];

  List<Transfer> get items => List.unmodifiable(_items);

  bool get anyRunning =>
      _items.any((transfer) => transfer._state == TransferState.running);

  static const _tick = Duration(milliseconds: 250);
  final _clock = Stopwatch()..start();
  Duration? _told;

  /// Runs [work] as a transfer called [name], to or from [host], and hands
  /// back what it returns. Its end is the transfer's: done, cancelled when
  /// Cancel was tapped or it threw [FileBrowserFault.cancelled], failed
  /// otherwise. Whatever it threw is thrown on.
  Future<T> run<T>({
    required String name,
    required String host,
    required TransferDirection direction,
    required Future<T> Function(Transfer transfer) work,
  }) async {
    final transfer = Transfer._(this, name, host, direction);
    _items.insert(0, transfer);
    notifyListeners();
    try {
      final result = await work(transfer);
      _end(transfer, TransferState.done);
      return result;
    } catch (error) {
      final cancelled =
          transfer._cancel.isCompleted ||
          error is FileBrowserException &&
              error.fault == FileBrowserFault.cancelled;
      _end(
        transfer,
        cancelled ? TransferState.cancelled : TransferState.failed,
        error: cancelled ? null : '$error',
      );
      rethrow;
    }
  }

  /// Asks [transfer]'s work to stop. It ends cancelled once it has.
  void cancel(Transfer transfer) {
    if (transfer._state != TransferState.running) return;
    if (transfer._cancel.isCompleted) return;
    transfer._cancel.complete();
    notifyListeners();
  }

  /// Takes every transfer that has ended off the list.
  void clearFinished() {
    _items.removeWhere((transfer) => transfer._state != TransferState.running);
    notifyListeners();
  }

  void _report(Transfer transfer, int done, int total) {
    transfer
      .._done = done
      .._total = total
      .._at = transfer._clock.elapsed;
    final now = _clock.elapsed;
    final told = _told;
    if (told != null && now - told < _tick) return;
    _told = now;
    notifyListeners();
  }

  void _end(Transfer transfer, TransferState state, {String? error}) {
    transfer
      .._state = state
      .._error = error;
    notifyListeners();
  }
}

/// The app's transfers: see [Transfers].
final transfers = Transfers();
