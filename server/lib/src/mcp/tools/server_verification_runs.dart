import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_browser/browser.dart'
    show BrowserAction, BrowserException;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart' show AgentInstallationDao;
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:karmashala_verification/artifacts.dart';
import 'package:karmashala_verification/command_checks.dart'
    show verificationRunId;
import 'package:karmashala_verification/report.dart';
import 'package:karmashala_verification/store.dart' show VerificationDao;
import 'package:karmashala_verification/tools.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:path/path.dart' as p;

import '../../browser/server_browser.dart';
import 'server_tool_context.dart';

/// The server's one recording slot: a review of a change, or a page on the
/// server's own browser (slice 3d) — every `browser_*` call a step, with its
/// screenshots. Its rows go through the data API, so every client's copy
/// follows the run; its evidence and report are written under
/// `<data dir>/verification`, where the app's pane reads them.
///
/// A device run is the app's (its adb), and is never started here — see
/// `VerificationToolSet`.
class ServerVerificationRuns implements VerificationToolBackend {
  ServerVerificationRuns(
    this._context, {
    String Function()? newId,
    this.browser,
  }) : _newId = newId,
       _runs = VerificationDao(_context.database),
       _store = VerificationArtifactStore(
         Directory(p.join(_context.dataDirectory, 'verification')),
       );

  final ServerToolContext _context;
  final String Function()? _newId;
  final VerificationDao _runs;
  final VerificationArtifactStore _store;

  /// The browser a page run drives; null refuses page runs in words.
  final ServerBrowser? browser;

  VerificationRun? _active;
  _RunRecorder? _recorder;

  @override
  VerificationRun? get activeRun => _active;

  bool get isRecording => _active != null;

  @override
  Future<VerificationRun> start({
    required VerificationTarget target,
    String? title,
    String? sessionId,
    String? producedBySessionId,
    bool launch = true,
  }) async {
    final open = _active;
    if (open != null) {
      throw VerificationException(
        'A verification run is already recording: "${open.title}" '
        '(${open.id}). Finish it before starting another.',
      );
    }
    if (target.kind == VerificationTargetKind.device) {
      throw StateError(
        'The server records a review of a change or a page; a device run is '
        'the app\'s.',
      );
    }
    final pageBrowser = browser;
    if (target.isBrowser && pageBrowser == null) {
      throw const VerificationException(
        'This Karmashala server drives no browser, so no page can be '
        'verified here.',
      );
    }
    final id = _newId?.call() ?? verificationRunId(_context.now());
    final directory = await _store.createDirectory(id);
    final run = _context.write(
      VerificationStart(
        VerificationRun(
          id: id,
          title: (title == null || title.trim().isEmpty)
              ? _defaultTitle(target)
              : title.trim(),
          target: target,
          sessionId: sessionId,
          producedBySessionId: producedBySessionId,
          startedAt: _context.now(),
          artifactDirectory: directory.path,
        ),
      ),
    );
    _active = run;
    final recorder = _recorder = _RunRecorder(_context, _store, run.id);
    if (pageBrowser != null && target.isBrowser) {
      try {
        await _openBrowser(pageBrowser, recorder, target.url);
      } on Object catch (error) {
        // The run survives an unreachable page: still finishable, as
        // inconclusive, rather than losing the record of having tried.
        recorder.note('Could not reach the target', detail: '$error');
        rethrow;
      } finally {
        await pageBrowser.afterUse();
      }
    }
    return run;
  }

  /// Installs the recorder on the browser, attaches (or opens the page), and
  /// starts collecting console errors before the navigation.
  Future<void> _openBrowser(
    ServerBrowser browser,
    _RunRecorder recorder,
    String? url,
  ) async {
    final service = browser.service..actionSink = recorder.recordBrowser;
    if (!service.isConnected) {
      try {
        await service.connect(port: browser.port);
      } on BrowserException {
        if (url == null || url.isEmpty) rethrow;
        await service.connect(port: browser.port, url: url);
      }
    }
    await service.startObserving();
    if (url != null && url.isNotEmpty) await service.navigate(url);
  }

  @override
  void note(String text, {String? detail}) {
    _require();
    if (text.trim().isEmpty) {
      throw const VerificationException('A note needs something to say.');
    }
    _recorder!.note(text.trim(), detail: detail);
  }

  /// Closes the run, writes its report, and files the verdict in the
  /// decision record of the session whose work it judged.
  @override
  Future<VerificationRun> finish({
    required VerificationVerdict verdict,
    String? reason,
    String? producedBySessionId,
  }) async {
    final run = _require();
    final recorder = _recorder!;
    final pageBrowser = browser;
    if (run.target.isBrowser && pageBrowser != null) {
      try {
        await _collectClosingEvidence(pageBrowser, recorder);
      } finally {
        await _bestEffort(pageBrowser.service.stopObserving);
        pageBrowser.service.actionSink = null;
        await pageBrowser.afterUse();
      }
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
    final finished = _context.write(
      VerificationFinish(
        run.id,
        verdict: verdict,
        reason: reason?.trim(),
        producedBySessionId: producedBySessionId,
      ),
    );
    _active = null;
    _recorder = null;
    final whole = _runs.getRun(run.id) ?? finished;
    await _writeReport(whole);
    _recordVerdict(whole);
    return whole;
  }

  /// Collected without being asked, at the end: the page's console and failed
  /// requests, and a last screenshot (a step too — the sink is still on).
  Future<void> _collectClosingEvidence(
    ServerBrowser browser,
    _RunRecorder recorder,
  ) async {
    final observer = browser.service.observer;
    if (observer != null) {
      final messages = observer.consoleMessages;
      final errors = messages.where((m) => m.isError).length;
      final warnings = messages.length - errors;
      if (messages.isNotEmpty) {
        recorder.attach(
          kind: VerificationArtifactKind.consoleErrors,
          label:
              '$errors console error${errors == 1 ? '' : 's'}'
              '${warnings == 0 ? '' : ', $warnings warning'
                        '${warnings == 1 ? '' : 's'}'}',
          name: 'console',
          text: messages.map((m) => m.toLine()).join('\n'),
        );
      }
      final failures = observer.networkFailures;
      if (failures.isNotEmpty) {
        recorder.attach(
          kind: VerificationArtifactKind.networkFailures,
          label:
              '${failures.length} failed request'
              '${failures.length == 1 ? '' : 's'}',
          name: 'network',
          text: failures.map((f) => f.toLine()).join('\n'),
        );
      }
    }
    if (browser.service.isConnected) {
      await _bestEffort(() => browser.service.screenshot());
    }
  }

  /// [action], or null: evidence that cannot be collected must not lose the
  /// run's verdict.
  static Future<T?> _bestEffort<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on Object {
      return null;
    }
  }

  static String _defaultTitle(VerificationTarget target) =>
      switch (target.kind) {
        VerificationTargetKind.browser => 'Verify ${target.url ?? 'the page'}',
        _ => 'Review of the change',
      };

  @override
  Future<List<VerificationRun>> list({
    int limit = 50,
    String? sessionId,
  }) async => [
    for (final run in _runs.listRuns(limit: limit, sessionId: sessionId))
      run.copyWith(
        steps: _runs.stepsFor(run.id),
        artifacts: _runs.artifactsFor(run.id),
      ),
  ];

  @override
  Future<VerificationRun?> get(String id) async => _runs.getRun(id);

  @override
  Future<VerificationRun?> find(String idOrPrefix) async {
    final exact = _runs.getRun(idOrPrefix);
    if (exact != null) return exact;
    final matches = _runs.findByPrefix(idOrPrefix);
    return matches.length == 1 ? _runs.getRun(matches.single.id) : null;
  }

  @override
  Future<List<VerificationRun>> matching(String prefix) async =>
      _runs.findByPrefix(prefix);

  @override
  Future<List<int>?> readArtifact(VerificationArtifact artifact) =>
      _store.read(artifact);

  Future<void> _writeReport(VerificationRun run) async {
    final inlined = <String, String>{};
    for (final artifact in run.artifacts) {
      if (!shouldInline(artifact)) continue;
      final bytes = await _store.read(artifact);
      if (bytes == null) continue;
      inlined[artifact.relativePath] = utf8.decode(bytes, allowMalformed: true);
    }
    try {
      final file = File(p.join(run.artifactDirectory, 'report.md'));
      await file.parent.create(recursive: true);
      await file.writeAsString(
        renderVerificationReport(run, inlined: inlined),
        flush: true,
      );
    } on FileSystemException catch (error) {
      _context.log('the report of ${run.id} could not be written ($error)');
    }
  }

  /// The verdict in the **subject** session's record, not the verifier's; an
  /// unattached run writes nothing. Best-effort, as the app's was.
  void _recordVerdict(VerificationRun run) {
    final subject = run.sessionId;
    final verdict = run.verdict;
    if (subject == null || verdict == null) return;
    final reason = run.reason;
    final producer = run.producedBySessionId;
    try {
      _context.write(
        DecisionAppend(
          DecisionRecord(
            sessionId: subject,
            kind: DecisionKind.verificationVerdict,
            summary: reason == null || reason.trim().isEmpty
                ? '${verdict.label} — ${run.title}'
                : '${verdict.label} — ${run.title}. $reason',
            detail: 'Verdict ${run.attribution.phrase}.',
            decidedBy: producer == null ? null : _agentNameFor(producer),
            recordedBySessionId: producer,
            origin: DecisionOrigin.verificationRun,
            originId: run.id,
            recordedAt: _context.now(),
          ),
        ),
      );
    } on Object catch (error) {
      _context.log(
        'the verdict of ${run.id} could not be recorded for $subject ($error)',
      );
    }
  }

  /// The display name of the agent running [sessionId], or null — never a
  /// guess.
  String? _agentNameFor(String sessionId) {
    final session = SessionDao(_context.database).getById(sessionId);
    if (session == null) return null;
    final agentId = AgentInstallationDao(
      _context.database,
    ).getById(session.agentInstallationId)?.agentId;
    return agentId == null ? null : _context.agents.displayNameFor(agentId);
  }

  VerificationRun _require() =>
      _active ??
      (throw const VerificationException(
        'No verification run is recording. Call verification_start first.',
      ));
}

/// One run's steps and files: a step is written at once (the store is
/// synchronous, so steps keep their order); its files are written after,
/// queued, and [drain] is what finishing awaits. Nothing here throws at the
/// browser it watches — a write that fails is kept in [problems].
class _RunRecorder {
  _RunRecorder(this._context, this._store, this.runId);

  final ServerToolContext _context;
  final VerificationArtifactStore _store;
  final String runId;
  var _ordinal = 0;
  Future<void> _queue = Future<void>.value();
  final problems = <String>[];

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
    required String text,
  }) => _enqueue(() async {
    final artifact = await _store.writeText(
      runId: runId,
      kind: kind,
      label: label,
      name: name,
      text: text,
      at: _context.now(),
    );
    _context.write(VerificationArtifactAdd(artifact));
  });

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
    final at = _context.now();
    try {
      _context.write(
        VerificationStepAdd(
          runId,
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
    } on Object catch (error) {
      problems.add('$error');
      return;
    }
    if ((png == null || png.isEmpty) && (text == null || text.isEmpty)) return;
    final prefix = ordinal.toString().padLeft(3, '0');
    _enqueue(() async {
      if (png != null && png.isNotEmpty) {
        _context.write(
          VerificationArtifactAdd(
            await _store.write(
              runId: runId,
              kind: VerificationArtifactKind.screenshot,
              label: summary,
              name: '$prefix-$slug',
              bytes: png,
              stepOrdinal: ordinal,
              at: at,
            ),
          ),
        );
      }
      if (text != null && text.isNotEmpty) {
        _context.write(
          VerificationArtifactAdd(
            await _store.writeText(
              runId: runId,
              kind: textKind,
              label: summary,
              name: '$prefix-$slug',
              text: text,
              stepOrdinal: ordinal,
              at: at,
            ),
          ),
        );
      }
    });
  }

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
}
