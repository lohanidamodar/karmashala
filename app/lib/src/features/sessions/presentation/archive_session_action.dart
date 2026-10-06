import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/dialogs.dart';

import '../application/delivery_providers.dart';
import '../application/session_actions.dart';
import '../application/session_archive_service.dart';
import '../application/session_providers.dart';
import 'end_session_action.dart';

/// Whether [session] is live, so may not be archived yet: something runs it,
/// or its row claims an agent is running.
bool sessionIsLive(WidgetRef ref, Session session) =>
    session.status.claimsLive || sessionRunsNow(ref, session.id);

/// Archives [sessions] — hides them, with their ended descendants — in one
/// request, and says what it left: a live session is named, never archived,
/// and the only one asked for is offered End.
Future<void> archiveSessionsFromUi(
  BuildContext context,
  WidgetRef ref,
  List<Session> sessions,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final live = [for (final s in sessions) if (sessionIsLive(ref, s)) s];
  final ended = [for (final s in sessions) if (!sessionIsLive(ref, s)) s];
  if (ended.isEmpty) {
    final one = live.length == 1 ? live.single : null;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          one != null
              ? '"${one.title}" is still running, so it was not archived. '
                    'End it first.'
              : '${live.length} sessions are still running, so none was '
                    'archived. End them first.',
        ),
        action: one == null || !context.mounted
            ? null
            : SnackBarAction(
                label: 'End session',
                onPressed: () => endSessionFromRow(
                  context,
                  ref,
                  one.id,
                  title: one.title,
                ),
              ),
      ),
    );
    return;
  }
  final owning = [for (final s in ended) if (ownsWorktree(s)) s];
  final blockers = <String, String?>{};
  var deleteTrees = false;
  if (owning.isNotEmpty) {
    for (final session in owning) {
      blockers[session.id] = await worktreeDeleteBlocker(context, session);
      if (!context.mounted) return;
    }
    final choice = await _ArchiveDialog.show(
      context,
      sessions: ended,
      owning: owning,
      blockers: blockers,
    );
    if (choice == null) return;
    deleteTrees = choice;
  }
  SessionsArchived result;
  try {
    result = await ref
        .read(sessionActionsProvider)
        .archiveSessions([for (final s in ended) s.id]);
  } on Object catch (error) {
    messenger?.showSnackBar(
      SnackBar(content: Text('Could not archive: ${_words(error)}')),
    );
    return;
  }
  if (deleteTrees) {
    final service = ref.read(sessionArchiveServiceProvider);
    final kept = <String>[];
    for (final session in owning) {
      if (blockers[session.id] != null) continue;
      final outcome = await service.archive(session.id);
      if (!outcome.isArchived) {
        kept.add('"${session.title}": ${outcome.message}');
      }
    }
    if (kept.isNotEmpty) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Worktree kept — ${kept.join('; ')}')),
      );
    }
  }
  final leftLive = {
    for (final s in live) s.title,
    for (final s in result.live) s.title,
  };
  if (leftLive.isEmpty) return;
  messenger?.showSnackBar(
    SnackBar(
      content: Text(
        'Archived ${result.changed.length}. Still running, so left as they '
        'are: ${leftLive.join(', ')}.',
      ),
    ),
  );
}

/// Shows [ids] and their archived descendants again.
Future<void> unarchiveSessionsFromUi(
  BuildContext context,
  WidgetRef ref,
  List<String> ids,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref.read(sessionActionsProvider).unarchiveSessions(ids);
  } on Object catch (error) {
    messenger?.showSnackBar(
      SnackBar(content: Text('Could not unarchive: ${_words(error)}')),
    );
  }
}

/// The rows of [ids] this client holds.
List<Session> sessionsById(WidgetRef ref, Iterable<String> ids) => [
  for (final id in ids) ?ref.read(sessionsDataProvider).getById(id),
];

String _words(Object error) => switch (error) {
  DataRefused(:final message) => message,
  StateError(:final message) => message,
  _ => '$error',
};

/// Whether [session] has a worktree of its own that is still on disk.
bool ownsWorktree(Session session) =>
    session.worktree != null && !session.worktreeRemoved;

/// Why [session]'s worktree must not be deleted now — work no remote holds —
/// or null when it may. A tree that could not be read is not deleted either.
Future<String?> worktreeDeleteBlocker(
  BuildContext context,
  Session session,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final sub = container.listen(
    sessionLocalDeliveryProvider(session.id).future,
    (_, _) {},
  );
  final SessionDelivery delivery;
  try {
    delivery = await sub.read();
  } on Object {
    return 'its worktree could not be read';
  } finally {
    sub.close();
  }
  final dirty = delivery.dirtyFiles;
  if (dirty == null) return 'its worktree could not be read';
  if (dirty > 0) return '$dirty uncommitted change${dirty == 1 ? '' : 's'}';
  // A branch never pushed holds every commit it has made.
  final unpushed =
      delivery.unpushed ??
      (delivery.upstream == null ? delivery.aheadOfBase ?? 0 : 0);
  if (unpushed > 0) {
    return '$unpushed unpushed commit${unpushed == 1 ? '' : 's'}';
  }
  return null;
}

/// "Delete worktree": removes [sessionId]'s worktree directory after a
/// confirmation, and a second one for uncommitted work. The session is left
/// as it is, archived or not; its transcript and branch are kept.
Future<void> deleteSessionWorktree(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final session = ref.read(sessionsDataProvider).getById(sessionId);
  final worktree = session?.worktree;
  if (session == null || worktree == null) return;
  final blocker = await worktreeDeleteBlocker(context, session);
  if (!context.mounted) return;
  final unpushed = blocker != null && blocker.contains('unpushed')
      ? '\n\nIt has $blocker: they stay on the branch, but no remote has '
            'them.'
      : '';
  final confirmed = await _confirm(
    context,
    title: 'Delete this worktree?',
    body:
        'The directory ${worktree.path} is removed.\n\n'
        'The session, its transcript, review notes and checkpoints are kept, '
        'and so is the branch.$unpushed',
    action: 'Delete',
  );
  if (confirmed != true || !context.mounted) return;

  final service = ref.read(sessionArchiveServiceProvider);
  var outcome = await service.archive(sessionId);
  if (outcome.refusal == ArchiveRefusal.uncommittedChanges && context.mounted) {
    // Asked about this session rather than set as a mode: it destroys work no
    // branch holds.
    final discard = await _confirm(
      context,
      title: 'Discard uncommitted work?',
      body:
          '${outcome.message}\n\n'
          'They are in no commit and no branch, so this cannot be undone.',
      action: 'Discard and delete',
      destructive: true,
    );
    if (discard != true) {
      messenger?.showSnackBar(SnackBar(content: Text(outcome.message)));
      return;
    }
    outcome = await service.archive(sessionId, discardUncommitted: true);
  }
  messenger?.showSnackBar(SnackBar(content: Text(outcome.message)));
}

Future<bool?> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool destructive = false,
}) => showDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: Text(body),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      if (destructive)
        DestructiveButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(action),
        )
      else
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(action),
        ),
    ],
  ),
);

/// Archive's question for sessions that own a worktree: whether to delete
/// it too. Off by default; not offered for a tree holding work no remote has.
class _ArchiveDialog extends StatefulWidget {
  const _ArchiveDialog({
    required this.sessions,
    required this.owning,
    required this.blockers,
  });

  final List<Session> sessions;
  final List<Session> owning;
  final Map<String, String?> blockers;

  /// Whether to delete the worktrees too, or null when cancelled.
  static Future<bool?> show(
    BuildContext context, {
    required List<Session> sessions,
    required List<Session> owning,
    required Map<String, String?> blockers,
  }) => showDialog<bool>(
    context: context,
    builder: (_) =>
        _ArchiveDialog(sessions: sessions, owning: owning, blockers: blockers),
  );

  @override
  State<_ArchiveDialog> createState() => _ArchiveDialogState();
}

class _ArchiveDialogState extends State<_ArchiveDialog> {
  var _delete = false;

  @override
  Widget build(BuildContext context) {
    final one = widget.sessions.length == 1;
    final blocked = [
      for (final s in widget.owning)
        if (widget.blockers[s.id] case final reason?) (s, reason),
    ];
    final deletable = widget.owning.length - blocked.length;
    final String? why;
    if (blocked.isEmpty) {
      why = null;
    } else if (widget.owning.length == 1) {
      why = 'Not now: it has ${blocked.single.$2}.';
    } else {
      final each = [for (final (s, r) in blocked) '"${s.title}" has $r'];
      why = '${blocked.length} kept: ${each.join('; ')}.';
    }
    return AlertDialog(
      title: Text(
        one
            ? 'Archive "${widget.sessions.single.title}"?'
            : 'Archive ${widget.sessions.length} sessions?',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${one ? 'It leaves' : 'They leave'} the session lists. '
            'Transcripts and files are kept; "Show archived" brings '
            '${one ? 'it' : 'them'} back.',
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _delete,
            onChanged: deletable == 0
                ? null
                : (value) => setState(() => _delete = value ?? false),
            title: Text(
              widget.owning.length == 1
                  ? 'Also delete its worktree'
                  : 'Also delete their worktrees',
            ),
            subtitle: why == null ? null : Text(why),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_delete),
          child: const Text('Archive'),
        ),
      ],
    );
  }
}
