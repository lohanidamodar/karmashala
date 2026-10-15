import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../domain/timeline_model.dart';
import 'timeline_avatar.dart';
import 'timeline_painters.dart';

String _clock(DateTime at) {
  final local = at.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

String _capital(String words) =>
    words.isEmpty ? words : words[0].toUpperCase() + words.substring(1);

/// **What one session did**, beside the lanes on a wide screen and in a
/// sheet on a narrow one: what it is doing now, how long it worked and kept
/// the owner waiting, every span with what was asked, what it started, and
/// the way into it.
class TimelineDetail extends StatelessWidget {
  const TimelineDetail({
    required this.session,
    required this.children,
    required this.onOpen,
    required this.onSelect,
    this.agentName,
    this.onClose,
    this.parent,
    super.key,
  });

  final TimelineSession session;

  /// The sub-sessions it started in the range, and the one that started it.
  final List<TimelineSession> children;
  final TimelineSession? parent;

  /// Opens the session's tab; null hides the button (a deleted session).
  final VoidCallback? onOpen;
  final void Function(TimelineSession session) onSelect;
  final String? agentName;

  /// Closes a docked pane; null in a sheet, which closes itself.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = TimelinePalette.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final state = session.stateNow;
    final now = switch (state) {
      TimelineState.waiting => 'Waiting on you',
      TimelineState.working => 'Working',
      TimelineState.ready => 'Ready',
      TimelineState.paused => 'Paused at a usage limit',
      null => session.deleted ? 'Deleted' : 'Ended',
    };
    final since = state == null || session.spans.isEmpty
        ? ''
        : ' · ${describeDuration(session.spans.last.duration)}';
    final facts = <(String, String)>[
      ('Worked', describeDuration(session.workingTotal)),
      ('Waited on you', describeDuration(session.waitingTotal)),
      ('Turns', '${session.ticks.length}'),
    ];
    final where = [
      session.projectName,
      ?(agentName ?? session.agent),
      ?session.machine,
    ].join(' · ');
    final spans = session.spans.reversed.toList();
    return Column(
      key: ValueKey('timeline-detail-${session.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.md,
            Insets.sm,
            Insets.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TimelineAvatar(session: session, size: Chrome.stackAvatar),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(where, style: muted),
                    const SizedBox(height: Insets.xs),
                    Text(
                      '$now$since',
                      key: const ValueKey('timeline-detail-state'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: state == null ? muted?.color : palette.of(state),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (onClose case final close?)
                IconButton(
                  key: const ValueKey('timeline-detail-close'),
                  tooltip: 'Close',
                  icon: const Icon(AppIcons.x),
                  onPressed: close,
                ),
            ],
          ),
        ),
        const Divider(height: Insets.hair),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: Insets.sm),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                child: Wrap(
                  spacing: Insets.xl,
                  runSpacing: Insets.sm,
                  children: [
                    for (final (label, value) in facts)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(label, style: muted),
                          Text(
                            value,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              _Heading('What it did', muted: muted),
              for (final span in spans)
                _SpanRow(span: span, palette: palette, muted: muted),
              if (parent case final parent?) ...[
                _Heading('Started by', muted: muted),
                _Relative(session: parent, onSelect: onSelect),
              ],
              if (children.isNotEmpty) ...[
                _Heading(
                  'Sub-sessions · '
                  '${children.where((c) => !c.live).length} done of '
                  '${children.length}',
                  muted: muted,
                ),
                for (final child in children)
                  _Relative(session: child, onSelect: onSelect),
              ],
            ],
          ),
        ),
        if (onOpen case final open?) ...[
          const Divider(height: Insets.hair),
          Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: FilledButton(
              key: const ValueKey('timeline-detail-open'),
              onPressed: open,
              child: const Text('Open session'),
            ),
          ),
        ],
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {required this.muted});

  final String text;
  final TextStyle? muted;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, 0),
    child: Text(text.toUpperCase(), style: Chrome.groupLabel.merge(muted)),
  );
}

class _SpanRow extends StatelessWidget {
  const _SpanRow({
    required this.span,
    required this.palette,
    required this.muted,
  });

  final TimelineSpan span;
  final TimelinePalette palette;
  final TextStyle? muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: SizedBox(
              width: Insets.lg,
              height: Chrome.timelineSubBar,
              child: CustomPaint(
                painter: TimelineSwatchPainter(
                  state: span.state,
                  palette: palette,
                  inferred: span.approximate || span.backfilled,
                ),
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              _capital(describeSpan(span)),
              style: theme.textTheme.bodySmall?.copyWith(
                color: span.state == TimelineState.waiting
                    ? palette.waiting
                    : null,
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          Text('${_clock(span.from)}–${_clock(span.to)}', style: muted),
        ],
      ),
    );
  }
}

class _Relative extends StatelessWidget {
  const _Relative({required this.session, required this.onSelect});

  final TimelineSession session;
  final void Function(TimelineSession session) onSelect;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey('timeline-detail-relative-${session.id}'),
    dense: true,
    leading: TimelineAvatar(session: session, size: Chrome.miniAvatar),
    title: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis),
    onTap: () => onSelect(session),
  );
}
