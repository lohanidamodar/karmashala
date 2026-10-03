/// **Logging in to an agent spoken to over ACP**, as the server tells it:
/// the methods the agent advertises on `initialize`, and the one a person
/// chose for an installation. ACP v1 exposes no account identity, so nothing
/// here says who is logged in — only which method was used, and whether
/// `authenticate` confirmed it.
library;

/// How long a login the agent completes itself is given: a browser
/// login waits on a person choosing an account and consenting.
const Duration kAcpAgentLoginPatience = Duration(minutes: 10);

/// One way an agent can be logged in, as it advertised it.
final class AcpAuthMethod {
  const AcpAuthMethod({
    required this.id,
    required this.name,
    this.description,
    this.terminal = false,
    this.apiKeyVariable,
  });

  factory AcpAuthMethod.fromJson(Map<String, Object?> json) => AcpAuthMethod(
    id: json['id']! as String,
    name: json['name'] as String? ?? json['id']! as String,
    description: json['description'] as String?,
    terminal: json['terminal'] == true,
    apiKeyVariable: json['apiKeyVariable'] as String?,
  );

  final String id;
  final String name;
  final String? description;

  /// The person completes this login in a terminal running the agent's own
  /// program; the agent is never asked to `authenticate` with it.
  final bool terminal;

  /// The environment variable this method reads a key from, where the
  /// agent's descriptor declares one; the app then asks for the key and
  /// keeps it in the server's vault under that name.
  final String? apiKeyVariable;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': ?description,
    'terminal': terminal,
    'apiKeyVariable': ?apiKeyVariable,
  };
}

/// What `acpAuth.methods` answers: the agent's methods, as `initialize`
/// listed them, and whether it answers `logout`.
final class AcpAuthMethods {
  const AcpAuthMethods({
    required this.installationId,
    required this.methods,
    this.supportsLogout = false,
  });

  factory AcpAuthMethods.fromJson(Map<String, Object?> json) => AcpAuthMethods(
    installationId: json['installationId']! as String,
    methods: [
      for (final method in (json['methods'] as List?) ?? const [])
        AcpAuthMethod.fromJson((method as Map).cast<String, Object?>()),
    ],
    supportsLogout: json['supportsLogout'] == true,
  );

  final String installationId;
  final List<AcpAuthMethod> methods;
  final bool supportsLogout;

  Map<String, Object?> toJson() => {
    'installationId': installationId,
    'methods': [for (final method in methods) method.toJson()],
    'supportsLogout': supportsLogout,
  };
}

/// The method a person chose for one installation. [authenticatedAt] is when
/// `authenticate` last succeeded with it; null for a terminal login, which
/// the protocol gives no way to confirm.
final class AcpAuthState {
  const AcpAuthState({
    required this.installationId,
    required this.methodId,
    required this.methodName,
    required this.chosenAt,
    this.authenticatedAt,
  });

  factory AcpAuthState.fromJson(Map<String, Object?> json) => AcpAuthState(
    installationId: json['installationId']! as String,
    methodId: json['methodId']! as String,
    methodName: json['methodName'] as String? ?? json['methodId']! as String,
    chosenAt: DateTime.parse(json['chosenAt']! as String).toUtc(),
    authenticatedAt: switch (json['authenticatedAt']) {
      final String at => DateTime.tryParse(at)?.toUtc(),
      _ => null,
    },
  );

  final String installationId;
  final String methodId;
  final String methodName;
  final DateTime chosenAt;
  final DateTime? authenticatedAt;

  /// Whether the agent itself confirmed this login.
  bool get confirmed => authenticatedAt != null;

  Map<String, Object?> toJson() => {
    'installationId': installationId,
    'methodId': methodId,
    'methodName': methodName,
    'chosenAt': chosenAt.toUtc().toIso8601String(),
    'authenticatedAt': ?authenticatedAt?.toUtc().toIso8601String(),
  };
}
