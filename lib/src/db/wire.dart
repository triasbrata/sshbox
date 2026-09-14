import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../session/terminal_session.dart' show Tunnel;

/// What a database said no with, or why talking to it failed, in words the
/// database browser shows as the result.
class DbException implements Exception {
  const DbException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A database connection's bytes, read in the sizes its protocol asks for,
/// one exchange at a time: what the PostgreSQL, MongoDB and Redis clients
/// share. Over a [Tunnel] through the host, or a plain socket in a test.
class Wire {
  Wire(Tunnel tunnel)
    : _input = StreamIterator(tunnel.output),
      _sink = tunnel.input;

  final StreamIterator<List<int>> _input;
  final StreamSink<List<int>> _sink;
  Future<void> _tail = Future.value();

  /// The chunk being read, and how far into it.
  List<int> _chunk = const [];
  int _at = 0;

  Future<void> _more() async {
    if (!await _input.moveNext()) {
      throw const DbException('The database closed the connection.');
    }
    _chunk = _input.current;
    _at = 0;
  }

  /// Exactly [count] bytes, or a [DbException] once the far end has closed.
  Future<Uint8List> read(int count) async {
    final out = Uint8List(count);
    var filled = 0;
    while (filled < count) {
      if (_at == _chunk.length) await _more();
      final take = min(count - filled, _chunk.length - _at);
      out.setRange(filled, filled + take, _chunk, _at);
      filled += take;
      _at += take;
    }
    return out;
  }

  /// The bytes up to the next CRLF, without it.
  Future<Uint8List> readLine() async {
    final line = BytesBuilder(copy: false);
    while (true) {
      if (_at == _chunk.length) await _more();
      final end = _chunk.indexOf(10, _at);
      final stop = end < 0 ? _chunk.length : end + 1;
      line.add(_chunk.sublist(_at, stop));
      _at = stop;
      if (end < 0) continue;
      final bytes = line.toBytes();
      if (bytes.length > 1 && bytes[bytes.length - 2] == 13) {
        return Uint8List.sublistView(bytes, 0, bytes.length - 2);
      }
    }
  }

  void write(List<int> bytes) => _sink.add(bytes);

  /// Runs [exchange] once every one before it has finished, so each reply is
  /// read by the request that asked for it.
  Future<T> serial<T>(Future<T> Function() exchange) {
    final run = _tail.then((_) => exchange());
    _tail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Not waited for: a socket's close waits on the far end.
  Future<void> close() async {
    unawaited(_sink.close().then<void>((_) {}, onError: (_) {}));
    await _input.cancel();
  }
}

/// A SCRAM sign-in (RFC 5802): PostgreSQL's with SHA-256, MongoDB's with
/// SHA-256 or SHA-1. [first] goes out, the server's first message comes back
/// into [reply], and its last into [verify].
///
/// ponytail: the password goes as its UTF-8, without SASLprep, so one that
/// SASLprep changes (non-ASCII spaces, compatibility forms) fails to sign in.
/// Add SASLprep if a user ever has one.
class Scram {
  Scram(this._hash, String user, this._password, {String? nonce})
    : _user = user.replaceAll('=', '=3D').replaceAll(',', '=2C'),
      _nonce =
          nonce ??
          base64.encode([
            for (var i = 0; i < 18; i++) Random.secure().nextInt(256),
          ]);

  final Hash _hash;
  final String _user;
  final String _password;
  final String _nonce;
  List<int>? _serverSignature;

  String get _bare => 'n=$_user,r=$_nonce';

  /// The client's first message, with a header that asks for no channel
  /// binding.
  String get first => 'n,,$_bare';

  /// The client's final message, proving the password, for [serverFirst].
  String reply(String serverFirst) {
    final fields = _fields(serverFirst);
    final nonce = fields['r'] ?? '';
    final salt = fields['s'];
    final iterations = int.tryParse(fields['i'] ?? '');
    if (!nonce.startsWith(_nonce) || salt == null || iterations == null) {
      throw const DbException('The database answered the sign-in oddly.');
    }
    final salted = _hi(utf8.encode(_password), base64.decode(salt), iterations);
    final clientKey = _hmac(salted, utf8.encode('Client Key'));
    final withoutProof = 'c=biws,r=$nonce';
    final auth = utf8.encode('$_bare,$serverFirst,$withoutProof');
    final signature = _hmac(_hash.convert(clientKey).bytes, auth);
    _serverSignature = _hmac(_hmac(salted, utf8.encode('Server Key')), auth);
    final proof = [
      for (var i = 0; i < clientKey.length; i++) clientKey[i] ^ signature[i],
    ];
    return '$withoutProof,p=${base64.encode(proof)}';
  }

  /// Throws unless [serverFinal] proves the server knows the password too.
  void verify(String serverFinal) {
    final fields = _fields(serverFinal);
    if (fields['e'] case final error?) {
      throw DbException('Sign-in refused: $error');
    }
    final expected = _serverSignature;
    if (expected == null || fields['v'] != base64.encode(expected)) {
      throw const DbException(
        'The database could not prove it knows the password.',
      );
    }
  }

  List<int> _hmac(List<int> key, List<int> data) =>
      Hmac(_hash, key).convert(data).bytes;

  /// Hi() from RFC 5802: PBKDF2, one block, with HMAC as its PRF.
  List<int> _hi(List<int> password, List<int> salt, int iterations) {
    final mac = Hmac(_hash, password);
    var u = mac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = [...u];
    for (var n = 1; n < iterations; n++) {
      u = mac.convert(u).bytes;
      for (var i = 0; i < out.length; i++) {
        out[i] ^= u[i];
      }
    }
    return out;
  }

  static Map<String, String> _fields(String message) => {
    for (final field in message.split(','))
      if (field.length > 1 && field[1] == '=') field[0]: field.substring(2),
  };
}
