import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import 'package:karmashala_media/media.dart';
import '../../../core/media/video_support_provider.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/local_environment.dart';
import '../application/terminal_recording_controller.dart';
import '../data/cast_frame_renderer.dart';
import 'terminal_panel.dart';

/// Shows what a finished recording is, where it went, and what can be made
/// from it.
Future<void> showRecordingSavedDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => const _RecordingSavedDialog(),
);

class _RecordingSavedDialog extends ConsumerWidget {
  const _RecordingSavedDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(terminalRecordingProvider);
    final saved = state.saved;
    // The pane's own recording was put away while this was open — nothing left
    // to talk about.
    if (saved == null) {
      return const AlertDialog(content: SizedBox.shrink());
    }
    final export = state.export;
    final duration = saved.cast.duration;

    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.stopCircle,
        title: saved.endedWithPane
            ? 'Pane closed — recording kept'
            : 'Recording stopped',
        subtitle:
            '${_seconds(duration)} · ${saved.cast.events.length} chunks · '
            '${saved.cast.columns}x${saved.cast.rows}',
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PathRow(path: saved.file.path, label: 'Recording'),
            const SizedBox(height: Insets.sm),
            Text(
              'The recording is the terminal output itself, so it can be '
              'rendered again at any size. It holds everything that was on '
              'screen — including anything secret that was printed there. '
              'Nothing was removed, and nothing can be: check it before you '
              'share it.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (saved.cast.truncated) ...[
              const SizedBox(height: Insets.sm),
              Text(
                'The recording reached its size limit and stops early. '
                'Everything up to that point is exactly what happened.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: Insets.md),
            const Divider(height: 1),
            const SizedBox(height: Insets.md),
            if (export == null)
              _FormatChoices(saved: saved)
            else
              _ExportProgress(export: export),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        Insets.lg,
        0,
        Insets.lg,
        Insets.md,
      ),
      actions: [
        if (export?.isRunning ?? false)
          TextButton(
            onPressed: ref.read(terminalRecordingProvider.notifier).cancelRender,
            child: const Text('Stop rendering'),
          ),
        FilledButton(
          autofocus: true,
          onPressed: () {
            ref.read(terminalRecordingProvider.notifier).dismiss();
            Navigator.of(context).pop();
          },
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// The formats on offer, and why one of them is not.
class _FormatChoices extends ConsumerWidget {
  const _FormatChoices({required this.saved});

  final SavedRecording saved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final terminalTheme = terminalThemeFor(theme, null);
    final support = ref.watch(videoSupportProvider);

    // Where the OS can write an MP4, the frame sequence has nothing left to
    // offer: it was only ever the way to reach one.
    final offered = <RecordingFormat>[
      RecordingFormat.gif,
      if (support.available)
        RecordingFormat.mp4
      else
        RecordingFormat.pngSequence,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Make a video of it', style: theme.textTheme.titleSmall),
        const SizedBox(height: Insets.sm),
        if (!support.available) ...[
          Text(
            support.detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.tertiary,
            ),
          ),
          const SizedBox(height: Insets.sm),
        ],
        for (final format in offered) ...[
          _FormatRow(
            saved: saved,
            format: format,
            style: TerminalRecordingController.styleFor(
              format: format,
              cast: saved.cast,
              theme: terminalTheme,
            ),
          ),
          const SizedBox(height: Insets.sm),
        ],
      ],
    );
  }
}

class _FormatRow extends ConsumerWidget {
  const _FormatRow({
    required this.saved,
    required this.format,
    required this.style,
  });

  final SavedRecording saved;
  final RecordingFormat format;
  final CastFrameStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final note = format.needsToolNote;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: OutlinedButton(
            onPressed: () => ref
                .read(terminalRecordingProvider.notifier)
                .render(saved, format: format, style: style),
            child: Text(switch (format) {
              RecordingFormat.gif => 'Render GIF',
              RecordingFormat.mp4 => 'Render MP4',
              RecordingFormat.pngSequence => 'Render frames',
            }),
          ),
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          child: Text(
            note ??
                switch (format) {
                  RecordingFormat.gif =>
                    'Plays anywhere as it is. '
                        '${style.width}x${style.height}, 256 colours.',
                  RecordingFormat.mp4 =>
                    'A finished video, nothing to run afterwards. '
                        '${style.width}x${style.height}, full colour.',
                  RecordingFormat.pngSequence => '',
                },
            style: theme.textTheme.bodySmall?.copyWith(
              color: note == null
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.tertiary,
            ),
          ),
        ),
      ],
    );
  }
}

class _ExportProgress extends ConsumerWidget {
  const _ExportProgress({required this.export});

  final RecordingExport export;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final error = export.error;
    if (error != null) {
      return Text(
        'Rendering failed: $error',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final result = export.result;
    if (result == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rendering ${export.format.label} — '
            'frame ${export.rendered} of ${export.total}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.sm),
          LinearProgressIndicator(value: export.progress),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PathRow(
          path: result.path,
          label: result.needsExternalTool
              ? '${result.frames} frames'
              : export.format.label,
        ),
        if (!result.needsExternalTool) ...[
          const SizedBox(height: Insets.sm),
          Text(
            '${result.frames} frames, ${_size(result.bytes)}. '
            'This is a finished ${export.format.extension.toUpperCase()} — '
            'open it in any player.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (result.externalCommand case final command?) ...[
          const SizedBox(height: Insets.sm),
          Text(
            'These are frames, not a video. Karmashala does not bundle '
            '${result.externalTool}; run this to get the MP4 — it is also '
            'saved as render-mp4.txt beside the frames.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.tertiary,
            ),
          ),
          const SizedBox(height: Insets.sm),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  command,
                  maxLines: 3,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: kMonoFamily,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copy the command',
                icon: const Icon(AppIcons.copy, size: Chrome.icon),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: command)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A path, said out loud, with the way to go and look at it.
class _PathRow extends ConsumerWidget {
  const _PathRow({required this.path, required this.label});

  final String path;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.labelSmall),
              SelectableText(
                path,
                maxLines: 2,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Show in file manager',
          icon: const Icon(AppIcons.folderOpen, size: Chrome.icon),
          onPressed: () async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            final outcome = await ref
                .read(revealInFileManagerProvider)
                .reveal(
                  EnvironmentPath(
                    environmentId: localHostEnvironmentId,
                    path: path,
                  ),
                  select: true,
                );
            if (outcome.ok || messenger == null) return;
            messenger.showSnackBar(SnackBar(content: Text(outcome.error!)));
          },
        ),
      ],
    );
  }
}

String _size(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(0)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String _seconds(Duration duration) {
  final total = duration.inMilliseconds / 1000;
  if (total < 60) return '${total.toStringAsFixed(1)}s';
  final minutes = duration.inMinutes;
  return '${minutes}m ${duration.inSeconds - minutes * 60}s';
}
