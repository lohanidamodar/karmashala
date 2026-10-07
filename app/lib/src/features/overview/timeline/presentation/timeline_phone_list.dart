import 'package:flutter/material.dart';
import 'package:karmashala_ui/tokens.dart';

import '../domain/timeline_model.dart';
import 'timeline_chart.dart' show describeSession;
import 'timeline_painters.dart';

/// The timeline on a phone: the range's sessions as a list, newest first,
/// each with a compact bar across the whole range.
class TimelinePhoneList extends StatelessWidget {
  const TimelinePhoneList({
    required this.model,
    required this.now,
    required this.onOpen,
    super.key,
  });

  final TimelineModel model;
  final DateTime now;
  final void Function(TimelineSession session) onOpen;

  @override
  Widget build(BuildContext context) {
    final sessions = [
      for (final project in model.projects) ...project.sessions,
    ]..sort((a, b) => b.start.compareTo(a.start));
    final palette = TimelinePalette.of(context);
    final viewport = TimelineViewport(start: model.from, end: model.to);
    return ListView.separated(
      key: const ValueKey('timeline-phone-list'),
      itemCount: sessions.length,
      separatorBuilder: (_, _) => const Divider(height: Insets.hair),
      itemBuilder: (context, index) {
        final session = sessions[index];
        return _PhoneRow(
          key: ValueKey('timeline-phone-${session.id}'),
          session: session,
          viewport: viewport,
          palette: palette,
          now: now,
          onOpen: session.deleted ? null : () => onOpen(session),
        );
      },
    );
  }
}

class _PhoneRow extends StatelessWidget {
  const _PhoneRow({
    required this.session,
    required this.viewport,
    required this.palette,
    required this.now,
    required this.onOpen,
    super.key,
  });

  final TimelineSession session;
  final TimelineViewport viewport;
  final TimelinePalette palette;
  final DateTime now;
  final VoidCallback? onOpen;

  String _clock(DateTime at) {
    final local = at.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waited = session.waitingTotal;
    final subtitle = [
      session.projectName,
      session.startOnly
          ? 'started ${_clock(session.start)}'
          : '${_clock(session.start)}–'
                '${session.live ? 'now' : _clock(session.end)}',
      if (waited > Duration.zero) 'waited ${describeDuration(waited)}',
    ].join(' · ');
    return Semantics(
      button: onOpen != null,
      label: describeSession(session),
      excludeSemantics: true,
      onTap: onOpen,
      child: InkWell(
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Touch.target),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg,
              vertical: Insets.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontStyle: session.backfilled ? FontStyle.italic : null,
                    decoration: session.deleted
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                const SizedBox(height: Insets.xxs),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: Insets.xs),
                SizedBox(
                  height: Insets.sm + Insets.xxs,
                  child: CustomPaint(
                    painter: TimelineLanePainter(
                      session: session,
                      viewport: viewport,
                      palette: palette,
                      now: now,
                      compact: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
