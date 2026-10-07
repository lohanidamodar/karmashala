import 'package:agent_cli/read.dart' show BackgroundRunState;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/agents/presentation/agent_logo.dart';
import '../../features/git/application/remote_links.dart'
    show openExternalUrlProvider;
import '../../features/running/application/running_providers.dart';
import '../../features/running/domain/port_label.dart';
import '../../features/running/domain/running_board.dart';
import '../../features/sessions/application/background_runs_providers.dart';
import '../../features/sessions/application/session_agent_providers.dart';
import '../../features/settings/presentation/settings_catalog.dart';
import 'phone_routes.dart';
import 'running_tab_view.dart' show openPortInBrowserPane;
import 'workbench_tabs.dart' show openSettingsTab;

/// A section's heading: its name and how many it holds.
class RunningSectionHeading extends StatelessWidget {
  const RunningSectionHeading(this.text, {this.count, super.key});

  final String text;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md, bottom: Insets.sm),
      child: Semantics(
        header: true,
        child: Text.rich(
          TextSpan(
            text: text,
            children: [
              if (count case final count?)
                TextSpan(
                  text: '  $count',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
            ],
          ),
          style: theme.textTheme.titleSmall,
        ),
      ),
    );
  }
}

/// Quiet words: an empty state, a time, a count.
class RunningMuted extends StatelessWidget {
  const RunningMuted(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// A sentence about what was not read, put away once read.
class RunningInfoRow extends StatelessWidget {
  const RunningInfoRow({required this.text, this.onDismiss, super.key});

  final String text;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
      padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.xs, 0, Insets.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs / 2),
            child: Icon(
              AppIcons.info,
              size: Chrome.iconSmall,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(child: RunningMuted(text)),
          if (onDismiss != null)
            IconButton(
              tooltip: 'Dismiss',
              iconSize: Chrome.iconSmall,
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.x),
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }
}

/// A rounded, outlined surface every card on the tab sits on.
class _Surface extends StatelessWidget {
  const _Surface({required this.child, this.quiet = false});

  final Widget child;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      decoration: BoxDecoration(
        color: quiet ? scheme.surface : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

IconData _iconFor(PortKind kind) => switch (kind) {
  PortKind.http => AppIcons.globe,
  PortKind.devTools => AppIcons.globe,
  PortKind.dartVmService => AppIcons.code,
  PortKind.database => AppIcons.stack,
  PortKind.device => AppIcons.deviceMobile,
  PortKind.karmashala => AppIcons.gearSix,
  PortKind.other => AppIcons.linkSimple,
};

/// Opens [url] in the system's browser at once — or, [inPane], in
/// Karmashala's Browser pane. From a phone the desktop's Browser pane shows
/// it, and says so.
Future<void> openRunningUrl(
  WidgetRef ref,
  String url, {
  bool inPane = false,
  ScaffoldMessengerState? messenger,
}) async {
  final phone = ref.read(phoneShellRouterProvider).current != null;
  if (phone || inPane) {
    await openPortInBrowserPane(ref, url, messenger: messenger);
    return;
  }
  await ref.read(openExternalUrlProvider)(url);
}

/// One listening port: its address (a link when a browser can open it), what
/// it is, who holds it, and the ways to it.
class RunningPortCard extends ConsumerWidget {
  const RunningPortCard({
    required this.port,
    required this.machineLabel,
    this.isWsl = false,
    super.key,
  });

  final BoardPort port;
  final MachineLabel machineLabel;

  /// Whether it listens inside WSL, where Windows reaches it by forwarding.
  final bool isWsl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final number = port.port.port;
    final url = port.url;
    final phone = ref.watch(phoneShellRouterProvider).current != null;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final unforwarded = isWsl && url != null && !port.forwardedFromWsl;
    final copied = url ?? port.address;
    return RunningStoppable(
      process: port.process,
      owner: port.process.title ?? machineLabel(port.machine),
      builder: (context, menu) => _Surface(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.md,
            Insets.sm,
            Insets.xs,
            Insets.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                // On the link's centre-line when there is one.
                padding: EdgeInsets.only(
                  top: url == null
                      ? Insets.xs / 2
                      : ((phone ? Touch.target : Chrome.menuRow) -
                                Chrome.iconSmall) /
                            2,
                ),
                child: Icon(
                  _iconFor(port.label.kind),
                  size: Chrome.iconSmall,
                  color: url == null ? scheme.onSurfaceVariant : scheme.primary,
                ),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: Insets.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (url != null)
                          RunningLink(
                            key: ValueKey('running-link-$number'),
                            text: port.address,
                            url: url,
                            tooltip: switch ((isWsl, unforwarded)) {
                              (true, true) =>
                                'Bound to ${port.port.address} inside WSL: '
                                    'Windows\' localhost may not reach it',
                              (true, false) =>
                                'WSL forwards this port to Windows\' localhost',
                              _ => null,
                            },
                            minHeight: phone ? Touch.target : Chrome.menuRow,
                            onOpen: (inPane) => openRunningUrl(
                              ref,
                              url,
                              inPane: inPane,
                              messenger: messenger,
                            ),
                          )
                        else
                          SelectableText(
                            port.address,
                            key: ValueKey('running-address-$number'),
                            style: theme.textTheme.titleSmall,
                          ),
                        if (unforwarded)
                          Icon(
                            AppIcons.warning,
                            size: Chrome.iconSmall,
                            color: scheme.onSurfaceVariant,
                            semanticLabel: 'may not be reachable from Windows',
                          ),
                      ],
                    ),
                    const SizedBox(height: Insets.xs / 2),
                    _PortOwnerLine(port: port, machineLabel: machineLabel),
                    if (port.port.host != null && port.label.isHttp)
                      RunningMuted(
                        'On ${machineLabel(port.machine)}; not forwarded here.',
                      ),
                  ],
                ),
              ),
              // The phone's link already goes to the desktop's Browser pane.
              if (url != null && !phone)
                IconButton(
                  key: ValueKey('running-open-pane-$number'),
                  tooltip: 'Open in Karmashala\'s browser',
                  iconSize: Chrome.iconSmall,
                  icon: const Icon(AppIcons.globe),
                  onPressed: () => openRunningUrl(
                    ref,
                    url,
                    inPane: true,
                    messenger: messenger,
                  ),
                ),
              IconButton(
                key: ValueKey('running-copy-$number'),
                tooltip: url == null ? 'Copy address' : 'Copy URL',
                iconSize: Chrome.iconSmall,
                icon: const Icon(AppIcons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: copied));
                  messenger?.showSnackBar(
                    SnackBar(content: Text('Copied $copied')),
                  );
                },
              ),
              ?menu,
            ],
          ),
        ),
      ),
    );
  }
}

/// `Vite dev server · ◐ analytics · WSL · archlinux`.
class _PortOwnerLine extends ConsumerWidget {
  const _PortOwnerLine({required this.port, required this.machineLabel});

  final BoardPort port;
  final MachineLabel machineLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final process = port.process;
    final sessionId = process.agentSessionId;
    final agentId = sessionId == null
        ? null
        : ref.watch(sessionAgentIdProvider(sessionId));
    final owner = switch (port.owner) {
      PortOwner.session || PortOwner.terminal => process.title ?? 'a pane',
      PortOwner.server => 'Karmashala server',
      PortOwner.device => 'Device mirroring',
      PortOwner.machine => 'not started by a session',
    };
    return Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xs / 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(port.label.name, style: style),
        Text('·', style: style),
        if (agentId != null)
          AgentLogo(agentId: agentId, size: Chrome.iconSmall)
        else if (port.owner == PortOwner.terminal)
          Icon(
            AppIcons.terminal,
            size: Chrome.iconSmall,
            color: scheme.onSurfaceVariant,
          ),
        Text(owner, style: style),
        Text('·', style: style),
        Text(machineLabel(port.machine), style: style),
      ],
    );
  }
}

/// An address that is a link: the row's most prominent words, a pointer, one
/// click to open it in the system browser; Ctrl/Cmd-click opens it in
/// Karmashala's Browser pane.
class RunningLink extends StatefulWidget {
  const RunningLink({
    required this.text,
    required this.url,
    required this.onOpen,
    this.tooltip,
    this.minHeight = Chrome.menuRow,
    super.key,
  });

  final String text;
  final String url;
  final String? tooltip;

  /// The hit target's height: a pointer's 32, a thumb's [Touch.target].
  final double minHeight;

  /// Told whether the Browser pane was asked for.
  final void Function(bool inPane) onOpen;

  @override
  State<RunningLink> createState() => _RunningLinkState();
}

class _RunningLinkState extends State<RunningLink> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final link = Semantics(
      link: true,
      label: 'Open ${widget.url}',
      excludeSemantics: true,
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(Radii.sm),
        onHover: (hovered) => setState(() => _hovered = hovered),
        onTap: () {
          final keys = HardwareKeyboard.instance;
          widget.onOpen(keys.isControlPressed || keys.isMetaPressed);
        },
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: widget.minHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.xs / 2),
            child: Align(
              alignment: Alignment.centerLeft,
              widthFactor: 1,
              child: Text(
                widget.text,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                  decorationColor: _hovered
                      ? scheme.primary
                      : StateLayers.linkUnderline(scheme),
                  decorationThickness: _hovered ? 2 : 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final tooltip = widget.tooltip;
    return tooltip == null ? link : Tooltip(message: tooltip, child: link);
  }
}

/// A row about a process a pane started, with Stop on it — right-click,
/// Shift+F10, and a ⋯ [builder] places, shown on hover or focus (always under
/// a thumb). A process that cannot be stopped gets no menu.
class RunningStoppable extends ConsumerWidget {
  const RunningStoppable({
    required this.process,
    required this.owner,
    required this.builder,
    super.key,
  });

  final RunningProcess process;
  final String owner;
  final Widget Function(BuildContext context, Widget? menu) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!process.stoppable) return builder(context, null);
    final name = process.name ?? 'process';
    final label = 'More for $name ${process.pid}';
    List<PopupMenuEntry<String>> items() => [
      PopupMenuItem(
        key: ValueKey('running-stop-${process.pid}'),
        value: 'stop',
        child: Text('Stop $name…'),
      ),
    ];
    return RowContextMenu(
      menuLabel: label,
      itemBuilder: items,
      onSelected: (_) => _stop(context, ref, name),
      builder: (context) => builder(
        context,
        RowMenuButton(
          key: ValueKey('running-more-${process.pid}'),
          tooltip: label,
          itemBuilder: items,
          onSelected: (_) => _stop(context, ref, name),
        ),
      ),
    );
  }

  Future<void> _stop(BuildContext context, WidgetRef ref, String name) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final controller = ref.read(runningProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop $name?'),
        content: Text(
          'Process ${process.pid}, started in "$owner". What it started '
          'stops with it, and nothing it was doing is saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          DestructiveButton(
            key: const ValueKey('running-stop-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Stop $name'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final refusal = await controller.stop(process);
    if (refusal != null) {
      messenger?.showSnackBar(SnackBar(content: Text(refusal)));
    }
  }
}

/// The server's own ports, folded into one quiet card.
class RunningServerCard extends ConsumerStatefulWidget {
  const RunningServerCard({required this.server, super.key});

  final RunningProcess server;

  @override
  ConsumerState<RunningServerCard> createState() => _RunningServerCardState();
}

class _RunningServerCardState extends ConsumerState<RunningServerCard> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final server = widget.server;
    final count = server.ports.length;
    return _Surface(
      quiet: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('running-server-toggle'),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.sm,
              ),
              child: Row(
                children: [
                  const Icon(AppIcons.gearSix, size: Chrome.iconSmall),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      'Karmashala server · $count '
                      '${count == 1 ? 'port' : 'ports'}',
                    ),
                  ),
                  Icon(
                    _open ? AppIcons.caretUp : AppIcons.caretDown,
                    size: Chrome.iconSmall,
                    semanticLabel: _open ? 'Collapse' : 'Expand',
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...[
            for (final port in server.ports)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.xl + Insets.sm,
                  0,
                  Insets.md,
                  Insets.xs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'localhost:${port.port} — ${port.label ?? 'Server'}',
                      ),
                    ),
                    IconButton(
                      key: ValueKey('running-copy-${port.port}'),
                      tooltip: 'Copy address',
                      iconSize: Chrome.iconSmall,
                      icon: const Icon(AppIcons.copy),
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: 'localhost:${port.port}'),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(
                left: Insets.lg,
                bottom: Insets.xs,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('running-server-settings'),
                  onPressed: () =>
                      openSettingsTab(ref, section: SettingsSectionId.server),
                  child: Text(
                    'Manage in Settings → Server · pid ${server.pid}',
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

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
                      padding: const EdgeInsets.only(top: Insets.xs / 2),
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
                padding: const EdgeInsets.symmetric(vertical: Insets.xs / 2),
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
