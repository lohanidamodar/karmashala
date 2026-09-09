import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/discovery.dart';
import 'package:karmashala_git/repositories.dart';
import 'session_launcher.dart';

/// The title a session carries when nobody types one.
const defaultSessionTitle = 'New session';

/// What a session starts with when nobody is asked.
///
/// **One definition, two surfaces.** The New session dialog opens *on* these —
/// the title is already in the field and the agent is already in the dropdown,
/// so Start is one keypress — and the Explorer's `+` runs them without opening
/// anything at all. Two sets of defaults that quietly disagreed would be a bug
/// nobody could see: the button would start one agent and the dialog beside it
/// another, and both would look right.
///
/// **What is deliberately not here.** The model and the permission mode.
/// [SessionLauncher] resolves both from the session, then the per-agent
/// preference, then settings, whenever a launch does not override them — see
/// `resolveSessionPermission` and the model precedence beside it. Copying them
/// into a second place would be a second precedence rule, and the one thing
/// worse than a default in two places is a *rule* in two places.
class SessionDefaults {
  const SessionDefaults({required this.installation, required this.title});

  /// The agent a launch would use, or `null` when the destination's
  /// environment has none installed — which is the one thing that makes the
  /// defaults insufficient, and the reason [isComplete] exists.
  final AgentInstallation? installation;

  final String title;

  /// Whether a session can be started from these without asking anything.
  bool get isComplete => installation != null;
}

/// Resolves [SessionDefaults] for a destination.
///
/// A small class behind a provider rather than a `Provider.family`, for the
/// reason `CheckoutPicker` is one too: every answer is read at call time, so a
/// discovery that just installed an agent cannot be served a cached "none".
class SessionDefaultsResolver {
  const SessionDefaultsResolver(this._ref);

  final Ref _ref;

  /// The defaults for a session that would run in [environmentId].
  ///
  /// The agent is [SessionLauncher.defaultInstallationIn], which is already the
  /// app's single answer to "which agent, here": the pinned installation if it
  /// is still present, else the first of the default agent, else the first
  /// installed. Asking per *environment* is the point — a WSL checkout must not
  /// default to an agent installed on Windows, whose executable path means
  /// nothing inside the distribution.
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
