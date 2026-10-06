import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';

import '../application/session_actions.dart';
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
