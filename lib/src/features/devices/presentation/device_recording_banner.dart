import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/process.dart';
import '../application/device_providers.dart';
import '../application/device_recording_controller.dart';
import 'package:karmashala_devices/devices.dart';

/// The one thing on screen that says a recording is running: it reads
/// [deviceRecordingProvider], which outlives the pane a switch unmounts.
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

  /// Why nothing is being captured, in terms the user can act on: a pane they
  /// switched away from comes back by itself, a device that went does not.
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
      // The attention colour rather than the error colour: a recording in
      // progress is something to remember, not something that went wrong.
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
                // Selectable: the point of the sentence is a path to paste.
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
