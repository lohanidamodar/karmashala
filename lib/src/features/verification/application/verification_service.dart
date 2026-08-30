import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../browser/data/browser_service.dart';
import '../../browser/domain/browser_failure.dart';
import '../../devices/data/adb_service.dart';
import '../../devices/domain/logcat_entry.dart';
import '../data/verification_artifact_store.dart';
import '../data/verification_dao.dart';
import '../domain/verification_artifact.dart';
import '../domain/verification_run.dart';
import '../domain/verification_step.dart';
import '../domain/verification_target.dart';
import 'verification_recorder.dart';
import 'verification_report.dart';

/// Raised when a run cannot be started, noted or finished. Its message is the
/// whole message — the MCP bridge renders a thrown error verbatim.
class VerificationException implements Exception {
  const VerificationException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Starts, records and finishes verification runs.
///
/// **One run at a time, deliberately.** The evidence is collected by installing
/// a sink on the app's single browser and adb services; two runs would fight
/// over the same seam, and a step landing in the wrong run is worse than being
/// told to finish the first one.
class VerificationService {
  VerificationService(
    this._dao,
    this._store, {
    required this.browserOf,
    required this.adbOf,
    String Function()? newId,
    DateTime Function()? now,
  }) : _newId = newId ?? _timestampId,
       _now = now ?? _utcNow;

  final VerificationDao _dao;
  final VerificationArtifactStore _store;

  /// The app's single browser driver, read lazily — a run installs its sink on
  /// this exact object, which is what makes the pane and the MCP tools record
  /// themselves.
  final BrowserService Function() browserOf;

  /// adb, or null when no Android SDK was found.
  final AdbService? Function() adbOf;

  final String Function() _newId;
  final DateTime Function() _now;

  static DateTime _utcNow() => DateTime.now().toUtc();

  VerificationRecorder? _recorder;

  /// The run being recorded, or null.
  VerificationRun? get activeRun => _recorder?.run;

  bool get isRecording => _recorder != null;

  /// Fires whenever a run starts, is stepped or finishes, so a pane can follow
  /// along without polling.
  Stream<void> get changes => _changes.stream;
  final _changes = StreamController<void>.broadcast();

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // --- Lifecycle -------------------------------------------------------------

  /// Begins recording against [target].
  ///
  /// A browser target attaches to the browser and goes to the URL; a device
  /// target with a package brings that app to the front, unless [launch] is
  /// false. Both are recorded as the run's first steps, because they are the
  /// first thing the run did.
  Future<VerificationRun> start({
    required VerificationTarget target,
    String? title,
    String? sessionId,
    bool launch = true,
  }) async {
    final open = _recorder;
    if (open != null) {
      throw VerificationException(
        'A verification run is already recording: "${open.run.title}" '
        '(${open.run.id}). Finish it before starting another.',
      );
    }

    final id = _newId();
    final directory = await _store.createDirectory(id);
    final run = VerificationRun(
      id: id,
      title: (title == null || title.trim().isEmpty)
          ? _defaultTitle(target)
          : title.trim(),
      target: target,
      sessionId: sessionId,
      startedAt: _now(),
      artifactDirectory: directory.path,
    );
    _dao.insertRun(run);

    final recorder = VerificationRecorder(_dao, _store, run: run, now: _now);
    _recorder = recorder;
    _changed();

    try {
      switch (target.kind) {
        case VerificationTargetKind.browser:
          await _openBrowser(recorder, target);
        case VerificationTargetKind.device:
          await _openDevice(recorder, target, launch: launch);
      }
    } on Object catch (error) {
      // The run itself survives a target that could not be reached: an agent
      // still wants to finish it as "inconclusive, the page never loaded"
      // rather than have the failure erase the record of trying.
      recorder.note('Could not reach the target', detail: '$error');
      rethrow;
    } finally {
      _changed();
    }
    return run;
  }

  Future<void> _openBrowser(
    VerificationRecorder recorder,
    VerificationTarget target,
  ) async {
    final browser = browserOf()..actionSink = recorder.recordBrowser;
    final url = target.url;
    if (!browser.isConnected) {
      try {
        await browser.connect();
      } on BrowserException {
        // Nothing drivable to attach to. Opening a tab at the target is the
        // only way to get a page at all, so the run starts there.
        if (url == null || url.isEmpty) rethrow;
        await browser.connect(url: url);
      }
    }
    // Watching starts **before** the navigation, not after it: the errors a
    // page throws while loading are exactly the ones worth catching, and
    // observing afterwards would miss every one of them.
    await browser.startObserving();
    if (url != null && url.isNotEmpty) await browser.navigate(url);
  }

  Future<void> _openDevice(
    VerificationRecorder recorder,
    VerificationTarget target, {
    required bool launch,
  }) async {
    final adb = adbOf();
    if (adb == null) {
      throw const VerificationException(
        'No Android SDK was found, so no device can be verified.',
      );
    }
    adb.actionSink = recorder.recordDevice;
    final serial = target.serial;
    if (serial == null || serial.isEmpty) {
      throw const VerificationException(
        'A device verification needs a serial. Use list_devices to find one.',
      );
    }
    final devices = await adb.listDevices();
    final device = devices.where((d) => d.serial == serial).firstOrNull;
    if (device == null) {
      throw VerificationException(
        'No device with serial $serial is connected.',
      );
    }
    if (!device.isReady) {
      throw VerificationException(
        'Device $serial is ${device.state.name}, not ready.',
      );
    }
    final package = target.packageName;
    if (launch && package != null && package.isNotEmpty) {
      await adb.launchPackage(serial, package);
    }
  }

  /// Waits for every queued artifact write to land.
  ///
  /// Steps are already durable when the call that produced them returns; this
  /// is about the files. A caller that is about to *read* a run — a tool result,
  /// the pane, the report — awaits this first.
  Future<void> flush() => _recorder?.drain() ?? Future<void>.value();

  /// Adds a step the agent wrote itself.
  void note(String text, {String? detail}) {
    final recorder = _require();
    if (text.trim().isEmpty) {
      throw const VerificationException('A note needs something to say.');
    }
    recorder.note(text.trim(), detail: detail);
    _changed();
  }

  /// Closes the run: collects the trailing evidence, records the verdict, and
  /// writes the report.
  Future<VerificationRun> finish({
    required VerificationVerdict verdict,
    String? reason,
  }) async {
    final recorder = _require();
    final run = recorder.run;
    try {
      await _collectClosingEvidence(recorder, run);
    } finally {
      await _detach(run);
    }
    await recorder.drain();

    if (recorder.problems.isNotEmpty) {
      recorder.note(
        'The recorder could not write '
        '${recorder.problems.length} item(s)',
        detail: recorder.problems.join('\n'),
      );
      await recorder.drain();
    }

    _dao.finishRun(
      run.id,
      finishedAt: _now(),
      verdict: verdict,
      reason: reason?.trim(),
    );
    _recorder = null;
    final finished = _dao.getRun(run.id)!;
    await _writeReport(finished);
    _changed();
    return _dao.getRun(run.id)!;
  }

  /// Everything collected without being asked, at the end of the run.
  ///
  /// Each piece is best effort and independently guarded: a device that
  /// unplugged must still produce a run with the steps that did happen.
  Future<void> _collectClosingEvidence(
    VerificationRecorder recorder,
    VerificationRun run,
  ) async {
    if (run.target.isBrowser) {
      final browser = browserOf();
      final observer = browser.observer;
      if (observer != null) {
        final errors = observer.consoleMessages
            .where((m) => m.isError)
            .toList();
        final warnings = observer.consoleMessages
            .where((m) => !m.isError)
            .toList();
        if (observer.consoleMessages.isNotEmpty) {
          recorder.attach(
            kind: VerificationArtifactKind.consoleErrors,
            label:
                '${errors.length} console error'
                '${errors.length == 1 ? '' : 's'}'
                '${warnings.isEmpty ? '' : ', ${warnings.length} warning'
                          '${warnings.length == 1 ? '' : 's'}'}',
            name: 'console',
            text: observer.consoleMessages.map((m) => m.toLine()).join('\n'),
          );
        }
        if (observer.networkFailures.isNotEmpty) {
          recorder.attach(
            kind: VerificationArtifactKind.networkFailures,
            label:
                '${observer.networkFailures.length} failed request'
                '${observer.networkFailures.length == 1 ? '' : 's'}',
            name: 'network',
            text: observer.networkFailures.map((f) => f.toLine()).join('\n'),
          );
        }
      }
      // The last thing the page looked like. Taken with the sink still
      // installed so it is a step as well as a picture.
      await _bestEffort(() => browser.screenshot());
      return;
    }

    final adb = adbOf();
    final serial = run.target.serial;
    if (adb == null || serial == null) return;
    await _bestEffort(() => adb.screenshot(serial));
    await _bestEffort(() => adb.dumpUiHierarchy(serial));
    final package = run.target.packageName;
    if (package != null && package.isNotEmpty) {
      final entries = await _bestEffort(
        () => adb.readLogcat(
          serial,
          packageName: package,
          minLevel: LogLevel.debug,
          maxLines: 400,
        ),
      );
      if (entries != null && entries.isEmpty) {
        recorder.note(
          'No logcat lines for $package — it was not running when the run '
          'finished.',
        );
      }
    }
  }

  /// Removes the sinks and stops watching. Always runs, even when the closing
  /// evidence threw: a run that leaves its sink installed would record the next
  /// person's clicks.
  Future<void> _detach(VerificationRun run) async {
    final adb = adbOf();
    if (adb != null) adb.actionSink = null;
    final browser = browserOf();
    if (run.target.isBrowser) {
      await _bestEffort(browser.stopObserving);
    }
    browser.actionSink = null;
  }

  /// Abandons the active run without a verdict, leaving it open in the record.
  ///
  /// Used when the app is shutting down. Deliberately not "delete": an
  /// abandoned run is a fact about what happened.
  Future<void> abandon() async {
    final recorder = _recorder;
    if (recorder == null) return;
    await _detach(recorder.run);
    await recorder.drain();
    _recorder = null;
    _changed();
  }

  // --- Reading ---------------------------------------------------------------

  /// Runs newest first, each with its steps and artifacts.
  ///
  /// The steps come along because every caller shows a count — the pane's row,
  /// the tool's listing — and a list that says "0 steps" for a run with twelve
  /// is worse than no count at all.
  List<VerificationRun> list({int limit = 50, String? sessionId}) => [
    for (final run in _dao.listRuns(limit: limit, sessionId: sessionId))
      run.copyWith(
        steps: _dao.stepsFor(run.id),
        artifacts: _dao.artifactsFor(run.id),
      ),
  ];

  VerificationRun? get(String id) => _dao.getRun(id);

  /// A run by id, or by an unambiguous prefix of one.
  ///
  /// Ids are long enough to be sortable in a folder listing, which makes them
  /// long enough to be tedious to retype; this accepts the leading characters
  /// the way git accepts a short hash, and refuses rather than guesses when
  /// several match.
  VerificationRun? find(String idOrPrefix) {
    final exact = _dao.getRun(idOrPrefix);
    if (exact != null) return exact;
    final matches = _dao.findByPrefix(idOrPrefix);
    return matches.length == 1 ? _dao.getRun(matches.single.id) : null;
  }

  /// Every run whose id starts with [prefix] — for explaining a failed [find].
  List<VerificationRun> matching(String prefix) => _dao.findByPrefix(prefix);

  /// The bytes of one artifact, or null when the file is gone.
  Future<List<int>?> readArtifact(VerificationArtifact artifact) =>
      _store.read(artifact);

  String pathOf(VerificationArtifact artifact) => _store.pathOf(artifact);

  /// Attaches a run to a session (or detaches it with null).
  void attachToSession(String runId, String? sessionId) {
    _dao.updateSessionId(runId, sessionId);
    _changed();
  }

  Future<void> delete(String id) async {
    if (_recorder?.run.id == id) await abandon();
    _dao.deleteRun(id);
    await _store.deleteRun(id);
    _changed();
  }

  /// Writes the run's markdown report and returns its path.
  Future<String> export(String id) async {
    final run = _dao.getRun(id);
    if (run == null) {
      throw VerificationException('No verification run with id $id.');
    }
    return _writeReport(run);
  }

  Future<String> _writeReport(VerificationRun run) async {
    final inlined = <String, String>{};
    for (final artifact in run.artifacts) {
      if (!shouldInline(artifact)) continue;
      final bytes = await _store.read(artifact);
      if (bytes == null) continue;
      // Decoded as UTF-8, not fromCharCodes: a logcat line or a page's own
      // error message is routinely not ASCII, and mangling it in the report is
      // exactly the kind of quiet corruption evidence must not have.
      inlined[artifact.relativePath] = utf8.decode(bytes, allowMalformed: true);
    }
    final markdown = renderVerificationReport(run, inlined: inlined);
    final file = File(p.join(run.artifactDirectory, 'report.md'));
    await file.parent.create(recursive: true);
    await file.writeAsString(markdown, flush: true);
    return file.path;
  }

  Future<void> dispose() async {
    await abandon();
    await _changes.close();
  }

  // --- Helpers ---------------------------------------------------------------

  VerificationRecorder _require() {
    final recorder = _recorder;
    if (recorder == null) {
      throw const VerificationException(
        'No verification run is recording. Call verification_start first.',
      );
    }
    return recorder;
  }

  /// Runs [action], returning null instead of throwing. Used for evidence:
  /// failing to collect a screenshot must not lose the run's verdict.
  Future<T?> _bestEffort<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on BrowserException {
      return null;
    } on Object {
      return null;
    }
  }

  static String _defaultTitle(VerificationTarget target) =>
      switch (target.kind) {
        VerificationTargetKind.browser => 'Verify ${target.url ?? 'the page'}',
        VerificationTargetKind.device =>
          'Verify ${target.packageName ?? target.serial ?? 'the device'}',
      };

  /// Sortable, unique, and legible in a folder listing.
  static String _timestampId() {
    final now = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'run-${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '-${now.millisecond.toString().padLeft(3, '0')}';
  }
}

/// The steps of a run, most recent first — what a pane's timeline shows.
extension VerificationRunSteps on VerificationRun {
  List<VerificationStep> get stepsNewestFirst => steps.reversed.toList();
}
