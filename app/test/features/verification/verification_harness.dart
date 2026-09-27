import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/features/verification/application/verification_service.dart';
import 'package:karmashala/src/features/verification/data/verification_data.dart';
import 'package:karmashala_verification/artifacts.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';

/// A 1×1 PNG, so an artifact written by a test is a real image.
final Uint8List tinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
]);

/// Everything a verification test needs, wired to fakes: the runs are kept by
/// a [FakeDataServer], the evidence files in a temp folder. Every run is the
/// server's to record (slice 4a); [record] stands in for one it recorded.
class VerificationHarness {
  VerificationHarness._(this.server, this.client)
    : root = Directory.systemTemp.createTempSync('verify-run') {
    data = VerificationData(client);
    store = VerificationArtifactStore(root);
    service = VerificationService(data, store, changes: changes);
  }

  /// A harness over a fresh fake server, its client primed.
  static Future<VerificationHarness> start() async {
    final server = FakeDataServer();
    return VerificationHarness._(server, await server.connect());
  }

  final Directory root;
  final FakeDataServer server;
  final DataClient client;
  late final VerificationData data;
  late final VerificationArtifactStore store;
  late final VerificationService service;

  /// The signal the service publishes into, held here so a widget test can
  /// override `verificationChangesProvider` with the same one.
  final changes = VerificationChangeSignal();

  /// The run as the server holds it, whole.
  VerificationRun? stored(String id) => server.verificationRows.getRun(id);

  var _ids = 0;

  /// A run as the server would have recorded it — [steps] and [texts] (an
  /// artifact per entry, written to disk) included — and its whole record.
  Future<VerificationRun> record({
    String? id,
    String title = 'the save button saves',
    VerificationTarget target = const VerificationTarget.device(
      serial: 'FAKE123',
      packageName: 'com.example.app',
    ),
    VerificationVerdict? verdict = VerificationVerdict.pass,
    String? reason,
    String? sessionId,
    String? producedBySessionId,
    List<String> steps = const [],
    Map<VerificationArtifactKind, String> texts = const {},
    DateTime? startedAt,
  }) async {
    final runId = id ?? 'run-${(++_ids).toString().padLeft(3, '0')}';
    final directory = await store.createDirectory(runId);
    final at = startedAt ?? DateTime.utc(2026, 9, 27, 12, _ids);
    final artifacts = <VerificationArtifact>[];
    for (final MapEntry(key: kind, value: text) in texts.entries) {
      artifacts.add(
        await store.writeText(
          runId: runId,
          kind: kind,
          label: kind.name,
          name: kind.name,
          text: text,
          at: at,
        ),
      );
    }
    final run = VerificationRun(
      id: runId,
      title: title,
      target: target,
      sessionId: sessionId,
      producedBySessionId: producedBySessionId,
      startedAt: at,
      finishedAt: verdict == null ? null : at.add(const Duration(seconds: 5)),
      artifactDirectory: directory.path,
      verdict: verdict,
      reason: reason,
      steps: [
        for (final (index, summary) in steps.indexed)
          VerificationStep(
            ordinal: index + 1,
            kind: VerificationStepKind.note,
            summary: summary,
            at: at,
          ),
      ],
      artifacts: artifacts,
    );
    await data.record(run);
    changes.bump();
    return (await data.get(runId))!;
  }

  String pathIn(VerificationRun run, VerificationArtifact artifact) =>
      p.join(run.artifactDirectory, artifact.relativePath);

  Future<void> dispose() async {
    await service.dispose();
    await changes.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}
