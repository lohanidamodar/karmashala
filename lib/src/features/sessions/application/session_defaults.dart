import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/discovery.dart';
import 'package:karmashala_git/repositories.dart';
import 'session_launcher.dart';

/// The title a session carries when nobody types one.
const defaultSessionTitle = 'New session';

/// What a session starts with when nobody is asked — one definition for both
/// the dialog and the Explorer's `+`. Not the model or the permission mode.
class SessionDefaults {
  const SessionDefaults({required this.installation, required this.title});

  /// The agent a launch would use, or `null` when the destination's environment
  /// has none installed — the one thing that makes the defaults insufficient.
  final AgentInstallation? installation;

  final String title;

  /// Whether a session can be started from these without asking anything.
  bool get isComplete => installation != null;
}

/// Resolves [SessionDefaults] for a destination. A class behind a provider,
/// not a family, so a discovery that just installed an agent is not cached out.
class SessionDefaultsResolver {
  const SessionDefaultsResolver(this._ref);

  final Ref _ref;

  /// The defaults for a session that would run in [environmentId]. Asked per
  /// *environment*: a WSL checkout must not default to a Windows install.
  SessionDefaults forEnvironment(String environmentId) => SessionDefaults(
    installation: _ref
        .read(sessionLauncherProvider)
        .defaultInstallationIn(environmentId),
    title: defaultSessionTitle,
  );

  /// The defaults for a session that would run in [repository].
  SessionDefaults forCheckout(Repository repository) =>
      forEnvironment(repository.path.environmentId);
}

final sessionDefaultsProvider = Provider<SessionDefaultsResolver>(
  SessionDefaultsResolver.new,
);
