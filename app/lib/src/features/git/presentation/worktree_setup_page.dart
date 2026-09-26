import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import '../../settings/presentation/settings_section.dart';
import '../application/worktree_setup_providers.dart';
import 'package:karmashala_git/git.dart';
import 'worktree_cleanup_section.dart';
import 'worktree_creation_view.dart';
import 'worktree_setup_dialog.dart';

/// Settings → Worktrees: what each checkout wants done to a new worktree, and
/// what happened last time. Nothing polls; every write bumps the revision.
class WorktreeSetupPage extends ConsumerWidget {
  const WorktreeSetupPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(worktreeSetupsProvider);
    final repositories = ref.watch(repositoryDaoProvider).getAll();
    // Watched so a project added while this is open reaches the "add a
    // checkout" list without a reopen.
    ref.watch(projectsControllerProvider);
    // A configured checkout's runs are on its card; these are the others'.
    final recent = [
      for (final run in ref.watch(recentWorktreeRunsProvider))
        if (!(settings[run.repositoryId]?.isNotEmpty ?? false)) run,
    ];
    final now = ref.watch(clockProvider).nowUtc();

    final configured = [
      for (final repository in repositories)
        if (settings[repository.id]?.isNotEmpty ?? false) repository,
    ];
    final rest = [
      for (final repository in repositories)
        if (!(settings[repository.id]?.isNotEmpty ?? false)) repository,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'WORKTREE SETUP',
          trailing: rest.isEmpty
              ? null
              : _AddButton(candidates: rest, settings: settings),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Ignored files to copy into a new worktree, and a command to run.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Insets.md),
              if (configured.isEmpty)
                Text(
                  repositories.isEmpty
                      ? 'No checkouts have been scanned yet.'
                      : 'No checkout has a setup yet.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                for (final repository in configured)
                  _CheckoutCard(
                    key: ValueKey(repository.id),
                    repository: repository,
                    setup: settings[repository.id]!,
                  ),
            ],
          ),
        ),
        if (recent.isNotEmpty)
          SettingsSection(
            title: 'RECENT WORKTREES',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final run in recent)
                  _RunLine(
                    key: ValueKey('recent ${run.worktreePath}'),
                    run: run,
                    now: now,
                  ),
              ],
            ),
          ),
        const WorktreeCleanupSection(),
      ],
    );
  }
}

/// Adds a setup to a checkout that has none. A menu of the checkouts this
/// workspace knows about, which is the only set a setting can be written for.
class _AddButton extends ConsumerWidget {
  const _AddButton({required this.candidates, required this.settings});

  final List<Repository> candidates;
  final Map<String, WorktreeSetup> settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopupMenuButton<String>(
    tooltip: 'Add a setup',
    onSelected: (id) => _edit(
      context,
      ref,
      candidates.firstWhere((r) => r.id == id),
      const WorktreeSetup(),
    ),
    itemBuilder: (_) => [
      for (final repository in candidates)
        DesktopMenuDetailItem(
          value: repository.id,
          label: repository.name,
          detail: repository.path.path,
          icon: AppIcons.folder,
        ),
    ],
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: Insets.sm, vertical: Insets.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.plus),
          SizedBox(width: Insets.xs),
          Text('Add a checkout'),
        ],
      ),
    ),
  );
}

Future<void> _edit(
  BuildContext context,
  WidgetRef ref,
  Repository repository,
  WorktreeSetup existing,
) async {
  final saved = await WorktreeSetupDialog.show(
    context,
    checkoutName: repository.name,
    existing: existing,
  );
  if (saved == null) return;
  ref.read(worktreeSetupControllerProvider).save(repository.id, saved);
}

/// One checkout's setup, and the verdicts of the worktrees it has made.
class _CheckoutCard extends ConsumerWidget {
  const _CheckoutCard({
    required this.repository,
    required this.setup,
    super.key,
  });

  final Repository repository;
  final WorktreeSetup setup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final environment = ref
        .watch(executionEnvironmentDaoProvider)
        .getById(repository.path.environmentId);
    final runs = ref.watch(worktreeSetupRunsProvider(repository.id));
    final now = ref.watch(clockProvider).nowUtc();

    return Container(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  repository.name,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // The environment decides where the command runs and where the
              // copy happens.
              Text(
                _environmentLabel(environment?.kind, environment?.name),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: Insets.sm),
              TextButton(
                onPressed: () => _edit(context, ref, repository, setup),
                child: const Text('Edit'),
              ),
              TextButton(
                onPressed: () => ref
                    .read(worktreeSetupControllerProvider)
                    .clear(repository.id),
                child: const Text('Remove'),
              ),
            ],
          ),
          Text(
            repository.path.path,
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: Insets.sm),
          _Line(
            label: 'Command',
            value: setup.command.isEmpty
                ? 'none'
                : joinCommandLine(setup.command),
          ),
          _Line(
            label: 'Copy in',
            value: setup.copyPaths.isEmpty
                ? 'nothing'
                : setup.copyPaths.join(', '),
          ),
          if (setup.teardown.isNotEmpty)
            _Line(label: 'Teardown', value: joinCommandLine(setup.teardown)),
          if (setup.command.isNotEmpty)
            _Line(
              label: 'Agent',
              value: setup.startAgentBeforeSetup
                  ? 'starts at once'
                  : 'waits for the command',
            ),
          if (runs.isNotEmpty) ...[
            const SizedBox(height: Insets.sm),
            for (final run in runs.take(5))
              _RunLine(key: ValueKey(run.worktreePath), run: run, now: now),
          ],
        ],
      ),
    );
  }
}

String _environmentLabel(EnvironmentKind? kind, String? name) => switch (kind) {
  EnvironmentKind.wsl => 'WSL · ${name ?? 'distro'}',
  EnvironmentKind.ssh => 'SSH · ${name ?? 'remote'}',
  EnvironmentKind.windowsNative => 'Windows',
  EnvironmentKind.localPosix => name ?? 'this machine',
  // The row is there and its environment is not: said, never guessed.
  null => 'environment not recorded',
};

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One worktree's verdict, with its age and the sentences behind it. One
/// needing attention is expanded and coloured; a worktree with no recorded run
/// is not listed at all, rather than listed as healthy.
class _RunLine extends StatelessWidget {
  const _RunLine({required this.run, required this.now, super.key});

  final WorktreeSetupReport run;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final attention = run.verdict == WorktreeSetupVerdict.attention;
    final creation = run.creation;
    final lines = [
      for (final copy in run.problems) '${copy.path}: ${copy.reason}',
      if (run.command != null && run.command!.result.needsAttention)
        run.command!.reason,
      if (creation != null)
        for (final stage in creation.problems)
          // The setup script's own words are already above.
          if (stage.stage != WorktreeStage.setupScript)
            '${stage.stage.label}: ${stage.detail ?? stage.state.name}',
      if (creation?.cleanup != null) creation!.cleanup!,
    ];
    final status = creation == null
        ? (attention ? 'needs attention' : 'set up')
        : describeWorktreeOutcome(creation.outcome);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                attention ? AppIcons.warning : AppIcons.checkCircle,
                size: Chrome.iconSmall,
                color: attention ? scheme.error : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.xs),
              Expanded(
                child: Text(
                  '${lastPathSegment(run.worktreePath)} — '
                  '$status · '
                  '${describeAge(now.difference(run.ranAt))}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: attention ? scheme.error : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 1),
              child: Text(line, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
