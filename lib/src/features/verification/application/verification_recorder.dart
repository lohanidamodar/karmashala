import 'dart:async';

import 'package:karmashala_browser/browser.dart';
import 'package:karmashala_devices/devices.dart';
import '../data/verification_artifact_store.dart';
import '../data/verification_dao.dart';
import '../domain/verification_artifact.dart';
import '../domain/verification_run.dart';
import '../domain/verification_step.dart';

/// Turns what the browser and device services report into a run's steps and
/// files.
///
/// Both sinks are synchronous — a browser verb must not wait on a disk write to
/// return — so every recorded action is appended to one serialized queue.
/// [drain] is what a caller awaits before reading the run back, and it is the
/// only thing standing between "the tool returned" and "the evidence is on
/// disk". Nothing here throws at the service it is watching: a recorder that
/// cannot write a file must not turn a successful click into a failed one.
class VerificationRecorder {
  VerificationRecorder(
    this._dao,
    this._store, {
    required this.run,
    DateTime Function()? now,
  }) : _now = now ?? _utcNow;

  static DateTime _utcNow() => DateTime.now().toUtc();

  final VerificationRun run;
  final VerificationDao _dao;
  final VerificationArtifactStore _store;
  final DateTime Function() _now;

  var _ordinal = 0;
  Future<void> _queue = Future<void>.value();

  /// Failures the recorder itself hit, surfaced when the run is finished rather
  /// than thrown at whatever was being recorded.
  final List<String> problems = [];

  String get runId => run.id;

  /// Everything queued has been written.
  Future<void> drain() => _queue;

  // --- Sinks -----------------------------------------------------------------

  /// Installed on `BrowserService.actionSink` for the duration of a run.
  void recordBrowser(BrowserAction action) => _append(
    kind: _browserKind(action.verb),
    summary: action.summary,
    detail: action.detail,
    ok: action.ok,
    png: action.png,
    text: action.text,
    textKind: action.verb == 'capture'
        ? VerificationArtifactKind.elementCapture
        : VerificationArtifactKind.other,
    slug: action.verb,
  );

  /// Installed on `AdbService.actionSink` for the duration of a run.
  void recordDevice(DeviceAction action) => _append(
    kind: _deviceKind(action.verb),
    summary: action.summary,
    detail: action.verb == 'uiDump' || action.verb == 'logcat'
        ? null
        : action.detail,
    ok: action.ok,
    png: action.png,
    text: action.text,
    textKind: switch (action.verb) {
      'uiDump' => VerificationArtifactKind.uiTree,
      'logcat' => VerificationArtifactKind.logcat,
      _ => VerificationArtifactKind.other,
    },
    slug: action.verb,
  );

  /// A step the agent wrote by hand — what it is checking, or what it saw.
  void note(String text, {String? detail}) => _append(
    kind: VerificationStepKind.note,
    summary: text,
    detail: detail,
    slug: 'note',
  );

  /// A file collected outside any action — the console log, the closing
  /// screenshot. Attached to no step, because nothing the agent did produced it.
  void attach({
    required VerificationArtifactKind kind,
    required String label,
    required String name,
    List<int>? bytes,
    String? text,
  }) {
    _enqueue(() async {
      final artifact = bytes != null
          ? await _store.write(
              runId: run.id,
              kind: kind,
              label: label,
              name: name,
              bytes: bytes,
              at: _now(),
            )
          : await _store.writeText(
              runId: run.id,
              kind: kind,
              label: label,
              name: name,
              text: text ?? '',
              at: _now(),
            );
      _dao.insertArtifact(artifact);
    });
  }

  // --- Writing ---------------------------------------------------------------

  void _append({
    required VerificationStepKind kind,
    required String summary,
    required String slug,
    String? detail,
    bool ok = true,
    List<int>? png,
    String? text,
    VerificationArtifactKind textKind = VerificationArtifactKind.other,
  }) {
    final ordinal = ++_ordinal;
    final at = _now();
    // The step lands now, not on the queue. `sqlite3` writes on this isolate,
    // so by the time a browser or device verb returns, what it did is already
    // durable — a run that dies mid-way still has everything up to that point,
    // and a caller reading the run back immediately sees the step it just took.
    // Only the *files* are queued, because bytes on disk are genuinely async.
    _dao.insertStep(
      run.id,
      VerificationStep(
        ordinal: ordinal,
        kind: kind,
        summary: summary,
        detail: detail,
        ok: ok,
        at: at,
      ),
    );
    if ((png == null || png.isEmpty) && (text == null || text.isEmpty)) return;
    _enqueue(() async {
      final prefix = ordinal.toString().padLeft(3, '0');
      if (png != null && png.isNotEmpty) {
        _dao.insertArtifact(
          await _store.write(
            runId: run.id,
            kind: VerificationArtifactKind.screenshot,
            label: summary,
            name: '$prefix-$slug',
            bytes: png,
            stepOrdinal: ordinal,
            at: at,
          ),
        );
      }
      if (text != null && text.isNotEmpty) {
        _dao.insertArtifact(
          await _store.writeText(
            runId: run.id,
            kind: textKind,
            label: summary,
            name: '$prefix-$slug',
            text: text,
            stepOrdinal: ordinal,
            at: at,
          ),
        );
      }
    });
  }

  /// Chains [work] onto the queue, keeping order and swallowing its failure
  /// into [problems].
  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      try {
        await work();
      } on Object catch (error) {
        problems.add('$error');
      }
    });
  }

  static VerificationStepKind _browserKind(String verb) => switch (verb) {
    'navigate' => VerificationStepKind.navigate,
    'click' => VerificationStepKind.click,
    'type' => VerificationStepKind.type,
    'key' => VerificationStepKind.key,
    'evaluate' => VerificationStepKind.evaluate,
    'find' => VerificationStepKind.find,
    'screenshot' => VerificationStepKind.screenshot,
    'capture' => VerificationStepKind.capture,
    _ => VerificationStepKind.other,
  };

  static VerificationStepKind _deviceKind(String verb) => switch (verb) {
    'launch' => VerificationStepKind.launch,
    'tap' => VerificationStepKind.tap,
    'swipe' => VerificationStepKind.swipe,
    'type' => VerificationStepKind.type,
    'key' => VerificationStepKind.key,
    'screenshot' => VerificationStepKind.screenshot,
    'uiDump' => VerificationStepKind.uiDump,
    'logcat' => VerificationStepKind.logcat,
    _ => VerificationStepKind.other,
  };
}
