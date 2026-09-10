import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_remote/remote.dart';
import '../../sessions/presentation/activity_strip.dart';
import '../application/companion_providers.dart';

/// What this session is doing right now, above the composer, from the desktop's
/// own `sessionActivityFrom`; draws nothing before the host has answered.
class CompanionActivityStrip extends ConsumerStatefulWidget {
  const CompanionActivityStrip({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<CompanionActivityStrip> createState() =>
      _CompanionActivityStripState();
}

class _CompanionActivityStripState
    extends ConsumerState<CompanionActivityStrip> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    _tick = null;
    super.dispose();
  }

  void _startTicking() {
    _tick ??= Timer.periodic(kActivityTickInterval, (_) => setState(() {}));
  }

  void _stopTicking() {
    _tick?.cancel();
    _tick = null;
  }

  @override
  Widget build(BuildContext context) {
    final activity = ref.watch(companionActivityProvider(widget.sessionId));
    final reading = activity.asData?.value;
    if (reading == null || !reading.known) {
      // Nothing heard from the desktop yet: not a claim of any kind.
      _stopTicking();
      return const SizedBox.shrink();
    }

    final refused = reading.refused;
    if (refused != null) {
      _stopTicking();
      return _QuietLine(icon: AppIcons.info, text: refused);
    }
    if (reading.calls.isEmpty) {
      _stopTicking();
      final absence = reading.absence;
      return absence == null
          ? const SizedBox.shrink()
          : _QuietLine(
              icon: AppIcons.question,
              text: companionActivityAbsenceSentence(absence),
            );
    }

    _startTicking();
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final colour = SemanticColors.of(context).working;
    // The host's own reading plus what has passed here since, never one
    // machine's instant minus another's.
    final since = DateTime.now().difference(reading.at);
    final longest = reading.calls
        .map((call) => call.elapsed)
        .reduce((a, b) => a > b ? a : b);
    final subagents = reading.calls.where((call) => call.subagent).length;
    final single = reading.calls.length == 1 ? reading.calls.first : null;
    final elapsed = formatElapsed(longest + (since.isNegative ? Duration.zero : since));

    return Semantics(
      label: single != null
          ? '${single.subagent ? 'Subagent' : 'Tool'} running: '
                '${single.summary}, $elapsed'
          : '${describeRunningMix(reading.calls.length, subagents)}, '
                'oldest $elapsed',
      child: Container(
        margin: EdgeInsets.fromLTRB(density.padX, 0, density.padX, Insets.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(
              subagents > 0 ? AppIcons.robot : AppIcons.circleHalf,
              size: Chrome.iconSmall,
              color: colour,
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Text(
                single?.summary ??
                    describeRunningMix(reading.calls.length, subagents),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MonoStyles.small.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(width: Insets.sm),
            Text(
              single != null ? elapsed : 'oldest $elapsed',
              style: theme.textTheme.labelSmall?.copyWith(color: colour),
            ),
          ],
        ),
      ),
    );
  }
}

/// The phone's wording for an absence the host stated as a fact — worded here,
/// so an older host's unrecognised value reads as null.
String companionActivityAbsenceSentence(RemoteActivityAbsence absence) =>
    switch (absence) {
      RemoteActivityAbsence.noRecord =>
        'Working — your desktop keeps no record of what this session is '
            'running.',
    };

class _QuietLine extends StatelessWidget {
  const _QuietLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final colour = SemanticColors.of(context).neutral;
    return Padding(
      padding: EdgeInsets.fromLTRB(density.padX, 0, density.padX, Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: Chrome.iconSmall, color: colour),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: colour)),
          ),
        ],
      ),
    );
  }
}
