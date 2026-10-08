import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../explorer/application/explorer_actions.dart';
import '../../sessions/application/session_providers.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';

/// After [sessionId] was resumed or started with no tab (the "Resume and start
/// sessions in the background" setting): its card peeked when the Agent
/// dashboard is showing, else a notice — `Resumed "X"` — whose Open opens its
/// tab. Nothing else moves.
void announceBackgroundLaunch(
  ProviderContainer container, {
  required String sessionId,
  required ScaffoldMessengerState? messenger,
  bool started = false,
}) {
  // The board's focus lives exactly while the dashboard is built.
  if (container.exists(overviewFocusProvider)) {
    container.read(overviewPrefsProvider.notifier).setView(OverviewView.board);
    container.read(overviewFocusProvider.notifier).peek(sessionId);
    return;
  }
  final title =
      container.read(sessionsDataProvider).getById(sessionId)?.title ??
      'the session';
  messenger?.showSnackBar(
    SnackBar(
      content: Text('${started ? 'Started' : 'Resumed'} "$title"'),
      action: SnackBarAction(
        label: 'Open',
        onPressed: () => unawaited(
          container.read(explorerActionsProvider).openNative(sessionId),
        ),
      ),
    ),
  );
}
