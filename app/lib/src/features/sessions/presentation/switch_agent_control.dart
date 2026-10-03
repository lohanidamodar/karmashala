import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../agents/presentation/agent_logo.dart';
import '../../agents/presentation/picker_face.dart';
import '../application/session_chat_source.dart';
import '../application/session_handoff_service.dart';
import '../application/session_status_providers.dart';
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

/// Why no agent can be picked while the session's turn runs.
const String kSwitchWhileBusy =
    'A turn is running. Stop it, or wait for it to settle, then switch.';

/// **The composer's "Switch agent" control**: the face names the agent running
/// the session; the menu lists the installed agents with their logos, the
/// current one checked, those that ran it before marked as resuming their own
/// conversation, and every one refused with the reason while a turn runs.
/// Picking one hands the session over in place; the last row opens
/// "Continue with…" for a new session instead. Nothing is drawn for a server
/// that cannot switch.
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

  bool _busy() => switch (ref.read(sessionActivityLookupProvider)(
    widget.sessionId,
  )) {
    AgentActivityStatus.working || AgentActivityStatus.awaitingApproval => true,
    _ => false,
  };

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

  String _detail(HandoffTarget target, String? current) {
    if (target.refusal case final refusal?) return refusal;
    final stops = current == null ? '' : 'Stops $current; ';
    return target.resumesConversation
        ? '${stops}continues ${target.agentName}\'s own conversation here, '
              'told what it missed.'
        : '$stops${target.agentName} takes this conversation over here, '
              'at its default model.';
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(capabilitiesProvider.select((c) => c.switchAgent))) {
      return const SizedBox.shrink();
    }
    final service = ref.read(sessionHandoffServiceProvider);
    final current = service
        .switchTargetsFor(widget.sessionId)
        .where((t) => t.isCurrent)
        .firstOrNull;
    return PopupMenuButton<_Pick>(
      key: const ValueKey('switch-agent'),
      tooltip: '',
      enabled: !_switching,
      position: PopupMenuPosition.over,
      onSelected: _picked,
      itemBuilder: (context) {
        final targets = service.switchTargetsFor(
          widget.sessionId,
          used: _used(),
          busy: _busy() ? kSwitchWhileBusy : null,
        );
        final running = targets.where((t) => t.isCurrent).firstOrNull;
        return [
          for (final target in targets)
            DesktopMenuDetailItem<_Pick>(
              key: ValueKey('switch-to-${target.installation.id}'),
              value: _SwitchTo(target),
              enabled: target.canReceive,
              selected: target.isCurrent,
              leading: AgentLogo(
                agentId: target.installation.agentId,
                size: Chrome.icon,
              ),
              label: target.agentName,
              badge: target.isCurrent
                  ? 'running now'
                  : target.resumesConversation
                  ? 'resumes its conversation'
                  : null,
              detail: target.isCurrent
                  ? 'Runs this session now.'
                  : _detail(target, running?.agentName),
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
          label: _switching
              ? 'Switching…'
              : current?.agentName ?? 'Switch agent',
          maxLabelWidth: 160,
        ),
      ),
    );
  }
}
