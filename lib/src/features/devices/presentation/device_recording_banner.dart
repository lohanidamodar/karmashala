import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import 'package:agent_cli/process.dart';
import '../application/device_providers.dart';
import '../application/device_recording_controller.dart';
import 'package:karmashala_devices/devices.dart';

/// The one thing on screen that says a recording is running.
///
/// A recording is a long-lived side effect with a file at the end of it, so it
/// cannot be represented by a button that looks pressed: the pane it was
/// started from is unmounted every time the side panel switches surface. This
/// reads [deviceRecordingProvider], which outlives that, and it is also where
/// the outcome is read — a recording that ended while the user was elsewhere is
/// still waiting to be told about when they come back.
class DeviceRecordingBanner extends ConsumerWidget {
  const DeviceRecordingBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(deviceRecordingProvider);
    return switch (state) {
      DeviceRecordingActive() => _Running(state),
      DeviceRecordingIdle(:final last?) => _Finished(last),
      DeviceRecordingIdle() => const SizedBox.shrink(),
    };
  }
}

class _Running extends ConsumerWidget {
  const _Running(this.recording);

  final DeviceRecordingActive recording;

  /// Why nothing is being captured, in the terms the user can act on.
  ///
  /// Two different situations wearing the same missing frame stream: a pane
  /// they switched away from, which comes back by itself, and a device that has
  /// gone, which does not. Naming the wrong one would either invite them to
  /// wait for nothing or throw away a recording that was about to resume.
  String? _paused(WidgetRef ref) {
    if (recording.receiving) return null;
    if (recording.target.platform != DevicePlatform.android) {
      return 'Paused — the recording has no source.';
    }
    final devices = ref.watch(devicesProvider);
    final known = devices.asData?.value;
    if (known == null) return 'Paused — looking for ${recording.target.id}.';
    final still = known
        .where((d) => d.serial == recording.target.id)
        .firstOrNull;
    if (still == null) {
      return 'Paused — ${recording.target.id} is no longer connected. Stop the '
          'recording to keep what was captured.';
    }
    if (!still.isReady) {
      return 'Paused — ${recording.target.id} is ${still.state.name}. Stop the '
          'recording to keep what was captured.';
    }
    return 'Paused — the live view is off, so nothing is being captured. It '
        'resumes when the live view comes back.';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final paused = _paused(ref);
    return _Surface(
      icon: paused == null ? AppIcons.circle : AppIcons.pauseCircle,
      // The one place in this app that paints a dot to mean "recording", and it
      // is the attention colour rather than the error colour: a recording in
      // progress is something the user is being asked to remember, not
      // something that went wrong.
      iconColour: paused == null
          ? SemanticColors.of(context).attention
          : theme.colorScheme.onSurfaceVariant,
      title: paused == null
          ? 'Recording ${recording.target.label}'
          : 'Recording ${recording.target.label} — paused',
      detail: paused ?? recording.path,
      secondDetail: paused == null ? null : recording.path,
      actions: [
        TextButton.icon(
          key: const Key('device-recording-stop'),
          onPressed: () =>
              ref.read(deviceRecordingProvider.notifier).stop(),
          icon: const Icon(AppIcons.stopCircle),
          label: const Text('Stop recording'),
        ),
      ],
    );
  }
}

class _Finished extends ConsumerWidget {
  const _Finished(this.outcome);

  final DeviceRecordingOutcome outcome;

  Future<void> _reveal(BuildContext context, WidgetRef ref) async {
    final path = outcome.path;
    if (path == null) return;
    final outcomeOfReveal = await ref
        .read(revealInFileManagerProvider)
        .reveal(
          EnvironmentPath(
            environmentId: localHostEnvironmentId,
            path: path,
          ),
          select: true,
        );
    if (!context.mounted || outcomeOfReveal.ok) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(outcomeOfReveal.error!)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final failed = outcome.result == DeviceRecordingResult.failed;
    final path = outcome.path;
    final canReveal =
        path != null &&
        ref
            .watch(revealInFileManagerProvider)
            .canReveal(
              EnvironmentPath(
                environmentId: localHostEnvironmentId,
                path: path,
              ),
            );
    return _Surface(
      icon: failed
          ? AppIcons.warningCircle
          : outcome.result == DeviceRecordingResult.empty
          ? AppIcons.info
          : AppIcons.checkCircle,
      iconColour: failed
          ? SemanticColors.of(context).failure
          : theme.colorScheme.onSurfaceVariant,
      title: 'Recording of ${outcome.deviceId}',
      detail: outcome.message,
      actions: [
        if (canReveal)
          TextButton.icon(
            key: const Key('device-recording-reveal'),
            onPressed: () => _reveal(context, ref),
            icon: const Icon(AppIcons.folderOpen),
            label: const Text('Show file'),
          ),
        IconButton(
          key: const Key('device-recording-dismiss'),
          tooltip: 'Dismiss',
          onPressed: () => ref.read(deviceRecordingProvider.notifier).dismiss(),
          icon: const Icon(AppIcons.x),
        ),
      ],
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({
    required this.icon,
    required this.iconColour,
    required this.title,
    required this.detail,
    required this.actions,
    this.secondDetail,
  });

  final IconData icon;
  final Color iconColour;
  final String title;
  final String detail;
  final String? secondDetail;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, color: iconColour),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.labelLarge),
                const SizedBox(height: 2),
                // Selectable, because the whole point of the sentence is a
                // path the user may want to paste into a player or an ffmpeg
                // command.
                SelectableText(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (secondDetail != null)
                  SelectableText(
                    secondDetail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: Insets.sm),
          Wrap(spacing: Insets.xs, children: actions),
        ],
      ),
    );
  }
}
