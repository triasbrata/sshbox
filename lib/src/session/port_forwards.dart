import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/host_repository.dart';
import '../data/known_host_store.dart';
import '../data/secret_store.dart';
import '../models/forward_setting.dart';
import 'dartssh2_transport.dart';
import 'local_forwarder.dart';
import 'session_manager.dart' show LiveSession;
import 'terminal_session.dart';

enum ForwardStatus { stopped, connecting, running, reconnecting, error }

/// Something to tell the user, as a toast: red when [failed], with an Open
/// for [link].
typedef ForwardNotice = ({String message, bool failed, Uri? link});

/// Where one [ForwardSetting] is at while the app runs. Every one starts
/// stopped: nothing opens by itself when the app starts.
class ForwardRun {
  ForwardRun._(
    this._setting,
    void Function(ForwardRun run, LocalForward rule, String? problem) onProblem,
  ) {
    _forwarder = LocalForwarder(
      onProblem: (rule, problem) => onProblem(this, rule, problem),
    );
  }

  ForwardSetting _setting;
  ForwardStatus _status = ForwardStatus.stopped;
  String? _error;
  Uri? _signIn;
  final _problems = <int, String>{};

  /// What toasts call it: the setting's name, or its host's.
  String _name = '';

  late final LocalForwarder _forwarder;
  TerminalSession? _connection;
  Timer? _retry;
  int _failures = 0;

  /// Bumped by every connect and every let-go, so a connect that finishes
  /// after its setting was switched off, or dropped, lets its connection go.
  int _attempt = 0;

  ForwardSetting get setting => _setting;
  ForwardStatus get status => _status;

  /// Why it failed, or why its last reconnect did.
  String? get error => _error;

  /// A sign-in the host is waiting on — Tailscale SSH's check.
  Uri? get signIn => _signIn;

  /// Why a port could not open or reach its destination, by tablet port.
  Map<int, String> get problems => Map.unmodifiable(_problems);

  /// Switched on: connecting, running, or reconnecting.
  bool get on => switch (_status) {
    ForwardStatus.stopped || ForwardStatus.error => false,
    _ => true,
  };
}

/// The port forwarding settings, and each one's own SSH connection while it
/// is switched on: no pty and no shell, only the tunnels. It is made the way
/// a terminal session's is — the same host key check and prompts, the same
/// saved credentials, through the same jump hosts.
class PortForwards extends ChangeNotifier {
  /// [transport] is a test's, as `LiveSession` takes one.
  PortForwards({SecretStore? secrets, this._transport})
    : _secrets = secrets ?? KeystoreSecretStore();

  static const _key = 'sshbox.forwards.v1';

  /// How long each reconnect in a row waits: the last, from then on.
  static const retryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  final SecretStore _secrets;
  final SessionTransport? _transport;

  /// Asks about a host key that is not the one pinned — see
  /// `KnownHostStore.trust`. Set by the app while it is up; without it such
  /// a key is refused.
  Future<bool> Function(HostKeyCheck check)? confirmHostKey;

  /// Shows a notice. Set by the app while it is up.
  void Function(ForwardNotice notice)? onNotice;

  /// By setting id, in list order.
  final _runs = <String, ForwardRun>{};

  List<ForwardRun> get runs => List.unmodifiable(_runs.values);

  /// How many are switched on: what keeps the app alive in the background.
  int get onCount => _runs.values.where((run) => run.on).length;

  /// Reads the settings, once, before anything starts. The first time, the
  /// port forwards hosts kept themselves become settings, switched off.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    var settings = <ForwardSetting>[];
    try {
      settings = raw == null
          ? ForwardSetting.migrate(
              jsonDecode(prefs.getString(HostRepository.storageKey) ?? '[]')
                  as List,
            )
          : [
              for (final json in jsonDecode(raw) as List)
                ForwardSetting.fromJson(json as Map<String, dynamic>),
            ];
    } catch (_) {
      // A corrupt list costs its settings, not the app's start.
    }
    _runs
      ..clear()
      ..addEntries([
        for (final setting in settings)
          MapEntry(setting.id, ForwardRun._(setting, _onProblem)),
      ]);
    if (raw == null) await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final run in _runs.values) run.setting.toJson()]),
    );
  }

  /// Adds [setting], or replaces the one with its id. One that was on starts
  /// again, with its new host and ports.
  Future<void> save(ForwardSetting setting) async {
    final run = _runs[setting.id];
    final wasOn = run?.on ?? false;
    if (run == null) {
      _runs[setting.id] = ForwardRun._(setting, _onProblem);
    } else {
      await stop(setting.id);
      run._setting = setting;
    }
    await _persist();
    notifyListeners();
    if (wasOn) unawaited(start(setting.id));
  }

  /// Stops it first, if it is on.
  Future<void> delete(String id) async {
    await stop(id);
    _runs.remove(id);
    await _persist();
    notifyListeners();
  }

  /// Switches it on: done once it runs, or has failed.
  Future<void> start(String id) async {
    final run = _runs[id];
    if (run == null || run.on) return;
    run
      .._status = ForwardStatus.connecting
      .._error = null
      .._failures = 0
      .._problems.clear();
    notifyListeners();
    await _connect(run);
  }

  /// Switches it off: every port, what is connected through them, the
  /// connection, and any reconnect waiting.
  Future<void> stop(String id) async {
    final run = _runs[id];
    if (run == null) return;
    run
      .._status = ForwardStatus.stopped
      .._error = null
      .._signIn = null
      .._problems.clear();
    notifyListeners();
    await _letGo(run);
  }

  Future<void> _letGo(ForwardRun run) async {
    run._attempt++;
    run._retry?.cancel();
    run._retry = null;
    final connection = run._connection;
    run._connection = null;
    await run._forwarder.stop();
    await connection?.dispose();
  }

  Future<void> _connect(ForwardRun run) async {
    final attempt = ++run._attempt;
    bool current() => attempt == run._attempt;
    var keyRefused = false;
    run._name = run.setting.displayName(null);
    try {
      final host = (await HostRepository(_secrets).load())
          .where((host) => host.id == run.setting.hostId)
          .firstOrNull;
      if (host == null) {
        throw const SshSessionException(
          'Its host was deleted. Edit it and pick another.',
        );
      }
      run._name = run.setting.displayName(host);
      final transport =
          _transport ??
          Dartssh2Transport(
            confirmHostKey: (check) async {
              final trusted =
                  current() && (await confirmHostKey?.call(check) ?? false);
              keyRefused = !trusted;
              return trusted;
            },
            onAuthBanner: (banner) {
              final url = LiveSession.extractAuthUrl(banner);
              if (url == null || !current()) return;
              run._signIn = url;
              notifyListeners();
              _say('${run._name}: sign in to continue', link: url);
            },
          );
      final connection = await transport.connect(
        host: host,
        secrets: _secrets,
        columns: 80,
        rows: 24,
        shell: false,
      );
      if (!current()) {
        await connection.dispose();
        return;
      }
      run._connection = connection;
      if (connection is! ForwardCapable) {
        throw const SshSessionException('This connection cannot forward.');
      }
      connection.status.addListener(() {
        if (identical(run._connection, connection) &&
            connection.status.value != SessionStatus.connected) {
          _failed(run, connection.failure ?? 'The connection dropped.');
        }
      });
      run
        .._signIn = null
        .._problems.clear();
      await run._forwarder.sync(
        connection as ForwardCapable,
        run.setting.mappings,
      );
      if (!current()) return;
      final opened = [
        for (final mapping in run.setting.mappings)
          if (!run._problems.containsKey(mapping.localPort)) mapping.localPort,
      ];
      if (opened.isEmpty) {
        throw const SshSessionException('No port could open.');
      }
      run
        .._status = ForwardStatus.running
        .._error = null
        .._failures = 0;
      notifyListeners();
      _say('Forwarding 127.0.0.1:${opened.join(', ')}');
    } catch (error) {
      if (!current()) return;
      _failed(
        run,
        error is SshSessionException ? error.message : '$error',
        // A first connect says why and stops, as does a key the user did
        // not trust: asking again every 30 seconds would be no answer.
        retry: run.status != ForwardStatus.connecting && !keyRefused,
      );
    }
  }

  /// Lets go of everything [run] held, and tries again in a while or says
  /// why not.
  void _failed(ForwardRun run, String message, {bool retry = true}) {
    unawaited(_letGo(run));
    run._error = message;
    if (retry) {
      run._status = ForwardStatus.reconnecting;
      final delay =
          retryDelays[math.min(run._failures++, retryDelays.length - 1)];
      run._retry = Timer(delay, () => unawaited(_connect(run)));
    } else {
      run._status = ForwardStatus.error;
      _say('${run._name}\n$message', failed: true);
    }
    notifyListeners();
  }

  void _onProblem(ForwardRun run, LocalForward rule, String? problem) {
    final port = rule.localPort;
    if (problem == null) {
      if (run._problems.remove(port) != null) notifyListeners();
      return;
    }
    run._problems[port] = problem;
    notifyListeners();
    _say('${run._name}\n$port: $problem', failed: true);
  }

  void _say(String message, {bool failed = false, Uri? link}) =>
      onNotice?.call((message: message, failed: failed, link: link));
}

/// The app's one: `main` loads it, the Port forwarding page switches its
/// settings, and the app keeps itself alive while any is on.
final portForwards = PortForwards();
