import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:karmashala_browser/browser.dart';
import 'package:karmashala_devices/devices.dart';
import '../data/verification_artifact_store.dart';
import '../data/verification_dao.dart';
import '../domain/verification_artifact.dart';
import '../domain/verification_run.dart';
import '../domain/verification_step.dart';
import '../domain/verification_target.dart';
import 'verification_recorder.dart';
import 'verification_report.dart';

/// Raised when a run cannot be started, noted or finished; its message is the
/// whole message, since the bridge renders a thrown error verbatim.
class VerificationException implements Exception {
  const VerificationException(this.message);
  final String message;

  @override
  String toString() => message;
}

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
/// sink goes on the app's single browser and adb services.
class VerificationService {
  VerificationService(
    this._dao,
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

  final VerificationDao _dao;
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

  /// Waits for every queued artifact write to land; steps are already durable.
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

  /// Records several gates this app ran as **one** run: a step and an output
  /// per check, and the worst verdict among them — fail, then inconclusive,
  /// then pass. One run, so "the newest verdict" cannot be the last check's
  /// pass sitting on top of an earlier failure.
  ///
  /// A check that never ran carries its [CommandCheck.refusal] and counts as
  /// inconclusive.
  Future<VerificationRun> recordCommandChecks({
    required String title,
    required String workingDirectory,
    required String environmentId,
    required DateTime startedAt,
    required List<CommandCheck> checks,
    String? sessionId,
    String? producedBySessionId,
  }) async {
    final id = _newId();
    final directory = await _store.createDirectory(id);
    final finishedAt = _now();
    VerificationVerdict verdictOf(CommandCheck check) =>
        check.refusal != null || check.exitCode == null
        ? VerificationVerdict.inconclusive
        : check.exitCode == 0
        ? VerificationVerdict.pass
        : VerificationVerdict.fail;
    final verdicts = [for (final check in checks) verdictOf(check)];
    final verdict = verdicts.contains(VerificationVerdict.fail)
        ? VerificationVerdict.fail
        : verdicts.contains(VerificationVerdict.inconclusive) || checks.isEmpty
        ? VerificationVerdict.inconclusive
        : VerificationVerdict.pass;

    final steps = <VerificationStep>[
      for (final (i, check) in checks.indexed)
        VerificationStep(
          ordinal: i + 1,
          kind: VerificationStepKind.other,
          summary: '${check.name}: ${check.command.join(' ')}',
          detail:
              check.refusal ??
              switch (check.exitCode) {
                0 => 'passed',
                null => 'stopped without an exit code Karmashala observed',
                final code => 'exited $code',
              },
          at: finishedAt,
          ok: verdicts[i] == VerificationVerdict.pass,
        ),
    ];
    final failed = [
      for (final (i, check) in checks.indexed)
        if (verdicts[i] != VerificationVerdict.pass) check.name,
    ];
    final passed = checks.length - failed.length;
    final run = VerificationRun(
      id: id,
      title: title,
      target: const VerificationTarget.change(),
      sessionId: sessionId,
      producedBySessionId: producedBySessionId,
      startedAt: startedAt,
      finishedAt: finishedAt,
      verdict: verdict,
      reason: failed.isEmpty
          ? '${checks.length == 1 ? 'The check' : 'All ${checks.length} checks'} passed.'
          : '$passed of ${checks.length} passed; not passed: '
                '${failed.join(', ')}.',
      artifactDirectory: directory.path,
      steps: steps,
    );
    _dao.insertRun(run);
    for (final step in steps) {
      _dao.insertStep(id, step);
    }
    for (final (i, check) in checks.indexed) {
      if (check.output.trim().isEmpty) continue;
      final artifact = await _store.writeText(
        runId: id,
        name: 'output-${i + 1}',
        kind: VerificationArtifactKind.other,
        label: check.name,
        text: check.output,
        stepOrdinal: i + 1,
        at: finishedAt,
      );
      _dao.insertArtifact(artifact);
    }
    _changed();
    return _dao.getRun(id) ?? run;
  }

  /// Records a gate this app ran itself in one call. It takes no recording
  /// slot, so it cannot clobber an open run, and an exit code we never saw is
  /// `inconclusive`, never a pass (§19).
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
  }) async {
    final id = _newId();
    final directory = await _store.createDirectory(id);
    final finishedAt = _now();
    final verdict = switch (exitCode) {
      0 => VerificationVerdict.pass,
      null => VerificationVerdict.inconclusive,
      _ => VerificationVerdict.fail,
    };
    final line = command.join(' ');
    final step = VerificationStep(
      ordinal: 1,
      kind: VerificationStepKind.other,
      summary: line,
      detail: 'in $workingDirectory ($environmentId)',
      at: finishedAt,
      ok: exitCode == 0,
    );
    final run = VerificationRun(
      id: id,
      title: title,
      target: const VerificationTarget.change(),
      sessionId: sessionId,
      producedBySessionId: producedBySessionId,
      startedAt: startedAt,
      finishedAt: finishedAt,
      verdict: verdict,
      reason: switch (exitCode) {
        0 => '$line passed.',
        null =>
          '$line stopped without an exit code Karmashala observed, so whether '
              'it passed is unknown.',
        final code => '$line exited $code.',
      },
      artifactDirectory: directory.path,
      steps: <VerificationStep>[step],
    );
    _dao.insertRun(run);
    _dao.insertStep(id, step);
    if (output.trim().isNotEmpty) {
      final artifact = await _store.writeText(
        runId: id,
        name: 'output',
        kind: VerificationArtifactKind.other,
        label: line,
        text: output,
        stepOrdinal: 1,
        at: finishedAt,
      );
      _dao.insertArtifact(artifact);
    }
    _changed();
    return _dao.getRun(id) ?? run;
  }

  /// Closes the run: trailing evidence, the verdict, and the report.
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

    _dao.finishRun(
      run.id,
      finishedAt: _now(),
      verdict: verdict,
      reason: reason?.trim(),
      producedBySessionId: producedBySessionId,
    );
    _recorder = null;
    final finished = _dao.getRun(run.id)!;
    await _writeReport(finished);
    _changed();
    return _dao.getRun(run.id)!;
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
  List<VerificationRun> list({int limit = 50, String? sessionId}) => [
    for (final run in _dao.listRuns(limit: limit, sessionId: sessionId))
      run.copyWith(
        steps: _dao.stepsFor(run.id),
        artifacts: _dao.artifactsFor(run.id),
      ),
  ];

  VerificationRun? get(String id) => _dao.getRun(id);

  /// A run by id or unambiguous prefix; it refuses when several match.
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

/// One gate in [VerificationService.recordCommandChecks].
class CommandCheck {
  const CommandCheck({
    required this.name,
    required this.command,
    this.exitCode,
    this.output = '',
    this.refusal,
  });

  final String name;
  final List<String> command;
  final int? exitCode;
  final String output;

  /// Why it never ran, or null when it did.
  final String? refusal;
}
