import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/karmashala_ui.dart' show ItemCard, LabeledValueRow;
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/presentation/usage_chip.dart'
    show formatResetClock, formatUsageDuration;
import '../../sessions/application/session_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/usage_limit_settings.dart';
import '../../settings/presentation/settings_catalog.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/scheduled_resume_providers.dart';
import '../domain/scheduled_resume.dart';
import 'minute_ticker.dart';
import 'resume_on_reset_dialog.dart';

/// Every resume that is waiting, in one place, with what the last few came to
/// — and what happens when an agent hits its limit in the first place.
class ScheduledResumesSection extends ConsumerWidget {
  const ScheduledResumesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final live = ref.watch(liveScheduledResumesProvider);
    final ended = ref.watch(recentScheduledResumesProvider);
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);

    return SettingsSection(
      title: SettingsAnchor.scheduledResumes.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'A session can be resumed when its account\'s usage window resets '
            '— from its row\'s menu, its header, or the notice a limit leaves '
            'in its bar. The account is read again at that moment: still '
            'limited, and the resume moves to the new reset instead.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.sm),
          SettingsRow(
            label: 'When an agent hits its usage limit',
            help: switch (settings.usageLimitBehavior) {
              UsageLimitBehavior.ask =>
                'The session\'s bar says so and offers to resume at the reset.',
              UsageLimitBehavior.schedule =>
                'A resume is armed at the reset without asking, where the '
                    'session\'s mode does not stop to ask.',
              UsageLimitBehavior.nothing => 'Nothing is said or scheduled.',
            },
            controlMaxWidth: 320,
            control: DropdownButtonFormField<UsageLimitBehavior>(
              initialValue: settings.usageLimitBehavior,
              isExpanded: true,
              items: [
                for (final behavior in UsageLimitBehavior.values)
                  DropdownMenuItem(
                    value: behavior,
                    child: Text(behavior.label),
                  ),
              ],
              onChanged: (value) {
                if (value != null) controller.setUsageLimitBehavior(value);
              },
            ),
          ),
          SettingsRow(
            label: 'Default resume message',
            help:
                'Sent once the session is resumed. Empty resumes without '
                'sending anything; each agent remembers the last one used.',
            controlMaxWidth: 320,
            control: _MessageField(
              value: settings.resumeMessage,
              onChanged: controller.setResumeMessage,
            ),
          ),
          const SizedBox(height: Insets.sm),
          if (live.isEmpty)
            Text('No resume is waiting.', style: theme.textTheme.bodySmall)
          else
            for (final resume in live)
              _ResumeCard(key: ValueKey(resume.id), resume: resume),
          if (ended.isNotEmpty) ...[
            const SizedBox(height: Insets.sm),
            Text('Recent', style: theme.textTheme.labelMedium),
            for (final resume in ended.take(8))
              _ResumeCard(key: ValueKey(resume.id), resume: resume),
          ],
        ],
      ),
    );
  }
}

class _MessageField extends StatefulWidget {
  const _MessageField({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_MessageField> createState() => _MessageFieldState();
}

class _MessageFieldState extends State<_MessageField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    onChanged: widget.onChanged,
    decoration: InputDecoration(
      isDense: true,
      hintText: kDefaultResumeMessage,
      semanticCounterText: '',
    ),
  );
}

class _ResumeCard extends ConsumerWidget {
  const _ResumeCard({required this.resume, super.key});

  final ScheduledResume resume;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionDaoProvider).getById(resume.sessionId);
    final resumes = ref.read(scheduledResumeControllerProvider);
    final waiting =
        resume.state == ScheduledResumeState.pending ||
        resume.state == ScheduledResumeState.queued;

    return ItemCard(
      title: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Insets.sm,
        children: [
          Text(
            session?.title ?? 'a session that is no longer here',
            style: theme.textTheme.bodyMedium,
          ),
          Text(resume.state.label, style: theme.textTheme.bodySmall),
        ],
      ),
      details: [
        if (waiting)
          // The one countdown on the page, and the only thing that ticks.
          MinuteTicker(
            builder: (context, now) => _Line(
              label: 'When',
              value:
                  '${formatResetClock(resume.fireAt, now)} · in '
                  '${formatUsageDuration(resume.fireAt.toLocal().difference(now))}',
            ),
          )
        else
          _Line(
            label: 'When',
            value: formatResetClock(
              resume.finishedAt ?? resume.fireAt,
              ref.read(clockProvider).nowUtc().toLocal(),
            ),
          ),
        _Line(
          label: 'Waits on',
          value: resume.windowLabel == null
              ? 'a time you chose — usage is not checked'
              : 'the ${resume.windowLabel} window',
        ),
        _Line(
          label: 'Sends',
          value: resume.sendsMessage ? '"${resume.message}"' : 'nothing',
        ),
        _Line(label: 'By', value: resume.scheduledBy),
        if (resume.reason.isNotEmpty) _Line(label: 'Note', value: resume.reason),
      ],
      actions: [
        if (waiting) ...[
          TextButton(
            onPressed: () =>
                ResumeOnResetDialog.show(context, [resume.sessionId]),
            child: const Text('Change…'),
          ),
          TextButton(
            onPressed: () => resumes.cancelFor(resume.sessionId),
            child: const Text('Cancel'),
          ),
        ] else ...[
          if (resume.state == ScheduledResumeState.missed && session != null)
            TextButton(
              onPressed: () => resumes.runNow(resume),
              child: const Text('Resume now'),
            ),
          TextButton(
            onPressed: () => resumes.forget(resume.id),
            child: const Text('Forget'),
          ),
        ],
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LabeledValueRow(
      label: label,
      labelWidth: 62,
      labelStyle: theme.textTheme.bodySmall,
      padding: const EdgeInsets.only(top: 1),
      value: Text(
        value,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
