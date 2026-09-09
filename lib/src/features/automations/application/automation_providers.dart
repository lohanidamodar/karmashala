import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../data/automation_dao.dart';
import '../data/project_check_dao.dart';
import '../domain/automation.dart';
import '../domain/automation_check_verdict.dart';
import '../domain/automation_run.dart';
import '../domain/project_check.dart';

final automationDaoProvider = Provider<AutomationDao>(
  (ref) => AutomationDao(ref.watch(databaseProvider)),
);

final projectCheckDaoProvider = Provider<ProjectCheckDao>(
  (ref) => ProjectCheckDao(ref.watch(databaseProvider)),
);

/// Bumped by every write to an automation, a run or a checkout's checks.
///
/// The `worktreeSetupRevisionProvider` shape, and for the same reason: the
/// writer is not the surface. A fire happens on a timer nobody is watching, and
/// the page showing "did it run last night" has to notice without asking again
/// on a schedule of its own — nothing here polls (§19).
class AutomationsRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final automationsRevisionProvider =
    NotifierProvider<AutomationsRevision, int>(AutomationsRevision.new);

final automationsProvider = Provider<List<Automation>>((ref) {
  ref.watch(automationsRevisionProvider);
  return ref.watch(automationDaoProvider).getAll();
});

final automationRunsProvider = Provider.family<List<AutomationRun>, String>((
  ref,
  automationId,
) {
  ref.watch(automationsRevisionProvider);
  return ref.watch(automationDaoProvider).runsFor(automationId);
});

/// What one occurrence's project checks said, in the order they ran.
final automationRunChecksProvider =
    Provider.family<List<AutomationCheckVerdict>, String>((ref, runId) {
      ref.watch(automationsRevisionProvider);
      return ref.watch(automationDaoProvider).checksFor(runId);
    });

/// One checkout's configured checks.
final projectChecksProvider = Provider.family<List<ProjectCheck>, String>((
  ref,
  repositoryId,
) {
  ref.watch(automationsRevisionProvider);
  return ref.watch(projectCheckDaoProvider).forRepository(repositoryId);
});

/// Whether a checkout's work is verified at all.
final projectVerificationEnabledProvider = Provider.family<bool, String>((
  ref,
  repositoryId,
) {
  ref.watch(automationsRevisionProvider);
  return ref.watch(projectCheckDaoProvider).isVerificationEnabled(repositoryId);
});

/// Writes an automation or a checkout's verification, and tells the surfaces.
///
/// **Arming goes through here and nowhere else.** No MCP tool reaches it; the
/// only callers are the Settings page's own controls, which is what "arming is
/// a human action in the UI" means in code.
class AutomationController {
  AutomationController(this._ref);

  final Ref _ref;

  String newId() => _ref.read(idGeneratorProvider).newId();
  DateTime now() => _ref.read(clockProvider).nowUtc();

  void save(Automation automation) {
    final dao = _ref.read(automationDaoProvider);
    if (dao.getById(automation.id) == null) {
      dao.insert(automation);
    } else {
      dao.update(automation);
    }
    _ref.read(automationsRevisionProvider.notifier).bump();
  }

  void setEnabled(String id, {required bool enabled}) {
    _ref.read(automationDaoProvider).setEnabled(id, enabled: enabled);
    _ref.read(automationsRevisionProvider.notifier).bump();
  }

  void delete(String id) {
    _ref.read(automationDaoProvider).delete(id);
    _ref.read(automationsRevisionProvider.notifier).bump();
  }

  void setVerificationEnabled(String repositoryId, {required bool enabled}) {
    _ref
        .read(projectCheckDaoProvider)
        .setVerificationEnabled(repositoryId, enabled: enabled, now: now());
    _ref.read(automationsRevisionProvider.notifier).bump();
  }

  void addCheck(String repositoryId, String name, List<String> command) {
    _ref
        .read(projectCheckDaoProvider)
        .insert(
          ProjectCheck(
            id: newId(),
            repositoryId: repositoryId,
            name: name.trim(),
            command: command,
            createdAt: now(),
          ),
        );
    _ref.read(automationsRevisionProvider.notifier).bump();
  }

  void removeCheck(String id) {
    _ref.read(projectCheckDaoProvider).delete(id);
    _ref.read(automationsRevisionProvider.notifier).bump();
  }
}

final automationControllerProvider = Provider<AutomationController>(
  AutomationController.new,
);
