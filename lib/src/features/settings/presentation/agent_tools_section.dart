import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'settings_section.dart';

/// Every tool the MCP bridge serves, grouped and described from
/// `mcp_tool_catalogue` (under a test, so it cannot rot). Three of its five
/// axes are shown; the other two say nothing a reader of this page needs.
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

/// One family, collapsed: ninety-four unfurled rows would bury the page.
class _Family extends StatelessWidget {
  const _Family({required this.category, required this.tools});

  final McpToolCategory category;
  final List<String> tools;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      // The settings page has no cards; this tile's would be the only one.
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
            // A Wrap, not a Row: marks follow the name at any text scale.
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

/// One mark beside a tool name. A constructor per mark, not a colour argument,
/// and each says its own words: colour alone never carries state (§5).
class _Mark extends StatelessWidget {
  /// Changes nothing, anywhere.
  const _Mark.readOnly() : _text = 'read-only', _color = _MarkColor.neutral;

  /// No undo for what it removes or ends — the consequence, not the hint's name.
  const _Mark.noUndo() : _text = 'no undo', _color = _MarkColor.danger;

  /// It raises a window or waits on the person. Attention, not danger.
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
