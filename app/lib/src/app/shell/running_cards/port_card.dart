// A listening port's card, its owner line, and the link it opens.

part of '../running_cards.dart';

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
                      ? Insets.xxs
                      : ((phone ? Touch.target : Chrome.menuRow) -
                                Chrome.iconSmall) /
                            Insets.xxs,
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
                    const SizedBox(height: Insets.xxs),
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
      runSpacing: Insets.xxs,
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
            padding: const EdgeInsets.symmetric(horizontal: Insets.xxs),
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
