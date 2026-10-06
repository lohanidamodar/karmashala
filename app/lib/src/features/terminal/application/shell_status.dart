/// What a **plain terminal's status line** says about the pane (spec §4, board
/// A2 `active.isShell`): the shell, where it is, the branch there and the
/// machine. Every answer is null when nothing established it — the line leaves
/// a fact out rather than guess at one.
library;

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart' show GitPresence;
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:riverpod/riverpod.dart';

import '../../environments/application/environment_providers.dart';
import '../../environments/application/environments_controller.dart';
import '../../explorer/application/environment_terminals_providers.dart';
import '../../explorer/application/project_head.dart';
import '../../git/application/changes_providers.dart';
import '../../git/data/git_data.dart';
import '../../remote/application/machines_providers.dart';
import '../../environments/application/environment_location.dart';
import 'terminal_profiles.dart';

/// The profile pane [profileId] was launched from, or null when it is no
/// longer offered (a WSL distribution removed, an SSH host forgotten).
final shellProfileProvider = Provider.autoDispose
    .family<TerminalProfile?, String>((ref, profileId) {
      for (final profile in ref.watch(terminalProfilesProvider)) {
        if (profile.id == profileId) return profile;
      }
      return null;
    });

/// The id of the machine a pane launched from [profileId] runs on, by the same
/// rule the Explorer files panes under — null where the profile cannot say.
final shellEnvironmentIdProvider = Provider.autoDispose.family<String?, String>(
  (ref, profileId) => environmentIdOfProfile(
    profileId,
    localId: ref.watch(localEnvironmentProvider)?.id,
  ),
);

/// The machine [environmentId] is, named as a session's is, or null when no
/// environment row names it. Not `environmentLabelForIdProvider`, which falls
/// back to the raw id: a database key on the status line would be a label made
/// up.
final shellLocationProvider = Provider.autoDispose
    .family<EnvironmentLocation?, String>((ref, environmentId) {
      for (final env in ref.watch(environmentsControllerProvider)) {
        if (env.id == environmentId) {
          return locationOf(env, machine: ref.watch(activeMachineProvider));
        }
      }
      return null;
    });

/// The branch checked out at [directory], or null when it is not a repository,
/// is detached, or git could not be asked. Keyed by the directory the shell
/// reports, so a `cd` into another checkout reads that one.
///
/// Read again when the server says the checkout was touched and when the window
/// comes back to the front; the status line also invalidates it when a command
/// finishes in the pane, which is when a `git switch` typed there lands.
final shellBranchProvider = FutureProvider.autoDispose
    .family<String?, EnvironmentPath>((ref, directory) async {
      ref.watchCheckout(directory);
      ref.watch(windowRefocusCountProvider);
      // Read before the await: a `Ref` disposed in the gap throws on a read.
      final git = ref.read(gitDataProvider);
      final presence = ref.watch(checkoutGitPresenceProvider(directory).future);
      try {
        // An unknown answer (an SSH box) is not an absence, so git is still
        // asked; only a filesystem that said "no .git" is spared the spawn.
        if (await presence == GitPresence.notARepository) return null;
        return await git.currentBranch(directory);
      } on Object {
        return null;
      }
    });
