import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../application/evidence_reader.dart';
import '../application/verification_providers.dart';
import '../application/verification_service.dart';
import 'package:karmashala_verification/verification.dart';
import 'attribution_mark.dart';
import 'review_action.dart';
import 'verdict_appearance.dart';

part 'verification_pane/run_detail.dart';
part 'verification_pane/step_tiles.dart';
part 'verification_pane/verdict.dart';

/// The verification pane: the runs recorded, and what each proved. Master and
/// detail in place — a split at 360 px is two unreadable columns.
class VerificationPane extends ConsumerWidget {
  const VerificationPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The artifact root has to exist before anything can be read from disk.
    final ready = ref.watch(verificationRootReadyProvider);
    return ready.when(
      loading: () => const Center(
        child: InlineSpinner(
          size: InlineSpinnerSize.medium,
          semanticsLabel: 'Opening verification runs',
        ),
      ),
      error: (error, _) =>
          PanePlaceholder(message: 'Verification runs are unavailable: $error'),
      data: (_) {
        final selected = ref.watch(selectedVerificationRunProvider);
        if (selected == null) return const _RunList();
        final asked = ref.watch(verificationRunProvider(selected));
        final run = asked.value;
        if (run == null && asked.isLoading) {
          return const Center(
            child: InlineSpinner(
              size: InlineSpinnerSize.medium,
              semanticsLabel: 'Opening the run',
            ),
          );
        }
        if (run == null) {
          // The run was deleted from under us; fall back to the list.
          return const _RunList();
        }
        return _RunDetail(run: run);
      },
    );
  }
}

class _RunList extends ConsumerWidget {
  const _RunList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final asked = ref.watch(verificationRunsProvider);
    final runs = asked.value ?? const [];
    // Not read yet, or unreadable, is not "nothing verified yet".
    final loading = !asked.hasValue && !asked.hasError;
    final failed = !asked.hasValue && asked.hasError;
    // The server records every run; the newest still open is the one it is
    // recording (each row also says "still recording").
    final active = runs.isNotEmpty && runs.first.isOpen;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneSubToolbar(
          title: loading
              ? 'Reading runs…'
              : failed
              ? 'Runs unavailable'
              : runs.isEmpty
              ? 'No runs'
              : '${runs.length} run${runs.length == 1 ? '' : 's'}',
          trailing: !active
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(
                      child: StatusDot(
                        color: theme.colorScheme.primary,
                        label: 'Recording',
                      ),
                    ),
                    const SizedBox(width: Insets.xs),
                    Text('recording', style: theme.textTheme.labelSmall),
                  ],
                ),
        ),
        if (loading)
          const Expanded(
            child: Center(
              child: InlineSpinner(
                size: InlineSpinnerSize.medium,
                semanticsLabel: 'Reading verification runs',
              ),
            ),
          )
        else if (failed)
          Expanded(
            child: PanePlaceholder(
              message: 'Could not read the verification runs: ${asked.error}',
              icon: AppIcons.warningCircle,
            ),
          )
        else if (runs.isEmpty)
          const Expanded(
            child: PanePlaceholder(
              message:
                  'Nothing verified yet.\n\nAsk an agent to verify a change: '
                  'it starts a run, drives the page or the device, and finishes '
                  'with a verdict. The steps, the screenshots, the console '
                  'errors and the log slice end up here.',
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              itemCount: runs.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) => _RunRow(run: runs[index]),
            ),
          ),
      ],
    );
  }
}

class _RunRow extends ConsumerWidget {
  const _RunRow({required this.run});

  final VerificationRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final images = run.artifacts.where((a) => a.kind.isImage).length;
    return InkWell(
      onTap: () =>
          ref.read(selectedVerificationRunProvider.notifier).select(run.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _VerdictLine(
              run: run,
              child: Text(
                run.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: Insets.xxs),
            Text(
              '${run.target.kind.label} · ${run.target.label}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.xxs),
            Text(
              [
                '${run.steps.length} step${run.steps.length == 1 ? '' : 's'}',
                if (images > 0) '$images shot${images == 1 ? '' : 's'}',
                if (run.duration != null) formatRunDuration(run.duration!),
                formatWhen(run.startedAt),
              ].join(' · '),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "12s", "3m 04s" — the same wording the report uses.
String formatRunDuration(Duration value) => value.inMinutes >= 1
    ? '${value.inMinutes}m ${(value.inSeconds % 60).toString().padLeft(2, '0')}s'
    : '${value.inSeconds}s';

/// "just now", "4m ago", "yesterday" — a run's age, not its timestamp.
String formatWhen(DateTime at, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now().toUtc()).difference(at);
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
  if (elapsed.inHours < 24) return '${elapsed.inHours}h ago';
  if (elapsed.inDays == 1) return 'yesterday';
  return '${elapsed.inDays}d ago';
}
