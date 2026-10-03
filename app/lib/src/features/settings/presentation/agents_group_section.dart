import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import 'settings_catalog.dart';
import 'settings_page_body.dart' show SettingsAnchorScope;
import 'settings_section.dart';

/// **One group of the Agents and accounts page**: a section label with a
/// count ("TERMINAL AGENTS · 3"), a fold button beside it, and its rows
/// under it while open. Open by default, and opened again by a deep link to
/// an anchor it holds ([anchors]) — so a link never lands on a folded group.
class AgentsGroupSection extends StatefulWidget {
  const AgentsGroupSection({
    required this.title,
    required this.children,
    this.count,
    this.trailing,
    this.anchors = const {},
    super.key,
  });

  /// Written as the catalogue writes a heading; uppercased here.
  final String title;
  final int? count;
  final List<Widget> children;

  /// An action that stays beside the fold button: "Add ACP agent…".
  final Widget? trailing;
  final Set<SettingsAnchor> anchors;

  @override
  State<AgentsGroupSection> createState() => _AgentsGroupSectionState();
}

class _AgentsGroupSectionState extends State<AgentsGroupSection> {
  bool _open = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final revealing = SettingsAnchorScope.revealingOf(context);
    if (revealing != null && widget.anchors.contains(revealing)) _open = true;
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.count;
    final heading = count == null ? widget.title : '${widget.title} · $count';
    final fold = IconButton(
      tooltip: _open ? 'Collapse ${widget.title}' : 'Expand ${widget.title}',
      icon: Icon(
        _open ? AppIcons.caretUp : AppIcons.caretDown,
        size: Chrome.iconAction,
      ),
      visualDensity: VisualDensity.compact,
      onPressed: () => setState(() => _open = !_open),
    );
    final trailing = widget.trailing;
    return SettingsSection(
      title: heading.toUpperCase(),
      trailing: trailing == null
          ? fold
          : Wrap(
              spacing: Insets.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [trailing, fold],
            ),
      child: _open
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.children,
            )
          : const SizedBox.shrink(),
    );
  }
}
