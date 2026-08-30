import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/domain/agent_installation.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_launch.dart';

class FanOutResult {
  const FanOutResult({
    required this.session,
    required this.agentId,
    required this.repository,
  });
  final Session session;
  final String agentId;
  final Repository repository;
}

class FanOutService {
  FanOutService(this.ref);
  final Ref ref;

  Future<List<FanOutResult>> launch({
    required Repository repository,
    required List<AgentInstallation> installations,
    required String prompt,
  }) async {
    final message = prompt.trim();
    if (message.isEmpty) throw ArgumentError('Prompt cannot be empty.');
    if (installations.length < 2) {
      throw ArgumentError('Choose at least two agent installations.');
    }
    final unique = installations.map((i) => i.id).toSet();
    if (unique.length != installations.length) {
      throw ArgumentError('Each installation can only run once.');
    }
    return Future.wait([
      for (final installation in installations)
        ref
            .read(sessionLauncherProvider)
            .launch(
              SessionLaunchRequest(
                repository: repository,
                installation: installation,
                title: 'Compare · ${installation.agentId}',
                purpose: SessionPurpose.newSession,
                useWorktree: true,
                firstMessage: message,
              ),
            )
            .then(
              (result) => FanOutResult(
                session: result.session,
                agentId: installation.agentId,
                repository: repository,
              ),
            ),
    ]);
  }

  Future<String> diff(FanOutResult result) {
    final worktree = result.session.worktree;
    if (worktree == null) return Future.value('');
    return ref.read(changesServiceProvider).diff(worktree);
  }

  Future<void> mergeWinner(FanOutResult result) async {
    final worktree = result.session.worktree;
    if (worktree == null) throw StateError('This result has no worktree.');
    final changes = await ref.read(changesServiceProvider).changes(worktree);
    if (changes.isNotEmpty) {
      throw StateError(
        'The winner still has uncommitted changes. Ask the agent to commit '
        'before merging it.',
      );
    }
    await ref
        .read(changesServiceProvider)
        .mergeBranch(
          result.repository.path,
          'session/${result.session.id.substring(0, 8)}',
        );
  }
}

final fanOutServiceProvider = Provider<FanOutService>(FanOutService.new);
