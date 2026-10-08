import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/visuals.dart';
import 'package:path/path.dart' as p;

import '../domain/session_visual.dart';
import '../store/visual_dao.dart';
import 'artifact_sources.dart';

/// What [VisualBoard.draw] did, and anything the agent should know about it.
class VisualDrawn {
  const VisualDrawn(this.visual, {required this.created, this.note});

  final SessionVisual visual;
  final bool created;
  final String? note;
}

final _idPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$');

/// The visuals agents draw in their threads, kept on the server: the newest
/// spec of each in the database, an image's bytes in [directory].
class VisualBoard {
  VisualBoard({
    required this._dao,
    required String directory,
    required this._sources,
    DateTime Function()? now,
    String Function()? newId,
  }) : _directory = p.normalize(p.absolute(directory)),
       _now = now ?? (() => DateTime.now().toUtc()),
       _newId = newId ?? _randomId;

  final VisualDao _dao;
  final String _directory;
  final ArtifactSources _sources;
  final DateTime Function() _now;
  final String Function() _newId;

  /// Told each visual as it is drawn or changed.
  void Function(SessionVisual visual)? onChanged;

  List<SessionVisual> forSession(String sessionId) =>
      _dao.forSession(sessionId);

  SessionVisual? byId(String sessionId, String id) => _dao.byId(sessionId, id);

  /// Draws [data] as a [kind] visual in [sessionId]'s thread, or — with an
  /// [id] it already has — updates that one in place; [append] adds to a
  /// chart's points or a table's rows. An image path is read on
  /// [environmentId]'s host. Throws [FormatException] for a spec to fix and
  /// [ArgumentError] for a request that names nothing usable.
  Future<VisualDrawn> draw({
    required String sessionId,
    required String environmentId,
    String? id,
    VisualKind? kind,
    String? title,
    Object? data,
    bool append = false,
  }) async {
    final handle = id?.trim();
    if (handle != null && handle.isNotEmpty && !_idPattern.hasMatch(handle)) {
      throw ArgumentError(
        'id is letters, digits, ".", "_" and "-", at most 64 — not "$handle".',
      );
    }
    final existing = handle == null || handle.isEmpty
        ? null
        : _dao.byId(sessionId, handle);
    final named = title?.trim();
    if (existing == null) {
      if (kind == null) {
        throw ArgumentError(
          'kind is required for a new visual: '
          '${VisualKind.values.map((k) => k.name).join(', ')}.',
        );
      }
      if (append) {
        throw ArgumentError(
          'append adds to a visual you already drew; there is no '
          '"${handle ?? ''}" in this thread yet. Drop append to draw it.',
        );
      }
      if (data == null) throw ArgumentError('data is required.');
      if (_dao.count(sessionId) >= VisualCaps.perSession) {
        throw StateError(
          'This thread already holds ${VisualCaps.perSession} visuals; update '
          'one by its id instead of drawing another.',
        );
      }
    } else if (kind != null && kind.name != existing.kind) {
      throw ArgumentError(
        'Visual "${existing.id}" is a ${existing.kind}, not a ${kind.name}: '
        'pass kind ${existing.kind}, or a new id for a new visual.',
      );
    }
    final visualKind = kind ?? existing!.visualKind;
    if (visualKind == null) {
      throw ArgumentError(
        'Visual "${existing!.id}" has a kind this server does '
        'not know; draw a new one.',
      );
    }
    final visualId = handle == null || handle.isEmpty ? _newId() : handle;
    String? note;
    var stored = existing?.data;
    if (data != null) {
      var spec = append
          ? appendVisualSpec(existing!.spec, data)
          : parseVisualSpec(visualKind, data);
      if (append) note = _trimmed(spec);
      if (spec is ImageVisual && spec.path != null) {
        spec = await _keepImage(sessionId, visualId, environmentId, spec);
      }
      stored = spec.toJson();
    }
    return _save(
      sessionId: sessionId,
      id: visualId,
      kind: visualKind,
      title: named,
      data: stored,
      existing: existing,
      note: note,
    );
  }

  VisualDrawn _save({
    required String sessionId,
    required String id,
    required VisualKind kind,
    required String? title,
    required Object? data,
    required SessionVisual? existing,
    String? note,
  }) {
    final now = _now();
    final keptTitle = title == null || title.isEmpty ? existing?.title : title;
    if (existing != null &&
        keptTitle == existing.title &&
        jsonEncode(data) == jsonEncode(existing.data)) {
      return VisualDrawn(existing, created: false, note: note);
    }
    final visual = existing == null
        ? SessionVisual(
            sessionId: sessionId,
            id: id,
            kind: kind.name,
            title: keptTitle,
            data: data,
            revision: 1,
            createdAt: now,
            updatedAt: now,
          )
        : existing.copyWith(
            title: keptTitle,
            data: data,
            revision: existing.revision + 1,
            updatedAt: now,
          );
    _dao.save(visual);
    onChanged?.call(visual);
    return VisualDrawn(visual, created: existing == null, note: note);
  }

  /// Copies an image file's bytes beside the database; the visual keeps
  /// its name, type and size, never the path.
  Future<VisualSpec> _keepImage(
    String sessionId,
    String id,
    String environmentId,
    ImageVisual image,
  ) async {
    final path = image.path!;
    if (!isAbsoluteHostPath(path)) {
      throw ArgumentError(
        'path must be absolute on the session\'s host, not "$path".',
      );
    }
    final source = EnvironmentPath(environmentId: environmentId, path: path);
    final stat = await _sources.stat(source);
    if (!stat.exists) throw ArgumentError('There is no file at "$path".');
    if (stat.size > VisualCaps.imageBytes) {
      throw FormatException(
        'the image is ${stat.size ~/ 1024} KiB; at most '
        '${VisualCaps.imageBytes ~/ (1024 * 1024)} MiB is drawn — shrink it, '
        'or show it with artifact_show',
      );
    }
    final bytes = await _sources.read(source);
    if (bytes.length > VisualCaps.imageBytes) {
      throw const FormatException('the image grew past the cap while read');
    }
    final file = File(_imagePath(sessionId, id));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    final name = hostBaseName(path);
    return ImageVisual(
      alt: image.alt,
      fileName: name,
      mimeType: visualImageMimeType(name),
      size: bytes.length,
    );
  }

  /// The bytes of image visual [id]. Throws [StateError] when there are none.
  Future<Uint8List> image(String sessionId, String id) async {
    final visual = _dao.byId(sessionId, id);
    if (visual == null || visual.kind != VisualKind.image.name) {
      throw StateError('no image visual "$id" in this session');
    }
    final file = File(_imagePath(sessionId, id));
    if (!file.existsSync()) {
      throw StateError('image visual "$id" keeps no file: it is a web address');
    }
    return file.readAsBytes();
  }

  String _imagePath(String sessionId, String id) => p.join(
    _directory,
    sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_'),
    '$id.img',
  );

  static String? _trimmed(VisualSpec spec) => switch (spec) {
    final ChartVisual c when c.pointCount >= VisualCaps.points =>
      'The chart is at its cap of ${VisualCaps.points} points: the oldest '
          'are dropped as new ones come.',
    final TableVisual t when t.rows.length >= VisualCaps.rows =>
      'The table is at its cap of ${VisualCaps.rows} rows: the oldest are '
          'dropped as new ones come.',
    _ => null,
  };

  static String _randomId() {
    final random = Random.secure();
    return 'v-${List.generate(4, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }
}
