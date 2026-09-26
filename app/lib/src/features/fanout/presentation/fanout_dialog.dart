import '../../workspaces/data/workspace_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/discovery.dart';
import '../../git/application/changes_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../application/fanout_service.dart';
import 'comparison_list.dart';
import 'comparison_view.dart';
import 'fanout_usage_strip.dart';

/// The fan-out surface: past comparisons, a new one, and one open. It opens on
/// the list, because a comparison is a thing you return to.
class FanOutDialog extends ConsumerStatefulWidget {
  const FanOutDialog({this.initialComparisonId, super.key});

  /// Opens straight into one comparison, when the caller has one in mind.
  final String? initialComparisonId;

  static Future<void> show(BuildContext context, {String? comparisonId}) =>
      showDialog<void>(
        context: context,
        builder: (_) => FanOutDialog(initialComparisonId: comparisonId),
      );

  @override
  ConsumerState<FanOutDialog> createState() => _FanOutDialogState();
}

class _FanOutDialogState extends ConsumerState<FanOutDialog> {
  final _prompt = TextEditingController();
  final _selected = <String>{};
  String? _openComparisonId;
  bool _composing = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _openComparisonId = widget.initialComparisonId;
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Repository? get _repository {
    final id = ref.read(selectedRepositoryIdProvider);
    return id == null ? null : ref.read(workspaceDataProvider).repository(id);
  }

  Future<void> _launch(List<AgentInstallation> installs) async {
    final repo = _repository;
    if (repo == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final launched = await ref
          .read(fanOutServiceProvider)
          .launch(
            repository: repo,
            installations: installs
                .where((i) => _selected.contains(i.id))
                .toList(),
            prompt: _prompt.text,
          );
      if (!mounted) return;
      setState(() {
        _composing = false;
        _openComparisonId = launched.comparison.id;
        _prompt.clear();
        _selected.clear();
      });
      // A partial launch is still a launch: the failed agents are candidates in
      // the comparison now, so the view below names them without a banner.
      if (launched.hasFailures) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(launched.partialSummary!)));
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = _repository;
    final installs = repo == null
        ? const <AgentInstallation>[]
        : ref
              .watch(agentInstallationsDataProvider)
              .getByEnvironment(repo.path.environmentId);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 28 of margin is comfortable on a desktop window and wasteful at
        // 720x560. Clamped, because asking for more only tells Flutter to
        // shrink it.
        final inset = constraints.maxHeight < 700 || constraints.maxWidth < 900
            ? 8.0
            : 28.0;
        return Dialog(
          insetPadding: EdgeInsets.all(inset),
          child: SizedBox(
            width: (constraints.maxWidth - inset * 2).clamp(0.0, 1180.0),
            height: (constraints.maxHeight - inset * 2).clamp(0.0, 780.0),
            child: Padding(
              padding: const EdgeInsets.all(Insets.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.topRight,
                    child: IconButton(
                      tooltip: 'Close',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(AppIcons.x, size: Chrome.icon),
                    ),
                  ),
                  Expanded(child: _body(repo, installs)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body(Repository? repo, List<AgentInstallation> installs) {
    if (_composing) return _setup(repo?.name, installs);
    if (_openComparisonId case final id?) {
      return ComparisonView(
        comparisonId: id,
        onBack: () => setState(() => _openComparisonId = null),
      );
    }
    return ComparisonList(
      onOpen: (id) => setState(() => _openComparisonId = id),
      onNew: repo == null ? null : () => setState(() => _composing = true),
    );
  }

  Widget _setup(String? repoName, List<AgentInstallation> installs) =>
      FanOutSetupForm(
        repositoryName: repoName,
        installations: installs,
        prompt: _prompt,
        selected: _selected,
        busy: _busy,
        error: _error,
        onCancel: () => setState(() => _composing = false),
        onToggle: (id, selected) => setState(() {
          if (selected) {
            _selected.add(id);
          } else {
            _selected.remove(id);
          }
        }),
        onLaunch: () => _launch(installs),
      );
}

/// The new-fan-out form: one prompt, the agents to send it to, and what that
/// costs. Everything it shows is handed in; the dialog owns the state.
class FanOutSetupForm extends StatelessWidget {
  const FanOutSetupForm({
    required this.repositoryName,
    required this.installations,
    required this.prompt,
    required this.selected,
    required this.busy,
    required this.error,
    required this.onCancel,
    required this.onToggle,
    required this.onLaunch,
    super.key,
  });

  /// Below this height the prompt starts shorter and the usage strip yields
  /// first, so the agent list keeps its rows.
  static const compactHeight = 580.0;

  final String? repositoryName;
  final List<AgentInstallation> installations;
  final TextEditingController prompt;
  final Set<String> selected;
  final bool busy;
  final String? error;
  final VoidCallback onCancel;
  final void Function(String installationId, bool selected) onToggle;
  final VoidCallback onLaunch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repoName = repositoryName;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < compactHeight;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  onPressed: onCancel,
                  icon: const Icon(AppIcons.arrowLeft, size: Chrome.icon),
                ),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: Text(
                    'New fan-out'
                    '${repoName == null ? '' : '  ·  $repoName'}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const Divider(height: Insets.lg),
            TextField(
              controller: prompt,
              // Every block competes for the same height, and the agent list
              // is the one that must not lose: an agent you cannot reach is an
              // agent you cannot pick. The field still grows to ten lines.
              minLines: compact ? 3 : 5,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: 'Prompt sent to every agent',
              ),
            ),
            const SizedBox(height: Insets.md),
            Text('Agents', style: theme.textTheme.labelLarge),
            Expanded(
              child: ListView(
                children: [
                  for (final install in installations)
                    CheckboxListTile(
                      dense: true,
                      value: selected.contains(install.id),
                      title: Text(install.agentId),
                      subtitle: Text(
                        install.version ?? install.executable.path,
                        style: MonoStyles.body,
                      ),
                      onChanged: busy
                          ? null
                          : (value) => onToggle(install.id, value ?? false),
                    ),
                ],
              ),
            ),
            // Beside the button, not above the list: the cost of a fan-out is
            // only a decision once you know how many sessions it is and on
            // whose quota.
            FanOutUsageStrip(
              installations: installations
                  .where((i) => selected.contains(i.id))
                  .toList(),
              maxHeight: compact
                  ? FanOutUsageStrip.compactMaxHeight
                  : FanOutUsageStrip.defaultMaxHeight,
            ),
            if (error != null) DesktopErrorBanner(error!),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onCancel, child: const Text('Cancel')),
                const SizedBox(width: Insets.sm),
                FilledButton(
                  onPressed: !busy && repoName != null && selected.length >= 2
                      ? onLaunch
                      : null,
                  child: Text(
                    busy ? 'Launching…' : 'Launch ${selected.length} agents',
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
