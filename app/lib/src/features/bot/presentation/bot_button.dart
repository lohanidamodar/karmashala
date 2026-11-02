import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/capabilities/capabilities.dart';
import '../application/bot_providers.dart';
import 'bot_panel.dart' show notConnected;

/// **The Bot button**, in the title bar and the phone's top bar. Not drawn on
/// a server with no bot, disabled with its reason while the server is away,
/// and it carries a dot: the attention colour for a waiting question, the
/// unread colour for a reply. The dot's meaning is in the label too.
class BotButton extends ConsumerWidget {
  const BotButton({this.touch = false, this.chord, super.key});

  /// The phone's top bar: its 48dp target, not the title bar's glyph.
  final bool touch;

  /// How the shortcut is written, for the tooltip.
  final String? chord;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(capabilitiesProvider.select((c) => c.bot))) {
      return const SizedBox.shrink();
    }
    final connected = ref.watch(botConnectedProvider);
    final attention = ref.watch(botAttentionProvider);
    final selected = ref.watch(botPanelProvider);
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    final label = switch (attention) {
      BotAttention.none => 'Bot',
      BotAttention.unread => 'Bot, unread reply',
      BotAttention.waiting => 'Bot, waiting for your answer',
    };
    final enabled = connected;
    final VoidCallback? onPressed = enabled
        ? ref.read(botPanelProvider.notifier).toggle
        : null;
    final color = !enabled
        ? scheme.onSurfaceVariant.withValues(alpha: StateLayers.dimmedOpacity)
        : selected
        ? scheme.primary
        : scheme.onSurfaceVariant;
    final glyph = SizedBox(
      width: touch ? Touch.target : Chrome.control,
      height: touch ? Touch.target : Chrome.control,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            AppIcons.robot,
            size: touch ? Touch.icon * 4 / 3 : Chrome.icon,
            color: color,
          ),
          if (attention != BotAttention.none)
            PositionedDirectional(
              top: touch ? Insets.md : Insets.xs,
              end: touch ? Insets.md : Insets.xs,
              child: Container(
                key: ValueKey('bot-dot:${attention.name}'),
                width: Chrome.dot,
                height: Chrome.dot,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: attention == BotAttention.waiting
                      ? semantic.attention
                      : semantic.unread,
                ),
              ),
            ),
        ],
      ),
    );
    return Tooltip(
      message: enabled ? [label, ?chord].join('  ·  ') : notConnected,
      child: Semantics(
        button: true,
        enabled: enabled,
        selected: selected,
        label: label,
        hint: enabled ? null : notConnected,
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('bot-button'),
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: onPressed,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected ? StateLayers.selected(scheme) : null,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: glyph,
          ),
        ),
      ),
    );
  }
}
