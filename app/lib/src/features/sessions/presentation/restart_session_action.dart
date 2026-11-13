import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/dialogs.dart';

import '../application/session_engine_provider.dart';
import '../application/session_launcher.dart';
import '../application/session_ui_providers.dart';
import 'end_session_action.dart';

/// "Restart session" from a session's menu: the agent stops and starts again
/// on the same conversation. A running one asks first; an ended one starts
/// without asking, as Resume does. The server ends it, waits for the end and
/// resumes it ([SessionLauncher.restartSession], the mode chip's "Restart to
/// apply"); a one-off turn this app runs is stopped before that.
Future<void> restartSessionFromRow(
  BuildContext context,
  WidgetRef ref,
  Session session,
) async {
  final id = session.id;
  if (sessionRunsNow(ref, id)) {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Restart "${session.title}"?',
      message: 'The agent stops and starts again in the same conversation.',
      confirmLabel: 'Restart session',
    );
    if (!confirmed || !context.mounted) return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  final starting = ref.read(sessionsStartingProvider.notifier)..add(id);
  String say;
  try {
    final engine = ref.read(sessionEngineProvider);
    // Two processes on one conversation otherwise.
    if (engine.isActive(id)) await engine.stop(id);
    final launched = await ref.read(sessionLauncherProvider).restartSession(id);
    say = [
      'Restarted "${session.title}".',
      ?launched.workingDirectoryNotice,
    ].join(' ');
  } on Object catch (error) {
    say =
        'Could not restart "${session.title}": '
        '${error is StateError ? error.message : error}';
  } finally {
    starting.remove(id);
    ref.publishSessionChange(SessionChange.statusChanged(id));
  }
  messenger?.showSnackBar(SnackBar(content: Text(say)));
}
