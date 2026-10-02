part of '../data_change.dart';

// What a session's agent offers at runtime and is not on its row: the modes
// an ACP agent lets a client switch between (ACP design, C5). Told to every
// client as the agent announces or changes them; nothing of it is stored.

DataChange? _sessionsChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'sessionModesChanged' => SessionModesChanged(
        sessionId: json['sessionId']! as String,
        currentModeId: json['currentModeId'] as String?,
        availableModes: [
          for (final mode in (json['availableModes'] as List?) ?? const [])
            SessionModeOption.fromJson((mode as Map).cast<String, Object?>()),
        ],
      ),
      _ => null,
    };

/// One mode an agent offers, in its own words.
final class SessionModeOption {
  const SessionModeOption({
    required this.id,
    required this.name,
    this.description,
  });

  factory SessionModeOption.fromJson(Map<String, Object?> json) =>
      SessionModeOption(
        id: json['id']! as String,
        name: json['name'] as String? ?? json['id']! as String,
        description: json['description'] as String?,
      );

  final String id;
  final String name;
  final String? description;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': ?description,
  };

  @override
  bool operator ==(Object other) =>
      other is SessionModeOption &&
      other.id == id &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(id, name, description);
}

/// Session [sessionId]'s agent now offers [availableModes] and is in
/// [currentModeId] — null when it has not said which. An empty list is an
/// agent with no modes to set.
final class SessionModesChanged extends DataChange {
  const SessionModesChanged({
    required this.sessionId,
    required this.currentModeId,
    required this.availableModes,
  });

  final String sessionId;
  final String? currentModeId;
  final List<SessionModeOption> availableModes;

  /// The mode the agent is in, as offered, or null when it named one that is
  /// not in the list.
  SessionModeOption? get current {
    for (final mode in availableModes) {
      if (mode.id == currentModeId) return mode;
    }
    return null;
  }

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionModesChanged',
    'sessionId': sessionId,
    'currentModeId': ?currentModeId,
    'availableModes': [for (final mode in availableModes) mode.toJson()],
  };
}
