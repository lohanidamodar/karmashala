import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/discovery.dart';
import 'package:karmashala_git/repositories.dart';
import 'session_launcher.dart';

/// The title a session carries when nobody types one.
const defaultSessionTitle = 'New session';

/// What a session starts with when nobody is asked — **one definition, two
/// surfaces**: the New session dialog opens *on* these, and the Explorer's `+`
/// runs them without opening anything, so two sets that quietly disagreed would
/// be a bug nobody could see. The model and the permission mode are
/// deliberately not here: [SessionLauncher] resolves both, and a *rule* in two
/// places is worse than a default in two places.
class SessionDefaults {
  const SessionDefaults({required this.installation, required this.title});

  /// The agent a launch would use, or `null` when the destination's environment
  /// has none installed — the one thing that makes the defaults insufficient.
  final AgentInstallation? installation;

  final String title;

  /// Whether a session can be started from these without asking anything.
  bool get isComplete => installation != null;
}

/// Resolves [SessionDefaults] for a destination. A small class behind a
/// provider rather than a `Provider.family`, so every answer is read at call
/// time and a discovery that just installed an agent cannot be served a cached
/// "none".
class SessionDefaultsResolver {
  const SessionDefaultsResolver(this._ref);

  final Ref _ref;

  /// The defaults for a session that would run in [environmentId]. The agent is
  /// [SessionLauncher.defaultInstallationIn], already the app's single answer
  /// to "which agent, here". Asking per *environment* is the point — a WSL
  /// checkout must not default to an agent installed on Windows.
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
