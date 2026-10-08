import 'package:flutter/material.dart';

import 'package:karmashala_remote/client.dart' show GatewayException;
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'question_prompt_card.dart';

/// Submits a checklist with these ticks, one per box in order.
typedef ChecklistSubmitFn = Future<void> Function(List<bool> ticks);

/// A checklist the agent drew in its terminal — Claude Code's "2 new MCP
/// servers found in this project" — with a box per choice, ticked as the
/// screen has them, and the agent's own submit and reject. Enabling a server
/// is a trust decision: nothing is pressed until the person submits.
class ChecklistPromptCard extends StatefulWidget {
  const ChecklistPromptCard({
    required this.agentName,
    required this.menu,
    required this.onSubmit,
    required this.onReject,
    this.onOpenTerminal,
    this.canAnswer = true,
    super.key,
  });

  final String agentName;

  /// A checklist ([RemoteMenu.isChecklist]).
  final RemoteMenu menu;
  final ChecklistSubmitFn onSubmit;
  final Future<void> Function() onReject;

  /// Offered when an answer could not be seen to land.
  final VoidCallback? onOpenTerminal;

  /// Whether this reader may answer — the phone's `approve` capability.
  final bool canAnswer;

  @override
  State<ChecklistPromptCard> createState() => _ChecklistPromptCardState();
}

class _ChecklistPromptCardState extends State<ChecklistPromptCard> {
  late List<bool> _ticks = _seed();
  bool _busy = false;
  String? _failure;

  List<int> get _boxes => [
    for (var i = 0; i < widget.menu.checked.length; i++)
      if (widget.menu.checked[i] != null) i,
  ];

  List<bool> _seed() => [for (final i in _boxes) widget.menu.checked[i]!];

  @override
  void didUpdateWidget(ChecklistPromptCard old) {
    super.didUpdateWidget(old);
    // Another checklist is another question: ticks chosen for the last one
    // must not carry over.
    if (old.menu.menuId != widget.menu.menuId) {
      _ticks = _seed();
      _failure = null;
    }
  }

  Future<void> _run(Future<void> Function() answer) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await answer();
    } catch (e) {
      if (mounted) {
        setState(() => _failure = e is GatewayException ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final menu = widget.menu;
    final boxes = _boxes;
    final submit = menu.checked.indexOf(null);
    final enabled = widget.canAnswer && !_busy;
    final ticked = [
      for (var b = 0; b < boxes.length; b++)
        if (_ticks[b]) menu.options[boxes[b]],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              AppIcons.warningCircle,
              size: density.iconSmall,
              color: SemanticColors.of(context).attention,
            ),
            SizedBox(width: density.glyphGap),
            Expanded(
              child: Text(
                menu.prompt.isEmpty
                    ? '${widget.agentName} is asking you to choose'
                    : '${widget.agentName}: ${menu.prompt.first}',
                style: theme.textTheme.labelLarge,
              ),
            ),
          ],
        ),
        if (menu.prompt.length > 1) ...[
          SizedBox(height: density.lineGap),
          Text(
            menu.prompt.skip(1).join('\n'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        SizedBox(height: density.lineGap),
        for (var b = 0; b < boxes.length; b++)
          CompanionChoice(
            key: ValueKey('checklist-box-$b'),
            label: menu.options[boxes[b]],
            description: '',
            multi: true,
            selected: _ticks[b],
            onTap: enabled
                ? () => setState(() => _ticks[b] = !_ticks[b])
                : null,
          ),
        const SizedBox(height: Insets.sm),
        if (!widget.canAnswer)
          Text(
            'This phone was not granted approval rights, so it cannot answer. '
            'Answer in its terminal.',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
          )
        else ...[
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              FilledButton(
                key: const ValueKey('checklist-submit'),
                onPressed: enabled && submit >= 0
                    ? () => _run(() => widget.onSubmit(List.of(_ticks)))
                    : null,
                child: Text(submit >= 0 ? menu.options[submit] : 'Submit'),
              ),
              OutlinedButton(
                key: const ValueKey('checklist-reject'),
                onPressed: enabled ? () => _run(widget.onReject) : null,
                child: const Text('Reject all'),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          Text(
            ticked.isEmpty
                ? 'Nothing ticked: none will be enabled.'
                : 'Will enable ${ticked.join(', ')}. Karmashala ticks each box '
                      'in the terminal, checks it, then submits.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        if (_failure case final failure?) ...[
          const SizedBox(height: Insets.xs),
          Text(
            failure,
            key: const ValueKey('checklist-failure'),
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
          ),
          if (widget.onOpenTerminal case final open?)
            TextButton.icon(
              onPressed: open,
              icon: const Icon(AppIcons.terminal, size: Chrome.iconSmall),
              label: const Text('Open the terminal'),
            ),
        ],
      ],
    );
  }
}
