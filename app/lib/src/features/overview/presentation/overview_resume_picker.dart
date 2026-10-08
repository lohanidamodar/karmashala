import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_shell.dart' show phoneWorkbenchOpener;
import '../../../app/widgets/adaptive_modal.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../sessions/application/session_actions.dart';
import '../application/overview_prefs.dart';
import '../application/overview_reads.dart';
import '../application/overview_resume.dart';
import 'overview_card_parts.dart' show overviewPlain;
import 'overview_resume_actions.dart';

/// What the person chose in Resume….
@immutable
class ResumeChoice {
  const ResumeChoice({
    required this.sessionId,
    required this.keepHere,
    this.message,
  });

  final String sessionId;

  /// Sent as its next turn; null resumes it idle.
  final String? message;

  /// Kept on the dashboard rather than opened in a tab.
  final bool keepHere;
}

/// **Resume…** from the dashboard: the picker — a full-screen sheet on a
/// phone, a dialog elsewhere — and then the resume it asked for.
Future<void> showOverviewResume(BuildContext context, WidgetRef ref) async {
  final compact = WidthClass.of(MediaQuery.sizeOf(context).width).isCompact;
  final choice = await showAdaptiveModal<ResumeChoice>(
    context: context,
    title: 'Resume a session',
    heightFactor: compact ? 1 : 0.8,
    width: DialogWidth.regular,
    // Ticked as the background setting says; unticking is for this resume
    // only.
    builder: (_) =>
        OverviewResumePicker(keepHere: ref.read(launchInBackgroundProvider)),
  );
  if (choice == null || !context.mounted) return;
  await runResumeChoice(context, ref, choice);
}

/// Resumes as [choice] says. Kept here: at the server, no tab, no focus
/// moved, its card picked and peeked. Otherwise in its tab, as Open tab does.
Future<void> runResumeChoice(
  BuildContext context,
  WidgetRef ref,
  ResumeChoice choice,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final prefs = ref.read(overviewPrefsProvider.notifier);
  final id = choice.sessionId;
  final message = choice.message?.trim();
  void say(String? text) {
    if (text != null) messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  if (choice.keepHere) {
    prefs.setView(OverviewView.board);
    await resumeOnDashboard(context, ref, id, message: message);
    return;
  }
  final showWorkbench = phoneWorkbenchOpener(context, ref);
  final actions = ref.read(sessionActionsProvider);
  try {
    if (message != null && message.isNotEmpty) {
      await actions.continueSession(id, message);
    } else {
      await actions.unarchiveSessions([id]);
      final result = await ref.read(explorerActionsProvider).openNative(id);
      say(result.message);
      if (result.isFailure) return;
    }
    showWorkbench?.call();
  } on Object catch (error) {
    say(error is StateError ? error.message : '$error');
  }
}

/// The sessions nothing runs now, to search and narrow, then one chosen with
/// an optional message. Pops a [ResumeChoice].
class OverviewResumePicker extends ConsumerStatefulWidget {
  const OverviewResumePicker({required this.keepHere, super.key});

  /// Whether "Keep working here" starts ticked.
  final bool keepHere;

  @override
  ConsumerState<OverviewResumePicker> createState() =>
      _OverviewResumePickerState();
}

class _OverviewResumePickerState extends ConsumerState<OverviewResumePicker> {
  final _message = TextEditingController();
  var _query = '';
  String? _projectId;
  String? _agentId;
  var _includeArchived = false;
  ResumeCandidate? _chosen;
  late var _keepHere = widget.keepHere;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  void _resume({required bool send}) {
    final chosen = _chosen;
    if (chosen == null) return;
    final text = _message.text.trim();
    Navigator.of(context).pop(
      ResumeChoice(
        sessionId: chosen.id,
        message: send && text.isNotEmpty ? text : null,
        keepHere: _keepHere,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chosen = _chosen;
    return KeyedSubtree(
      key: const ValueKey('overview-resume-picker'),
      child: chosen == null ? _list(context) : _compose(context, chosen),
    );
  }

  Widget _list(BuildContext context) {
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    final all = ref.watch(overviewResumeCandidatesProvider);
    final shown = filterResumeCandidates(
      all,
      query: _query,
      projectId: _projectId,
      agentId: _agentId,
      includeArchived: _includeArchived,
    );
    final projects = <String, String>{
      for (final c in all) ?c.projectId: c.projectName ?? 'Unnamed project',
    };
    final agents = <String, String>{
      for (final c in all) ?c.agentId: c.agentName ?? 'Unknown agent',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
          child: SearchField(
            key: const ValueKey('overview-resume-search'),
            autofocus: true,
            decoration: compactSearchDecoration(
              hintText: 'Search stopped and ended sessions',
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.sm,
            Insets.lg,
            Insets.sm,
          ),
          child: Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              _PickChip(
                key: const ValueKey('overview-resume-project'),
                all: 'All projects',
                choices: projects,
                chosen: _projectId,
                onChosen: (id) => setState(() => _projectId = id),
              ),
              _PickChip(
                key: const ValueKey('overview-resume-agent'),
                all: 'All agents',
                choices: agents,
                chosen: _agentId,
                onChosen: (id) => setState(() => _agentId = id),
              ),
              FilterChip(
                key: const ValueKey('overview-resume-archived'),
                label: const Text('Include archived'),
                selected: _includeArchived,
                visualDensity: VisualDensity.compact,
                onSelected: (on) => setState(() => _includeArchived = on),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Insets.lg),
                    child: Text(
                      all.isEmpty
                          ? 'Every session is running. Nothing to resume.'
                          : 'No stopped or ended session matches.',
                      key: const ValueKey('overview-resume-empty'),
                      textAlign: TextAlign.center,
                      style: muted,
                    ),
                  ),
                )
              : ListView.builder(
                  key: const ValueKey('overview-resume-list'),
                  padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                  itemCount: shown.length,
                  itemBuilder: (context, i) => _CandidateRow(
                    candidate: shown[i],
                    onTap: () => setState(() => _chosen = shown[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _compose(BuildContext context, ResumeCandidate chosen) {
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    return ListenableBuilder(
      listenable: _message,
      builder: (context, _) {
        final hasMessage = _message.text.trim().isNotEmpty;
        return ListView(
          key: const ValueKey('overview-resume-compose'),
          padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
          children: [
            Row(
              children: [
                IconButton(
                  key: const ValueKey('overview-resume-back'),
                  tooltip: 'Back to the list',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _chosen = null),
                  icon: const Icon(AppIcons.arrowLeft),
                ),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chosen.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        resumeCandidateLine(chosen),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.md),
            // Enter sends, Shift+Enter is a new line; a soft keyboard's
            // Send key does the same.
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): () =>
                    _resume(send: true),
                const SingleActivator(LogicalKeyboardKey.numpadEnter): () =>
                    _resume(send: true),
              },
              child: TextField(
                key: const ValueKey('overview-resume-message'),
                controller: _message,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Add a message (optional)',
                ),
                onSubmitted: (_) => _resume(send: true),
              ),
            ),
            const SizedBox(height: Insets.sm),
            if (chosen.archived)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.xs),
                child: Text(
                  'Archived — resuming unarchives it.',
                  key: const ValueKey('overview-resume-unarchives'),
                  style: muted,
                ),
              ),
            Text(
              'Resuming costs nothing: the conversation is read back from '
              'disk. The next message carries the whole conversation to the '
              'model as context.',
              key: const ValueKey('overview-resume-cost'),
              style: muted,
            ),
            CheckboxListTile(
              key: const ValueKey('overview-resume-keep-here'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: _keepHere,
              title: const Text("Keep working here (don't open a tab)"),
              onChanged: (value) => setState(() => _keepHere = value ?? true),
            ),
            const SizedBox(height: Insets.sm),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Insets.sm,
              runSpacing: Insets.xs,
              children: [
                TextButton(
                  key: const ValueKey('overview-resume-idle'),
                  onPressed: () => _resume(send: false),
                  child: const Text('Resume'),
                ),
                FilledButton.icon(
                  key: const ValueKey('overview-resume-send'),
                  onPressed: hasMessage ? () => _resume(send: true) : null,
                  icon: const Icon(AppIcons.paperPlaneRight),
                  label: const Text('Resume and send'),
                ),
              ],
            ),
            const SizedBox(height: Insets.md),
          ],
        );
      },
    );
  }
}

/// "Claude Code · opus · karmashala": agent, model and project, as known.
String resumeCandidateLine(ResumeCandidate candidate) => [
  ?candidate.agentName,
  ?candidate.modelId,
  ?candidate.projectName,
].join(' · ');

/// One session in the picker: its title, agent · model · project, its last
/// answer on one line, and when it last ran.
class _CandidateRow extends ConsumerWidget {
  const _CandidateRow({required this.candidate, required this.onTap});

  final ResumeCandidate candidate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final now = ref.read(clockProvider).nowUtc();
    final said = ref
        .watch(overviewLastAnswerProvider(candidate.id))
        .value
        ?.text;
    final answer = said == null ? null : overviewPlain(said);
    final line = resumeCandidateLine(candidate);
    return InkWell(
      key: ValueKey('overview-resume-row:${candidate.id}'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Touch.target),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg,
            vertical: Insets.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: candidate.title),
                          if (candidate.archived)
                            TextSpan(
                              text: '  Archived',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: muted,
                                fontWeight: FontWeight.normal,
                              ),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (line.isNotEmpty)
                      Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    if (answer != null && answer.isNotEmpty)
                      Text(
                        answer,
                        key: ValueKey('overview-resume-answer:${candidate.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Insets.sm),
              Text(
                compactAge(now.difference(candidate.lastActiveAt)),
                style: theme.textTheme.labelSmall?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact filter that picks one of [choices], or all of them.
class _PickChip extends StatelessWidget {
  const _PickChip({
    required this.all,
    required this.choices,
    required this.chosen,
    required this.onChosen,
    super.key,
  });

  final String all;

  /// Name by id.
  final Map<String, String> choices;
  final String? chosen;
  final ValueChanged<String?> onChosen;

  static const _allValue = '';

  @override
  Widget build(BuildContext context) => Builder(
    builder: (chip) => FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(choices[chosen] ?? all),
          const SizedBox(width: Insets.xxs),
          const Icon(AppIcons.caretDown, size: Chrome.iconSmall),
        ],
      ),
      selected: chosen != null,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      onSelected: (_) async {
        final sorted = choices.entries.toList()
          ..sort(
            (a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()),
          );
        final picked = await showDesktopMenuUnder<String>(chip, [
          DesktopMenuItem(
            value: _allValue,
            label: all,
            icon: AppIcons.list,
            selected: chosen == null,
          ),
          for (final MapEntry(key: id, value: name) in sorted)
            DesktopMenuItem(
              value: id,
              label: name,
              icon: AppIcons.circle,
              selected: chosen == id,
            ),
        ]);
        if (picked != null) onChosen(picked == _allValue ? null : picked);
      },
    ),
  );
}
