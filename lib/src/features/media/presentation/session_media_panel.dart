import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../core/util/clock_provider.dart';
import '../application/session_media_providers.dart';
import 'session_media_list.dart';

/// The Media side-panel surface.
///
/// Asked for in one line: *"may be we can create a media sidebar that shows all
/// the media from current session in descending order?"* — and the reason it
/// was asked for is the sentence before it, *"where can i see this image
/// preview in the terminal? i can't see it"*. A picture pasted into the
/// terminal is recorded as base64 with no path, and the transcript's preview
/// draws from paths, so there was nowhere at all to see it.
///
/// Everything expensive happens behind [sessionMediaProvider], which is
/// `autoDispose`: the scan runs while this is on screen and stops the moment it
/// is closed. Nothing here reads a file — this app freezes when work lands on
/// the UI thread.
class SessionMediaPanel extends ConsumerWidget {
  const SessionMediaPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = ref.watch(mediaPanelSessionIdProvider);
    if (sessionId == null) {
      return const PanePlaceholder(
        message: 'Open a session to see the pictures it has been shown.',
        icon: AppIcons.image,
      );
    }

    final media = ref.watch(sessionMediaProvider(sessionId));
    final resolveHostPath = ref.watch(sessionMediaHostPathProvider(sessionId));
    return media.when(
      data: (items) => SessionMediaList(
        items: items,
        resolveHostPath: resolveHostPath,
        // Read here rather than inside the list so ages are deterministic in
        // tests and move only when the list is rebuilt.
        now: ref.watch(clockProvider).nowUtc(),
      ),
      loading: () => const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      // The stream is written not to fail, but a surface that shows a red box
      // where a list of pictures should be is worse than one that says what
      // happened.
      error: (error, _) => PanePlaceholder(
        message: 'Could not read this session: $error',
        icon: AppIcons.image,
      ),
    );
  }
}
