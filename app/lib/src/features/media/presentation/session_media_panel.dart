import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/session_context.dart';
import '../application/session_media_providers.dart';
import 'session_media_list.dart';

/// The Media side-panel surface. Everything expensive is behind
/// [sessionMediaProvider], which is `autoDispose`; nothing here reads a file.
class SessionMediaPanel extends ConsumerWidget {
  const SessionMediaPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = ref.watch(panelSessionIdProvider);
    if (sessionId == null) {
      return const PanePlaceholder(
        message: 'Open a session to see the pictures it has been shown.',
        icon: AppIcons.image,
      );
    }

    final media = ref.watch(sessionMediaProvider(sessionId));
    final resolveHostPath = ref.watch(sessionMediaHostPathProvider(sessionId));
    final fetch = ref.watch(sessionMediaFetchProvider(sessionId));
    return media.when(
      data: (items) => SessionMediaList(
        items: items,
        resolveHostPath: resolveHostPath,
        fetch: fetch,
        // Read here rather than inside the list so ages are deterministic in
        // tests and move only when the list is rebuilt.
        now: ref.watch(clockProvider).nowUtc(),
      ),
      loading: () => const Center(
        child: InlineSpinner(
          size: InlineSpinnerSize.large,
          semanticsLabel: 'Reading this session',
        ),
      ),
      // The stream is written not to fail, but a red box where a list of
      // pictures should be is worse than a sentence saying what happened.
      error: (error, _) => PanePlaceholder(
        message: 'Could not read this session: $error',
        icon: AppIcons.image,
      ),
    );
  }
}
