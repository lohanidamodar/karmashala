import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';

import '../../../core/capabilities/capabilities.dart';
import '../application/session_providers.dart';
import '../application/session_signals.dart';
import '../application/session_detach.dart';

/// The menus' label for [detachSessionFromUi].
const String kDetachLabel = 'Detach from parent';

/// Whether [sessionId] may be detached here: a session started by another,
/// on a server that detaches, from a device allowed to. Watched, so a menu
/// built from it moves when the row does.
bool watchCanDetach(WidgetRef ref, String sessionId) {
  ref.watchSession(sessionId);
  final caps = ref.watch(capabilitiesProvider);
  return caps.detachSessions &&
      ref.read(sessionsDataProvider).getById(sessionId)?.parentSessionId !=
          null;
}

/// **Detach**: [sessionId] becomes a session of its own — out of its
/// parent's card and depth, and nothing goes between the two any more. Asked
/// first, as what it says while apart never reaches the parent; said in
/// words when the server refuses.
Future<void> detachSessionFromUi(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) async {
  final sessions = ref.read(sessionsDataProvider);
  final child = sessions.getById(sessionId);
  final parentId = child?.parentSessionId;
  if (child == null || parentId == null) return;
  final parent = sessions.getById(parentId)?.title ?? 'its parent';
  final messenger = ScaffoldMessenger.maybeOf(context);
  final confirmed = await showConfirmDialog(
    context,
    title: 'Detach "${child.title}"?',
    message:
        'It becomes a session of its own. "$parent" stops hearing from it, '
        'and it can no longer report back. It keeps running, with its '
        'transcript, worktree and project. Attach to… can put it back '
        'under a session later; what it says in between never reaches '
        '"$parent".',
    confirmLabel: 'Detach',
  );
  if (!confirmed) return;
  String say;
  try {
    await ref.read(sessionDetachProvider)(sessionId);
    say = '"${child.title}" is on its own now.';
  } on StateError catch (refusal) {
    say = 'Could not detach it: ${refusal.message}';
  }
  messenger?.showSnackBar(SnackBar(content: Text(say)));
}

/// The session ⋯'s Detach, hidden for a session nothing started.
class DetachSessionButton extends ConsumerWidget {
  const DetachSessionButton({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!watchCanDetach(ref, sessionId)) return const SizedBox.shrink();
    return IconButton(
      key: const ValueKey('session-detach'),
      tooltip: kDetachLabel,
      icon: const Icon(AppIcons.linkBreak),
      onPressed: () => detachSessionFromUi(context, ref, sessionId),
    );
  }
}
