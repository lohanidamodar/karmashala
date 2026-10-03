import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/sessions/presentation/session_repositories_bar.dart';
import '../../features/sessions/presentation/session_subagents_panel.dart';
import '../../features/sessions/presentation/session_transcript_view.dart';

/// **⋯ on the pane status line**: the session's rarer verbs, which lived in
/// the chat view's header until the header went (owner, 2026-09-28: the tab
/// carries title and state, the status line the rest). On the status line so
/// terminal and chat view share them — one place per control.
class SessionMoreButton extends StatefulWidget {
  const SessionMoreButton({required this.sessionId, super.key});

  final String sessionId;

  @override
  State<SessionMoreButton> createState() => _SessionMoreButtonState();
}

class _SessionMoreButtonState extends State<SessionMoreButton> {
  // Kept across rebuilds: the status line rebuilds as the session works, and
  // a new controller would close the card under the pointer.
  final _controller = MenuController();

  static const _width = 300.0;

  @override
  Widget build(BuildContext context) {
    final tones = SurfaceTones.of(context);
    return MenuAnchor(
      controller: _controller,
      style: const MenuStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
      ),
      menuChildren: [
        // A fixed width answers the menu's intrinsic questions itself; nothing
        // below is a LayoutBuilder.
        SizedBox(
          width: _width,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tones.raised,
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(color: tones.floatingLine),
              boxShadow: Shadows.floating,
            ),
            child: Padding(
              padding: const EdgeInsets.all(Insets.sm),
              child: SessionMoreBody(sessionId: widget.sessionId),
            ),
          ),
        ),
      ],
      child: IconButton(
        key: const ValueKey('session-more'),
        tooltip: 'More: recap, open in a system terminal, stop, repositories',
        visualDensity: UiDensity.of(context).controlDensity,
        iconSize: Chrome.iconSmall,
        icon: const Icon(AppIcons.dotsThree),
        onPressed: () =>
            _controller.isOpen ? _controller.close() : _controller.open(),
      ),
    );
  }
}

/// What [SessionMoreButton]'s card holds; the phone's Session sheet lists the
/// same, so the verbs stay in one place.
class SessionMoreBody extends StatelessWidget {
  const SessionMoreBody({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = theme.textTheme.labelSmall
        ?.merge(Chrome.groupLabel)
        .copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SESSION', style: label),
        const SizedBox(height: Insets.xs),
        Row(
          children: [
            SessionRecapButton(sessionId: sessionId),
            SessionSubagentsButton(sessionId: sessionId),
            OpenSessionInSystemTerminalButton(sessionId: sessionId),
            StopSessionButton(sessionId: sessionId),
          ],
        ),
        const SizedBox(height: Insets.sm),
        Text('REPOSITORIES', style: label),
        const SizedBox(height: Insets.xs),
        SessionRepositoriesBar(sessionId: sessionId),
      ],
    );
  }
}
