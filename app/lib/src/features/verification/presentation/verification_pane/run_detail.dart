// One run's detail: actions, its session and its verifier.

part of '../verification_pane.dart';

class _RunDetail extends ConsumerWidget {
  const _RunDetail({required this.run});

  final VerificationRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final images = run.artifacts.where((a) => a.kind.isImage).toList();
    final files = run.artifacts.where((a) => !a.kind.isImage).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneSubToolbar(
          leading: IconButton(
            iconSize: Chrome.icon,
            visualDensity: VisualDensity.compact,
            tooltip: 'Back to the runs',
            icon: const Icon(AppIcons.arrowLeft),
            onPressed: () =>
                ref.read(selectedVerificationRunProvider.notifier).select(null),
          ),
          title: run.title,
          trailing: _RunActions(run: run),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(Insets.md),
            children: [
              _VerdictLine(
                run: run,
                child: Text(
                  run.reason ?? 'No reason was recorded.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: Insets.md),
              _MetaRow(label: 'Target', value: run.target.label),
              if (run.target.packageName != null)
                _MetaRow(label: 'Package', value: run.target.packageName!),
              _MetaRow(
                label: 'Started',
                value:
                    '${run.startedAt.toLocal()}'
                    '${run.duration == null ? ' (still recording)' : ' · ${formatRunDuration(run.duration!)}'}',
              ),
              _SessionRow(run: run),
              _VerifierRow(run: run),
              // Directly under who graded it: that row is the question.
              if (run.sessionId case final sessionId?) ...[
                const SizedBox(height: Insets.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ReviewAction(sessionId: sessionId),
                ),
              ],
              const SizedBox(height: Insets.lg),
              EyebrowLabel(
                'Steps (${run.steps.length})',
                padding: _sectionTitlePadding,
              ),
              if (run.steps.isEmpty)
                Text(
                  'Nothing was recorded.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                for (final step in run.steps) _StepTile(run: run, step: step),
              if (images.isNotEmpty) ...[
                const SizedBox(height: Insets.lg),
                EyebrowLabel(
                  'Screenshots (${images.length})',
                  padding: _sectionTitlePadding,
                ),
                for (final image in images)
                  _ScreenshotTile(run: run, artifact: image),
              ],
              if (files.isNotEmpty) ...[
                const SizedBox(height: Insets.lg),
                EyebrowLabel(
                  'Evidence (${files.length})',
                  padding: _sectionTitlePadding,
                ),
                for (final file in files) _FileTile(run: run, artifact: file),
              ],
              const SizedBox(height: Insets.xl),
            ],
          ),
        ),
      ],
    );
  }
}

/// Export, reveal, delete — in the header, because they are about the run.
class _RunActions extends ConsumerStatefulWidget {
  const _RunActions({required this.run});

  final VerificationRun run;

  @override
  ConsumerState<_RunActions> createState() => _RunActionsState();
}

class _RunActionsState extends ConsumerState<_RunActions> {
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    String message;
    try {
      final path = await ref
          .read(verificationServiceProvider)
          .export(widget.run.id);
      await Clipboard.setData(ClipboardData(text: path));
      message = 'Report written and its path copied: $path';
    } on VerificationException catch (error) {
      message = error.message;
    } on Object catch (error) {
      message = 'Could not write the report: $error';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _delete() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete this run?',
      message:
          'Its steps, screenshots and log slice are deleted from disk. '
          '"${widget.run.title}" cannot be recovered.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await ref.read(verificationServiceProvider).delete(widget.run.id);
    if (!mounted) return;
    ref.read(selectedVerificationRunProvider.notifier).select(null);
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (_busy)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Insets.sm),
          child: InlineSpinner(semanticsLabel: 'Writing the report'),
        )
      else
        IconButton(
          iconSize: Chrome.icon,
          visualDensity: VisualDensity.compact,
          tooltip: 'Write the markdown report and copy its path',
          icon: const Icon(AppIcons.article),
          onPressed: _export,
        ),
      IconButton(
        iconSize: Chrome.icon,
        visualDensity: VisualDensity.compact,
        tooltip: 'Copy the artifact folder',
        icon: const Icon(AppIcons.copy),
        onPressed: () => Clipboard.setData(
          ClipboardData(text: widget.run.artifactDirectory),
        ),
      ),
      IconButton(
        iconSize: Chrome.icon,
        visualDensity: VisualDensity.compact,
        tooltip: 'Delete this run',
        icon: const Icon(AppIcons.trash),
        onPressed: _delete,
      ),
    ],
  );
}

/// The session a run belongs to, by name — and a way to go and read it.
class _SessionRow extends ConsumerWidget {
  const _SessionRow({required this.run});

  final VerificationRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = run.sessionId;
    if (id == null) {
      return const _MetaRow(label: 'Session', value: 'not attached to one');
    }
    // A deleted session must not blank the row: the evidence outlives it.
    // Watched through its signal, so a rename reaches this row.
    ref.watchSession(id);
    final session = ref.read(sessionsDataProvider).getById(id);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _MetaRow(
            label: 'Session',
            value: session?.title ?? '$id (no longer in the list)',
          ),
        ),
        if (session != null)
          TextButton(
            onPressed: () =>
                ref.read(selectedSessionIdProvider.notifier).select(id),
            child: const Text('Open'),
          ),
      ],
    );
  }
}

/// Who produced the verdict — derived from the two ids on every paint.
class _VerifierRow extends ConsumerWidget {
  const _VerifierRow({required this.run});

  final VerificationRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = run.producedBySessionId;
    if (id == null) {
      return _MetaRow(
        label: 'Verifier',
        value:
            '${VerdictAttribution.notRecorded.label} — nobody said who '
            'graded this run',
      );
    }
    ref.watchSession(id);
    final session = ref.read(sessionsDataProvider).getById(id);
    return _MetaRow(
      label: 'Verifier',
      value: '${session?.title ?? id} · ${run.attribution.label}',
    );
  }
}
