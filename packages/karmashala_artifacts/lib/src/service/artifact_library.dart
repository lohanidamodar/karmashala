import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/artifact.dart';
import '../store/artifact_dao.dart';
import 'artifact_sources.dart';

/// A session's artifacts, kept on the server. Every revision's bytes are
/// copied into [directory], so a client is served the snapshot — never the
/// host path — and an old revision still opens after the source changes.
class ArtifactLibrary {
  ArtifactLibrary({
    required this._dao,
    required String directory,
    required this._sources,
    String Function()? newId,
    DateTime Function()? now,
    this.maxBytes = 16 * 1024 * 1024,
    this.keepRevisions = 20,
  }) : _directory = p.normalize(p.absolute(directory)),
       _newId = newId ?? _randomId,
       _now = now ?? _utcNow;

  final ArtifactDao _dao;
  final String _directory;
  final ArtifactSources _sources;
  final String Function() _newId;
  final DateTime Function() _now;

  /// The largest content kept, in bytes.
  final int maxBytes;

  /// How many revisions keep their snapshot; older ones are dropped.
  final int keepRevisions;

  /// Told each artifact as it is made or changed.
  void Function(Artifact artifact)? onChanged;

  final _busy = <String, Future<void>>{};

  Artifact? byId(String id) => _dao.byId(id);

  List<Artifact> forSession(String sessionId) => _dao.forSession(sessionId);

  List<ArtifactRevision> revisions(String id) => _dao.revisions(id);

  /// The artifacts a watcher looks at: those read from a host file.
  List<Artifact> watched({int limit = 200}) => _dao.withSource(limit: limit);

  /// Registers [source] — or text [content] — on [sessionId]. Showing a file
  /// the session already showed refreshes that artifact instead of adding a
  /// second. Throws [ArgumentError] for a request that names nothing usable
  /// and [StateError] for a file that cannot be read.
  Future<Artifact> show({
    required String sessionId,
    EnvironmentPath? source,
    String? content,
    String? title,
    ArtifactKind? kind,
    ArtifactMode? mode,
    ArtifactOrigin origin = ArtifactOrigin.tool,
  }) async {
    if ((source == null) == (content == null)) {
      throw ArgumentError('Pass either a path or content, not both or neither.');
    }
    final named = title?.trim();
    if (source != null) {
      if (!isAbsoluteHostPath(source.path)) {
        throw ArgumentError(
          'path must be absolute on the session\'s host, not "${source.path}".',
        );
      }
      final existing = _dao.bySource(sessionId, source);
      if (existing != null) {
        return _serially(existing.id, () async {
          var current = await _refreshNow(existing) ?? existing;
          if ((named != null && named.isNotEmpty && named != current.title) ||
              (mode != null && mode != current.mode)) {
            current = current.copyWith(
              title: named == null || named.isEmpty ? null : named,
              mode: mode,
              updatedAt: _now(),
            );
            _dao.update(current);
            onChanged?.call(current);
          }
          if (current.sourceState != ArtifactSourceState.present) {
            throw StateError(_unreadable(current));
          }
          return current;
        });
      }
      final fileName = hostBaseName(source.path);
      final resolvedKind = kind ?? artifactKindForName(fileName);
      if (resolvedKind == null) {
        throw ArgumentError(
          'Cannot tell what "$fileName" is from its name; pass kind '
          '(${ArtifactKind.values.map((k) => k.name).join(', ')}).',
        );
      }
      final bytes = await _readSource(source);
      return _create(
        sessionId: sessionId,
        source: source,
        fileName: fileName,
        title: named == null || named.isEmpty ? fileName : named,
        kind: resolvedKind,
        mode: mode,
        origin: origin,
        bytes: bytes,
      );
    }
    if (kind == null) {
      throw ArgumentError(
        'Content needs a kind: ${_textKinds.join(', ')}.',
      );
    }
    if (!kind.isText) {
      throw ArgumentError(
        'A ${kind.name} is a file: pass its path rather than content.',
      );
    }
    final bytes = Uint8List.fromList(utf8.encode(content!));
    _checkSize(bytes.length, 'content');
    final shownTitle = named == null || named.isEmpty ? 'Artifact' : named;
    return _create(
      sessionId: sessionId,
      fileName: '${_slug(shownTitle)}.${kind.extension}',
      title: shownTitle,
      kind: kind,
      mode: mode,
      origin: origin,
      bytes: bytes,
    );
  }

  /// Changes [id]'s title, mode, network permission or — for inline content —
  /// its text, which is a new revision.
  Future<Artifact> update(
    String id, {
    String? title,
    ArtifactMode? mode,
    String? content,
    bool? networkAllowed,
  }) {
    return _serially(id, () async {
      var current =
          _dao.byId(id) ?? (throw StateError('No artifact with id $id.'));
      if (content != null) {
        if (current.hasSource) {
          throw ArgumentError(
            '$id is read from a file: rewrite the file instead, and the new '
            'revision is picked up.',
          );
        }
        final bytes = Uint8List.fromList(utf8.encode(content));
        _checkSize(bytes.length, 'content');
        current = _snapshot(current, bytes) ?? current;
      }
      final named = title?.trim();
      final next = current.copyWith(
        title: named == null || named.isEmpty ? null : named,
        mode: mode,
        networkAllowed: networkAllowed,
        updatedAt: _now(),
      );
      _dao.update(next);
      onChanged?.call(next);
      return next;
    });
  }

  /// Looks at [id]'s source again: a changed file is a new revision, and one
  /// that is gone or out of reach is said to be. Null for an unknown id.
  Future<Artifact?> refresh(String id) async {
    final artifact = _dao.byId(id);
    if (artifact == null) return null;
    return _serially(id, () async {
      final current = _dao.byId(id);
      return current == null ? null : await _refreshNow(current);
    });
  }

  /// The bytes of [id] at [revision], the newest when null. Throws
  /// [StateError] when that revision is no longer kept.
  Future<Uint8List> content(String id, {int? revision}) async {
    final kept = _dao.revisions(id);
    final wanted = revision == null
        ? kept.lastOrNull
        : kept.where((r) => r.revision == revision).firstOrNull;
    if (wanted == null) {
      throw StateError(
        revision == null
            ? 'Artifact $id has no stored content.'
            : 'Revision $revision of artifact $id is no longer kept.',
      );
    }
    final path = p.normalize(p.absolute(wanted.path));
    if (!p.isWithin(_directory, path)) {
      throw StateError('Artifact $id\'s snapshot is outside the artifact store.');
    }
    return File(path).readAsBytes();
  }

  Future<T> _serially<T>(String id, Future<T> Function() body) async {
    final before = _busy[id];
    final done = Completer<void>();
    _busy[id] = done.future;
    try {
      if (before != null) await before;
      return await body();
    } finally {
      done.complete();
      if (identical(_busy[id], done.future)) _busy.remove(id)?.ignore();
    }
  }

  Future<Artifact?> _refreshNow(Artifact artifact) async {
    final source = artifact.source;
    if (source == null) return artifact;
    final ArtifactSourceStat stat;
    final Uint8List bytes;
    try {
      stat = await _sources.stat(source);
      if (!stat.exists) {
        return _mark(
          artifact,
          ArtifactSourceState.missing,
          'No file at ${source.path} any more.',
        );
      }
      if (stat.size > maxBytes) {
        return _mark(
          artifact,
          ArtifactSourceState.tooLarge,
          '${source.path} is ${stat.size} bytes, over the $maxBytes kept.',
        );
      }
      bytes = await _sources.read(source);
    } on Object catch (error) {
      return _mark(
        artifact,
        ArtifactSourceState.unreachable,
        'Could not read ${source.path}: $error',
      );
    }
    final snapped = _snapshot(artifact, bytes);
    if (snapped != null) {
      final next = snapped.copyWith(
        sourceState: ArtifactSourceState.present,
        sourceProblem: () => null,
      );
      _dao.update(next);
      onChanged?.call(next);
      return next;
    }
    return _mark(artifact, ArtifactSourceState.present, null);
  }

  Artifact _mark(Artifact artifact, ArtifactSourceState state, String? why) {
    if (artifact.sourceState == state && artifact.sourceProblem == why) {
      return artifact;
    }
    final next = artifact.copyWith(
      sourceState: state,
      sourceProblem: () => why,
      updatedAt: _now(),
    );
    _dao.update(next);
    onChanged?.call(next);
    return next;
  }

  Future<Uint8List> _readSource(EnvironmentPath source) async {
    final ArtifactSourceStat stat;
    try {
      stat = await _sources.stat(source);
    } on Object catch (error) {
      throw StateError('Could not reach ${source.path}: $error');
    }
    if (!stat.exists) {
      throw StateError(
        'No file at ${source.path} on the session\'s host. Write it first, '
        'then show it.',
      );
    }
    _checkSize(stat.size, source.path);
    try {
      return await _sources.read(source);
    } on Object catch (error) {
      throw StateError('Could not read ${source.path}: $error');
    }
  }

  Future<Artifact> _create({
    required String sessionId,
    required String fileName,
    required String title,
    required ArtifactKind kind,
    required ArtifactMode? mode,
    required ArtifactOrigin origin,
    required Uint8List bytes,
    EnvironmentPath? source,
  }) async {
    final at = _now();
    final blank = Artifact(
      id: _newId(),
      sessionId: sessionId,
      title: title,
      kind: kind,
      mode: mode ?? ArtifactMode.inline,
      origin: origin,
      source: source,
      fileName: fileName,
      revision: 0,
      size: 0,
      mimeType: artifactMimeType(kind, fileName),
      createdAt: at,
      updatedAt: at,
    );
    _dao.insert(blank);
    final made = _snapshot(blank, bytes)!;
    _dao.update(made);
    onChanged?.call(made);
    return made;
  }

  /// [artifact] at a new revision holding [bytes], with its snapshot written;
  /// null when [bytes] are what the newest revision already holds.
  Artifact? _snapshot(Artifact artifact, Uint8List bytes) {
    final digest = sha256.convert(bytes).toString();
    final kept = _dao.revisions(artifact.id);
    if (kept.isNotEmpty && kept.last.digest == digest) return null;
    final revision = artifact.revision + 1;
    final folder = Directory(p.join(_directory, artifact.id))
      ..createSync(recursive: true);
    final file = File(p.join(folder.path, '$revision.${_extensionOf(artifact)}'))
      ..writeAsBytesSync(bytes, flush: true);
    final at = _now();
    _dao.insertRevision(
      ArtifactRevision(
        artifactId: artifact.id,
        revision: revision,
        size: bytes.length,
        digest: digest,
        path: file.path,
        capturedAt: at,
      ),
    );
    final all = [...kept.map((r) => r.revision), revision];
    final drop = all.length - keepRevisions;
    for (final old in all.take(drop < 0 ? 0 : drop)) {
      final gone = kept.firstWhere((r) => r.revision == old);
      _dao.deleteRevision(artifact.id, old);
      try {
        File(gone.path).deleteSync();
      } on FileSystemException {
        // Already gone; the row was what made it reachable.
      }
    }
    return artifact.copyWith(
      revision: revision,
      size: bytes.length,
      updatedAt: at,
    );
  }

  void _checkSize(int size, String what) {
    if (size > maxBytes) {
      throw StateError(
        '$what is $size bytes; an artifact holds at most $maxBytes.',
      );
    }
  }

  String _unreadable(Artifact artifact) =>
      artifact.sourceProblem ?? 'Artifact ${artifact.id} could not be read.';

  static String _extensionOf(Artifact artifact) {
    final dot = artifact.fileName.lastIndexOf('.');
    final ext = dot < 0 ? '' : artifact.fileName.substring(dot + 1);
    return RegExp(r'^[A-Za-z0-9]{1,8}$').hasMatch(ext)
        ? ext.toLowerCase()
        : artifact.kind.extension;
  }

  static String _slug(String title) {
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) return 'artifact';
    return slug.length > 48 ? slug.substring(0, 48) : slug;
  }

  static final _textKinds = ArtifactKind.values
      .where((k) => k.isText)
      .map((k) => k.name);

  static DateTime _utcNow() => DateTime.now().toUtc();

  static String _randomId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

final _random = Random.secure();
