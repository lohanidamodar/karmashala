import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sessions/application/session_launcher.dart';
import '../../explorer/application/session_context.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../settings/application/settings_controller.dart';
import 'package:agent_cli/descriptors.dart';

/// The model one session will run on. A value with `==` rather than a record,
/// because a state that never equals itself repaints on every session signal.
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

  /// What the per-agent default in Settings names, carried so the menu can say
  /// what "follow the default" resolves to without reading the setting twice.
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

/// The model [sessionId] runs on, resolved by [SessionLauncher] alone. Watches
/// three concerns, and deliberately neither `status` nor `title`.
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
      // The one setting this chip follows, selected rather than watched whole:
      // a window resize writes settings too. This only decides *when*.
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

/// The same, for the session the app chrome is following: the status bar shows
/// the session you are looking at, and **nothing at all** when there is none.
final focusedSessionModelProvider = Provider.autoDispose<SessionModelState?>((
  ref,
) {
  final sessionId = ref.watch(focusedSessionIdProvider);
  if (sessionId == null) return null;
  return ref.watch(sessionModelProvider(sessionId));
});
