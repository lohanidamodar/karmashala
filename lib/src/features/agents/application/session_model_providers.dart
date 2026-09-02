import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sessions/application/session_launcher.dart';
import '../../explorer/application/session_context.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../domain/agent_descriptor.dart';

/// The model one session will run on, and everything a control needs to say so.
///
/// A value with `==`, not a record, because it is what `ref.watch` compares: a
/// state that never equals itself would repaint the chip on every session
/// signal, which is precisely the cost this feature was asked not to add.
@immutable
class SessionModelState {
  const SessionModelState({
    required this.sessionId,
    required this.descriptor,
    required this.modelId,
    required this.defaultModelId,
    required this.inherited,
  });

  final String sessionId;

  /// The agent behind the session. Null for an agent the registry does not
  /// know, which draws no control.
  final AgentDescriptor? descriptor;

  /// The model this session will actually be launched with, or null for "no
  /// model flag, the agent's own default".
  final String? modelId;

  /// What the per-agent default in Settings names, or null for "let the agent
  /// choose". Carried so the menu can say what "follow the default" resolves
  /// to without reading the setting a second time.
  final String? defaultModelId;

  /// Whether [modelId] came from the default rather than from a choice made for
  /// this session. Two states that must not look alike — see `ModelChip`.
  final bool inherited;

  String get agentName => descriptor?.displayName ?? 'This agent';

  AgentModelSupport get support =>
      descriptor?.launch.model ?? const AgentModelSupport.unsupported();

  @override
  bool operator ==(Object other) =>
      other is SessionModelState &&
      other.sessionId == sessionId &&
      identical(other.descriptor, descriptor) &&
      other.modelId == modelId &&
      other.defaultModelId == defaultModelId &&
      other.inherited == inherited;

  @override
  int get hashCode =>
      Object.hash(sessionId, descriptor, modelId, defaultModelId, inherited);
}

/// The model [sessionId] runs on, resolved by [SessionLauncher] and by nothing
/// else.
///
/// **Watches three concerns and not `title`.** `settings` is the per-session
/// write the chip itself makes; `membership` and `placement` cover the row
/// going away or changing which agent installation it names. Deliberately not
/// `status`: whether the agent is idle decides what a *click* does, not what
/// the chip says, and it is read at the moment of the click instead — a chip
/// that woke on every status transition would tick through every turn of every
/// session for a label that never changed.
///
/// Deliberately not `SessionSignals.forSession`, which would be narrower per
/// row and wider per kind: it wakes on `title`, and the CLI store sweep renames
/// rows on a timer without the user doing anything at all.
final sessionModelProvider = Provider.autoDispose
    .family<SessionModelState?, String>((ref, sessionId) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.placement,
        SessionChangeKind.settings,
      });
      final effective = ref
          .read(sessionLauncherProvider)
          .effectiveModelFor(sessionId);
      if (effective == null) return null;
      // And the one setting this chip follows, selected rather than watched
      // whole: a window resize writes settings too, and a chip that repainted
      // for that would be the cost this feature was asked not to add. The value
      // still comes out of the launcher's resolution above; this only decides
      // *when* to resolve again.
      final agentId = effective.descriptor?.id;
      ref.watch(
        settingsControllerProvider.select(
          (s) => agentId == null ? null : s.defaultModelFor(agentId),
        ),
      );
      return SessionModelState(
        sessionId: sessionId,
        descriptor: effective.descriptor,
        modelId: effective.modelId,
        defaultModelId: effective.defaultModelId,
        inherited: effective.inherited,
      );
    });

/// The same, for the session the app chrome is following.
///
/// Shaped after `focusedUsageInstallationProvider`: the status bar shows the
/// session you are looking at, and **nothing at all** when there is none.
final focusedSessionModelProvider = Provider.autoDispose<SessionModelState?>((
  ref,
) {
  final sessionId = ref.watch(focusedSessionIdProvider);
  if (sessionId == null) return null;
  return ref.watch(sessionModelProvider(sessionId));
});
