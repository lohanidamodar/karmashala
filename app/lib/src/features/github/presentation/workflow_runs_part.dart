import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/checkout_picker.dart';
import '../../git/data/git_data.dart';
import '../../git/presentation/remote_link.dart';
import '../../sessions/presentation/hand_to_session.dart';
import '../../sessions/presentation/session_destination_picker.dart';
import '../application/github_providers.dart';
import 'github_section.dart';

/// The newest Actions runs on the checkout's branch; a failed one offers its
/// log to an agent.
class WorkflowRunsPart extends ConsumerWidget {
  const WorkflowRunsPart({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ref
        .watch(githubWorkflowRunsProvider)
        .when(
          loading: () => const Padding(
            padding: EdgeInsets.all(Insets.sm),
            child: Center(
              child: InlineSpinner(semanticsLabel: 'Asking GitHub for runs'),
            ),
          ),
          error: (e, _) => GitHubNote(
            icon: AppIcons.warningCircle,
            text: gitHubFailureText(e),
          ),
          data: (runs) => runs.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(bottom: Insets.sm),
                  child: Text('No workflow runs on this branch.', style: muted),
                )
              : Column(children: [for (final run in runs) _RunTile(run: run)]),
        );
  }
}

class _RunTile extends ConsumerWidget {
  const _RunTile({required this.run});

  final WorkflowRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = SemanticColors.of(context);
    final (icon, color, state) = run.failed
        ? (AppIcons.xCircle, semantic.failure, run.conclusion ?? 'failed')
        : run.completed
        ? (AppIcons.checkCircle, semantic.idle, run.conclusion ?? 'completed')
        : (AppIcons.clock, null, run.status.replaceAll('_', ' '));
    final checkout = ref.watch(selectedCheckoutProvider);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        icon,
        size: Chrome.icon,
        color: color,
        semanticLabel: state,
      ),
      title: RemoteLink(
        text: run.title.isEmpty
            ? run.workflowName
            : '${run.workflowName} · ${run.title}',
        url: run.url,
        style: Theme.of(context).textTheme.bodyMedium,
        tooltip: run.url,
        icon: run.url != null,
      ),
      subtitle: Text(
        [state, ?run.branch, ?run.event].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: !run.failed || checkout == null
          ? null
          : HandToSessionButton(
              label: 'Fix in session',
              dense: true,
              title: 'Fix: ${run.workflowName}',
              destination: SessionDestination(
                projectId: checkout.projectId,
                checkout: checkout,
              ),
              // Fetched only when asked: a log is tens of KB per run.
              prompt: () async {
                final log = await ref
                    .read(gitDataProvider)
                    .failedRunLog(checkout.path, runId: run.id);
                return fixRunPrompt(run, log);
              },
            ),
    );
  }
}
