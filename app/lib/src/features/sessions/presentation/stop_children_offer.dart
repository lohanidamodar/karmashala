import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/session_input.dart';
import '../application/session_subagents_providers.dart';

/// After [parentId] was stopped: offers on a snackbar to stop its child
/// sessions still working. Never stops them unasked — a person may want the
/// delegated work to finish.
void offerToStopChildren(
  BuildContext context,
  WidgetRef ref,
  String parentId,
) {
  final running = ref.read(runningChildSessionsProvider(parentId));
  if (running.isEmpty) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final input = ref.read(sessionInputProvider);
  final count = running.length;
  messenger.showSnackBar(
    SnackBar(
      key: const ValueKey('stop-children-offer'),
      content: Text(
        count == 1
            ? 'Stopped. 1 child session is still working.'
            : 'Stopped. $count child sessions are still working.',
      ),
      action: SnackBarAction(
        label: 'Stop them too',
        onPressed: () {
          for (final childId in running) {
            unawaited(_stop(input, childId, messenger));
          }
        },
      ),
    ),
  );
}

Future<void> _stop(
  SessionInput input,
  String childId,
  ScaffoldMessengerState messenger,
) async {
  try {
    await input.interrupt(childId);
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not stop a child session: $error')),
    );
  }
}
