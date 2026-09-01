import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_installation.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../application/fanout_service.dart';
import 'comparison_list.dart';
import 'comparison_view.dart';
import 'fanout_usage_strip.dart';

/// The fan-out surface: past comparisons, a new one, and one open.
///
/// Launching used to *become* the result view and the result view died with the
/// dialog. It now opens on the list, because a comparison is a thing you return
/// to — the launch simply selects the one it just made.
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
    return id == null ? null : ref.read(repositoryDaoProvider).getById(id);
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
              .watch(agentInstallationDaoProvider)
              .getByEnvironment(repo.path.environmentId);
    // 28 of margin on every side is comfortable on a desktop-sized window and
    // wasteful on the 720x560 minimum, where it spends a tenth of the height on
    // nothing. The requested size is clamped for the same reason: asking for
    // 1180x780 inside a smaller window only tells Flutter to shrink it, and the
    // number then lies to anyone reading this.
    final screen = MediaQuery.sizeOf(context);
    final inset = screen.height < 700 || screen.width < 900 ? 8.0 : 28.0;
    return Dialog(
      insetPadding: EdgeInsets.all(inset),
      child: SizedBox(
        width: (screen.width - inset * 2).clamp(0.0, 1180.0),
        height: (screen.height - inset * 2).clamp(0.0, 780.0),
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

  Widget _setup(String? repoName, List<AgentInstallation> installs) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => setState(() => _composing = false),
            icon: const Icon(AppIcons.arrowLeft, size: Chrome.icon),
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(
              'New fan-out'
              '${repoName == null ? '' : '  ·  $repoName'}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        ],
      ),
      const Divider(height: Insets.lg),
      TextField(
        controller: _prompt,
        // On a 560px-tall window every block competes for the same height, and
        // the agent list is the one that must not lose: an agent you cannot
        // reach is an agent you cannot pick. The field still grows to ten lines.
        minLines: MediaQuery.sizeOf(context).height < 700 ? 3 : 5,
        maxLines: 10,
        decoration: const InputDecoration(
          labelText: 'Prompt sent to every agent',
        ),
      ),
      const SizedBox(height: Insets.md),
      Text('Agents', style: Theme.of(context).textTheme.labelLarge),
      Expanded(
        child: ListView(
          children: [
            for (final install in installs)
              CheckboxListTile(
                dense: true,
                value: _selected.contains(install.id),
                title: Text(install.agentId),
                subtitle: Text(
                  install.version ?? install.executable.path,
                  style: const TextStyle(fontFamily: kMonoFamily),
                ),
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        if (value ?? false) {
                          _selected.add(install.id);
                        } else {
                          _selected.remove(install.id);
                        }
                      }),
              ),
          ],
        ),
      ),
      // Beside the button, not above the list: the cost of a fan-out is only a
      // decision once you know how many sessions it is and on whose quota.
      FanOutUsageStrip(
        installations: installs.where((i) => _selected.contains(i.id)).toList(),
      ),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: SemanticColors.of(context).failure),
        ),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => setState(() => _composing = false),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: Insets.sm),
          FilledButton(
            onPressed: !_busy && repoName != null && _selected.length >= 2
                ? () => _launch(installs)
                : null,
            child: Text(
              _busy ? 'Launching…' : 'Launch ${_selected.length} agents',
            ),
          ),
        ],
      ),
    ],
  );
}
