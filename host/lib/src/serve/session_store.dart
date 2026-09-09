import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/output_backlog.dart';
import '../domain/session_lifecycle.dart';
import '../domain/session_recorder.dart';
import '../pty/pty.dart';

/// A session's ring, on disk, bounded the same way the ring is.
///
/// Append-only: the bytes go down in the order the child produced them and the
/// absolute offset of the first surviving byte is recorded beside them, which
/// is the whole contract `attach since N` needs. When the file passes
/// [rotateAboveBytes] its oldest bytes are dropped in one rewrite — the same
/// thing the ring does continuously, done in batches because a file cannot
/// overwrite its own beginning cheaply.
///
/// The bound is deliberately the ring's: a session that would cost 4 MiB of
/// memory costs at most [rotateAboveBytes] of disk, so a host holding a hundred
/// sessions is not a different-sized problem on disk than it is in RAM.
class SessionStore implements SessionBacklogStore {
  SessionStore(
    this.directory, {
    this.capacityBytes = OutputBacklog.defaultCapacityBytes,
    this.keepEndedSessions = 16,
  });

  /// `<host directory>/sessions`.
  final Directory directory;

  /// How much of each session survives a restart. The ring's capacity, so a
  /// restarted host answers exactly what a running one would have.
  final int capacityBytes;

  /// How many *ended* sessions are kept. Running ones are never pruned: the
  /// host's job is to hold them.
  final int keepEndedSessions;

  /// The rewrite happens a quarter of a capacity late, so the copy is amortised
  /// over that quarter rather than paid on every chunk.
  int get rotateAboveBytes => capacityBytes + capacityBytes ~/ 4;

  static const int _metaVersion = 1;

  void ensureDirectory() {
    if (!directory.existsSync()) directory.createSync(recursive: true);
  }

  Directory _directoryFor(String id) => Directory('${directory.path}/${_safeName(id)}');

  /// A directory name that is a name on every filesystem, and a suffix so two
  /// ids that sanitise the same way do not share one. The id itself is read
  /// back from the metadata, never from the name.
  static String _safeName(String id) {
    final cleaned = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final trimmed = cleaned.length <= 64 ? cleaned : cleaned.substring(0, 64);
    var hash = 0x811c9dc5;
    for (final unit in id.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return '$trimmed-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  /// Opens the record for a session that is starting now.
  @override
  SessionRecord open(String id, PtySpawnRequest request, DateTime startedAt) {
    final dir = _directoryFor(id);
    // Not deleted first: opening `out.bin` for writing truncates it and
    // `_writeMeta` replaces the metadata, so a record left by the same id is
    // fully overwritten — and Windows refuses to delete a directory whose file
    // some other handle still holds, which a host that was killed mid-session
    // leaves behind.
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final record = SessionRecord._(
      store: this,
      id: id,
      directory: dir,
      request: request,
      startedAt: startedAt,
    );
    record._writeMeta();
    return record;
  }

  /// Everything the last host left behind, oldest first.
  ///
  /// A directory that cannot be read is skipped rather than fatal: a host that
  /// refuses to start because one session's metadata was truncated by a power
  /// cut would be a worse host than one that lost that session.
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
      final meta = jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
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

  /// The last [length] bytes, read without holding the whole file. A ring's
  /// worth is all that can be answered for, whatever the file grew to between
  /// rotations.
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
        : DateTime.fromMicrosecondsSinceEpoch((meta['endedAt'] as num).toInt(), isUtc: true);
    switch (meta['state']) {
      case 'exited':
        return SessionExited((meta['exitCode'] as num).toInt(), endedAt);
      case 'ended':
        return SessionEndedWithoutCode(endedAt, meta['reason'] as String? ?? 'unrecorded');
      default:
        // It was running when the host stopped, so its process went with it.
        // Never an exit code, and never a zero: this is exactly the case
        // ExitedMessage's null code exists for.
        return SessionEndedWithoutCode(
          DateTime.now().toUtc(),
          'the host that owned this session stopped while it was running, so '
          'the process did not survive; only its output was kept',
        );
    }
  }

  /// Drops a session's record for good. Called when the session is closed on
  /// purpose, never when a client merely disconnects.
  @override
  void forget(String id) {
    final dir = _directoryFor(id);
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      // Windows refuses to delete a directory holding an open file, and the
      // one process that can still have `out.bin` open is this one. Dropping
      // the metadata is enough to make the record forgotten — `restore` skips a
      // directory without it and `pruneEnded` counts it among the oldest — and
      // it is better than leaving a session a later host would resurrect.
    }
    try {
      File('${dir.path}/meta.json').deleteSync();
    } on FileSystemException {
      // Nothing left to try; the record stays until something can remove it.
    }
  }

  /// Keeps the newest [keepEndedSessions] ended records and deletes the rest.
  ///
  /// Run when a session *ends* — an event the host already observes — and never
  /// on a timer or a scan of its own.
  void pruneEnded() {
    if (!directory.existsSync()) return;
    final ended = <(DateTime, Directory)>[];
    for (final entity in directory.listSync().whereType<Directory>()) {
      try {
        final meta =
            jsonDecode(File('${entity.path}/meta.json').readAsStringSync()) as Map<String, dynamic>;
        if (meta['state'] == 'running') continue;
        final endedAt = (meta['endedAt'] as num?)?.toInt() ?? 0;
        ended.add((DateTime.fromMicrosecondsSinceEpoch(endedAt, isUtc: true), entity));
      } on Object {
        // Unreadable: it can go with the rest of the old ones.
        ended.add((DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true), entity));
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
  }) : _store = store,
       _directory = directory,
       _request = request,
       _startedAt = startedAt,
       _out = File('${directory.path}/out.bin').openSync(mode: FileMode.writeOnly);

  final SessionStore _store;
  final String id;
  final Directory _directory;
  final PtySpawnRequest _request;
  final DateTime _startedAt;
  RandomAccessFile _out;

  /// The absolute offset of the first byte still in `out.bin`. Everything
  /// before it was dropped by a rotation and is what `attach since N` reports
  /// as discarded.
  int _firstOffset = 0;
  int _onDisk = 0;
  SessionLifecycle _lifecycle = const SessionRunning();

  /// The output handle is released once no further byte can arrive.
  var _handleClosed = false;

  /// Something on disk refused us. Everything after that is a no-op: losing the
  /// record is survivable, and taking the session down with it is not.
  var _broken = false;

  @override
  void record(Uint8List bytes) {
    if (_broken || _handleClosed || bytes.isEmpty) return;
    try {
      _out.writeFromSync(bytes);
      _onDisk += bytes.length;
      if (_onDisk > _store.rotateAboveBytes) _rotate();
    } on FileSystemException {
      // The disk is full or the directory went away. The ring in memory is
      // untouched and the session keeps running; only the record is lost, and
      // losing it silently is better than taking the session with it.
      _broken = true;
    }
  }

  /// Drops everything but the last capacity of bytes, in one rewrite.
  void _rotate() {
    final keep = _store.capacityBytes;
    final drop = _onDisk - keep;
    final reader = File('${_directory.path}/out.bin').openSync()..setPositionSync(drop);
    final Uint8List tail;
    try {
      tail = reader.readSync(keep);
    } finally {
      reader.closeSync();
    }
    _out.closeSync();
    _out = File('${_directory.path}/out.bin').openSync(mode: FileMode.writeOnly)
      ..truncateSync(0)
      ..writeFromSync(tail);
    _firstOffset += drop;
    _onDisk = tail.length;
    _writeMeta();
  }

  /// Deliberately independent of [close]: the end and the last byte arrive in
  /// either order, and the metadata write needs no open handle.
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
      _out.closeSync();
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
      // Written whole, then moved into place: a half-written meta.json is a
      // session the next host silently drops, and a power cut is exactly when
      // that happens.
      final staging = File('${_directory.path}/meta.json.new')
        ..writeAsStringSync(jsonEncode(meta), flush: true);
      staging.renameSync('${_directory.path}/meta.json');
    } on FileSystemException {
      _broken = true;
    }
  }
}
