import 'package:agent_cli/descriptors.dart';
import 'package:flutter/widgets.dart';
import 'package:karmashala_ui/icons.dart';

/// The app's icon for an adapter's [AgentGlyph] hint.
IconData agentGlyphIcon(AgentGlyph glyph) => switch (glyph) {
  AgentGlyph.robot => AppIcons.robot,
  AgentGlyph.terminal => AppIcons.terminal,
};
