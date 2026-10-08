// A session's card, with its process groups and process lines.

part of '../running_cards.dart';

/// One session's card: what it is, where, how much runs, and what matters
/// first; the wrappers and the whole tree are a tap away.
class RunningSessionCard extends ConsumerStatefulWidget {
  const RunningSessionCard({
    required this.session,
    required this.machineLabel,
    required this.initiallyOpen,
    this.onDismissNote,
    super.key,
  });

  final BoardSession session;
  final MachineLabel machineLabel;
  final bool initiallyOpen;
  final void Function(RunningNote note)? onDismissNote;

  @override
  ConsumerState<RunningSessionCard> createState() => _RunningSessionCardState();
}

class _RunningSessionCardState extends ConsumerState<RunningSessionCard> {
  late var _open = widget.initiallyOpen;
  var _helpers = false;
  var _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final session = widget.session;
    final sessionId = session.agentSessionId;
    final agentId = sessionId == null
        ? null
        : ref.watch(sessionAgentIdProvider(sessionId));
    final title = session.title ?? 'a pane';
    final runs = session.agentSessionId == null
        ? const <SessionBackgroundRun>[]
        : ref
              .watch(sessionBackgroundRunsProvider(session.agentSessionId!))
              .where((r) => r.run.state == BackgroundRunState.running)
              .toList();
    final counts = [
      widget.machineLabel(session.machine),
      '${session.processCount} '
          '${session.processCount == 1 ? 'process' : 'processes'}',
      if (session.portCount > 0)
        '${session.portCount} ${session.portCount == 1 ? 'port' : 'ports'}',
    ].join(' · ');
    final shown = session.headline.isNotEmpty
        ? session.headline
        : session.others.take(3).toList();
    final hiddenOthers =
        session.others.length - (session.headline.isEmpty ? shown.length : 0);
    return _Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            label:
                '${session.agentSessionId == null ? 'Terminal' : 'Session'} '
                '$title, $counts',
            excludeSemantics: true,
            child: InkWell(
              key: ValueKey('running-session-${session.key}'),
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.md,
                  Insets.sm,
                  Insets.sm,
                  Insets.sm,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: Insets.xxs),
                      child: agentId != null
                          ? AgentLogo(agentId: agentId, size: Chrome.iconTitle)
                          : Icon(
                              AppIcons.terminal,
                              size: Chrome.iconTitle,
                              color: scheme.onSurfaceVariant,
                            ),
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.titleSmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          RunningMuted(counts),
                        ],
                      ),
                    ),
                    Icon(
                      _open ? AppIcons.caretUp : AppIcons.caretDown,
                      size: Chrome.iconSmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.md,
                0,
                Insets.xs,
                Insets.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final note in session.notes)
                    RunningInfoRow(
                      text: note.text,
                      onDismiss: widget.onDismissNote == null
                          ? null
                          : () => widget.onDismissNote!(note),
                    ),
                  for (final group in shown)
                    _GroupRow(group: group, owner: title),
                  for (final run in runs)
                    RunningMuted(
                      'Background ${run.run.kind.name}: '
                      '${run.run.description ?? run.run.id}',
                    ),
                  Wrap(
                    spacing: Insets.xs,
                    children: [
                      if (hiddenOthers > 0 && !_all)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: Insets.sm,
                          ),
                          child: RunningMuted('+$hiddenOthers more'),
                        ),
                      if (session.helpers.isNotEmpty && !_all)
                        TextButton(
                          key: ValueKey('running-helpers-${session.key}'),
                          onPressed: () => setState(() => _helpers = !_helpers),
                          child: Text(
                            '${_helpers ? 'Hide' : session.helpers.length} '
                            'helper ${session.helpers.length == 1 ? 'process' : 'processes'}',
                          ),
                        ),
                      if (session.processCount > 0)
                        TextButton(
                          key: ValueKey('running-all-${session.key}'),
                          onPressed: () => setState(() => _all = !_all),
                          child: Text(
                            _all ? 'Hide the tree' : 'Show all processes',
                          ),
                        ),
                    ],
                  ),
                  if (_helpers && !_all)
                    for (final process in session.helpers)
                      _ProcessLine(process: process, owner: title, depth: 1),
                  if (_all)
                    for (final (process, depth) in _tree(session.processes))
                      _ProcessLine(
                        process: process,
                        owner: title,
                        depth: depth,
                      ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// [processes] in tree order, each with its depth under the pane's root.
  static List<(RunningProcess, int)> _tree(List<RunningProcess> processes) {
    final live = processes.where((p) => p.pid > 0).toList();
    final byPid = {for (final p in live) '${p.pidMachine}:${p.pid}': p};
    final children = <String, List<RunningProcess>>{};
    final roots = <RunningProcess>[];
    for (final process in live) {
      final parentKey = '${process.pidMachine}:${process.parent}';
      if (byPid.containsKey(parentKey) && process.parent != process.pid) {
        (children[parentKey] ??= []).add(process);
      } else {
        roots.add(process);
      }
    }
    final out = <(RunningProcess, int)>[];
    void visit(RunningProcess process, int depth) {
      if (out.length > live.length) return;
      out.add((process, depth));
      for (final child
          in children['${process.pidMachine}:${process.pid}'] ??
              const <RunningProcess>[]) {
        visit(child, depth + 1);
      }
    }

    for (final root in roots) {
      visit(root, 0);
    }
    return out;
  }
}

/// `node · :3000 · vite --port 3000`, or `flutter_tester.exe ×6`, opening to
/// its processes.
class _GroupRow extends StatefulWidget {
  const _GroupRow({required this.group, required this.owner});

  final ProcessGroup group;
  final String owner;

  @override
  State<_GroupRow> createState() => _GroupRowState();
}

class _GroupRowState extends State<_GroupRow> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final single = group.count == 1 ? group.processes.single : null;
    final ports = group.ports.map((p) => ':${p.port}').join(' ');
    final line = single?.commandLine;
    final theme = Theme.of(context);
    Widget row(BuildContext context, Widget? menu) => Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: single == null ? () => setState(() => _open = !_open) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      text: group.name,
                      children: [
                        if (group.count > 1)
                          TextSpan(
                            text: ' ×${group.count}',
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        if (ports.isNotEmpty)
                          TextSpan(
                            text: '  $ports',
                            style: TextStyle(color: theme.colorScheme.primary),
                          ),
                      ],
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                  if (line != null && line.isNotEmpty)
                    Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFamily: kBundledMonoFamily,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        ?menu,
        if (single == null)
          IconButton(
            tooltip: _open ? 'Hide them' : 'Show each',
            iconSize: Chrome.iconSmall,
            icon: Icon(_open ? AppIcons.caretUp : AppIcons.caretDown),
            onPressed: () => setState(() => _open = !_open),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (single != null)
          RunningStoppable(process: single, owner: widget.owner, builder: row)
        else
          row(context, null),
        if (_open)
          for (final process in group.processes)
            _ProcessLine(process: process, owner: widget.owner, depth: 1),
      ],
    );
  }
}

/// One process in the tree: its name and pid, and Stop behind ⋯.
class _ProcessLine extends StatelessWidget {
  const _ProcessLine({
    required this.process,
    required this.owner,
    required this.depth,
  });

  final RunningProcess process;
  final String owner;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final ports = process.ports.map((p) => ':${p.port}').join(' ');
    return RunningStoppable(
      process: process,
      owner: owner,
      builder: (context, menu) => Padding(
        padding: EdgeInsets.only(left: Insets.md * depth.clamp(0, 6)),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
                child: Text(
                  '${process.name ?? 'process'} · pid ${process.pid}'
                  '${ports.isEmpty ? '' : '  $ports'}',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            ?menu,
          ],
        ),
      ),
    );
  }
}
