import 'package:agent_cli/descriptors.dart' show AgentModelSupport;
import 'package:flutter/foundation.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../agents/application/agent_model_catalog_providers.dart';
import '../../agents/application/session_model_providers.dart';
import 'session_config_options_providers.dart';

/// The model a session's agent last said it is running, with the label its
/// catalogue gives that id (the raw id where it gives none).
@immutable
class SessionActiveModel {
  const SessionActiveModel({
    required this.modelId,
    required this.label,
    required this.observedAt,
    required this.source,
  });

  /// The agent's own id for it, as it wrote it.
  final String modelId;
  final String label;
  final DateTime observedAt;
  final ActiveModelSource source;

  @override
  bool operator ==(Object other) =>
      other is SessionActiveModel &&
      other.modelId == modelId &&
      other.label == label &&
      other.observedAt == observedAt &&
      other.source == source;

  @override
  int get hashCode => Object.hash(modelId, label, observedAt, source);
}

/// What [sessionId]'s agent last said it runs (`SessionActiveModelChanged`),
/// labelled; null while it has said nothing. Never a setting.
final sessionActiveModelProvider = Provider.autoDispose
    .family<SessionActiveModel?, String>((ref, sessionId) {
      final client = ref.watch(dataClientProvider);
      final told = client.sessionActiveModelChanges.listen((change) {
        if (change.sessionId == sessionId) ref.invalidateSelf();
      });
      ref.onDispose(told.cancel);
      final change = client.sessionActiveModels[sessionId];
      if (change == null) return null;
      return SessionActiveModel(
        modelId: change.modelId,
        label: modelLabelIn(
          change.modelId,
          options: ref.watch(sessionConfigOptionsProvider(sessionId)),
          support: ref.watch(sessionModelProvider(sessionId))?.support,
        ),
        observedAt: change.observedAt,
        source: change.source,
      );
    });

/// [modelId]'s label: its ACP agent's own choice name in [options], else the
/// list its CLI reported ([support]), else the raw id.
String modelLabelIn(
  String modelId, {
  SessionConfigOptionsChanged? options,
  AgentModelSupport? support,
}) {
  for (final option in options?.options ?? const <SessionConfigOption>[]) {
    if (!option.isModel) continue;
    for (final choice in option.choices) {
      if (choice.value == modelId) return choice.name;
    }
  }
  return support?.modelFor(modelId)?.label ?? modelId;
}

/// **How [sessionId]'s transcript names a model**: [modelLabelIn] over its
/// agent's options and its catalogue, watched, so turns read "Opus 5.5" once
/// the catalogue arrives rather than keeping the id they were first drawn
/// with. The catalogue is the session's own, else its agent's in its
/// environment — a session no model state covers still has one.
final sessionModelLabelerProvider = Provider.autoDispose
    .family<String Function(String modelId), String>((ref, sessionId) {
      final options = ref.watch(sessionConfigOptionsProvider(sessionId));
      final key = agentModelsKeyOfSession(ref, sessionId);
      final support =
          ref.watch(sessionModelProvider(sessionId))?.support ??
          (key == null ? null : ref.watch(agentModelSupportInProvider(key)));
      return (modelId) =>
          modelLabelIn(modelId, options: options, support: support);
    });
