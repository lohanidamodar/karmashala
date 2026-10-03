import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:karmashala_ui/icons.dart';

import '../application/acp_agent_icon_providers.dart';
import '../application/agent_providers.dart';
import 'agent_glyph_icon.dart';

/// **An agent's own mark**, as its adapter names it ([AgentPresentation]):
/// the logo the app ships for its mark, else the icon the registry publishes
/// for it once fetched, else the adapter's generic glyph. Decorative: whoever
/// draws it says the agent's name.
class AgentLogo extends ConsumerWidget {
  const AgentLogo({
    required this.agentId,
    this.size = 14,
    this.color,
    super.key,
  });

  final String agentId;
  final double size;

  /// The tint for a glyph or a registry icon; a logo image keeps its own
  /// colours.
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
      null => switch (presentation?.iconUrl) {
        final url? => _RegistryIcon(
          url: url,
          size: size,
          color: color,
          fallback: _glyph(presentation),
        ),
        null => _glyph(presentation),
      },
    };
  }

  Widget _glyph(AgentPresentation? presentation) => Icon(
    agentGlyphIcon(presentation?.glyph ?? AgentGlyph.robot),
    size: size,
    color: color,
  );

  Widget _image(String asset) => Image.asset(
    asset,
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
    excludeFromSemantics: true,
  );
}

/// The registry's SVG for an agent, drawn in the glyph's tint (the registry
/// draws its icons in `currentColor`); the glyph until it is fetched, and
/// instead of it when it cannot be.
class _RegistryIcon extends ConsumerWidget {
  const _RegistryIcon({
    required this.url,
    required this.size,
    required this.color,
    required this.fallback,
  });

  final String url;
  final double size;
  final Color? color;
  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final svg = ref.watch(acpAgentIconProvider(url)).value;
    if (svg == null) return fallback;
    final tint =
        color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      theme: SvgTheme(currentColor: tint),
      excludeFromSemantics: true,
    );
  }
}
