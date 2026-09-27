import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/device_ports.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/process.dart';
import '../application/device_providers.dart';
import '../application/device_recording_controller.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'device_recording_indicator.dart';

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
    return RecordingClock(
      recording: recording,
      builder: (context, now) {
        final elapsed = formatRecordingElapsed(
          now.difference(recording.startedAt),
        );
        return _Surface(
          // The red dot every recorder shows, pulsing while frames arrive —
          // a plain circle read as a radio button, not as "recording".
          leading: paused == null
              ? RecordingDot(
                  key: const Key('device-recording-dot'),
                  size: Chrome.icon,
                  semanticLabel: 'Recording',
                )
              : Icon(
                  AppIcons.pauseCircle,
                  key: const Key('device-recording-paused'),
                  size: Chrome.icon,
                  color: theme.colorScheme.onSurfaceVariant,
                  semanticLabel: 'Recording paused',
                ),
          title: paused == null
              ? 'Recording ${recording.target.label}'
              : 'Recording ${recording.target.label} — paused',
          detail: paused ?? recording.path,
          secondDetail: paused == null ? null : recording.path,
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.sm),
              child: Text(
                elapsed,
                key: const Key('device-recording-elapsed'),
                style: theme.textTheme.labelLarge?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            TextButton.icon(
              key: const Key('device-recording-stop'),
              onPressed: () =>
                  ref.read(deviceRecordingProvider.notifier).stop(),
              icon: const Icon(AppIcons.stopFill, size: Chrome.icon),
              label: const Text('Stop recording'),
            ),
          ],
        );
      },
    );
  }
}

class _Finished extends ConsumerWidget {
  const _Finished(this.outcome);

  final DeviceRecordingOutcome outcome;

  Future<void> _reveal(BuildContext context, WidgetRef ref) async {
    final path = outcome.path;
    if (path == null) return;
    final failure = await ref
        .read(devicePathRevealerProvider)
        .reveal(
          EnvironmentPath(environmentId: localHostEnvironmentId, path: path),
          select: true,
        );
    if (!context.mounted || failure == null) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(failure)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final failed = outcome.result == DeviceRecordingResult.failed;
    final path = outcome.path;
    final canReveal =
        path != null &&
        ref
            .watch(devicePathRevealerProvider)
            .canReveal(
              EnvironmentPath(
                environmentId: localHostEnvironmentId,
                path: path,
              ),
            );
    return _Surface(
      leading: Icon(
        failed
            ? AppIcons.warningCircle
            : outcome.result == DeviceRecordingResult.empty
            ? AppIcons.info
            : AppIcons.checkCircle,
        size: Chrome.icon,
        color: failed
            ? SemanticColors.of(context).failure
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: 'Recording of ${outcome.deviceId}',
      detail: outcome.message,
      actions: [
        if (canReveal)
          TextButton.icon(
            key: const Key('device-recording-reveal'),
            onPressed: () => _reveal(context, ref),
            icon: const Icon(AppIcons.folderOpen, size: Chrome.icon),
            label: const Text('Show file'),
          ),
        IconButton(
          key: const Key('device-recording-dismiss'),
          tooltip: 'Dismiss',
          onPressed: () => ref.read(deviceRecordingProvider.notifier).dismiss(),
          icon: const Icon(AppIcons.x, size: Chrome.icon),
        ),
      ],
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({
    required this.leading,
    required this.title,
    required this.detail,
    required this.actions,
    this.secondDetail,
  });

  /// The state glyph at the start of the line, sized [Chrome.icon].
  final Widget leading;
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
          Padding(padding: const EdgeInsets.only(top: 2), child: leading),
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
