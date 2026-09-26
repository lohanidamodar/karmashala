import 'dart:async';

import 'package:karmashala_browser/browser.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_verification/artifacts.dart';
import 'package:karmashala_verification/verification.dart';

import '../data/verification_data.dart';

/// Turns what the browser and device services report into a run's steps and
/// files. Both sinks are synchronous, so writes queue and [drain] is what a
/// caller awaits; nothing here throws at the service it is watching.
class VerificationRecorder {
  VerificationRecorder(
    this._data,
    this._store, {
    required this.run,
    DateTime Function()? now,
  }) : _now = now ?? _utcNow;

  static DateTime _utcNow() => DateTime.now().toUtc();

  final VerificationRun run;
  final VerificationData _data;
  final VerificationArtifactStore _store;
  final DateTime Function() _now;

  var _ordinal = 0;
  Future<void> _queue = Future<void>.value();

  /// Failures the recorder hit, surfaced at finish rather than thrown.
  final List<String> problems = [];

  String get runId => run.id;

  /// Everything queued has been written.
  Future<void> drain() => _queue;

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

  /// A file collected outside any action, so attached to no step.
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
      await _data.addArtifact(artifact);
    });
  }

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
    // Sent now, in order, ahead of its files; [drain] waits for both.
    _enqueue(
      () => _data.addStep(
        run.id,
        VerificationStep(
          ordinal: ordinal,
          kind: kind,
          summary: summary,
          detail: detail,
          ok: ok,
          at: at,
        ),
      ),
    );
    if ((png == null || png.isEmpty) && (text == null || text.isEmpty)) return;
    _enqueue(() async {
      final prefix = ordinal.toString().padLeft(3, '0');
      if (png != null && png.isNotEmpty) {
        await _data.addArtifact(
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
        await _data.addArtifact(
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

  /// Chains [work] onto the queue, swallowing its failure into [problems].
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
