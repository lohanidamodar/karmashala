import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:karmashala_verification/artifacts.dart';
import 'package:karmashala_verification/report.dart';
import 'package:karmashala_verification/tools.dart' show VerificationException;
import 'package:karmashala_verification/verification.dart';

import '../data/verification_data.dart';

export 'package:karmashala_verification/tools.dart' show VerificationException;

/// "A run started, stepped or finished" — owned apart from
/// [VerificationService] so a listener never reaches the artifact root for it.
class VerificationChangeSignal {
  final _controller = StreamController<void>.broadcast();

  /// Fires on every start, step and finish, so a pane need not poll.
  Stream<void> get stream => _controller.stream;

  void bump() {
    if (!_controller.isClosed) _controller.add(null);
  }

  Future<void> dispose() => _controller.close();
}

/// The runs as this app reads, exports, attaches and deletes them. Every run
/// is recorded by the server — a review of a change, a page on its browser, a
/// device on its machine (slice 4a) — so nothing here starts or finishes one.
class VerificationService {
  VerificationService(
    this._data,
    this._store, {
    VerificationChangeSignal? changes,
  }) : _changes = changes ?? VerificationChangeSignal(),
       _ownsChanges = changes == null;

  final VerificationData _data;
  final VerificationArtifactStore _store;

  Stream<void> get changes => _changes.stream;
  final VerificationChangeSignal _changes;

  /// Whether [dispose] closes the signal — false when one was handed in, since
  /// it outlives any single service.
  final bool _ownsChanges;

  void _changed() => _changes.bump();

  /// Runs newest first, with steps and artifacts — every caller shows a count.
  Future<List<VerificationRun>> list({int limit = 50, String? sessionId}) =>
      _data.recent(limit: limit, sessionId: sessionId);

  Future<VerificationRun?> get(String id) => _data.get(id);

  /// A run by id or unambiguous prefix; it refuses when several match.
  Future<VerificationRun?> find(String idOrPrefix) async {
    final exact = await get(idOrPrefix);
    if (exact != null) return exact;
    final matches = await _data.matching(idOrPrefix);
    return matches.length == 1 ? _data.get(matches.single.id) : null;
  }

  /// The bytes of one artifact, or null when the file is gone.
  Future<List<int>?> readArtifact(VerificationArtifact artifact) =>
      _store.read(artifact);

  String pathOf(VerificationArtifact artifact) => _store.pathOf(artifact);

  Future<void> attachToSession(String runId, String? sessionId) async {
    await _data.attach(runId, sessionId);
    _changed();
  }

  Future<void> delete(String id) async {
    await _data.delete(id);
    await _store.deleteRun(id);
    _changed();
  }

  /// Writes the run's markdown report and returns its path.
  Future<String> export(String id) async {
    final run = await _data.get(id);
    if (run == null) {
      throw VerificationException('No verification run with id $id.');
    }
    final inlined = <String, String>{};
    for (final artifact in run.artifacts) {
      if (!shouldInline(artifact)) continue;
      final bytes = await _store.read(artifact);
      if (bytes == null) continue;
      // UTF-8, not fromCharCodes: a logcat line is routinely not ASCII.
      inlined[artifact.relativePath] = utf8.decode(bytes, allowMalformed: true);
    }
    final markdown = renderVerificationReport(run, inlined: inlined);
    final file = File(p.join(run.artifactDirectory, 'report.md'));
    await file.parent.create(recursive: true);
    await file.writeAsString(markdown, flush: true);
    return file.path;
  }

  Future<void> dispose() async {
    if (_ownsChanges) await _changes.dispose();
  }
}

/// The steps of a run, most recent first — what a pane's timeline shows.
extension VerificationRunSteps on VerificationRun {
  List<VerificationStep> get stepsNewestFirst => steps.reversed.toList();
}
