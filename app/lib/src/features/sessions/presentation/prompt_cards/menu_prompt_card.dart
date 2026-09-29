import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/client.dart' show GatewayException;
import 'question_prompt_card.dart';

/// Chooses one option of a menu the agent drew on its screen.
typedef CompanionMenuAnswerFn = Future<void> Function(int option);

/// A menu the agent drew in its terminal — folder trust, a permission prompt,
/// a startup offer — with its own options to choose from. **No Approve**:
/// Approve is Enter, and Enter chooses whatever is highlighted, which on a
/// folder-trust prompt is "No, exit". Nothing is chosen until the user picks
/// an option and confirms it.
class MenuPromptCard extends StatefulWidget {
  const MenuPromptCard({
    required this.agentName,
    required this.menu,
    required this.onChoose,
    this.canAnswer = true,
    super.key,
  });

  final String agentName;
  final RemoteMenu menu;
  final CompanionMenuAnswerFn onChoose;

  /// Whether this reader may answer — the phone's `approve` capability.
  final bool canAnswer;

  @override
  State<MenuPromptCard> createState() => _MenuPromptCardState();
}

class _MenuPromptCardState extends State<MenuPromptCard> {
  /// Rows of the prompt shown before it scrolls; rows, so large text keeps
  /// them.
  static const _promptRows = 8;

  int? _chosen;
  bool _busy = false;

  @override
  void didUpdateWidget(MenuPromptCard old) {
    super.didUpdateWidget(old);
    // Another menu is another question: a choice made for the last one would
    // otherwise be one tap away from answering this one.
    if (old.menu.menuId != widget.menu.menuId) _chosen = null;
  }

  Future<void> _choose() async {
    final option = _chosen;
    if (_busy || option == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.onChoose(option);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is GatewayException ? e.message : '$e')),
      );
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
                '${widget.agentName} is asking you to choose',
                style: theme.textTheme.labelLarge,
              ),
            ),
          ],
        ),
        if (menu.prompt.isNotEmpty) ...[
          SizedBox(height: density.lineGap),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: _promptHeight(context)),
            child: SingleChildScrollView(
              child: SelectableText(
                menu.prompt.join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                ),
              ),
            ),
          ),
        ],
        SizedBox(height: density.lineGap),
        for (var i = 0; i < menu.options.length; i++)
          CompanionChoice(
            key: ValueKey('menu-option-$i'),
            label: menu.options[i],
            // Said, because it is the trap: the terminal's own default.
            description: i == menu.highlighted
                ? 'Highlighted in the terminal — what Enter alone would pick'
                : '',
            multi: false,
            selected: _chosen == i,
            onTap: _busy || !widget.canAnswer
                ? null
                : () => setState(() => _chosen = i),
          ),
        const SizedBox(height: Insets.sm),
        if (!widget.canAnswer)
          Text(
            'This phone was not granted approval rights, so it cannot answer. '
            'Answer in its terminal.',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
          )
        else ...[
          FilledButton(
            onPressed: _busy || _chosen == null ? null : _choose,
            child: const Text('Choose'),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'Karmashala moves to your choice in the terminal, checks it is '
            'highlighted, then confirms it.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  double _promptHeight(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final row = (style?.fontSize ?? Insets.md) * (style?.height ?? 1.35);
    return MediaQuery.textScalerOf(context).scale(row) * _promptRows;
  }
}
