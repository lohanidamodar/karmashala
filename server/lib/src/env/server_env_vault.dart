import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_mcp/access.dart'
    show HandshakePermissions, SystemHandshakePermissions;
import 'package:path/path.dart' as p;

import '../data/env_work.dart';

/// The environment variables this server lays over every terminal it starts
/// (slice 5a): one JSON file, `<data dir>/secrets/env.json`, in a directory
/// only this account can open. **Write-only**: a client lists names, sets a
/// value or removes one; a value leaves this object only through [overlay],
/// for the server's own launches, and never in an answer, a change or a log.
///
/// Per server: a server on another machine has its own vault. Nothing is read
/// from the desktop app's old vault (no migration).
class ServerEnvVault implements EnvVault {
  ServerEnvVault({
    required String dataDirectory,
    required void Function(List<DataChange> changes) tell,
    DateTime Function()? clock,
    HandshakePermissions permissions = const SystemHandshakePermissions(),
  }) : _directory = Directory(p.join(dataDirectory, directoryName)),
       _tell = tell,
       _now = clock ?? _utcNow,
       _permissions = permissions {
    _load();
  }

  /// The directory inside the data directory, and the file in it.
  static const String directoryName = 'secrets';
  static const String fileName = 'env.json';

  final Directory _directory;
  final void Function(List<DataChange> changes) _tell;
  final DateTime Function() _now;
  final HandshakePermissions _permissions;

  final _values = <String, String>{};
  final _updated = <String, DateTime>{};

  /// Why the file on disk could not be read, when it could not; while set,
  /// writes are refused so an unreadable vault is never overwritten.
  String? _unreadable;

  /// One write at a time, in order.
  Future<void> _writes = Future<void>.value();

  static DateTime _utcNow() => DateTime.now().toUtc();

  File get _file => File(p.join(_directory.path, fileName));

  /// Name → value, for a launch this server makes. The only way out for a
  /// value, and it stays in this process.
  Map<String, String> overlay() => Map.unmodifiable(_values);

  /// The names, by name, with when each was set.
  List<EnvVariableName> get names {
    final names = _values.keys.toList()..sort();
    return [
      for (final name in names)
        EnvVariableName(name: name, updatedAt: _updated[name]!),
    ];
  }

  /// What a client that has just subscribed is told: the names as they stand.
  List<DataChange> greeting() => [EnvVariablesChanged(names)];

  @override
  Future<Object?> handle(EnvVaultRequest<Object?> request) async =>
      switch (request) {
        EnvList() => names,
        final EnvSet r => await _set(r.variable, r.value),
        final EnvRemove r => await _remove(r.variable),
        final EnvRename r => await _rename(r.from, r.to, r.value),
      };

  Future<DataAck> _set(String rawName, String value) async {
    final name = rawName.trim();
    final refused = envNameRefusal(name) ?? envValueRefusal(value);
    if (refused != null) throw DataRefused.invalid(refused);
    _refuseUnreadable();
    final before = (_values[name], _updated[name]);
    _values[name] = value;
    _updated[name] = _now();
    try {
      await _save();
    } on Object {
      _restore(name, before);
      rethrow;
    }
    return const DataAck();
  }

  /// [from] becomes [to], its value moving with it or replaced by [value], in
  /// one save: the file never holds both names, and a failed save puts both
  /// back as they were.
  Future<DataAck> _rename(String rawFrom, String rawTo, String? value) async {
    final from = rawFrom.trim();
    final to = rawTo.trim();
    final refused =
        envNameRefusal(to) ?? (value == null ? null : envValueRefusal(value));
    if (refused != null) throw DataRefused.invalid(refused);
    _refuseUnreadable();
    if (envRenameRefusal(from, to, _values.keys) case final clash?) {
      throw _values.containsKey(from)
          ? DataRefused.invalid(clash)
          : DataRefused.notFound(clash);
    }
    final beforeFrom = (_values[from], _updated[from]);
    final beforeTo = (_values[to], _updated[to]);
    final moved = _values.remove(from)!;
    _updated.remove(from);
    _values[to] = value ?? moved;
    _updated[to] = _now();
    try {
      await _save();
    } on Object {
      _restore(to, beforeTo);
      _restore(from, beforeFrom);
      rethrow;
    }
    return const DataAck();
  }

  Future<DataAck> _remove(String rawName) async {
    final name = rawName.trim();
    _refuseUnreadable();
    final before = (_values.remove(name), _updated.remove(name));
    if (before.$1 == null) return const DataAck();
    try {
      await _save();
    } on Object {
      _restore(name, before);
      rethrow;
    }
    return const DataAck();
  }

  /// Puts [name] back as it was before a write that did not land.
  void _restore(String name, (String?, DateTime?) before) {
    final (value, at) = before;
    if (value == null || at == null) {
      _values.remove(name);
      _updated.remove(name);
    } else {
      _values[name] = value;
      _updated[name] = at;
    }
  }

  void _refuseUnreadable() {
    final problem = _unreadable;
    if (problem == null) return;
    throw DataRefused(
      DataRefusalCode.failed,
      'the environment vault could not be read ($problem), so nothing is '
      'written over it',
    );
  }

  /// Read once, at start. A missing file is an empty vault; one that will
  /// not parse is left alone and refuses writes.
  void _load() {
    final file = _file;
    if (!file.existsSync()) return;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      final list = (decoded as Map)['variables'] as List;
      for (final item in list) {
        final row = (item as Map).cast<String, Object?>();
        final name = row['name'];
        final value = row['value'];
        final at = DateTime.tryParse('${row['updatedAt']}');
        if (name is! String || value is! String) continue;
        if (envNameRefusal(name) != null || envValueRefusal(value) != null) {
          continue;
        }
        _values[name] = value;
        _updated[name] =
            at?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      }
    } on Object catch (error) {
      _values.clear();
      _updated.clear();
      // The error's type only: a parse error can quote the file's text.
      _unreadable = '${error.runtimeType}';
    }
  }

  /// Writes the whole vault — owner-only directory, a temp file restricted
  /// before anything is written into it, then renamed over the old one — and
  /// tells every client the names.
  Future<void> _save() {
    final snapshot = {
      'variables': [
        for (final name in _values.keys)
          {
            'name': name,
            'value': _values[name],
            'updatedAt': _updated[name]!.toIso8601String(),
          },
      ],
    };
    final done = _writes.then((_) => _write(snapshot));
    _writes = done.catchError((Object _) {});
    return done.then((_) => _tell([EnvVariablesChanged(names)]));
  }

  Future<void> _write(Map<String, Object?> snapshot) async {
    try {
      if (!_directory.existsSync()) _directory.createSync(recursive: true);
      if (!await _permissions.restrictDirectory(_directory)) {
        throw const DataRefused(
          DataRefusalCode.failed,
          'the environment vault\'s folder could not be made owner-only, so '
          'nothing was written',
        );
      }
      final temp = File('${_file.path}.tmp');
      await temp.writeAsString('');
      if (!await _permissions.restrictFile(temp)) {
        await temp.delete();
        throw const DataRefused(
          DataRefusalCode.failed,
          'the environment vault\'s file could not be made owner-only, so '
          'nothing was written',
        );
      }
      await temp.writeAsString(jsonEncode(snapshot), flush: true);
      await temp.rename(_file.path);
    } on DataRefused {
      rethrow;
    } on FileSystemException catch (error) {
      // The OS's words about the path, never the content.
      throw DataRefused(
        DataRefusalCode.failed,
        'the environment vault could not be written: ${error.message}',
      );
    }
  }
}
