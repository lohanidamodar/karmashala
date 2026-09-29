/// Set on every git this app runs. Nobody can see a prompt a background git
/// raises, so it would only hold the command until its bound; and a lock this
/// app's own status reads take can fail an agent's commit in the same checkout.
const Map<String, String> kGitChildEnvironment = {
  'GIT_TERMINAL_PROMPT': '0',
  'GCM_INTERACTIVE': 'never',
  'GIT_OPTIONAL_LOCKS': '0',
};

/// [kGitChildEnvironment] plus `core.hooksPath=/dev/null`, through git's own
/// `GIT_CONFIG_*` variables (2.31+) so no argument list changes: what every git
/// this app runs gets, except [kGitHookedVerbs].
///
/// A hook is code in `.git`, and an agent may write there from inside its own
/// sandbox; a git this app runs is outside that sandbox. So a merge, a
/// checkout or a worktree the app makes on an agent's behalf never runs one.
const Map<String, String> kGitUnhookedEnvironment = {
  ...kGitChildEnvironment,
  'GIT_CONFIG_COUNT': '1',
  'GIT_CONFIG_KEY_0': 'core.hooksPath',
  'GIT_CONFIG_VALUE_0': '/dev/null',
};

/// The verbs whose hooks do run: a commit and a push are only ever the user's
/// own click here, and their hooks are the gates (pre-commit, commit-msg,
/// pre-push) a person expects that click to go through.
const Set<String> kGitHookedVerbs = {'commit', 'push'};

/// The environment for `git [args]`.
Map<String, String> gitEnvironmentFor(List<String> args) =>
    kGitHookedVerbs.contains(args.firstOrNull)
    ? kGitChildEnvironment
    : kGitUnhookedEnvironment;

/// Never inherited by a git this app runs: set in the environment this app was
/// started from, they would point every `git -C` at somebody else's repository.
const Set<String> kGitRemovedEnvironment = {
  'GIT_DIR',
  'GIT_WORK_TREE',
  'GIT_COMMON_DIR',
  'GIT_INDEX_FILE',
};
