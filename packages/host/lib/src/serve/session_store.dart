import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/output_backlog.dart';
import '../domain/session_lifecycle.dart';
import '../domain/session_recorder.dart';
import '../pty/pty.dart';

/// A session's ring, on disk, bounded the same way the ring is: append-only,
/// with the absolute offset of the first surviving byte beside it, which is the
/// whole contract `attach since N` needs.
class SessionStore implements SessionBacklogStore {
  SessionStore(
    this.directory, {
    this.capacityBytes = OutputBacklog.defaultCapacityBytes,
    this.keepEndedSessions = 16,
  });

  /// `<host directory>/sessions`.
  final Directory directory;

  /// The ring's capacity, so a restarted host answers what a running one would.
  final int capacityBytes;

  /// How many *ended* sessions are kept. Running ones are never pruned.
  final int keepEndedSessions;

  /// A quarter of a capacity late, so the copy is amortised over that quarter.
  int get rotateAboveBytes => capacityBytes + capacityBytes ~/ 4;

  static const int _metaVersion = 1;

  void ensureDirectory() {
    if (!directory.existsSync()) directory.createSync(recursive: true);
  }

  Directory _directoryFor(String id) =>
      Directory('${directory.path}/${_safeName(id)}');

  /// A name every filesystem accepts, with a hash suffix so two ids that
  /// sanitise the same way do not share a directory.
  static String _safeName(String id) {
    final cleaned = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final trimmed = cleaned.length <= 64 ? cleaned : cleaned.substring(0, 64);
    var hash = 0x811c9dc5;
    for (final unit in id.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return '$trimmed-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  /// Never throws: a record that cannot be opened costs the record, not the
  /// session it was about to describe.
  @override
  SessionRecord open(String id, PtySpawnRequest request, DateTime startedAt) {
    final dir = _directoryFor(id);
    RandomAccessFile? out;
    try {
      // Not deleted first: the open truncates `out.bin` anyway, and Windows
      // refuses to delete a directory a killed host still holds a handle in.
      if (!dir.existsSync()) dir.createSync(recursive: true);
      out = File('${dir.path}/out.bin').openSync(mode: FileMode.writeOnly);
    } on FileSystemException {
      out = null;
    }
    final record = SessionRecord._(
      store: this,
      id: id,
      directory: dir,
      request: request,
      startedAt: startedAt,
      out: out,
    );
    if (out != null) record._writeMeta();
    return record;
  }

  /// Everything the last host left behind, oldest first. An unreadable
  /// directory is skipped, never fatal.
  @override
  List<RestoredSession> restore() {
    if (!directory.existsSync()) return const [];
    final found = <RestoredSession>[];
    for (final entity in directory.listSync().whereType<Directory>()) {
      final session = _readOne(entity);
      if (session != null) found.add(session);
    }
    found.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return found;
  }

  RestoredSession? _readOne(Directory dir) {
    try {
      final metaFile = File('${dir.path}/meta.json');
      if (!metaFile.existsSync()) return null;
      final meta =
          jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
      if (meta['version'] != _metaVersion) return null;
      final id = meta['id'] as String;
      final firstOffset = (meta['firstOffset'] as num).toInt();

      final outFile = File('${dir.path}/out.bin');
      final onDisk = outFile.existsSync() ? outFile.lengthSync() : 0;
      final totalBytes = firstOffset + onDisk;
      final keep = onDisk <= capacityBytes ? onDisk : capacityBytes;
      final tail = _readTail(outFile, onDisk - keep, keep);

      final wasRunning = meta['state'] == 'running';
      return RestoredSession(
        id: id,
        request: PtySpawnRequest(
          argv: [for (final a in meta['argv'] as List) a as String],
          workingDirectory: meta['workingDirectory'] as String?,
          environment: {
            for (final entry in (meta['environment'] as Map).entries)
              entry.key as String: entry.value as String,
          },
          removedEnvironment: {
            for (final name
                in (meta['removedEnvironment'] as List?) ?? const [])
              name as String,
          },
          columns: (meta['columns'] as num).toInt(),
          rows: (meta['rows'] as num).toInt(),
        ),
        startedAt: DateTime.fromMicrosecondsSinceEpoch(
          (meta['startedAt'] as num).toInt(),
          isUtc: true,
        ),
        lifecycle: _lifecycleFrom(meta),
        wasRunning: wasRunning,
        backlog: OutputBacklog.restored(
          capacityBytes: capacityBytes,
          totalBytes: totalBytes,
          tail: tail,
        ),
      );
    } on Object {
      // Truncated, half-written, or from a future version of this file.
      return null;
    }
  }

  /// The last [length] bytes, read without holding the whole file.
  static Uint8List _readTail(File file, int from, int length) {
    if (length <= 0) return Uint8List(0);
    final handle = file.openSync()..setPositionSync(from);
    try {
      return handle.readSync(length);
    } finally {
      handle.closeSync();
    }
  }

  SessionLifecycle _lifecycleFrom(Map<String, dynamic> meta) {
    final endedAt = meta['endedAt'] == null
        ? DateTime.now().toUtc()
        : DateTime.fromMicrosecondsSinceEpoch(
            (meta['endedAt'] as num).toInt(),
            isUtc: true,
          );
    switch (meta['state']) {
      case 'exited':
        return SessionExited((meta['exitCode'] as num).toInt(), endedAt);
      case 'ended':
        return SessionEndedWithoutCode(
          endedAt,
          meta['reason'] as String? ?? 'unrecorded',
        );
      default:
        // Running when the host stopped, so never an exit code and never a
        // zero — the case ExitedMessage's null code exists for.
        return SessionEndedWithoutCode(
          DateTime.now().toUtc(),
          'the host that owned this session stopped while it was running, so '
          'the process did not survive; only its output was kept',
        );
    }
  }

  /// Drops the record for good — a deliberate close, never a disconnect.
  @override
  void forget(String id) {
    final dir = _directoryFor(id);
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      // Windows refuses to delete a directory holding our own open `out.bin`;
      // dropping the metadata alone is enough for `restore` to skip it.
    }
    try {
      File('${dir.path}/meta.json').deleteSync();
    } on FileSystemException {
      // Nothing left to try; the record stays until something can remove it.
    }
  }

  /// Keeps the newest [keepEndedSessions] ended records and deletes the rest.
  /// Run when a session ends, never on a timer.
  void pruneEnded() {
    if (!directory.existsSync()) return;
    final ended = <(DateTime, Directory)>[];
    for (final entity in directory.listSync().whereType<Directory>()) {
      try {
        final meta =
            jsonDecode(File('${entity.path}/meta.json').readAsStringSync())
                as Map<String, dynamic>;
        if (meta['state'] == 'running') continue;
        final endedAt = (meta['endedAt'] as num?)?.toInt() ?? 0;
        ended.add((
          DateTime.fromMicrosecondsSinceEpoch(endedAt, isUtc: true),
          entity,
        ));
      } on Object {
        // Unreadable: it can go with the rest of the old ones.
        ended.add((
          DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true),
          entity,
        ));
      }
    }
    if (ended.length <= keepEndedSessions) return;
    ended.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (_, dir) in ended.take(ended.length - keepEndedSessions)) {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Held open by something; it will be pruned next time one ends.
      }
    }
  }
}

/// One session's record, open for appending.
class SessionRecord implements SessionRecorder {
  SessionRecord._({
    required SessionStore store,
    required this.id,
    required Directory directory,
    required PtySpawnRequest request,
    required DateTime startedAt,
    required RandomAccessFile? out,
  }) : _store = store,
       _directory = directory,
       _request = request,
       _startedAt = startedAt,
       _out = out,
       _broken = out == null;

  final SessionStore _store;
  final String id;
  final Directory _directory;
  final PtySpawnRequest _request;
  final DateTime _startedAt;
  RandomAccessFile? _out;

  /// The absolute offset of the first byte still in `out.bin`; what `attach
  /// since N` reports as discarded.
  int _firstOffset = 0;
  int _onDisk = 0;
  SessionLifecycle _lifecycle = const SessionRunning();

  /// The output handle is released once no further byte can arrive.
  var _handleClosed = false;

  /// Something on disk refused us; everything after is a no-op, because losing
  /// the record is survivable and losing the session is not.
  bool _broken;

  /// Whether anything reaches disk. False from the start when the open failed.
  bool get isRecording => !_broken;

  @override
  void record(Uint8List bytes) {
    final out = _out;
    if (_broken || _handleClosed || out == null || bytes.isEmpty) return;
    try {
      out.writeFromSync(bytes);
      _onDisk += bytes.length;
      if (_onDisk > _store.rotateAboveBytes) _rotate();
    } on FileSystemException {
      // Disk full or directory gone: the ring in memory and the session are
      // untouched, and only the record is lost.
      _broken = true;
    }
  }

  /// Drops everything but the last capacity of bytes, in one rewrite.
  void _rotate() {
    final keep = _store.capacityBytes;
    final drop = _onDisk - keep;
    final reader = File('${_directory.path}/out.bin').openSync()
      ..setPositionSync(drop);
    final Uint8List tail;
    try {
      tail = reader.readSync(keep);
    } finally {
      reader.closeSync();
    }
    _out?.closeSync();
    _out = File('${_directory.path}/out.bin').openSync(mode: FileMode.writeOnly)
      ..truncateSync(0)
      ..writeFromSync(tail);
    _firstOffset += drop;
    _onDisk = tail.length;
    _writeMeta();
  }

  /// Independent of [close]: the end and the last byte arrive in either order.
  @override
  void ended(SessionLifecycle lifecycle) {
    if (_broken) return;
    _lifecycle = lifecycle;
    _writeMeta();
    _store.pruneEnded();
  }

  @override
  void close() {
    if (_handleClosed) return;
    _handleClosed = true;
    try {
      _out?.closeSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  void _writeMeta() {
    final lifecycle = _lifecycle;
    final meta = <String, Object?>{
      'version': SessionStore._metaVersion,
      'id': id,
      'argv': _request.argv,
      'workingDirectory': _request.workingDirectory,
      'environment': _request.environment,
      'removedEnvironment': _request.removedEnvironment.toList(),
      'columns': _request.columns,
      'rows': _request.rows,
      'startedAt': _startedAt.toUtc().microsecondsSinceEpoch,
      'firstOffset': _firstOffset,
      'state': switch (lifecycle) {
        SessionRunning() => 'running',
        SessionExited() => 'exited',
        SessionEndedWithoutCode() => 'ended',
      },
      'exitCode': lifecycle.exitCode,
      'reason': switch (lifecycle) {
        SessionEndedWithoutCode(:final reason) => reason,
        _ => null,
      },
      'endedAt': lifecycle.endedAt?.toUtc().microsecondsSinceEpoch,
    };
    try {
      // Written whole then renamed: a half-written meta.json is a session the
      // next host silently drops.
      final staging = File('${_directory.path}/meta.json.new')
        ..writeAsStringSync(jsonEncode(meta), flush: true);
      staging.renameSync('${_directory.path}/meta.json');
    } on FileSystemException {
      _broken = true;
    }
  }
}
