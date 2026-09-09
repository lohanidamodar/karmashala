import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// The observable launch behaviour of one built-in agent, written by hand.
///
/// Every field is a literal. Nothing here reads [AgentRegistry], so a descriptor
/// edit moves exactly one side of every assertion below and the test fails.
///
/// That independence is the whole point of this file, and what it has to be
/// independent *of* has changed twice. Loop 29 routed `permissionArgsFor`
/// through `AgentRegistry.builtIn`, which turned "the launcher agrees with the
/// registry" into a registry-vs-registry comparison that could not fail. The
/// per-agent permission model then did the same to the adapters: `claudeLaunchArgs`
/// and friends used to hold their own copy of the flag table and are now handed
/// `launch.permission.arguments`, so asserting one against the other is
/// likewise vacuous. What is left that a descriptor edit cannot move is the
/// literal spelling of each CLI's own flags, written out below from what those
/// binaries document, and the *shape* of the command line the adapters build
/// around them — base arguments first, then the mode, then the resume.
class _AgentGolden {
  const _AgentGolden({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.executable,
    required this.baseArguments,
    required this.defaultSelection,
    required this.permissionArguments,
    required this.resumeArguments,
    required this.interactiveResumeArguments,
  });

  final String id;
  final String displayName;

  /// Null for an agent with no protocol adapter of its own.
  final AgentKind? kind;

  /// The executable base name probed on both Windows and WSL.
  final String executable;

  /// Arguments every launch starts with, before permission flags.
  final List<String> baseArguments;

  /// The mode a session that has chosen nothing runs under, in the canonical
  /// form a session row and the settings file hold.
  ///
  /// Written out rather than derived because "nobody chose" is the case with no
  /// user behind it to notice: an agent whose default silently moved a rung
  /// would launch every new session differently and say nothing.
  final String defaultSelection;

  /// Every selection the agent offers, and the flags it puts on the command
  /// line — the CLI's own spellings, not this app's.
  ///
  /// This is the golden that carries its weight now. It is keyed by the
  /// canonical stored form, so it also pins the ids that end up in session rows
  /// and settings files, and its key set is asserted against the descriptor's
  /// own enumeration so a mode cannot be added or dropped without touching it.
  final Map<String, List<String>> permissionArguments;

  /// What resuming session `sid` appends in the headless/protocol launch.
  final List<String> resumeArguments;

  /// What resuming session `sid` appends in an interactive terminal launch.
  final List<String> interactiveResumeArguments;

  /// The full headless argument vector for [selection], resuming `sid` when
  /// asked.
  List<String> launchArguments(String selection, {required bool resume}) => [
    ...baseArguments,
    ...permissionArguments[selection]!,
    if (resume) ...resumeArguments,
  ];
}

/// The agents Karmashala ships, in registry order.
const List<_AgentGolden> _goldens = [
  _AgentGolden(
    id: 'claudeCode',
    displayName: 'Claude Code',
    kind: AgentKind.claudeCode,
    executable: 'claude',
    baseArguments: [
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--verbose',
    ],
    // `manual` rather than passing nothing: an unflagged session starts in
    // `auto` on a Pro/Max/Team account, so "no flag" was not the safe mode it
    // looked like.
    defaultSelection: 'mode=manual',
    // One axis, and `claude --permission-mode bogus --help` enumerates it:
    // "Allowed choices are acceptEdits, auto, bypassPermissions, manual,
    // dontAsk, plan." Each is passed by its own name.
    permissionArguments: {
      'mode=plan': ['--permission-mode', 'plan'],
      'mode=dontAsk': ['--permission-mode', 'dontAsk'],
      'mode=manual': ['--permission-mode', 'manual'],
      'mode=acceptEdits': ['--permission-mode', 'acceptEdits'],
      'mode=auto': ['--permission-mode', 'auto'],
      'mode=bypassPermissions': ['--permission-mode', 'bypassPermissions'],
    },
    resumeArguments: ['--resume', 'sid'],
    interactiveResumeArguments: ['--resume', 'sid'],
  ),
  _AgentGolden(
    id: 'codex',
    displayName: 'Codex CLI',
    kind: AgentKind.codex,
    executable: 'codex',
    baseArguments: ['app-server'],
    defaultSelection: 'approval=on-request;sandbox=workspace-write',
    // **Two** axes, which is the shape the shared enum could not hold: a
    // sandbox bounding what may be written and an approval policy deciding
    // what must be asked. Both reach the command line, sandbox first, and the
    // canonical string sorts them by axis id.
    //
    // Two approval values have been retired out from under this table by the
    // real CLI — `on-failure` (0.145.0) and `untrusted` (0.151.0) — and each
    // time the agent refused to launch. See built_in_agents.dart for both
    // transcripts.
    permissionArguments: {
      'approval=on-request;sandbox=read-only': [
        '--sandbox',
        'read-only',
        '--ask-for-approval',
        'on-request',
      ],
      'approval=never;sandbox=read-only': [
        '--sandbox',
        'read-only',
        '--ask-for-approval',
        'never',
      ],
      'approval=on-request;sandbox=workspace-write': [
        '--sandbox',
        'workspace-write',
        '--ask-for-approval',
        'on-request',
      ],
      'approval=never;sandbox=workspace-write': [
        '--sandbox',
        'workspace-write',
        '--ask-for-approval',
        'never',
      ],
      'approval=on-request;sandbox=danger-full-access': [
        '--sandbox',
        'danger-full-access',
        '--ask-for-approval',
        'on-request',
      ],
      'approval=never;sandbox=danger-full-access': [
        '--sandbox',
        'danger-full-access',
        '--ask-for-approval',
        'never',
      ],
      // One flag replaces both, so the approval axis contributes nothing and
      // its two rows collapse into this one — 7 selections for a 4x2 product.
      'approval=on-request;sandbox=bypass-all': [
        '--dangerously-bypass-approvals-and-sandbox',
      ],
    },
    resumeArguments: ['--resume', 'sid'],
    // Interactively Codex resumes with a subcommand, not a flag.
    interactiveResumeArguments: ['resume', 'sid'],
  ),
  _AgentGolden(
    id: 'antigravity',
    displayName: 'Antigravity',
    kind: AgentKind.antigravity,
    // `agy`, not `antigravity` — the name the CLI installs itself under, and
    // the reason discovery never found it before.
    executable: 'agy',
    // Nothing headless is claimed: the stream-json protocol `agy --help`
    // documents has not been run, and the adapter parses plain text.
    baseArguments: [],
    // Prompting is the CLI's own unflagged behaviour, so the default is the
    // one mode here with an empty argument list — declared, not absent.
    defaultSelection: 'mode=prompt',
    permissionArguments: {
      'mode=plan': ['--mode', 'plan'],
      'mode=prompt': [],
      'mode=accept-edits': ['--mode', 'accept-edits'],
      // Read off `agy --help` (1.1.22+). The previous `--yolo` was not a flag
      // this CLI has, and it was the dangerous mode that carried it.
      'mode=skip-permissions': ['--dangerously-skip-permissions'],
    },
    // `--conversation  Resume a previous conversation by ID`. One convention
    // for both launches — there is no subcommand form as there is for Codex.
    resumeArguments: ['--conversation', 'sid'],
    interactiveResumeArguments: ['--conversation', 'sid'],
  ),
  _AgentGolden(
    id: 'geminiCli',
    displayName: 'Gemini CLI',
    // No protocol adapter, so the generic one drives it — and everything below
    // is empty for the reason the descriptor is thin. `agent_cli` states `-p`
    // and `-m` and nothing else because nobody here has run this CLI, so an
    // empty golden is the claim that nothing is claimed.
    kind: null,
    executable: 'gemini',
    baseArguments: [],
    // `PermissionSelection.empty.canonical`: no mode is offered, so a session
    // that chose nothing enforces nothing and passes no flags.
    defaultSelection: 'none',
    permissionArguments: {},
    resumeArguments: [],
    interactiveResumeArguments: [],
  ),
];

void main() {
  const registry = AgentRegistry.builtIn;

  PermissionSelection selection(String canonical) =>
      PermissionSelection.parse(canonical)!;

  test('ships exactly the golden agents, in order', () {
    expect(registry.descriptors.map((d) => d.id), _goldens.map((g) => g.id));
    expect(
      registry.descriptors.map((d) => d.displayName),
      _goldens.map((g) => g.displayName),
    );
    expect(
      registry.descriptors.map((d) => d.kind),
      _goldens.map((g) => g.kind),
    );
    // Every agent with a protocol adapter is shipped: the enum has no orphans.
    // The nulls are the agents driven by the generic adapter, which is what
    // `AgentKind` means now — "this one has an adapter" — rather than "this one
    // is shipped".
    expect(_goldens.map((g) => g.kind).nonNulls, AgentKind.values);
    // Rows written before the id migration hold `AgentKind.name`, so the id and
    // the kind must still agree for the built-ins that have one to load.
    for (final golden in _goldens) {
      if (golden.kind != null) expect(golden.id, golden.kind!.name);
    }
    expect(registry.byId('nope'), isNull);
  });

  test('probes the golden executable name on both platforms', () {
    for (final golden in _goldens) {
      final binaries = registry.byId(golden.id)!.binaries;
      expect(binaries.forKind(EnvironmentKind.windowsNative), [
        golden.executable,
      ], reason: golden.id);
      expect(binaries.forKind(EnvironmentKind.wsl), [
        golden.executable,
      ], reason: golden.id);
    }
  });

  test('offers exactly the golden modes, and no others', () {
    // The key set, checked on its own so a mode that appears or disappears
    // fails here by name rather than as a missing map entry three tests down.
    // `selections()` is the enumeration everything agent-agnostic reads — the
    // carry rule, the phone's flat list — so this is also what those see.
    for (final golden in _goldens) {
      final support = registry.byId(golden.id)!.launch.permission;
      expect(
        [for (final s in support.selections()) s.canonical]..sort(),
        golden.permissionArguments.keys.toList()..sort(),
        reason: golden.id,
      );
    }
  });

  test('the descriptor passes the flags each CLI documents', () {
    // This used to compare each adapter's `*LaunchArgs` against the
    // descriptor. That comparison earned its place while the adapters held a
    // duplicate copy of the flag table; they now emit
    // `launch.permission.arguments` verbatim, so it compares the descriptor to
    // itself and cannot fail. What can still fail is the descriptor against
    // the spellings above, which came from the binaries rather than from here.
    for (final golden in _goldens) {
      final support = registry.byId(golden.id)!.launch.permission;
      for (final entry in golden.permissionArguments.entries) {
        expect(
          support.argumentsFor(selection(entry.key)),
          entry.value,
          reason: '${golden.id} / ${entry.key}',
        );
      }
    }
  });

  test('the terminal launcher passes the golden permission flags', () {
    // The one surface with no adapter behind it. It reads the same descriptor,
    // but through its own function and its own registry lookup — the arm that
    // used to answer an agent it did not recognise with another agent's flag.
    for (final golden in _goldens) {
      for (final entry in golden.permissionArguments.entries) {
        expect(
          permissionArgsFor(golden.id, selection(entry.key)),
          entry.value,
          reason: 'launcher: ${golden.id} / ${entry.key}',
        );
      }
    }
  });

  test('a session that chose nothing runs under the golden default', () {
    // Replaces "a mode that does not map is absent, not empty". The old
    // distinction was between a mode the agent could express and one it could
    // not; the surviving one is between the two ways of passing no flags.
    // **Null means nobody chose** and takes the declared default, which has
    // real flags for two of the three. **Empty means enforce nothing** and is
    // what the carry rule produces when every mode an agent has is more
    // permissive than what was asked for — resolving it to the default there
    // would silently widen exactly the case the rule narrows.
    for (final golden in _goldens) {
      final support = registry.byId(golden.id)!.launch.permission;
      expect(
        support.defaultSelection.canonical,
        golden.defaultSelection,
        reason: golden.id,
      );
      expect(
        support.argumentsFor(null),
        // An agent that offers no mode has no entry, and passes nothing.
        golden.permissionArguments[golden.defaultSelection] ?? const <String>[],
        reason: golden.id,
      );
      expect(
        support.argumentsFor(PermissionSelection.empty),
        isEmpty,
        reason: golden.id,
      );
      expect(
        permissionArgsFor(golden.id, PermissionSelection.empty),
        isEmpty,
        reason: 'launcher: ${golden.id}',
      );
    }
  });

  test('interactive resume uses the golden convention', () {
    for (final golden in _goldens) {
      expect(
        registry.byId(golden.id)!.launch.interactiveResume.argumentsFor('sid'),
        golden.interactiveResumeArguments,
        reason: golden.id,
      );
    }
  });

  test('the adapters and the registry both build the golden launch', () {
    // The adapters no longer decide *what* the mode's flags are, but they still
    // decide where they go: base arguments, then the mode, then the resume. A
    // permission list dropped, duplicated or emitted after the resume id would
    // still hand the CLI a command line it rejects, and only this composes the
    // whole vector to catch it.
    AgentLaunch launch(String id, String stored, String? resume) => AgentLaunch(
      workingDirectory: repository().path,
      installation: agentInstallation(),
      permission: ResolvedPermission.of(
        registry.byId(id)!.launch.permission,
        selection(stored),
      ),
      resumeSessionId: resume,
    );

    List<String> fromRegistry(String id, String stored, String? resume) {
      final spec = registry.byId(id)!.launch;
      return [
        ...spec.baseArguments,
        ...spec.permission.argumentsFor(selection(stored)),
        if (resume != null) ...spec.resume.argumentsFor(resume),
      ];
    }

    final adapters = <String, List<String> Function(AgentLaunch)>{
      'claudeCode': claudeLaunchArgs,
      'codex': codexLaunchArgs,
      'antigravity': antigravityLaunchArgs,
    };

    for (final golden in _goldens) {
      for (final stored in golden.permissionArguments.keys) {
        for (final resume in [null, 'sid']) {
          final expected = golden.launchArguments(
            stored,
            resume: resume != null,
          );
          final reason = '${golden.id} / $stored / $resume';
          // The hand-written adapter function...
          expect(
            adapters[golden.id]!(launch(golden.id, stored, resume)),
            expected,
            reason: 'adapter: $reason',
          );
          // ...and the descriptor, composed the way GenericAgentAdapter does.
          expect(
            fromRegistry(golden.id, stored, resume),
            expected,
            reason: 'registry: $reason',
          );
        }
      }
    }
  });

  test(
    'store specs describe only the agents with an on-disk session store',
    () {
      expect(registry.byId('claudeCode')!.store!.homeDirectoryName, '.claude');
      expect(
        registry.byId('claudeCode')!.store!.format,
        AgentStoreFormat.claudeJsonl,
      );
      expect(registry.byId('codex')!.store!.homeDirectoryName, '.codex');
      expect(
        registry.byId('codex')!.store!.format,
        AgentStoreFormat.codexRollout,
      );
      // Antigravity's store yields identity without content: conversation id,
      // directory, title and size are readable, message payloads are protobuf
      // in an unpublished schema. `antigravityStore` is that shape.
      expect(
        registry.byId('antigravity')!.store!.homeDirectoryName,
        '.gemini/antigravity-cli',
      );
      expect(
        registry.byId('antigravity')!.store!.format,
        AgentStoreFormat.antigravityStore,
      );
    },
  );

  test('status strategies reflect what each agent actually supports', () {
    expect(
      registry.byId('claudeCode')!.statusStrategy,
      AgentStatusStrategy.hooks,
    );
    // Codex reads `$CODEX_HOME/hooks.json` in Claude Code's own shape. This
    // said `stateFile` while the backlog recorded the CLI as configurable only
    // through TOML; the rollout file is still read, but it is the fallback now
    // and not the best source.
    expect(registry.byId('codex')!.statusStrategy, AgentStatusStrategy.hooks);
    // Antigravity's hooks are documented only in a skill the CLI ships, never
    // in `--help`, which is why this said `none` until a live run fired them.
    expect(
      registry.byId('antigravity')!.statusStrategy,
      AgentStatusStrategy.hooks,
    );
  });
}
