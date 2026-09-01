import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../application/evidence_reader.dart';
import '../application/verification_providers.dart';
import '../application/verification_service.dart';
import '../domain/verification_artifact.dart';
import '../domain/verdict_attribution.dart';
import '../domain/verification_run.dart';
import '../domain/verification_step.dart';
import 'attribution_mark.dart';
import 'review_action.dart';

/// The verification pane: the runs that have been recorded, and what each one
/// proved.
///
/// A list until a run is opened, then that run — master/detail *in place*,
/// because the panel is 360 px wide and a two-column split at that width is two
/// unreadable columns. The list is the index; the run is the evidence.
class VerificationPane extends ConsumerWidget {
  const VerificationPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The artifact root has to exist before anything can be read from disk.
    final ready = ref.watch(verificationRootReadyProvider);
    return ready.when(
      loading: () => const Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (error, _) =>
          PanePlaceholder(message: 'Verification runs are unavailable: $error'),
      data: (_) {
        final selected = ref.watch(selectedVerificationRunProvider);
        if (selected == null) return const _RunList();
        final run = ref.watch(verificationRunProvider(selected));
        if (run == null) {
          // The run was deleted from under us; fall back to the list rather
          // than showing an empty detail view.
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
    final runs = ref.watch(verificationRunsProvider);
    final active = ref.watch(verificationServiceProvider).activeRun;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(
          title: runs.isEmpty
              ? 'No runs'
              : '${runs.length} run${runs.length == 1 ? '' : 's'}',
          trailing: active == null
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Dot(colour: theme.colorScheme.primary),
                    const SizedBox(width: Insets.xs),
                    Text('recording', style: theme.textTheme.labelSmall),
                  ],
                ),
        ),
        const Divider(height: 1),
        if (runs.isEmpty)
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
            Row(
              children: [
                _VerdictChip(run: run),
                const SizedBox(width: Insets.xs),
                AttributionMark(attribution: run.attribution),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    run.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${run.target.kind.label} · ${run.target.label}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
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
        _Toolbar(
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
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(Insets.md),
            children: [
              Row(
                children: [
                  _VerdictChip(run: run),
                  const SizedBox(width: Insets.xs),
                  AttributionMark(attribution: run.attribution),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      run.reason ?? 'No reason was recorded.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
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
              // Directly under who graded it, because that row is where a
              // self-graded pass becomes legible and this is the answer to it.
              if (run.sessionId case final sessionId?) ...[
                const SizedBox(height: Insets.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ReviewAction(sessionId: sessionId),
                ),
              ],
              const SizedBox(height: Insets.lg),
              _SectionTitle('Steps (${run.steps.length})'),
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
                _SectionTitle('Screenshots (${images.length})'),
                for (final image in images)
                  _ScreenshotTile(run: run, artifact: image),
              ],
              if (files.isNotEmpty) ...[
                const SizedBox(height: Insets.lg),
                _SectionTitle('Evidence (${files.length})'),
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

/// Export, reveal, delete. Deliberately in the header rather than at the bottom
/// of a long scroll — they are about the run, not about what you have read.
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this run?'),
        content: Text(
          'Its steps, screenshots and log slice are deleted from disk. '
          '"${widget.run.title}" cannot be recovered.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
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
          child: SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
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
    // A deleted session must not blank the row: the evidence outlives it, and
    // the id is still the truth about what produced this run.
    final session = ref.read(sessionDaoProvider).getById(id);
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

/// Who produced the verdict, and whether that was the session under test.
///
/// The row that makes a self-graded pass legible as one. Derived from the two
/// ids every time it paints, so it cannot disagree with them.
class _VerifierRow extends ConsumerWidget {
  const _VerifierRow({required this.run});

  final VerificationRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = run.producedBySessionId;
    if (id == null) {
      return _MetaRow(
        label: 'Verifier',
        value: '${VerdictAttribution.notRecorded.label} — nobody said who '
            'graded this run',
      );
    }
    final session = ref.read(sessionDaoProvider).getById(id);
    return _MetaRow(
      label: 'Verifier',
      value: '${session?.title ?? id} · ${run.attribution.label}',
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.run, required this.step});

  final VerificationRun run;
  final VerificationStep step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final files = run.artifacts
        .where((a) => a.stepOrdinal == step.ordinal)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${step.ordinal}',
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${step.kind.label}  ',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: step.ok
                              ? theme.colorScheme.onSurfaceVariant
                              : semantic.failure,
                        ),
                      ),
                      TextSpan(
                        text: step.summary,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (step.detail != null)
                  Text(
                    step.detail!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: step.ok
                          ? theme.colorScheme.onSurfaceVariant
                          : semantic.failure,
                    ),
                  ),
                if (files.isNotEmpty)
                  Text(
                    files.map((f) => f.relativePath).join('  '),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScreenshotTile extends ConsumerStatefulWidget {
  const _ScreenshotTile({required this.run, required this.artifact});

  final VerificationRun run;
  final VerificationArtifact artifact;

  @override
  ConsumerState<_ScreenshotTile> createState() => _ScreenshotTileState();
}

class _ScreenshotTileState extends ConsumerState<_ScreenshotTile> {
  /// Asked once per tile, not once per build: the pane rebuilds on scroll and
  /// on every session signal, and a stat per rebuild per screenshot is exactly
  /// the cost this was moved off the frame to avoid.
  late Future<bool> _present;

  String get _path =>
      p.join(widget.run.artifactDirectory, widget.artifact.relativePath);

  @override
  void initState() {
    super.initState();
    _present = ref.read(verificationEvidenceReaderProvider).exists(_path);
  }

  @override
  void didUpdateWidget(_ScreenshotTile old) {
    super.didUpdateWidget(old);
    if (old.run.artifactDirectory != widget.run.artifactDirectory ||
        old.artifact.relativePath != widget.artifact.relativePath) {
      _present = ref.read(verificationEvidenceReaderProvider).exists(_path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artifact = widget.artifact;
    final file = File(_path);
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${artifact.label} · ${artifact.sizeLabel}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: FutureBuilder<bool>(
              future: _present,
              builder: (context, snapshot) {
                // Nothing until the answer arrives — a tile that guessed
                // "missing" for a frame would flash the cleaned-up note over
                // evidence that is perfectly present.
                if (!snapshot.hasData) return const SizedBox.shrink();
                if (!snapshot.data!) {
                  return _MissingFile(path: artifact.relativePath);
                }
                return Image.file(
                  file,
                  fit: BoxFit.contain,
                  // A run's evidence is not worth an exception: a corrupt or
                  // half-written PNG shows as a note, not a red box.
                  errorBuilder: (context, _, _) =>
                      _MissingFile(path: artifact.relativePath),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MissingFile extends StatelessWidget {
  const _MissingFile({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Insets.sm),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Text(
        '$path is not on disk any more.',
        style: theme.textTheme.labelSmall,
      ),
    );
  }
}

class _FileTile extends ConsumerStatefulWidget {
  const _FileTile({required this.run, required this.artifact});

  final VerificationRun run;
  final VerificationArtifact artifact;

  @override
  ConsumerState<_FileTile> createState() => _FileTileState();
}

class _FileTileState extends ConsumerState<_FileTile> {
  /// How much of a file is shown inline. A logcat slice is capped at 400 lines
  /// when it is captured, so this is a backstop rather than the usual case.
  static const _maxCharacters = 200 * 1024;

  bool _open = false;
  String? _text;

  /// Which open this text belongs to, so a slow read that lands after the user
  /// has closed the tile — or opened it again — cannot overwrite the newer one.
  int _generation = 0;

  /// **Read off the frame.** This used to be `existsSync()` plus
  /// `readAsStringSync()`, on the UI isolate, for a whole artifact file — the
  /// comment defending it argued a few hundred kilobytes was cheap, which is
  /// true of the bytes and false of the wait: an artifact directory can be a
  /// `\\wsl.localhost` share, where the synchronous pair costs 1.19 ms against
  /// 0.07 ms locally before the file is even read, and a 200 KB read on top of
  /// it is several frames of a frozen window. The state machine it was trading
  /// away is the three lines below.
  Future<void> _toggle() async {
    if (_open) {
      setState(() => _open = false);
      return;
    }
    final generation = ++_generation;
    setState(() {
      _open = true;
      _text = null;
    });
    final path = p.join(
      widget.run.artifactDirectory,
      widget.artifact.relativePath,
    );
    String body;
    try {
      final whole = await ref
          .read(verificationEvidenceReaderProvider)
          .read(path);
      if (whole == null) {
        body = '${widget.artifact.relativePath} is not on disk any more.';
      } else {
        body = whole.length <= _maxCharacters
            ? whole
            : '${whole.substring(0, _maxCharacters)}\n\n… truncated; the whole '
                  'file is ${widget.artifact.relativePath}.';
      }
    } on Object catch (error) {
      body = 'Could not read it: $error';
    }
    if (!mounted || generation != _generation) return;
    setState(() => _text = body);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Insets.xs),
            child: Row(
              children: [
                Icon(
                  _open ? AppIcons.caretDown : AppIcons.caretRight,
                  size: Chrome.iconSmall,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: Text(
                    '${widget.artifact.kind.label} — ${widget.artifact.label}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Text(
                  widget.artifact.sizeLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: Insets.sm),
            padding: const EdgeInsets.all(Insets.sm),
            color: theme.colorScheme.surfaceContainerHigh,
            child: SelectableText(
              _text ?? 'Reading ${widget.artifact.relativePath}…',
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'],
              ),
            ),
          ),
      ],
    );
  }
}

class _VerdictChip extends StatelessWidget {
  const _VerdictChip({required this.run});

  final VerificationRun run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final (colour, label) = switch (run.verdict) {
      VerificationVerdict.pass => (semantic.idle, 'PASS'),
      VerificationVerdict.fail => (semantic.failure, 'FAIL'),
      VerificationVerdict.inconclusive => (semantic.attention, '?'),
      null => (semantic.working, 'OPEN'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 1),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: colour,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.title, this.leading, this.trailing});

  final String title;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: Chrome.tabStrip,
      child: Row(
        children: [
          if (leading != null) leading! else const SizedBox(width: Insets.md),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
          ?trailing,
          const SizedBox(width: Insets.xs),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Insets.sm),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.colour});

  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
  );
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
