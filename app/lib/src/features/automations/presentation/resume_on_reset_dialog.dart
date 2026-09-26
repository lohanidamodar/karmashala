import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/karmashala_ui.dart' show InlineSpinner;
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../agents/presentation/usage_chip.dart' show formatResetClock;
import '../../agents/presentation/usage_window_meter.dart'
    show usageWindowFacts;
import '../../environments/application/environment_providers.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../application/scheduled_resume_providers.dart';
import 'package:karmashala_automations/resumes.dart';
import 'minute_ticker.dart';

/// The choice that is not a usage window.
const String _chosenTime = '#time';

/// The choice, for several sessions, of each one's own blocking window.
const String _eachReset = '#each';

/// Arming, changing or cancelling a resume for one session or several. The
/// gate's own sentence disables the button, as it does for an automation.
class ResumeOnResetDialog extends ConsumerStatefulWidget {
  const ResumeOnResetDialog({
    required this.sessionIds,
    this.namedWindow,
    super.key,
  });

  final List<String> sessionIds;

  /// The window the agent's own limit record named, to preselect.
  final String? namedWindow;

  static Future<void> show(
    BuildContext context,
    List<String> sessionIds, {
    String? namedWindow,
  }) {
    if (sessionIds.isEmpty) return Future<void>.value();
    return showDialog<void>(
      context: context,
      builder: (_) =>
          ResumeOnResetDialog(sessionIds: sessionIds, namedWindow: namedWindow),
    );
  }

  @override
  ConsumerState<ResumeOnResetDialog> createState() =>
      _ResumeOnResetDialogState();
}

class _ResumeOnResetDialogState extends ConsumerState<ResumeOnResetDialog> {
  late final TextEditingController _message;
  String? _choice;
  DateTime? _time;
  String? _mode;
  ResumeLatePolicy _late = ResumeLatePolicy.ask;
  bool _notify = true;
  List<String> _skipped = const [];

  bool get _single => widget.sessionIds.length == 1;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsControllerProvider);
    final existing = _single
        ? ref.read(scheduledResumeDaoProvider).liveFor(widget.sessionIds.single)
        : null;
    var message = settings.resumeMessage;
    if (_single) {
      final session = ref
          .read(sessionsDataProvider)
          .getById(widget.sessionIds.single);
      final agentId = session == null
          ? null
          : ref
                .read(agentInstallationsDataProvider)
                .getById(session.agentInstallationId)
                ?.agentId;
      if (agentId != null) message = settings.resumeMessageFor(agentId);
    }
    _message = TextEditingController(text: existing?.message ?? message);
    if (existing != null) {
      _mode = existing.permissionMode;
      _late = existing.latePolicy;
      _notify = existing.notify;
      if (existing.windowLabel == null) {
        _choice = _chosenTime;
        _time = existing.fireAt.toLocal();
      } else {
        _choice = existing.windowLabel;
      }
    } else if (!_single) {
      _choice = _eachReset;
    }
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  DateTime get _now => ref.read(clockProvider).nowUtc();

  @override
  Widget build(BuildContext context) =>
      _single ? _buildSingle(context) : _buildSeveral(context);

  // --- one session -----------------------------------------------------------

  Widget _buildSingle(BuildContext context) {
    final theme = Theme.of(context);
    final sessionId = widget.sessionIds.single;
    final session = ref.watch(sessionsDataProvider).getById(sessionId);
    final existing = ref.watch(sessionResumeBadgeProvider(sessionId));
    if (session == null) {
      return AlertDialog(
        title: const DesktopDialogTitle(
          icon: AppIcons.clock,
          title: 'Resume when usage resets',
        ),
        content: const Text('This session is no longer in the workspace.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }

    final access = ref.watch(resumeUsageAccessProvider(sessionId));
    final installation = access?.installation;
    final usage = access != null && access.readable && installation != null
        ? ref.watch(agentUsageProvider(installation))
        : null;
    final now = _now;
    final windows = resumableWindows(
      usage?.asData?.value.windows ?? const [],
      now,
    );
    final preselected = blockingWindow(
      windows,
      now: now,
      namedLabel: widget.namedWindow,
    );
    final loading = usage != null && usage.isLoading && windows.isEmpty;
    // Nothing chosen yet: the blocking window, else a time of their own.
    final choice =
        _choice != null &&
            (_choice == _chosenTime ||
                windows.any((window) => window.label == _choice))
        ? _choice!
        : preselected?.window.label ?? (loading ? null : _chosenTime);

    final descriptor = installation == null
        ? null
        : ref.watch(agentRegistryProvider).byId(installation.agentId);
    final refusal = ref
        .watch(scheduledResumeControllerProvider)
        .refusalFor(sessionId, permissionMode: _mode);
    final request = choice == null
        ? null
        : _requestFor(sessionId, choice, windows);
    final timeProblem =
        choice == _chosenTime && _time != null && request == null
        ? 'That time has already passed.'
        : null;

    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.clock,
        title: existing == null
            ? 'Resume when usage resets'
            : 'Change scheduled resume',
        subtitle: session.title,
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (access?.unreadableBecause case final why?)
              Text(why, style: theme.textTheme.bodySmall)
            else if (loading)
              const Row(
                children: [
                  InlineSpinner(),
                  SizedBox(width: Insets.sm),
                  Expanded(child: Text("Reading this account's limits…")),
                ],
              )
            else if (usage != null && usage.hasError && windows.isEmpty)
              Text(
                'This account\'s limits could not be read '
                '(${_errorText(usage.error)}), so only a time you choose can '
                'be used.',
                style: theme.textTheme.bodySmall,
              )
            else if (windows.isEmpty)
              Text(
                'No window of this account names a reset to come, so only a '
                'time you choose can be used.',
                style: theme.textTheme.bodySmall,
              ),
            RadioGroup<String>(
              groupValue: choice,
              onChanged: (value) => setState(() => _choice = value),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final window in windows)
                    RadioListTile<String>(
                      value: window.label,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${window.label} window'
                        '${_why(preselected, window)}',
                      ),
                      subtitle: MinuteTicker(
                        builder: (context, local) =>
                            Text(usageWindowFacts(window, local)),
                      ),
                    ),
                  RadioListTile<String>(
                    value: _chosenTime,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('A time I choose'),
                    subtitle: Text(
                      _time == null
                          ? 'Not checked against usage.'
                          : '${formatResetClock(_time!, now.toLocal())} · not '
                                'checked against usage',
                    ),
                    secondary: TextButton(
                      onPressed: _pickTime,
                      child: Text(_time == null ? 'Choose…' : 'Change…'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Insets.sm),
            _messageField(),
            const SizedBox(height: Insets.sm),
            _ModeField(
              agentName: descriptor?.displayName ?? 'the agent',
              support: descriptor?.launch.permission,
              value: _mode,
              runsNow: _runsNowLabel(sessionId),
              live:
                  ref.read(sessionLauncherProvider).livePaneFor(sessionId) !=
                  null,
              onChanged: (value) => setState(() => _mode = value),
            ),
            const SizedBox(height: Insets.sm),
            ..._lateAndNotify(theme),
            for (final problem in [?timeProblem, ?refusal?.reason]) ...[
              const SizedBox(height: Insets.sm),
              Text(
                problem,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (existing != null)
          TextButton(
            onPressed: () {
              ref.read(scheduledResumeControllerProvider).cancelFor(sessionId);
              Navigator.of(context).pop();
            },
            child: const Text('Cancel scheduled resume'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: request == null || refusal != null
              ? null
              : () {
                  ref.read(scheduledResumeControllerProvider).schedule(request);
                  Navigator.of(context).pop();
                },
          child: Text(existing == null ? 'Schedule' : 'Save'),
        ),
      ],
    );
  }

  static String _why(BlockingWindow? preselected, UsageWindow window) {
    if (preselected == null || preselected.window.label != window.label) {
      return '';
    }
    return switch (preselected.reason) {
      BlockingWindowReason.spent => ' — at its limit',
      BlockingWindowReason.named => ' — the one the agent named',
      BlockingWindowReason.nearLimit => ' — nearly spent',
      BlockingWindowReason.soonestReset => ' — resets soonest',
    };
  }

  static String _errorText(Object? error) =>
      error is UsageException ? error.message : '$error';

  String _runsNowLabel(String sessionId) {
    final effective = ref
        .read(sessionLauncherProvider)
        .effectivePermissionFor(sessionId);
    final support = effective?.descriptor?.launch.permission;
    if (effective == null || support == null || !support.isKnown) return '';
    return describeSelectionFamiliar(support, effective.selection);
  }

  ResumeRequest? _requestFor(
    String sessionId,
    String choice,
    List<UsageWindow> windows,
  ) {
    if (choice == _chosenTime) {
      final time = _time;
      if (time == null || !time.isAfter(_now.toLocal())) return null;
      return ResumeRequest(
        sessionId: sessionId,
        fireAt: time,
        message: _message.text,
        permissionMode: _mode,
        notify: _notify,
        latePolicy: _late,
      );
    }
    for (final window in windows) {
      if (window.label != choice) continue;
      return ResumeRequest.atReset(
        sessionId: sessionId,
        window: window,
        message: _message.text,
        permissionMode: _mode,
        notify: _notify,
        latePolicy: _late,
      );
    }
    return null;
  }

  // --- several sessions ------------------------------------------------------

  Widget _buildSeveral(BuildContext context) {
    final theme = Theme.of(context);
    final controller = ref.watch(scheduledResumeControllerProvider);
    final sessions = [
      for (final id in widget.sessionIds)
        ?ref.watch(sessionsDataProvider).getById(id),
    ];
    final refused = <String>[
      for (final session in sessions)
        if (controller.refusalFor(session.id) case final refusal?)
          '${session.title} — ${refusal.reason}',
    ];
    final choice = _choice ?? _eachReset;
    final time = _time;
    final ready =
        choice == _eachReset || (time != null && time.isAfter(_now.toLocal()));

    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.clock,
        title: 'Resume when usage resets',
        subtitle: '${sessions.length} sessions',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RadioGroup<String>(
              groupValue: choice,
              onChanged: (value) => setState(() => _choice = value),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const RadioListTile<String>(
                    value: _eachReset,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text("When each session's own limit resets"),
                    subtitle: Text(
                      'The window at its limit for that session\'s account, '
                      'or the soonest to reset.',
                    ),
                  ),
                  RadioListTile<String>(
                    value: _chosenTime,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('A time I choose'),
                    subtitle: Text(
                      time == null
                          ? 'Not checked against usage.'
                          : '${formatResetClock(time, _now.toLocal())} · not '
                                'checked against usage',
                    ),
                    secondary: TextButton(
                      onPressed: _pickTime,
                      child: Text(time == null ? 'Choose…' : 'Change…'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Insets.sm),
            _messageField(),
            const SizedBox(height: Insets.sm),
            ..._lateAndNotify(theme),
            if (refused.isNotEmpty || _skipped.isNotEmpty) ...[
              const SizedBox(height: Insets.sm),
              Text(
                refused.isNotEmpty
                    ? 'Not scheduled, each in its own mode:'
                    : 'Not scheduled:',
                style: theme.textTheme.labelMedium,
              ),
              for (final line in [...refused, ..._skipped])
                Padding(
                  padding: const EdgeInsets.only(top: Insets.xs),
                  child: Text(
                    line,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: !ready || refused.length == sessions.length
              ? null
              : () => _scheduleSeveral(sessions, choice),
          child: const Text('Schedule'),
        ),
      ],
    );
  }

  Future<void> _scheduleSeveral(List<Session> sessions, String choice) async {
    final controller = ref.read(scheduledResumeControllerProvider);
    final usage = ref.read(agentUsageServiceProvider);
    final environments = ref.read(environmentsDataProvider).getAll();
    final skipped = <String>[];
    for (final session in sessions) {
      if (controller.refusalFor(session.id) != null) continue;
      ResumeRequest? request;
      if (choice == _chosenTime) {
        request = ResumeRequest(
          sessionId: session.id,
          fireAt: _time!,
          message: _message.text,
          notify: _notify,
          latePolicy: _late,
        );
      } else {
        final access = ref.read(resumeUsageAccessProvider(session.id));
        final installation = access?.installation;
        if (access == null || !access.readable || installation == null) {
          skipped.add(
            '${session.title} — '
            '${access?.unreadableBecause ?? 'its limits cannot be read'}',
          );
          continue;
        }
        BlockingWindow? blocking;
        try {
          // Throttled: several sessions on one account share one reading.
          final reading = await usage.fetch(installation, environments);
          blocking = blockingWindow(reading.windows, now: _now);
        } on UsageException catch (error) {
          skipped.add('${session.title} — ${error.message}');
          continue;
        }
        if (blocking == null) {
          skipped.add(
            '${session.title} — no window of its account names a reset to '
            'come.',
          );
          continue;
        }
        request = ResumeRequest.atReset(
          sessionId: session.id,
          window: blocking.window,
          message: _message.text,
          notify: _notify,
          latePolicy: _late,
        );
      }
      try {
        controller.schedule(request);
      } on ScheduledResumeRefused catch (refused) {
        skipped.add('${session.title} — ${refused.reason}');
      }
    }
    if (!mounted) return;
    if (skipped.isEmpty) {
      Navigator.of(context).pop();
    } else {
      setState(() => _skipped = skipped);
    }
  }

  // --- shared ----------------------------------------------------------------

  Widget _messageField() => TextField(
    controller: _message,
    minLines: 1,
    maxLines: 4,
    onChanged: (_) => setState(() {}),
    decoration: const InputDecoration(
      labelText: 'Message to send on resume',
      helperText: 'Leave empty to resume without sending anything.',
    ),
  );

  List<Widget> _lateAndNotify(ThemeData theme) => [
    Text(
      "If I'm late — Karmashala was closed or the machine asleep",
      style: theme.textTheme.labelMedium,
    ),
    const SizedBox(height: Insets.xs),
    SegmentedButton<ResumeLatePolicy>(
      segments: [
        for (final policy in ResumeLatePolicy.values)
          ButtonSegment(value: policy, label: Text(policy.label)),
      ],
      selected: {_late},
      showSelectedIcon: false,
      onSelectionChanged: (value) => setState(() => _late = value.first),
    ),
    CheckboxListTile(
      value: _notify,
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: const Text('Also notify me'),
      subtitle: const Text('A desktop notification when it resumes.'),
      onChanged: (value) => setState(() => _notify = value ?? false),
    ),
  ];

  Future<void> _pickTime() async {
    final now = _now.toLocal();
    final initial = _time ?? now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 30)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    setState(() {
      _choice = _chosenTime;
      _time = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }
}

/// The mode the resume runs in. Empty is "as the session runs now", which is
/// the session's own choice or the per-agent default behind it.
class _ModeField extends StatelessWidget {
  const _ModeField({
    required this.agentName,
    required this.support,
    required this.value,
    required this.runsNow,
    required this.live,
    required this.onChanged,
  });

  final String agentName;
  final AgentPermissionSupport? support;
  final String? value;
  final String runsNow;
  final bool live;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final support = this.support;
    if (support == null || !support.isKnown) {
      return Text(
        unknownAgentReason(agentName),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final selections = support.selections();
    final chosen = value == null
        ? ''
        : support.normalise(PermissionSelection.parse(value)).canonical;
    return DropdownButtonFormField<String>(
      initialValue:
          chosen.isEmpty || selections.any((s) => s.canonical == chosen)
          ? chosen
          : '',
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Permission mode',
        helperMaxLines: 3,
        helperText: live
            ? 'A mode that stops to ask is refused: nobody would be there to '
                  'answer. Picking another mode restarts this open session '
                  'in it when the time comes.'
            : 'A mode that stops to ask is refused: nobody would be there to '
                  'answer.',
      ),
      items: [
        DropdownMenuItem(
          value: '',
          child: Text(
            runsNow.isEmpty
                ? 'As the session runs now'
                : 'As the session runs now — $runsNow',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final selection in selections)
          DropdownMenuItem(
            value: selection.canonical,
            child: Text(
              describeSelectionFamiliar(support, selection),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (value) =>
          onChanged(value == null || value.isEmpty ? null : value),
    );
  }
}
