import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/sessions/application/session_providers.dart';
import '../../features/sessions/application/session_signals.dart';
import '../../core/capabilities/capabilities.dart';
import '../../features/sessions/presentation/detach_session_action.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/sessions/presentation/operator_chip.dart';
import '../../features/automations/presentation/session_origin_label.dart';
import '../../features/sessions/presentation/session_repositories_bar.dart';
import '../../features/sessions/presentation/session_stats_dialog.dart';
import '../../features/sessions/presentation/session_subagents_panel.dart';
import '../../features/sessions/presentation/session_transcript_view.dart';

/// **⋯ on the pane status line**: the session's rarer verbs, which lived in
/// the chat view's header until the header went (owner, 2026-09-28: the tab
/// carries title and state, the status line the rest). On the status line so
/// terminal and chat view share them — one place per control. Since round 29
/// it also holds what the bar draws only when it has something to say: the
/// stats, the operator grant while off, and the view toggle when the bar is
/// short of room ([toggle]).
class SessionMoreButton extends ConsumerStatefulWidget {
  const SessionMoreButton({required this.sessionId, this.toggle, super.key});

  final String sessionId;

  /// The view toggle, when the bar has no room for it.
  final Widget? toggle;

  @override
  ConsumerState<SessionMoreButton> createState() => _SessionMoreButtonState();
}

class _SessionMoreButtonState extends ConsumerState<SessionMoreButton> {
  // Kept across rebuilds: the status line rebuilds as the session works, and
  // a new controller would close the card under the pointer.
  final _controller = MenuController();

  static const _width = 300.0;

  /// Asked from the button, which outlives the card: the confirm dialog's
  /// taps land outside the card and close it.
  void _letOperate() {
    _controller.close();
    setOperatorGrant(context, ref, widget.sessionId, granted: true);
  }

  @override
  Widget build(BuildContext context) {
    final tones = SurfaceTones.of(context);
    final toggle = widget.toggle;
    final theme = Theme.of(context);
    final label = theme.textTheme.labelSmall
        ?.merge(Chrome.groupLabel)
        .copyWith(color: theme.colorScheme.onSurfaceVariant);
    ref.watchSession(widget.sessionId);
    final operating =
        ref
            .read(sessionsDataProvider)
            .getById(widget.sessionId)
            ?.operatorGranted ??
        true;
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (toggle != null) ...[
                    Text('VIEW', style: label),
                    const SizedBox(height: Insets.xs),
                    toggle,
                    const SizedBox(height: Insets.sm),
                  ],
                  Text('AGENT', style: label),
                  const SizedBox(height: Insets.xs),
                  Wrap(
                    spacing: Insets.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SessionStatsButton(sessionId: widget.sessionId),
                      if (!operating)
                        TextButton.icon(
                          key: const ValueKey('session-more-operator'),
                          onPressed: _letOperate,
                          icon: const Icon(
                            AppIcons.shield,
                            size: Chrome.iconSmall,
                          ),
                          label: const Text('Let it operate Karmashala'),
                        ),
                    ],
                  ),
                  const SizedBox(height: Insets.sm),
                  SessionMoreBody(sessionId: widget.sessionId),
                ],
              ),
            ),
          ),
        ),
      ],
      child: IconButton(
        key: const ValueKey('session-more'),
        tooltip:
            'More: stats, recap, subagents, open in a system terminal, stop, '
            'repositories',
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
            _NewSubSessionButton(sessionId: sessionId),
            DetachSessionButton(sessionId: sessionId),
            StopSessionButton(sessionId: sessionId),
          ],
        ),
        SessionOriginLabel(sessionId: sessionId),
        const SizedBox(height: Insets.sm),
        Text('REPOSITORIES', style: label),
        const SizedBox(height: Insets.xs),
        SessionRepositoriesBar(sessionId: sessionId),
      ],
    );
  }
}

/// **New sub-session…**: the New-session dialog with "Link to" this session
/// ticked — any project, machine and agent, or none.
class _NewSubSessionButton extends ConsumerWidget {
  const _NewSubSessionButton({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(capabilitiesProvider.select((c) => c.mayStart))) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: const ValueKey('session-new-sub-session'),
      tooltip: 'New sub-session…',
      icon: const Icon(AppIcons.plusCircle),
      onPressed: () =>
          NewSessionDialog.show(context, parentSessionId: sessionId),
    );
  }
}
