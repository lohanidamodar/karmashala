import 'package:meta/meta.dart';

import '../json.dart';
import 'capabilities.dart';
import 'session_config.dart';

@immutable
final class InitializeResult {
  const InitializeResult({
    required this.protocolVersion,
    this.agentCapabilities = const AgentCapabilities(),
    this.authMethods = const [],
    this.agentInfo,
  });

  factory InitializeResult.fromJson(JsonMap json) => InitializeResult(
    protocolVersion: json.integer('protocolVersion'),
    agentCapabilities: AgentCapabilities.fromJson(
      json.object('agentCapabilities') ?? const {},
    ),
    authMethods: [
      for (final m in json.objects('authMethods') ?? const <JsonMap>[])
        AuthMethod.fromJson(m),
    ],
    agentInfo: switch (json.object('agentInfo')) {
      final info? => AgentInfo.fromJson(info),
      null => null,
    },
  );

  /// `null` when the agent sent none or not a number; [AcpAgentClient]
  /// treats that as a mismatch.
  final int? protocolVersion;
  final AgentCapabilities agentCapabilities;
  final List<AuthMethod> authMethods;
  final AgentInfo? agentInfo;

  JsonMap toJson() => withoutNulls({
    'protocolVersion': protocolVersion,
    'agentCapabilities': agentCapabilities.toJson(),
    'authMethods': [for (final m in authMethods) m.toJson()],
    'agentInfo': agentInfo?.toJson(),
  });
}

@immutable
final class NewSessionResult {
  const NewSessionResult({
    required this.sessionId,
    this.modes,
    this.configOptions,
  });

  factory NewSessionResult.fromJson(JsonMap json) => NewSessionResult(
    sessionId: json.requireString('sessionId'),
    modes: switch (json.object('modes')) {
      final modes? => SessionModeState.fromJson(modes),
      null => null,
    },
    configOptions: configOptionsFromJson(json.objects('configOptions')),
  );

  final String sessionId;
  final SessionModeState? modes;
  final List<ConfigOption>? configOptions;

  JsonMap toJson() => withoutNulls({
    'sessionId': sessionId,
    'modes': modes?.toJson(),
    'configOptions': switch (configOptions) {
      final options? => [for (final o in options) o.toJson()],
      null => null,
    },
  });
}

@immutable
final class LoadSessionResult {
  const LoadSessionResult({this.modes, this.configOptions});

  factory LoadSessionResult.fromJson(JsonMap json) => LoadSessionResult(
    modes: switch (json.object('modes')) {
      final modes? => SessionModeState.fromJson(modes),
      null => null,
    },
    configOptions: configOptionsFromJson(json.objects('configOptions')),
  );

  final SessionModeState? modes;
  final List<ConfigOption>? configOptions;

  JsonMap toJson() => withoutNulls({
    'modes': modes?.toJson(),
    'configOptions': switch (configOptions) {
      final options? => [for (final o in options) o.toJson()],
      null => null,
    },
  });
}
