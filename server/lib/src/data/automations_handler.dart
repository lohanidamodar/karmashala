import 'dart:async';

import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/scheduler.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_automations/webhooks.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_store/database.dart';

import 'told_automations.dart';

/// Automations, their runs and checks, origin chains, project checks and
/// scheduled resumes at the server: validates, writes through the DAOs (the
/// only writer of these tables), says what changed, and — after any write —
/// lets the server's scheduler look again ([written]).
class AutomationsHandler {
  AutomationsHandler(this._db, this._now, {void Function()? written})
    : _written = written,
      _automations = AutomationDao(_db),
      _checks = ProjectCheckDao(_db),
      _resumes = ScheduledResumeDao(_db);

  final AppDatabase _db;
  final DateTime Function() _now;
  final void Function()? _written;
  final AutomationDao _automations;
  final ProjectCheckDao _checks;
  final ScheduledResumeDao _resumes;

  Object? handle(
    AutomationsRequest<Object?> request,
    List<DataChange> changes,
  ) {
    if (request is AutomationsList) return snapshot();
    final automations = ToldAutomations(_automations, changes.add);
    final resumes = ToldResumes(_resumes, changes.add);
    final result = switch (request) {
      AutomationsList() => snapshot(),
      AutomationRunsPage(:final before, :final limit, :final automationId) =>
        _page(before, limit, automationId),
      AutomationSave(:final automation) => _save(automation, changes),
      AutomationSetEnabled(:final id, :final enabled) => _then(
        id,
        () => automations.setEnabled(id, enabled: enabled),
      ),
      AutomationDelete(:final id) => _delete(id, changes),
      AutomationRecordOutcome(:final id, :final failed) => _then(
        id,
        () => automations.recordOutcome(id, failed: failed),
      ),
      AutomationDisable(:final id, :final reason) => _then(
        id,
        () => automations.disable(id, reason),
      ),
      AutomationRunPut(:final run) => _putRun(run, automations),
      AutomationEventRunQueue(:final run) => queueEventRunIn(
        automations,
        _automation(run.automationId),
        run,
      ),
      AutomationRunCheckAdd(:final verdict) => _addCheck(verdict, automations),
      AutomationRunChecksObserved(:final runId, :final at) => _observed(
        runId,
        at,
        automations,
      ),
      AutomationOriginMark(:final sessionId, :final origin) => _mark(
        sessionId,
        origin,
        automations,
      ),
      AutomationOriginClear(:final sessionId) => _ack(
        () => automations.clearMessaged(sessionId),
      ),
      ProjectCheckAdd(:final check) => _addProjectCheck(check, changes),
      ProjectCheckDelete(:final id) => _deleteProjectCheck(id, changes),
      ProjectVerificationSet(:final repositoryId, :final enabled) =>
        _setVerification(repositoryId, enabled, changes),
      ResumeSchedule(:final resume) => _schedule(resume, resumes),
      ResumeUpdate(:final resume) => _updateResume(resume, resumes),
      ResumeTransition(:final id, :final from, :final to) => resumes.transition(
        id,
        from: from,
        to: to,
      ),
      ResumeDelete(:final id) => _ack(() => resumes.delete(id)),
    };
    final written = _written;
    if (written != null && changes.isNotEmpty) scheduleMicrotask(written);
    return result;
  }

  AutomationsSnapshot snapshot() {
    final runs = _automations.copiedRuns();
    return AutomationsSnapshot(
      automations: _automations.getAll(),
      runs: runs,
      checks: _automations.checksOf([for (final r in runs) r.id]),
      origins: _automations.origins(),
      projectChecks: _checks.all(),
      verified: _checks.verifiedRepositories(),
      resumes: _resumes.copied(),
    );
  }

  AutomationRunsPageResult _page(
    DateTime? before,
    int limit,
    String? automationId,
  ) {
    final size = limit.clamp(1, 200);
    final runs = _automations.runsPage(
      before: before,
      limit: size + 1,
      automationId: automationId,
    );
    final page = runs.take(size).toList();
    return AutomationRunsPageResult(
      runs: page,
      checks: _automations.checksOf([for (final r in page) r.id]),
      more: runs.length > size,
    );
  }

  static DataAck _ack(void Function() write) {
    write();
    return const DataAck();
  }

  Automation _automation(String id) =>
      _automations.getById(id) ??
      (throw DataRefused.notFound('no automation with id $id'));

  AutomationRun _existingRun(String id) =>
      _automations.runById(id) ??
      (throw DataRefused.notFound('no automation run with id $id'));

  void _repository(String id) {
    if (_db.query('SELECT 1 FROM repositories WHERE id = ?;', [id]).isEmpty) {
      throw DataRefused.notFound('no checkout with id $id');
    }
  }

  void _session(String id) {
    if (_db.query('SELECT 1 FROM sessions WHERE id = ?;', [id]).isEmpty) {
      throw DataRefused.notFound('no session with id $id');
    }
  }

  /// Runs [write] on automation [id] and answers it as it now stands.
  Automation _then(String id, void Function() write) {
    _automation(id);
    write();
    return _automation(id);
  }

  Automation _save(Automation automation, List<DataChange> changes) {
    if (automation.name.trim().isEmpty) {
      throw const DataRefused.invalid('An automation needs a name.');
    }
    final before = _automations.getById(automation.id);
    automation = _commandOf(automation, before);
    if (automation.folder == null) _repository(automation.repositoryId);
    automation = _webhookOf(automation, before);
    automation = _stepsOf(automation, before);
    if (before == null) {
      _automations.insert(automation);
    } else {
      if (before.repositoryId != automation.repositoryId ||
          (before.folder == null) != (automation.folder == null)) {
        throw const DataRefused.invalid(
          'An automation keeps the checkout it was armed in.',
        );
      }
      _automations.update(automation);
    }
    final stored = _automation(automation.id);
    changes.add(AutomationChanged(stored));
    return stored;
  }

  /// The webhook part as the server keeps it: its hook id is the server's
  /// own (from a CSPRNG, kept across edits), a client that predates webhooks
  /// cannot drop one by saving, and the template must be one it can fill.
  static Automation _webhookOf(Automation automation, Automation? before) {
    final kept = before?.webhook;
    final asked = automation.webhook;
    if (asked == null) {
      return kept == null ? automation : automation.copyWith(webhook: kept);
    }
    if (automation.isEventDriven) {
      throw const DataRefused.invalid(
        'An automation is a webhook or an event rule, not both.',
      );
    }
    // A command's call is its trigger only: it fills no prompt.
    final refusal = automation.runsCommand
        ? null
        : webhookTemplateRefusal(automation.prompt);
    if (refusal != null) throw DataRefused.invalid(refusal);
    return automation.copyWith(
      webhook: asked.copyWith(
        hookId: kept?.hookId ?? newWebhookHookId(),
        callsPerHour: asked.callsPerHour.clamp(1, kMaxWebhookCallsPerHour),
      ),
    );
  }

  /// The command part as the server keeps it. A client that predates
  /// commands sends none, and its save keeps the stored command, folder and
  /// checkout rather than turning it into an agent automation with no agent.
  static Automation _commandOf(Automation automation, Automation? before) {
    if (!automation.commandStated) {
      if (before == null) return automation;
      return automation.copyWith(
        command: before.command,
        clearCommand: before.command == null,
        folder: before.folder,
        clearFolder: before.folder == null,
        repositoryId: before.repositoryId,
        commandStated: true,
      );
    }
    final command = automation.command;
    if (command == null) {
      if (automation.folder != null) {
        throw const DataRefused.invalid(
          'Only a command runs in a folder; an agent runs in a project.',
        );
      }
      return automation;
    }
    if (command.refusal case final why?) throw DataRefused.invalid(why);
    final folder = automation.folder;
    if (folder != null) {
      if (folder.path.trim().isEmpty) {
        throw const DataRefused.invalid('Say which folder it runs in.');
      }
      if (automation.isEventDriven || automation.isGithub) {
        throw const DataRefused.invalid(
          'An event or GitHub rule watches a project, so it runs in one.',
        );
      }
      for (final kind in const [
        AutomationStepKind.check,
        AutomationStepKind.tell,
      ]) {
        if (automation.steps.of(kind) != null) {
          throw DataRefused.invalid(
            '"${kind.label}" needs a project; a folder has none.',
          );
        }
      }
      final pipeline = automation.steps.of(AutomationStepKind.pipeline);
      if (pipeline != null && pipeline.repositoryId == null) {
        throw const DataRefused.invalid(
          'Pick the project its pipeline runs in; a folder has none.',
        );
      }
    }
    if (automation.steps.of(AutomationStepKind.tell) != null) {
      throw const DataRefused.invalid(
        'A command starts no session, so there is no agent to tell.',
      );
    }
    return automation.copyWith(
      agentInstallationId: '',
      clearModel: true,
      worktree: false,
      repositoryId: folder == null ? null : '',
    );
  }

  /// A client that predates steps sends none, and its save must not drop the
  /// steps, model or worktree a newer one set.
  static Automation _stepsOf(Automation automation, Automation? before) {
    if (automation.steps.stated) return automation;
    var kept = automation.copyWith(
      steps: before?.steps ?? AutomationSteps.standard,
    );
    if (kept.webhook == null && before != null) {
      kept = kept.copyWith(
        modelId: before.modelId,
        clearModel: before.modelId == null,
        worktree: before.worktree,
      );
    }
    return kept;
  }

  DataAck _delete(String id, List<DataChange> changes) {
    _automation(id);
    _automations.delete(id);
    changes.add(AutomationRemoved(id));
    return const DataAck();
  }

  AutomationRun _putRun(AutomationRun run, ToldAutomations automations) {
    _automation(run.automationId);
    if (_automations.runById(run.id) == null) {
      automations.insertRun(run);
    } else {
      automations.updateRun(run);
    }
    return _existingRun(run.id);
  }

  DataAck _addCheck(
    AutomationCheckVerdict verdict,
    ToldAutomations automations,
  ) {
    _existingRun(verdict.runId);
    automations.insertRunCheck(verdict);
    return const DataAck();
  }

  AutomationRun _observed(
    String runId,
    DateTime at,
    ToldAutomations automations,
  ) {
    _existingRun(runId);
    automations.noteChecksObserved(runId, at);
    return _existingRun(runId);
  }

  DataAck _mark(
    String sessionId,
    List<String> origin,
    ToldAutomations automations,
  ) {
    _session(sessionId);
    automations.markMessaged(sessionId, origin, _now());
    return const DataAck();
  }

  ProjectCheck _addProjectCheck(ProjectCheck check, List<DataChange> changes) {
    final problem =
        projectCheckNameRefusal(check.name) ??
        projectCheckCommandRefusal(check.command);
    if (problem != null) throw DataRefused.invalid(problem);
    _repository(check.repositoryId);
    if (_checks.getById(check.id) != null) {
      throw DataRefused.invalid('a project check with id ${check.id} exists');
    }
    _checks.insert(
      ProjectCheck(
        id: check.id,
        repositoryId: check.repositoryId,
        name: check.name.trim(),
        command: check.command,
        createdAt: _now(),
      ),
    );
    final stored = _checks.getById(check.id)!;
    changes.add(ProjectCheckChanged(stored));
    return stored;
  }

  DataAck _deleteProjectCheck(String id, List<DataChange> changes) {
    if (_checks.getById(id) == null) {
      throw DataRefused.notFound('no project check with id $id');
    }
    _checks.delete(id);
    changes.add(ProjectCheckRemoved(id));
    return const DataAck();
  }

  DataAck _setVerification(
    String repositoryId,
    bool enabled,
    List<DataChange> changes,
  ) {
    _repository(repositoryId);
    _checks.setVerificationEnabled(repositoryId, enabled: enabled, now: _now());
    changes.add(ProjectVerificationChanged(repositoryId, enabled: enabled));
    return const DataAck();
  }

  ScheduledResume _schedule(ScheduledResume resume, ToldResumes resumes) {
    _session(resume.sessionId);
    if (_resumes.getById(resume.id) != null) {
      throw DataRefused.invalid(
        'a scheduled resume with id ${resume.id} exists',
      );
    }
    resumes.replaceFor(resume, now: _now());
    return _resumes.getById(resume.id)!;
  }

  ScheduledResume _updateResume(ScheduledResume resume, ToldResumes resumes) {
    if (_resumes.getById(resume.id) == null) {
      throw DataRefused.notFound('no scheduled resume with id ${resume.id}');
    }
    resumes.update(resume);
    return _resumes.getById(resume.id)!;
  }
}
