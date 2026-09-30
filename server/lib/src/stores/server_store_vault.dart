import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_mcp/access.dart'
    show HandshakePermissions, SystemHandshakePermissions;
import 'package:path/path.dart' as p;
import 'package:store_console/store_console.dart' show StoreKind;
import 'package:store_console_apple/store_console_apple.dart';
import 'package:store_console_play/store_console_play.dart';

/// The App Store Connect key held, and when its key file came in.
final class HeldAppleKey {
  const HeldAppleKey(this.key, this.importedAt);

  final AppleApiKey key;
  final DateTime importedAt;

  @override
  String toString() => 'HeldAppleKey(${key.keyId})';
}

/// The Play service account held, and when its key file came in.
final class HeldPlayAccount {
  const HeldPlayAccount(this.account, this.importedAt);

  final PlayAccount account;
  final DateTime importedAt;

  @override
  String toString() => 'HeldPlayAccount(${account.clientEmail})';
}

/// The app-store credentials this server uses: `<data dir>/secrets/
/// stores.json`, in a directory only this account can open. A credential
/// leaves this object only to build a store client in this process.
class ServerStoreVault {
  ServerStoreVault({
    required String dataDirectory,
    HandshakePermissions permissions = const SystemHandshakePermissions(),
  }) : _directory = Directory(p.join(dataDirectory, directoryName)),
       _permissions = permissions {
    _load();
  }

  static const String directoryName = 'secrets';
  static const String fileName = 'stores.json';
  static const int _version = 1;

  final Directory _directory;
  final HandshakePermissions _permissions;

  HeldAppleKey? _apple;
  HeldPlayAccount? _play;

  /// Why the file could not be read; while set, writes are refused so an
  /// unreadable vault is never overwritten.
  String? _unreadable;

  Future<void> _writes = Future<void>.value();

  File get _file => File(p.join(_directory.path, fileName));

  HeldAppleKey? get apple => _apple;
  HeldPlayAccount? get play => _play;

  Future<void> setApple(HeldAppleKey held) => _change(() => _apple = held);

  Future<void> setPlay(HeldPlayAccount held) => _change(() => _play = held);

  Future<void> remove(StoreKind store) => _change(() {
    switch (store) {
      case StoreKind.appStore:
        _apple = null;
      case StoreKind.googlePlay:
        _play = null;
    }
  });

  Future<void> _change(void Function() apply) async {
    _refuseUnreadable();
    final before = (_apple, _play);
    apply();
    try {
      await _save();
    } on Object {
      _apple = before.$1;
      _play = before.$2;
      rethrow;
    }
  }

  void _refuseUnreadable() {
    final problem = _unreadable;
    if (problem == null) return;
    throw DataRefused(
      DataRefusalCode.failed,
      'the app-store credentials could not be read ($problem), so nothing is '
      'written over them',
    );
  }

  void _load() {
    final file = _file;
    if (!file.existsSync()) return;
    try {
      final decoded = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, Object?>();
      if (decoded['version'] != _version) {
        throw const FormatException('unknown version');
      }
      final apple = decoded['apple'];
      if (apple is Map) {
        _apple = HeldAppleKey(
          AppleApiKey.decode(apple['key']! as String),
          DateTime.parse(apple['importedAt']! as String).toUtc(),
        );
      }
      final play = decoded['play'];
      if (play is Map) {
        _play = HeldPlayAccount(
          PlayAccount.decode(play['account']! as String),
          DateTime.parse(play['importedAt']! as String).toUtc(),
        );
      }
    } on Object catch (error) {
      _apple = null;
      _play = null;
      // The error's type only: a parse error can quote the file's text.
      _unreadable = '${error.runtimeType}';
    }
  }

  Future<void> _save() {
    final apple = _apple;
    final play = _play;
    final contents = {
      'version': _version,
      if (apple != null)
        'apple': {
          'key': apple.key.encode(),
          'importedAt': apple.importedAt.toUtc().toIso8601String(),
        },
      if (play != null)
        'play': {
          'account': play.account.encode(),
          'importedAt': play.importedAt.toUtc().toIso8601String(),
        },
    };
    final done = _writes.then((_) => _write(contents));
    _writes = done.catchError((Object _) {});
    return done;
  }

  Future<void> _write(Map<String, Object?> contents) async {
    try {
      if (!_directory.existsSync()) _directory.createSync(recursive: true);
      if (!await _permissions.restrictDirectory(_directory)) {
        throw const DataRefused(
          DataRefusalCode.failed,
          'the app-store credentials\' folder could not be made owner-only, '
          'so nothing was written',
        );
      }
      final temp = File('${_file.path}.tmp');
      await temp.writeAsString('');
      if (!await _permissions.restrictFile(temp)) {
        await temp.delete();
        throw const DataRefused(
          DataRefusalCode.failed,
          'the app-store credentials\' file could not be made owner-only, so '
          'nothing was written',
        );
      }
      await temp.writeAsString(jsonEncode(contents), flush: true);
      await temp.rename(_file.path);
    } on DataRefused {
      rethrow;
    } on FileSystemException catch (error) {
      // The OS's words about the path, never the content.
      throw DataRefused(
        DataRefusalCode.failed,
        'the app-store credentials could not be written: ${error.message}',
      );
    }
  }
}
