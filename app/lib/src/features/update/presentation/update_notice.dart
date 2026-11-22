import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../settings/application/settings_controller.dart';
import '../application/github_update_controller.dart';
import '../domain/update_status.dart';
import 'update_actions.dart';

/// "Karmashala X is available": a strip above the shell, in the shape of the
/// session host's and the reconnecting one, while a GitHub release is on
/// offer. Starts the update checks after the first frame.
///
/// Mounted inside `home`, under the Navigator, so What's new and the install
/// confirmation can open. One tree whether or not the strip shows, so the
/// shell under it keeps its element.
class GitHubUpdateNotice extends ConsumerStatefulWidget {
  const GitHubUpdateNotice({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<GitHubUpdateNotice> createState() => _GitHubUpdateNoticeState();
}

class _GitHubUpdateNoticeState extends ConsumerState<GitHubUpdateNotice> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(githubUpdateProvider.notifier).start());
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(githubUpdateProvider);
    final skipped = ref.watch(
      settingsControllerProvider.select((s) => s.skippedUpdateVersion),
    );
    final shown = state.noticeVisible(skippedVersion: skipped);
    return Column(
      children: [
        // On a phone the strip takes the status bar's inset, and the shell's
        // own bar under it no longer does.
        if (shown) SafeArea(bottom: false, child: UpdateStrip(state: state)),
        Expanded(
          key: const ValueKey('update_notice_child'),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: shown,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

/// The strip itself: what is on offer or under way, and what can be done.
/// Its text and buttons wrap, so it fits a 360 px phone at large text.
class UpdateStrip extends ConsumerWidget {
  const UpdateStrip({required this.state, super.key});

  final GitHubUpdateState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final fore = scheme.onSecondaryContainer;
    final controller = ref.read(githubUpdateProvider.notifier);
    final status = state.status;
    final release = state.release;
    if (release == null) return const SizedBox.shrink();
    final version = release.versionText;
    final buttonStyle = TextButton.styleFrom(foregroundColor: fore);

    Widget button(String key, String label, VoidCallback? onPressed) =>
        TextButton(
          key: ValueKey('update_notice_$key'),
          style: buttonStyle,
          onPressed: onPressed,
          child: Text(label),
        );

    final whatsNew = button(
      'whats_new',
      "What's new",
      () => unawaited(showReleaseNotes(context, ref, release)),
    );
    final later = button('later', 'Later', controller.later);

    final (String text, List<Widget> actions) = switch (status) {
      UpdateAvailable(:final plan) => (
        'Karmashala $version is available',
        [
          button(
            'update',
            updateActionLabel(plan),
            () => unawaited(controller.update()),
          ),
          whatsNew,
          button('skip', 'Skip this version', controller.skip),
          later,
        ],
      ),
      final UpdateDownloading downloading => (
        'Downloading Karmashala $version'
            '${downloading.fraction == null ? '…' : ' · ${(downloading.fraction! * 100).round()}%'}',
        [later],
      ),
      final UpdateReady ready => (
        readyText(ready),
        [
          button(
            'install',
            readyActionLabel(ready),
            () => unawaited(finishUpdate(context, ref, ready)),
          ),
          whatsNew,
          later,
        ],
      ),
      UpdateHandedOff(:final message) => (message, [later]),
      UpdateFailed(:final message) => (
        message,
        [
          button('retry', 'Try again', () => unawaited(controller.update())),
          later,
        ],
      ),
      _ => ('Karmashala $version is available', [later]),
    };

    final downloading = status is UpdateDownloading ? status : null;
    return Material(
      key: const ValueKey('update_notice'),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.xs,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  status is UpdateFailed
                      ? AppIcons.warningCircle
                      : AppIcons.downloadSimple,
                  size: Chrome.icon,
                  color: fore,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: Insets.xs,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: Insets.sm),
                        child: Text(
                          text,
                          key: const ValueKey('update_notice_text'),
                          style: textTheme.labelMedium?.copyWith(color: fore),
                        ),
                      ),
                      ...actions,
                    ],
                  ),
                ),
              ],
            ),
            if (downloading != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.xs),
                child: LinearProgressIndicator(
                  value: downloading.fraction,
                  color: fore,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
