import 'package:karmashala_automations/check_runner.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../verification/data/verification_data.dart';
import 'automation_providers.dart';

export 'package:karmashala_automations/check_runner.dart' show SessionChecks;

/// Whether [sessionId]'s repository has any project checks, so a surface
/// offers to run them only where there is something to run.
final sessionHasProjectChecksProvider = Provider.family<bool, String>((
  ref,
  sessionId,
) {
  final repositoryId = ref
      .watch(sessionsDataProvider)
      .getById(sessionId)
      ?.repositoryId;
  if (repositoryId == null) return false;
  return ref.watch(projectChecksProvider(repositoryId)).isNotEmpty;
});

/// The sessions whose checks are running from a surface right now, so every
/// place that offers the action shows it busy rather than starting a second
/// batch into the same worktree.
class RunningSessionChecks extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// Runs [sessionId]'s checks at the server (`checks.run`) unless they are
  /// already running — in sessions it owns on its machine, as commands over
  /// its own connection on an SSH box. Null when the repository has none;
  /// throws [StateError] with the server's words when they could not run.
  Future<SessionChecks?> run(String sessionId) async {
    if (state.contains(sessionId)) return null;
    state = {...state, sessionId};
    try {
      final SessionChecksRun answer;
      try {
        answer = (await ref.read(dataClientProvider).send(ChecksRun(sessionId)))
            .value;
      } on DataRefused catch (refusal) {
        throw StateError(refusal.message);
      }
      switch (answer.outcome) {
        case SessionChecksOutcome.none:
          return null;
        case SessionChecksOutcome.refused:
          throw StateError(
            answer.message ?? 'The server could not run the checks.',
          );
        case SessionChecksOutcome.ran:
          final run = await ref
              .read(verificationDataProvider)
              .get(answer.verificationRunId ?? '');
          if (run == null) return null;
          // The server kept the per-check lines as the run's steps.
          return (checks: const <CommandCheck>[], run: run);
      }
    } finally {
      state = {...state}..remove(sessionId);
    }
  }
}

final runningSessionChecksProvider =
    NotifierProvider<RunningSessionChecks, Set<String>>(
      RunningSessionChecks.new,
    );
