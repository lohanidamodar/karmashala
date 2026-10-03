import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../agents/presentation/picker_face.dart';
import '../application/session_chat_source.dart';
import '../application/session_handoff_service.dart';
import 'continue_with_dialog.dart';

/// What the switch menu picked: an agent to switch to, or "Continue in a new
/// session…" — the older handoff, which starts a new row.
sealed class _Pick {
  const _Pick();
}

final class _SwitchTo extends _Pick {
  const _SwitchTo(this.target);
  final HandoffTarget target;
}

final class _NewSession extends _Pick {
  const _NewSession();
}

/// **The composer's "Switch agent" control**: the installed agents, the one
/// running this session refused, those that ran it before marked as resuming
/// their own conversation. Picking one hands the session over in place; the
/// last row opens "Continue with…" for a new session instead. Nothing is drawn
/// for a server that cannot switch.
class SwitchAgentControl extends ConsumerStatefulWidget {
  const SwitchAgentControl({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<SwitchAgentControl> createState() => _SwitchAgentControlState();
}

class _SwitchAgentControlState extends ConsumerState<SwitchAgentControl> {
  var _switching = false;

  Set<String> _used() {
    final messages =
        ref.read(sessionChatTranscriptProvider(widget.sessionId)).value ??
        const [];
    return {for (final message in messages) ?message.agentInstallationId};
  }

  Future<void> _picked(_Pick pick) async {
    switch (pick) {
      case _NewSession():
        await ContinueWithDialog.show(context, widget.sessionId);
      case _SwitchTo(:final target):
        setState(() => _switching = true);
        final messenger = ScaffoldMessenger.maybeOf(context);
        try {
          await ref
              .read(sessionHandoffServiceProvider)
              .switchAgent(
                sessionId: widget.sessionId,
                targetInstallationId: target.installation.id,
              );
        } on Object catch (error) {
          messenger?.showSnackBar(
            SnackBar(
              content: Text(
                'Could not switch to ${target.agentName}: '
                '${error is StateError ? error.message : error}',
              ),
            ),
          );
        } finally {
          if (mounted) setState(() => _switching = false);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(capabilitiesProvider.select((c) => c.switchAgent))) {
      return const SizedBox.shrink();
    }
    return PopupMenuButton<_Pick>(
      key: const ValueKey('switch-agent'),
      tooltip: '',
      enabled: !_switching,
      position: PopupMenuPosition.over,
      onSelected: _picked,
      itemBuilder: (context) {
        final targets = ref
            .read(sessionHandoffServiceProvider)
            .switchTargetsFor(widget.sessionId, used: _used());
        return [
          for (final target in targets)
            DesktopMenuDetailItem<_Pick>(
              value: _SwitchTo(target),
              enabled: target.canReceive,
              selected: target.isSameAgent,
              label: target.agentName,
              badge: target.resumesConversation
                  ? 'resumes its conversation'
                  : null,
              detail:
                  target.refusal ??
                  (target.resumesConversation
                      ? 'Continues its own conversation here, told what it '
                            'missed.'
                      : 'Takes this conversation over here, in this chat.'),
            ),
          const DesktopMenuDivider(),
          DesktopMenuDetailItem<_Pick>(
            value: const _NewSession(),
            label: 'Continue in a new session…',
            detail:
                'Hand off or fork into a session of its own; this one '
                'stays as it is.',
          ),
        ];
      },
      child: Tooltip(
        message: 'Switch agent',
        child: PickerFace(
          icon: AppIcons.arrowsClockwise,
          label: _switching ? 'Switching…' : 'Switch agent',
        ),
      ),
    );
  }
}
