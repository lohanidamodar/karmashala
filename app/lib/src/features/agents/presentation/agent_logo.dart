import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';

import '../application/agent_providers.dart';
import 'agent_glyph_icon.dart';

/// **An agent's own mark**, as its adapter names it ([AgentPresentation.mark]):
/// the logo the app ships for that mark, or the adapter's generic glyph when
/// it names none. Decorative: whoever draws it says the agent's name.
class AgentLogo extends ConsumerWidget {
  const AgentLogo({
    required this.agentId,
    this.size = 14,
    this.color,
    super.key,
  });

  final String agentId;
  final double size;

  /// The tint for a glyph; a logo image keeps its own colours.
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presentation = ref
        .watch(agentRegistryProvider)
        .adapterFor(agentId)
        ?.presentation;
    return switch (presentation?.mark) {
      AgentMark.claude => _image('assets/agents/claude.png'),
      AgentMark.antigravity => _image('assets/agents/antigravity.png'),
      AgentMark.openAi => Icon(AppIcons.openAiLogo, size: size, color: color),
      null => Icon(
        agentGlyphIcon(presentation?.glyph ?? AgentGlyph.robot),
        size: size,
        color: color,
      ),
    };
  }

  Widget _image(String asset) => Image.asset(
    asset,
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
    excludeFromSemantics: true,
  );
}
