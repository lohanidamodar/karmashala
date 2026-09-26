import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:karmashala_browser/browser.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/artifacts.dart';
import 'package:karmashala_verification/report.dart';
import 'package:karmashala_verification/tools.dart';
import 'package:karmashala_verification/verification.dart';

import '../data/verification_data.dart';
import 'verification_recorder.dart';

export 'package:karmashala_verification/command_checks.dart' show CommandCheck;
export 'package:karmashala_verification/tools.dart'
    show VerificationException, VerificationTools;

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

/// Starts, records and finishes verification runs. One at a time: the evidence
/// sink goes on the app's single browser and adb services. The server records
/// a review of a change itself; the runs here are the ones that drive this
/// app's browser or a device attached to its machine.
class VerificationService implements VerificationToolBackend {
  VerificationService(
    this._data,
    this._store, {
    required this.browserOf,
    required this.adbOf,
    VerificationChangeSignal? changes,
    String Function()? newId,
    DateTime Function()? now,
  }) : _changes = changes ?? VerificationChangeSignal(),
       _ownsChanges = changes == null,
       _newId = newId ?? _timestampId,
       _now = now ?? _utcNow;

  final VerificationData _data;
  final VerificationArtifactStore _store;

  /// The app's single browser driver — a run installs its sink on this exact
  /// object, which is what makes the pane and the MCP tools self-record.
  final BrowserService Function() browserOf;

  /// adb, or null when no Android SDK was found.
  final AdbService? Function() adbOf;

  final String Function() _newId;
  final DateTime Function() _now;

  static DateTime _utcNow() => DateTime.now().toUtc();

  VerificationRecorder? _recorder;

  @override
  VerificationRun? get activeRun => _recorder?.run;

  bool get isRecording => _recorder != null;

  Stream<void> get changes => _changes.stream;
  final VerificationChangeSignal _changes;

  /// Whether [dispose] closes the signal — false when one was handed in, since
  /// it outlives any single service.
  final bool _ownsChanges;

  void _changed() => _changes.bump();

  /// Begins recording against [target]. A browser target attaches and
  /// navigates; a device target fronts its package unless [launch] is false.
  @override
  Future<VerificationRun> start({
    required VerificationTarget target,
    String? title,
    String? sessionId,
    String? producedBySessionId,
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
      producedBySessionId: producedBySessionId,
      startedAt: _now(),
      artifactDirectory: directory.path,
    );
    await _data.start(run);

    final recorder = VerificationRecorder(_data, _store, run: run, now: _now);
    _recorder = recorder;
    _changed();

    try {
      switch (target.kind) {
        case VerificationTargetKind.browser:
          await _openBrowser(recorder, target);
        case VerificationTargetKind.device:
          await _openDevice(recorder, target, launch: launch);
        case VerificationTargetKind.change:
          // A change run must not touch the browser or adb even to ask.
          break;
      }
    } on Object catch (error) {
      // The run survives an unreachable target: still finishable as
      // inconclusive, rather than losing the record of having tried.
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
        // Nothing to attach to: opening a tab is the only way to a page.
        if (url == null || url.isEmpty) rethrow;
        await browser.connect(url: url);
      }
    }
    // Before the navigation: the errors a page throws while loading count.
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

  /// Waits for every queued step and artifact write to land.
  Future<void> flush() => _recorder?.drain() ?? Future<void>.value();

  /// Adds a step the agent wrote itself.
  @override
  void note(String text, {String? detail}) {
    final recorder = _require();
    if (text.trim().isEmpty) {
      throw const VerificationException('A note needs something to say.');
    }
    recorder.note(text.trim(), detail: detail);
    _changed();
  }

  /// Records several gates this app ran as **one** run, the worst verdict
  /// among them (see `CommandCheckRecorder.recordBatch`).
  Future<VerificationRun> recordCommandChecks({
    required String title,
    required String workingDirectory,
    required String environmentId,
    required DateTime startedAt,
    required List<CommandCheck> checks,
    String? sessionId,
    String? producedBySessionId,
  }) => _commandChecks.recordBatch(
    title: title,
    startedAt: startedAt,
    checks: checks,
    sessionId: sessionId,
    producedBySessionId: producedBySessionId,
  );

  /// Records a gate this app ran itself in one call. It takes no recording
  /// slot, so it cannot clobber an open run.
  Future<VerificationRun> recordCommandCheck({
    required String title,
    required List<String> command,
    required String workingDirectory,
    required String environmentId,
    required DateTime startedAt,
    required int? exitCode,
    String output = '',
    String? sessionId,
    String? producedBySessionId,
  }) => _commandChecks.recordOne(
    title: title,
    command: command,
    workingDirectory: workingDirectory,
    environmentId: environmentId,
    startedAt: startedAt,
    exitCode: exitCode,
    output: output,
    sessionId: sessionId,
    producedBySessionId: producedBySessionId,
  );

  late final CommandCheckRecorder _commandChecks = CommandCheckRecorder(
    _data,
    _store,
    newId: _newId,
    now: _now,
    onChanged: _changed,
  );

  /// Closes the run: trailing evidence, the verdict, and the report.
  @override
  Future<VerificationRun> finish({
    required VerificationVerdict verdict,
    String? reason,
    String? producedBySessionId,
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

    final finished = await _data.finish(
      run.id,
      verdict: verdict,
      reason: reason?.trim(),
      producedBySessionId: producedBySessionId,
    );
    _recorder = null;
    await _writeReport(finished);
    _changed();
    return finished;
  }

  /// Collected without being asked, at the end. Each piece is guarded alone.
  Future<void> _collectClosingEvidence(
    VerificationRecorder recorder,
    VerificationRun run,
  ) async {
    // A change run's evidence is the reviewer's notes and the verdict's reason.
    if (run.target.isChange) return;
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
      // Taken with the sink still installed, so it is a step as well.
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

  /// Removes the sinks. Always runs: a leftover one records the next person.
  Future<void> _detach(VerificationRun run) async {
    // No sink was installed; building a browser to remove one is an excuse.
    if (run.target.isChange) return;
    final adb = adbOf();
    if (adb != null) adb.actionSink = null;
    final browser = browserOf();
    if (run.target.isBrowser) {
      await _bestEffort(browser.stopObserving);
    }
    browser.actionSink = null;
  }

  /// Abandons the active run without a verdict, leaving it open in the record.
  /// Not "delete": an abandoned run is a fact about what happened.
  Future<void> abandon() async {
    final recorder = _recorder;
    if (recorder == null) return;
    await _detach(recorder.run);
    await recorder.drain();
    _recorder = null;
    _changed();
  }

  /// Runs newest first, with steps and artifacts — every caller shows a count.
  /// Every read waits for this service's own queued writes first.
  @override
  Future<List<VerificationRun>> list({
    int limit = 50,
    String? sessionId,
  }) async {
    await flush();
    return _data.recent(limit: limit, sessionId: sessionId);
  }

  @override
  Future<VerificationRun?> get(String id) async {
    await flush();
    return _data.get(id);
  }

  /// A run by id or unambiguous prefix; it refuses when several match.
  @override
  Future<VerificationRun?> find(String idOrPrefix) async {
    final exact = await get(idOrPrefix);
    if (exact != null) return exact;
    final matches = await _data.matching(idOrPrefix);
    return matches.length == 1 ? _data.get(matches.single.id) : null;
  }

  /// Every run whose id starts with [prefix] — for explaining a failed [find].
  @override
  Future<List<VerificationRun>> matching(String prefix) =>
      _data.matching(prefix);

  /// The bytes of one artifact, or null when the file is gone.
  @override
  Future<List<int>?> readArtifact(VerificationArtifact artifact) =>
      _store.read(artifact);

  String pathOf(VerificationArtifact artifact) => _store.pathOf(artifact);

  Future<void> attachToSession(String runId, String? sessionId) async {
    await _data.attach(runId, sessionId);
    _changed();
  }

  Future<void> delete(String id) async {
    if (_recorder?.run.id == id) await abandon();
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
    return _writeReport(run);
  }

  Future<String> _writeReport(VerificationRun run) async {
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
    await abandon();
    if (_ownsChanges) await _changes.dispose();
  }

  VerificationRecorder _require() {
    final recorder = _recorder;
    if (recorder == null) {
      throw const VerificationException(
        'No verification run is recording. Call verification_start first.',
      );
    }
    return recorder;
  }

  /// Runs [action], returning null instead of throwing: a screenshot that
  /// cannot be collected must not lose the run's verdict.
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
        VerificationTargetKind.change => 'Review of the change',
      };

  static String _timestampId() => verificationRunId(DateTime.now());
}

/// The steps of a run, most recent first — what a pane's timeline shows.
extension VerificationRunSteps on VerificationRun {
  List<VerificationStep> get stepsNewestFirst => steps.reversed.toList();
}
