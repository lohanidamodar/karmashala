/// A session's model and permission mode as the phone can change them: what
/// is on offer, what is chosen, and what became of a change.
library;

import '../protocol.dart';

/// One choice in a picker, worded by the host so an older phone can still
/// offer a model or mode it has never heard of.
class RemoteChoice {
  const RemoteChoice({
    required this.id,
    required this.label,
    this.summary = '',
  });

  /// What is sent back to choose it, verbatim.
  final String id;
  final String label;
  final String summary;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (summary.isNotEmpty) 'summary': summary,
  };

  static RemoteChoice? tryParse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final label = json['label'];
    if (id is! String || id.isEmpty) return null;
    final summary = json['summary'];
    return RemoteChoice(
      id: id,
      label: label is String && label.isNotEmpty ? label : id,
      summary: summary is String ? summary : '',
    );
  }
}

/// `session.options`: the models and permission modes one session can be put
/// on. A null current id means "follows the desktop's default".
class RemoteSessionOptions {
  const RemoteSessionOptions({
    required this.sessionId,
    this.models = const [],
    this.modelId,
    this.modelDefaultLabel,
    this.permissions = const [],
    this.permissionId,
    this.permissionDefaultLabel,
  });

  final String sessionId;
  final List<RemoteChoice> models;
  final String? modelId;

  /// What following the default resolves to today, for the default row.
  final String? modelDefaultLabel;

  /// Only modes a phone may choose: one that removes every prompt needs the
  /// desktop's confirmation and a relaunch, so it is never offered here.
  final List<RemoteChoice> permissions;
  final String? permissionId;
  final String? permissionDefaultLabel;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'models': [for (final m in models) m.toJson()],
    'modelId': ?modelId,
    'modelDefault': ?modelDefaultLabel,
    'permissions': [for (final p in permissions) p.toJson()],
    'permissionId': ?permissionId,
    'permissionDefault': ?permissionDefaultLabel,
  };

  static RemoteSessionOptions fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw const ProtocolException('session options without a session');
    }
    List<RemoteChoice> choices(Object? list) => [
      if (list is List)
        for (final entry in list) ?RemoteChoice.tryParse(entry),
    ];
    String? text(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    return RemoteSessionOptions(
      sessionId: sessionId,
      models: choices(json['models']),
      modelId: text(json['modelId']),
      modelDefaultLabel: text(json['modelDefault']),
      permissions: choices(json['permissions']),
      permissionId: text(json['permissionId']),
      permissionDefaultLabel: text(json['permissionDefault']),
    );
  }
}

/// What a `session.configure` did to the session running now. A word the
/// phone does not know reads as [recorded]: the change is saved either way.
enum RemoteConfigureOutcome {
  /// The running session has it now.
  now('now'),

  /// Sent the moment the agent finishes the turn it is in.
  afterTurn('after_turn'),

  /// The agent's own picker is open in the desktop's pane; it is chosen there.
  pickerOpened('picker_opened'),

  /// Saved; the running session is unchanged until its next launch.
  recorded('recorded');

  const RemoteConfigureOutcome(this.wire);

  final String wire;

  static RemoteConfigureOutcome parse(Object? wire) => values.firstWhere(
    (value) => value.wire == wire,
    orElse: () => RemoteConfigureOutcome.recorded,
  );
}
