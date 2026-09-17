import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../ssh/presentation/pair_phone_entry.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import '../application/environment_health.dart';
import '../application/system_health.dart';
import '../application/system_health_service.dart';

/// What the machine can actually do, measured. One panel and not two, because
/// two that could disagree is worse than one that is incomplete.
class EnvironmentHealthDialog extends ConsumerStatefulWidget {
  const EnvironmentHealthDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const EnvironmentHealthDialog(),
  );

  @override
  ConsumerState<EnvironmentHealthDialog> createState() =>
      _EnvironmentHealthDialogState();
}

class _EnvironmentHealthDialogState
    extends ConsumerState<EnvironmentHealthDialog> {
  @override
  void initState() {
    super.initState();
    // Once, on open. Not in `build`, which runs again on every rebuild, and not
    // on a timer, which would spawn a handful of processes a minute for a
    // panel nobody is looking at.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final report = ref.read(systemHealthProvider);
      if (report.hasRun || report.running) return;
      ref.read(systemHealthProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(systemHealthProvider);
    return AlertDialog(
      title: const Row(
        children: [
          Icon(AppIcons.checkCircle, size: Chrome.iconTitle),
          SizedBox(width: Insets.sm),
          Text('System health'),
        ],
      ),
      content: SizedBox(
        width: 620,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ReadingAge(report: report),
            const SizedBox(height: Insets.sm),
            Expanded(child: _Body(report: report)),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: report.running
              ? null
              : () => ref.read(systemHealthProvider.notifier).refresh(),
          icon: const Icon(AppIcons.arrowsClockwise),
          label: Text(report.hasRun ? 'Check again' : 'Check now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// How old the reading is — the one line that decides how much of the rest to
/// believe.
class _ReadingAge extends ConsumerWidget {
  const _ReadingAge({required this.report});

  final SystemHealthReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final checkedAt = report.checkedAt;
    final label = switch ((report.running, checkedAt)) {
      (true, _) => 'Checking now — this spawns a process per check.',
      (false, null) => 'Nothing has been checked yet.',
      (false, final at?) => 'Checked ${describeAge(
        ref.read(clockProvider).nowUtc().difference(at),
      )}. Nothing here is re-checked on its own.',
    };
    return Row(
      children: [
        if (report.running)
          const InlineSpinner(size: InlineSpinnerSize.medium)
        else
          Icon(
            report.hasRun ? AppIcons.clockCounterClockwise : AppIcons.question,
            size: Chrome.icon,
            color: semantic.neutral,
          ),
        const SizedBox(width: Insets.xs),
        Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.report});

  final SystemHealthReport report;

  @override
  Widget build(BuildContext context) {
    if (!report.hasRun) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: Text(
            report.running
                ? 'Running the checks…'
                : 'No check has run, so nothing is known about this machine '
                      'yet. Nothing below is a claim that anything works.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return ListView(
      children: [
        for (final check in report.checks) _CheckRow(check: check),
        if (report.environments.isNotEmpty) ...[
          const Divider(height: Insets.lg),
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.xs),
            child: Text(
              'EXECUTION ENVIRONMENTS',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          for (final environment in report.environments)
            _EnvironmentRow(health: environment),
        ],
      ],
    );
  }
}

/// One machine check: verdict, evidence, and what to do about it.
class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.check});

  final SystemCheck check;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              healthIcon(check.level),
              size: Chrome.icon,
              color: healthColor(context, check.level),
            ),
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        check.title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (check.took case final took?)
                      Text(
                        _tookLabel(took),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: SemanticColors.of(context).neutral,
                        ),
                      ),
                  ],
                ),
                Text(check.summary, style: theme.textTheme.bodySmall),
                if (check.detail case final detail?
                    when detail.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(detail, style: MonoStyles.small),
                  ),
                if (check.remedy case final remedy?) ...[
                  const SizedBox(height: Insets.xs),
                  Text(
                    remedy,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
                if (check.remedyCommand case final command?)
                  _CopyableCommand(command: command),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Sub-millisecond checks exist (the endpoint row reads state rather than
  /// probing), and "0 ms" beside them would read as a failed measurement.
  static String _tookLabel(Duration took) => took.inMilliseconds < 1
      ? 'not probed'
      : '${took.inMilliseconds} ms';
}

/// The line that fixes it, offered to copy rather than to retype.
class _CopyableCommand extends StatelessWidget {
  const _CopyableCommand({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.xs,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: SelectableText(command, style: MonoStyles.small),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Copy command',
            icon: const Icon(AppIcons.copySimple, size: Chrome.icon),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(
                context,
              )?.showSnackBar(const SnackBar(content: Text('Command copied.')));
            },
          ),
        ],
      ),
    );
  }
}

/// One execution environment: reachable, and what was found in it.
class _EnvironmentRow extends ConsumerWidget {
  const _EnvironmentRow({required this.health});

  final EnvironmentHealth health;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pairable = sshHostOf(ref, health.environment) != null;
    // Versions, not just names. Which version of a CLI is installed decides
    // which modes a session there can use — that is a property of the
    // installation, and this app has learned it the hard way.
    final agents = [
      for (final install in health.installations)
        install.version == null
            ? install.agentId
            : '${install.agentId} ${install.version}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              healthIcon(health.level),
              size: Chrome.icon,
              color: healthColor(context, health.level),
            ),
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  health.environment.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(health.summary, style: theme.textTheme.bodySmall),
                if ([?health.gitVersion, ...agents].isNotEmpty)
                  Text(
                    [?health.gitVersion, ...agents].join(' · '),
                    style: MonoStyles.small,
                  ),
              ],
            ),
          ),
          if (pairable)
            TextButton.icon(
              onPressed: () => pairPhoneWith(context, ref, health.environment),
              icon: const Icon(AppIcons.deviceMobile, size: Chrome.icon),
              label: const Text(kPairPhoneLabel),
            ),
        ],
      ),
    );
  }
}

/// One icon vocabulary for every level, so `unknown` is drawn as its own thing
/// rather than borrowing the failure mark.
IconData healthIcon(HealthLevel level) => switch (level) {
  HealthLevel.healthy => AppIcons.checkCircle,
  HealthLevel.unknown => AppIcons.question,
  HealthLevel.warning => AppIcons.warningCircle,
  HealthLevel.failed => AppIcons.xCircle,
};

Color healthColor(BuildContext context, HealthLevel level) {
  final semantic = SemanticColors.of(context);
  return switch (level) {
    HealthLevel.healthy => semantic.idle,
    HealthLevel.unknown => semantic.neutral,
    HealthLevel.warning => semantic.attention,
    HealthLevel.failed => semantic.failure,
  };
}
