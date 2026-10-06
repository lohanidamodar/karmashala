/// What an agent in a session without a project is told first, ahead of
/// whatever the person asked: where it is, and that the repositories are
/// its to choose.
///
/// Plain prose, for an agent that reads no instruction file from its folder.
/// One that does reads [kScratchInstructionFiles] there instead, and its first
/// message is only what the person wrote.
String scratchPreamble(String folder) =>
    '$_opens '
    '$folder, which is an empty git repository. $_attach '
    '$_closes';

const _attach =
    'To work on a repository, '
    'attach one to this session: list_projects and list_checkouts show what '
    'this machine has, session_checkout_attach attaches a checkout (pass '
    'worktree to work on a branch of your own instead of the checkout '
    'itself), and project_add with a gitUrl clones a repository this machine '
    'lacks into ~/karmashala/<repo>, after which you attach it the same way.';

/// The files a scratch folder is given, by name: the guidance in `AGENTS.md`,
/// and a `CLAUDE.md` that imports it. Kept out of git by the folder's own
/// `.git/info/exclude`, and never rewritten once there.
const Map<String, String> kScratchInstructionFiles = {
  'AGENTS.md':
      '# A Karmashala scratch folder\n'
      '\n'
      'This session has no project. It runs in this scratch folder of its '
      'own, an empty git repository. $_attach '
      'Work that belongs to no repository can stay here.\n'
      '\n'
      'Karmashala wrote this file and CLAUDE.md; git ignores both '
      '(.git/info/exclude).\n',
  'CLAUDE.md': '@AGENTS.md\n',
};

/// Whether a folder holding [kScratchInstructionFiles] reaches an agent that
/// reads [declared] (`AgentDescriptor.instructionFiles`): only when it reads
/// some file and every one is there. Otherwise it is told in words.
bool scratchFilesCover(List<String> declared) =>
    declared.isNotEmpty && declared.every(kScratchInstructionFiles.containsKey);

const _opens =
    'This session has no project. It runs in a scratch folder of its own,';
const _closes =
    'Work that belongs to no repository can stay in the scratch folder.';

/// [scratchPreamble] ahead of [prompt], or alone when there is none.
String withScratchPreamble(String folder, String? prompt) {
  final preamble = scratchPreamble(folder);
  final rest = prompt?.trim();
  return rest == null || rest.isEmpty ? preamble : '$preamble\n\n$rest';
}

/// [text] with a [scratchPreamble] in it taken out: the note, and the rest
/// as the person wrote it. A text without one is all rest.
({String? preamble, String rest}) splitScratchPreamble(String text) {
  final start = text.indexOf(_opens);
  final end = start < 0 ? -1 : text.indexOf(_closes, start);
  if (end < 0) return (preamble: null, rest: text);
  final stop = end + _closes.length;
  final before = text.substring(0, start).trim();
  final after = text.substring(stop).trim();
  return (
    preamble: text.substring(start, stop),
    rest: [before, after].where((s) => s.isNotEmpty).join('\n\n'),
  );
}
