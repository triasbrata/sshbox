import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// A message the user sent in chat, kept on this device from the moment Send
/// is tapped until the session's own transcript records it, so that a kill, a
/// crash or a dead connection never turns it into something that only looked
/// sent.
class OutboxEntry {
  OutboxEntry({
    required this.id,
    required this.text,
    required this.createdAt,
    this.failed = false,
    this.attempts = 0,
    this.why,
    this.pictures = const [],
  });

  /// Random, never shown.
  final String id;
  final String text;

  /// UTC. A transcript turn counts as this message's only if it is not
  /// older than this (see [OutboxMatch.skew]).
  final DateTime createdAt;

  /// False: waiting to go, or being sent. True: it did not arrive, and
  /// [why] says why.
  bool failed;

  /// Automatic retries made so far.
  int attempts;
  String? why;

  /// The pictures, as copies this store holds.
  final List<OutboxPicture> pictures;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'at': createdAt.toIso8601String(),
    'failed': failed,
    'attempts': attempts,
    if (why != null) 'why': why,
    if (pictures.isNotEmpty) 'pictures': [for (final p in pictures) p.toJson()],
  };

  static OutboxEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final text = json['text'];
    final at = json['at'] is String ? DateTime.tryParse(json['at']) : null;
    if (id is! String || text is! String || at == null) return null;
    return OutboxEntry(
      id: id,
      text: text,
      createdAt: at.toUtc(),
      failed: json['failed'] == true,
      attempts: json['attempts'] is int ? json['attempts'] as int : 0,
      why: json['why'] is String ? json['why'] as String : null,
      pictures: [
        if (json['pictures'] is List)
          for (final p in json['pictures'] as List)
            ?OutboxPicture.fromJson(p),
      ],
    );
  }
}

/// A picture of a queued message: a copy this store made, so it survives the
/// cache it was picked from.
class OutboxPicture {
  const OutboxPicture({
    required this.name,
    required this.path,
    required this.number,
  });

  final String name;
  final String path;

  /// The `[Image #N]` in the text that stands for it.
  final int number;

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'number': number,
  };

  static OutboxPicture? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final path = json['path'];
    final number = json['number'];
    if (name is! String || path is! String || number is! int) return null;
    return OutboxPicture(name: name, path: path, number: number);
  }
}

/// Everything kept for one session: its undelivered messages, oldest first,
/// and the transcript turns already matched to a delivered message.
class OutboxBox {
  OutboxBox({List<OutboxEntry>? entries, List<String>? consumed})
    : entries = entries ?? [],
      consumed = consumed ?? [];

  final List<OutboxEntry> entries;

  /// Keys of transcript turns that a delivered message already owns, so the
  /// same turn can never prove a second message. Capped.
  final List<String> consumed;

  static const consumedCap = 200;
}

/// A write to the store that did not happen. Said to the user, with what they
/// wrote left in the box: a message is never accepted into a queue that is
/// not there.
class OutboxException implements Exception {
  OutboxException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The queue of unsent messages, one JSON file per host and session in a
/// folder of the app's own.
///
/// Plain files, not a database: a handful of small records per session, and
/// a database plugin would be another native build on four platforms for it.
/// Each write goes to a temporary file and is renamed over the old one, so a
/// kill mid-write leaves the old file whole; writes to one file are made one
/// at a time, in the order asked for.
class OutboxStore {
  OutboxStore(this._root) : _mem = null;

  /// The app's own folder, resolved the first time it is needed.
  OutboxStore.app()
    : _mem = null,
      _root = (() async {
        final base = await getApplicationSupportDirectory();
        return Directory('${base.path}/chat_outbox');
      });

  /// Held in memory and never on disk, for widget tests, whose clock is
  /// faked and cannot wait on real file I/O.
  @visibleForTesting
  OutboxStore.memory()
    : _mem = {},
      _root = (() async => throw StateError('an in-memory store has no folder'));

  /// The one every chat of the app files its messages in.
  static OutboxStore shared = OutboxStore.app();

  final Map<String, String>? _mem;
  final Future<Directory> Function() _root;
  Directory? _dir;
  final Map<String, Future<void>> _tails = {};

  Future<Directory> _folder() async {
    final dir = _dir ??= await _root();
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      await _private(dir.path, '700');
    }
    return dir;
  }

  /// Owner-only where the platform has the notion; the folder is the app's
  /// own on Android already.
  static Future<void> _private(String path, String mode) async {
    if (!(Platform.isLinux || Platform.isMacOS)) return;
    try {
      await Process.run('chmod', [mode, path]);
    } catch (_) {}
  }

  /// A file name made only of what a name can safely hold.
  static String _safe(String part) => part.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_');

  /// The file's name for [host] and [session]; a chat with no session yet
  /// uses [newChat].
  static String keyOf(String host, String session) =>
      '${_safe(host)}__${_safe(session)}';

  /// The session part used by a chat that has not started one yet.
  static const newChat = 'new';

  Future<File> _file(String key) async =>
      File('${(await _folder()).path}/$key.json');

  /// What is kept under [key]. A file that cannot be read as it is, is moved
  /// aside as `.bad` rather than thrown away, and [onCorrupt] says so.
  Future<OutboxBox> load(String key, {void Function()? onCorrupt}) async {
    final mem = _mem;
    if (mem != null) {
      final raw = mem[key];
      return raw == null ? OutboxBox() : _parse(raw) ?? OutboxBox();
    }
    final File file;
    try {
      file = await _file(key);
    } catch (error) {
      throw OutboxException('Messages kept on this device could not be opened ($error).');
    }
    if (!file.existsSync()) return OutboxBox();
    try {
      final box = _parse(await file.readAsString());
      if (box == null) throw const FormatException('not an object');
      return box;
    } catch (_) {
      try {
        file.renameSync('${file.path}.bad');
      } catch (_) {}
      onCorrupt?.call();
      return OutboxBox();
    }
  }

  static OutboxBox? _parse(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      return OutboxBox(
        entries: [
          if (json['entries'] is List)
            for (final e in json['entries'] as List)
              ?OutboxEntry.fromJson(e),
        ],
        consumed: [
          if (json['consumed'] is List)
            for (final c in json['consumed'] as List)
              if (c is String) c,
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// Saves [box] under [key], or deletes the file when there is nothing in
  /// it. Throws [OutboxException] when it could not.
  Future<void> save(String key, OutboxBox box) {
    final mem = _mem;
    if (mem != null) {
      if (box.entries.isEmpty && box.consumed.isEmpty) {
        mem.remove(key);
      } else {
        mem[key] = jsonEncode({
          'entries': [for (final e in box.entries) e.toJson()],
          'consumed': box.consumed,
        });
      }
      return Future<void>.value();
    }
    final previous = _tails[key] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      try {
        final file = await _file(key);
        if (box.entries.isEmpty && box.consumed.isEmpty) {
          if (file.existsSync()) file.deleteSync();
          return;
        }
        final consumed = box.consumed.length > OutboxBox.consumedCap
            ? box.consumed.sublist(box.consumed.length - OutboxBox.consumedCap)
            : box.consumed;
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(
          jsonEncode({
            'entries': [for (final e in box.entries) e.toJson()],
            'consumed': consumed,
          }),
          flush: true,
        );
        await _private(temp.path, '600');
        await temp.rename(file.path);
      } catch (error) {
        throw OutboxException('The message could not be saved on this device ($error).');
      }
    });
    _tails[key] = next;
    return next;
  }

  /// Copies [source] in for message [entryId], returning the copy's path.
  Future<String> copyPicture(String entryId, String name, String source) async {
    if (_mem != null) return source;
    try {
      final dir = Directory('${(await _folder()).path}/${_safe(entryId)}');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
        await _private(dir.path, '700');
      }
      final copy = File('${dir.path}/${_safe(name)}');
      await File(source).copy(copy.path);
      await _private(copy.path, '600');
      return copy.path;
    } catch (error) {
      throw OutboxException('A picture could not be saved on this device ($error).');
    }
  }

  /// Removes the picture copies of [entryId].
  Future<void> dropPictures(String entryId) async {
    if (_mem != null) return;
    try {
      final dir = Directory('${(await _folder()).path}/${_safe(entryId)}');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// Everything kept for [host], when the host is deleted.
  Future<void> deleteHost(String host) async {
    final mem = _mem;
    if (mem != null) {
      mem.removeWhere((key, _) => key.startsWith('${_safe(host)}__'));
      return;
    }
    try {
      final dir = await _folder();
      final prefix = '${_safe(host)}__';
      for (final item in dir.listSync()) {
        final name = item.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (item is File && name.startsWith(prefix)) {
          final box = await load(name.replaceAll(RegExp(r'\.json$'), ''));
          for (final entry in box.entries) {
            await dropPictures(entry.id);
          }
          item.deleteSync();
        }
      }
    } catch (_) {}
  }

  /// Deletes what is kept for hosts not in [hosts]: the leftovers of a host
  /// deleted while the app was not running. This machine's own shells and
  /// WSL distros are not saved hosts and are left alone. Picture copies that
  /// no entry refers to are removed too: a crash left them.
  Future<void> sweep(Set<String> hosts) async {
    if (_mem != null) return;
    try {
      final dir = await _folder();
      final keep = {for (final h in hosts) _safe(h), 'local'};
      final gone = <String>{};
      final live = <String>{};
      for (final item in dir.listSync()) {
        final name = item.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (item is File && name.endsWith('.json') && name.contains('__')) {
          final host = name.split('__').first;
          if (!keep.contains(host) && !host.startsWith('wsl_')) {
            gone.add(host);
          } else {
            final box = await load(name.replaceAll(RegExp(r'\.json$'), ''));
            live.addAll(box.entries.map((e) => _safe(e.id)));
          }
        }
      }
      for (final host in gone) {
        await deleteHost(host);
      }
      for (final item in dir.listSync()) {
        final name = item.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (item is Directory && !live.contains(name)) {
          item.deleteSync(recursive: true);
        }
      }
    } catch (_) {}
  }
}

/// One user turn read from a transcript.
class TranscriptTurn {
  const TranscriptTurn(this.key, this.text, this.at);

  /// What names the turn: its uuid, else its timestamp.
  final String key;

  /// As [OutboxMatch.normal] reads it.
  final String text;
  final DateTime at;
}

/// Deciding which queued messages a transcript already holds.
class OutboxMatch {
  /// The host's clock and this device's differ; a turn up to this much older
  /// than a message still counts as it. Small, because a turn matching
  /// wrongly loses a message silently, which is worse than a duplicate.
  static const skew = Duration(seconds: 90);

  /// [text] as two messages are compared: pictures by place alone, spaces as
  /// one.
  static String normal(String text) => text
      .replaceAll(RegExp(r'\s*\[Image #\d+\]\s*'), ' [Image] ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  /// The user turns of [transcript] (the host's answer to the history
  /// command): ordinary user lines and queued commands, in file order.
  static List<TranscriptTurn> turnsIn(
    String transcript,
    String? Function(Object? content) userText,
  ) {
    final turns = <TranscriptTurn>[];
    for (final line in const LineSplitter().convert(transcript)) {
      if (!line.startsWith('{')) continue;
      final Object? row;
      try {
        row = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (row is! Map || row['isSidechain'] == true) continue;
      String? text;
      if (row['type'] == 'user' && row['isMeta'] != true) {
        text = userText((row['message'] as Map?)?['content']);
      } else if (row['type'] == 'attachment') {
        final attachment = row['attachment'];
        if (attachment is Map &&
            attachment['type'] == 'queued_command' &&
            attachment['prompt'] is String) {
          text = attachment['prompt'] as String;
        }
      }
      final at = row['timestamp'] is String
          ? DateTime.tryParse(row['timestamp'] as String)
          : null;
      if (text == null || at == null) continue;
      final key = (row['uuid'] is String ? row['uuid'] : row['timestamp'])
          as String;
      turns.add(TranscriptTurn(key, normal(text), at.toUtc()));
    }
    return turns;
  }

  /// Which of [entries] (oldest first) the [turns] already hold, each turn
  /// proving at most one message: a turn in [consumed], or taken by an
  /// earlier entry here, proves nothing. Two identical messages need two
  /// turns. [textOf] is what reached the session for an entry's text.
  ///
  /// Returns the matched entries' ids mapped to the turn that proved each.
  static Map<String, String> matched(
    List<OutboxEntry> entries,
    List<TranscriptTurn> turns,
    Iterable<String> consumed, {
    String Function(String text)? textOf,
  }) {
    final used = {...consumed};
    final result = <String, String>{};
    for (final entry in entries) {
      final want = normal(textOf == null ? entry.text : textOf(entry.text));
      final earliest = entry.createdAt.subtract(skew);
      for (final turn in turns) {
        if (used.contains(turn.key) ||
            turn.text != want ||
            turn.at.isBefore(earliest)) {
          continue;
        }
        used.add(turn.key);
        result[entry.id] = turn.key;
        break;
      }
    }
    return result;
  }
}

/// How long to wait before automatic retry number [attempt] (0 is the first),
/// or null once the limit is spent.
Duration? outboxBackoff(int attempt) {
  const steps = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 45),
    Duration(minutes: 2),
  ];
  return attempt < steps.length ? steps[attempt] : null;
}
