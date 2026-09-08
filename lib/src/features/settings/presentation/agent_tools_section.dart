import 'package:flutter/material.dart';

import '../../../app/theme/design_tokens.dart';
import '../../mcp/mcp_tool_catalogue.dart';
import 'settings_section.dart';

/// Settings → Tools → Agent tools: every tool the MCP bridge serves, in its
/// family, with a line saying what it does.
///
/// ## What was here before
///
/// The same 94 names, as a `Wrap` of chips. Complete and useless: nothing said
/// what any of them did, nothing said which belonged together, and a reader
/// asking "can it drive my phone" had to read the whole wall and infer it from
/// prefixes. The names come from the served schemas either way — what is added
/// is the grouping and the line, both of which live in `mcp_tool_catalogue`
/// under a test, so the list cannot rot the first time somebody adds a tool.
///
/// ## Read-only, no-undo and moves-attention, and not the other two
///
/// The catalogue carries five axes. Three of them are facts a person acts on —
/// *this changes nothing*, *this cannot be undone*, and *this takes over what I
/// am looking at* — and they are the three shown. `idempotentHint` answers "is
/// a retry safe", which is something a client decides on its own with nobody
/// watching; and `openWorldHint` marks exactly the device, browser and
/// Flutter-app families, so as a tag it would repeat the heading above it on
/// about forty rows. Both still travel in `tools/list`, and the guides
/// `instructions` serves print all five.
///
/// The third tag is the one a reader of this page cannot get anywhere else.
/// Read-only and no-undo can both be guessed from a tool's name about half the
/// time; that `browser_pick` will front their browser and wait on them, or that
/// `device_boot` selects a simulator in the pane, cannot be.
///
/// ## No switches
///
/// It is a listing, not a control panel. Whether a tool can be turned off is a
/// product decision nobody has made, and a switch that does nothing is worse
/// than no switch.
///
/// It watches no provider: everything on it is compiled into the binary, so
/// the section costs nothing until a family is opened and nothing after.
class AgentToolsSection extends StatelessWidget {
  const AgentToolsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsSection(
      title: 'WHAT AN AGENT CAN CALL',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${kMcpToolListings.length} tools, in '
            '${McpToolCategory.values.length} families. An agent that reaches '
            'the bridge above can call all of them; open a family to see what '
            'each one does.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.xs),
          for (final entry in kMcpToolsByCategory.entries)
            _Family(category: entry.key, tools: entry.value),
        ],
      ),
    );
  }
}

/// One family, collapsed until asked for.
///
/// Collapsed because this section sits under three other blocks on the Tools
/// page and ninety-four unfurled rows would bury them — and because the reader
/// arrives looking for a family ("can it touch my phone?") rather than for a
/// tool they could already name.
class _Family extends StatelessWidget {
  const _Family({required this.category, required this.tools});

  final McpToolCategory category;
  final List<String> tools;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      // The settings page has no cards; the tile's own outline and fill would
      // be the only ones on it.
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(
        left: Insets.md,
        bottom: Insets.sm,
      ),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: Row(
        children: [
          Expanded(
            child: Text(category.label, style: theme.textTheme.bodyMedium),
          ),
          const SizedBox(width: Insets.sm),
          Text(
            '${tools.length}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: SemanticColors.of(context).neutral,
            ),
          ),
        ],
      ),
      subtitle: Text(category.blurb, style: theme.textTheme.bodySmall),
      children: [for (final name in tools) _ToolRow(name: name)],
    );
  }
}

/// One tool: its name, what it does, and the marks worth a person's attention.
class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final listing = kMcpToolListings[name]!;
    final annotations = kMcpToolAnnotations[name]!;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(bottom: Insets.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A Wrap, not a Row: the marks follow the name at any text scale
            // rather than squeezing it.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Insets.sm,
              runSpacing: Insets.xs,
              children: [
                Text(name, style: MonoStyles.body),
                if (annotations.readOnly) const _Mark.readOnly(),
                if (annotations.destructive) const _Mark.noUndo(),
                if (annotations.movesAttention) const _Mark.movesAttention(),
              ],
            ),
            Text(listing.summary, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// One mark beside a tool name.
///
/// A constructor per mark rather than a colour argument, the way `_HookNote` on
/// this page does it: which mark a row gets is the claim it makes, not a
/// styling choice. Each one says its own words as well as wearing its own
/// colour — §5's rule that state is never carried by colour alone.
class _Mark extends StatelessWidget {
  /// Changes nothing, anywhere.
  const _Mark.readOnly() : _text = 'read-only', _color = _MarkColor.neutral;

  /// There is no undo for what it removes, overwrites or ends. Worded as the
  /// consequence rather than as `destructiveHint`'s name: the reader is
  /// deciding whether to worry, not reading a spec.
  const _Mark.noUndo() : _text = 'no undo', _color = _MarkColor.danger;

  /// It raises a window, switches what is on screen, or stops and asks the
  /// person to point at something. The attention colour rather than the danger
  /// one: being interrupted is not the same as losing work.
  const _Mark.movesAttention()
    : _text = 'moves attention',
      _color = _MarkColor.attention;

  final String _text;
  final _MarkColor _color;

  @override
  Widget build(BuildContext context) {
    final semantic = SemanticColors.of(context);
    final color = switch (_color) {
      _MarkColor.neutral => semantic.neutral,
      _MarkColor.danger => semantic.failure,
      _MarkColor.attention => semantic.attention,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(_text, style: MonoStyles.small.copyWith(color: color)),
    );
  }
}

/// Which of [SemanticColors] a mark wears. Named for the claim, not the hue.
enum _MarkColor { neutral, danger, attention }
