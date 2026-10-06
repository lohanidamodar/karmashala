import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_automations/webhooks.dart';
import 'package:karmashala_mcp/access.dart'
    show HandshakePermissions, SystemHandshakePermissions;
import 'package:path/path.dart' as p;

/// The webhook secrets this server holds: `<data dir>/secrets/hooks.json`, in
/// the owner-only directory beside the env and store vaults. The listen key
/// and each hook's signing secret leave this object only to verify a call or
/// to open the listener, and once — to the person who rotated it.
class ServerHookVault {
  ServerHookVault({
    required String dataDirectory,
    HandshakePermissions permissions = const SystemHandshakePermissions(),
  }) : _directory = Directory(p.join(dataDirectory, directoryName)),
       _permissions = permissions {
    _load();
  }

  static const String directoryName = 'secrets';
  static const String fileName = 'hooks.json';

  final Directory _directory;
  final HandshakePermissions _permissions;

  String? _listenKey;
  final Map<String, String> _secrets = {};

  /// Why the file could not be read; while set, writes are refused so an
  /// unreadable vault is never overwritten.
  String? _unreadable;

  Future<void> _writes = Future<void>.value();

  File get _file => File(p.join(_directory.path, fileName));

  /// This server's listen key, made on first use.
  Future<String> listenKey() {
    // One in flight, and waited on: two callers must never mint two keys, nor
    // hand out one that is not yet on disk.
    final making = _makingKey;
    if (making != null) return making;
    final held = _listenKey;
    if (held != null) return Future.value(held);
    return _makingKey = () async {
      final key = newWebhookListenKey();
      try {
        await _change(() => _listenKey = key, () => _listenKey = null);
        return key;
      } finally {
        _makingKey = null;
      }
    }();
  }

  Future<String>? _makingKey;

  /// The key if one was ever made — the listener needs no new one to stay shut.
  String? get heldListenKey => _listenKey;

  String? secretOf(String hookId) => _secrets[hookId];

  /// The hooks a secret is held for.
  List<String> get hookIds => [..._secrets.keys];

  /// A new secret for [hookId], replacing any old one at once.
  Future<String> rotate(String hookId) async {
    final before = _secrets[hookId];
    final secret = newWebhookSecret();
    await _change(
      () => _secrets[hookId] = secret,
      () =>
          before == null ? _secrets.remove(hookId) : _secrets[hookId] = before,
    );
    return secret;
  }

  Future<void> forget(String hookId) async {
    final before = _secrets[hookId];
    if (before == null) return;
    await _change(
      () => _secrets.remove(hookId),
      () => _secrets[hookId] = before,
    );
  }

  Future<void> _change(void Function() apply, void Function() undo) async {
    final problem = _unreadable;
    if (problem != null) {
      throw StateError(
        'the webhook vault could not be read ($problem), so nothing is '
        'written over it',
      );
    }
    apply();
    final snapshot = {
      'version': 1,
      'listenKey': _listenKey,
      'secrets': Map.of(_secrets),
    };
    final done = _writes.then((_) => _write(snapshot));
    _writes = done.catchError((Object _) {});
    try {
      await done;
    } on Object {
      undo();
      rethrow;
    }
  }

  void _load() {
    final file = _file;
    if (!file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      _listenKey = json['listenKey'] as String?;
      final secrets = json['secrets'] as Map<String, Object?>? ?? const {};
      for (final MapEntry(:key, :value) in secrets.entries) {
        if (value is String) _secrets[key] = value;
      }
    } on Object catch (error) {
      _listenKey = null;
      _secrets.clear();
      // The type only: a parse error can quote the file.
      _unreadable = '${error.runtimeType}';
    }
  }

  Future<void> _write(Map<String, Object?> snapshot) async {
    if (!_directory.existsSync()) _directory.createSync(recursive: true);
    if (!await _permissions.restrictDirectory(_directory)) {
      throw StateError(
        'the webhook vault\'s folder could not be made owner-only, so nothing '
        'was written',
      );
    }
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString('');
    if (!await _permissions.restrictFile(temp)) {
      await temp.delete();
      throw StateError(
        'the webhook vault\'s file could not be made owner-only, so nothing '
        'was written',
      );
    }
    await temp.writeAsString(jsonEncode(snapshot), flush: true);
    await temp.rename(_file.path);
  }

  @override
  String toString() => 'ServerHookVault(${_secrets.length} secrets)';
}
