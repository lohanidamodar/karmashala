/// What an agent in a session without a project is told first, ahead of
/// whatever the person asked: where it is, and that the repositories are
/// its to choose.
///
/// Plain prose, because every agent reads a first message; a system-prompt
/// file would reach only the agents that take one.
String scratchPreamble(String folder) =>
    'This session has no project. It runs in a scratch folder of its own, '
    '$folder, which is an empty git repository. To work on a repository, '
    'attach one to this session: list_projects and list_checkouts show what '
    'this machine has, session_checkout_attach attaches a checkout (pass '
    'worktree to work on a branch of your own instead of the checkout '
    'itself), and project_add with a gitUrl clones a repository this machine '
    'lacks into ~/karmashala/<repo>, after which you attach it the same way. '
    'Work that belongs to no repository can stay in the scratch folder.';

/// [scratchPreamble] ahead of [prompt], or alone when there is none.
String withScratchPreamble(String folder, String? prompt) {
  final preamble = scratchPreamble(folder);
  final rest = prompt?.trim();
  return rest == null || rest.isEmpty ? preamble : '$preamble\n\n$rest';
}
