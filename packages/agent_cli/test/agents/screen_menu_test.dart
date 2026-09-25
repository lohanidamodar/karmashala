import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// Screens captured from the real CLIs in a real ConPTY and xterm2 grid
/// (`test/features/agents/live_prompt_probe_test.dart`, 2026-09-19), paths
/// neutralised. Blank rows are kept: they are part of what is parsed.
void main() {
  const claude = AgentMenuSupport(markers: ['❯']);
  const codex = AgentMenuSupport(markers: ['›']);

  group('Claude Code 2.1.274', () {
    test('folder trust: "No, exit" is what Enter would choose', () {
      final menu = readScreenMenu(const [
        '────────────────────────────────────────',
        ' Accessing workspace:',
        '',
        r' C:\work\demo',
        '',
        ' Quick safety check: Is this a project you created or one you trust?',
        " take a moment to review what's in this folder first.",
        '',
        " Claude Code'll be able to read, edit, and execute files here.",
        '',
        ' Security guide',
        '',
        ' ❯ No, exit',
        '   Yes, I trust this folder',
        '',
        ' Enter to confirm · Esc to cancel',
      ], claude)!;
      expect(menu.options, ['No, exit', 'Yes, I trust this folder']);
      expect(menu.highlighted, 0);
      expect(menu.prompt.first, 'Accessing workspace:');
      expect(menu.prompt.last, 'Security guide');
    });

    test('the same menu keeps its id as the highlight moves', () {
      List<String> screen(bool second) => [
        ' Security guide',
        '',
        second ? '   No, exit' : ' ❯ No, exit',
        second ? ' ❯ Yes, I trust this folder' : '   Yes, I trust this folder',
        '',
        ' Enter to confirm · Esc to cancel',
      ];
      final before = readScreenMenu(screen(false), claude)!;
      final after = readScreenMenu(screen(true), claude)!;
      expect(after.highlighted, 1);
      expect(after.id, before.id);
    });

    test('tool permission: numbered options, the command above them', () {
      final menu = readScreenMenu(const [
        '● Bash(echo probe-ok > probe.txt)',
        '  ⎿  Waiting…',
        '────────────────────────────────────────',
        ' Bash command',
        '',
        '   echo probe-ok > probe.txt',
        '   Write probe-ok to probe.txt',
        '',
        ' Do you want to proceed?',
        '   1. Yes',
        r' ❯ 2. Yes, and always allow access to C:\work\demo from this project',
        '   3. No',
        '',
        ' Esc to cancel',
      ], claude)!;
      expect(menu.options, [
        'Yes',
        r'Yes, and always allow access to C:\work\demo from this project',
        'No',
      ]);
      expect(menu.highlighted, 1);
      expect(menu.prompt, [
        'Bash command',
        'echo probe-ok > probe.txt',
        'Write probe-ok to probe.txt',
        'Do you want to proceed?',
      ], reason: 'the rule above the panel ends the prompt');
    });

    test('two prompts with the same options are two menus', () {
      List<String> asking(String command) => [
        ' Bash command',
        '   $command',
        ' Do you want to proceed?',
        ' ❯ 1. Yes',
        '   2. No',
      ];
      expect(
        readScreenMenu(asking('ls'), claude)!.id,
        isNot(readScreenMenu(asking('rm -rf build'), claude)!.id),
      );
    });

    test('a project MCP server: the default is the last option', () {
      final menu = readScreenMenu(const [
        '────────────────────────────────────────',
        '  New MCP server found in this project: probe-server',
        '',
        '  MCP servers may execute code or access system resources.',
        '',
        '    Use this MCP server',
        '    Use this and all future MCP servers in this project',
        '  ❯ Continue without using this MCP server',
        '',
        '  Enter to confirm · Esc to cancel',
      ], claude)!;
      expect(menu.options, hasLength(3));
      expect(menu.highlighted, 2);
      expect(menu.options.first, 'Use this MCP server');
    });

    test('a long option the agent wrapped is one option', () {
      final menu = readScreenMenu(const [
        ' Do you want to proceed?',
        ' ❯ 1. Yes',
        '   2. Yes, and always allow access to a folder with a very long',
        '      name from this project',
        '   3. No',
      ], claude)!;
      expect(menu.options, [
        'Yes',
        'Yes, and always allow access to a folder with a very long name '
            'from this project',
        'No',
      ]);
    });

    test('the idle composer is no menu', () {
      expect(
        readScreenMenu(const [
          '────────────',
          '❯',
          '────────────',
          '  ⏸ manual mode on · ? for shortcuts',
        ], claude),
        isNull,
      );
    });
  });

  group('Codex 0.153 / 0.154', () {
    test('directory trust', () {
      final menu = readScreenMenu(const [
        r'> You are in C:\work\demo',
        '',
        '  Do you trust the contents of this directory? Working with untrusted',
        '  project-local config, hooks, and exec policies to load.',
        '',
        '› 1. Yes, continue',
        '  2. No, quit',
        '',
        '  Press enter to continue',
      ], codex)!;
      expect(menu.options, ['Yes, continue', 'No, quit']);
      expect(menu.highlighted, 0);
      expect(menu.prompt.first, r'> You are in C:\work\demo');
    });

    test('the update offer: Enter would run the updater', () {
      final menu = readScreenMenu(const [
        '  ✨ Update available! 0.154.0 -> 0.155.1',
        '  Release notes: https://github.com/openai/codex/releases/latest',
        '',
        "› 1. Update now (runs `powershell -c 'irm https://x | iex'`)",
        '  2. Skip',
        '  3. Skip until next version',
        '',
        '  Press enter to continue',
      ], codex)!;
      expect(menu.highlighted, 0);
      expect(menu.options.last, 'Skip until next version');
    });

    test('the composer and its status line are no menu', () {
      expect(
        readScreenMenu(const [
          '› Ask Codex to do anything',
          '',
          r'  gpt-6-astra medium · ~\work\demo',
        ], codex),
        isNull,
      );
    });
  });

  // What approve and deny mean on each menu, by the adapters' own declarations:
  // an option by its words, never the highlight.
  group('the options approve and deny choose', () {
    final claudeMenus = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!.menus!;
    final codexMenus = AgentRegistry.builtIn.byId(AgentIds.codex)!.menus!;

    AgentScreenMenu menu(List<String> options, {List<String>? prompt}) =>
        AgentScreenMenu(
          prompt: prompt ?? const ['Do you trust this?'],
          options: options,
          highlighted: 0,
        );

    test('Claude Code folder trust: yes is the second row', () {
      final trust = menu(['No, exit', 'Yes, I trust this folder']);
      expect(claudeMenus.affirmativeIn(trust), 1);
      expect(claudeMenus.negativeIn(trust), 0);
      expect(claudeMenus.cancelDeclinesIn(trust), isFalse);
    });

    test('Claude Code tool permission: the plain Yes, and Esc declines', () {
      final permission = menu(
        [
          'Yes',
          'Yes, and switch to accept edits for this session (shift+tab)',
          'No',
        ],
        prompt: const ['Create file', 'Do you want to create note.txt?'],
      );
      expect(claudeMenus.affirmativeIn(permission), 0);
      expect(claudeMenus.negativeIn(permission), 2);
      expect(claudeMenus.cancelDeclinesIn(permission), isTrue);
    });

    test('Claude Code MCP server: "Continue without" is the refusal', () {
      final server = menu([
        'Use this MCP server',
        'Use this and all future MCP servers in this project',
        'Continue without using this MCP server',
      ]);
      expect(claudeMenus.affirmativeIn(server), 0);
      expect(claudeMenus.negativeIn(server), 2);
    });

    test('Codex directory trust and update offer', () {
      final trust = menu(['Yes, continue', 'No, quit']);
      expect(codexMenus.affirmativeIn(trust), 0);
      expect(codexMenus.negativeIn(trust), 1);
      final update = menu(['Update now', 'Skip', 'Skip until next version']);
      expect(codexMenus.affirmativeIn(update), isNull);
      expect(codexMenus.negativeIn(update), isNull);
    });

    test('an option both lists claim answers neither', () {
      const support = AgentMenuSupport(
        markers: ['❯'],
        affirmative: [r'^Yes\b'],
        negative: [r'\bnot\b'],
      );
      final muddled = menu(['Yes, but not now', 'Later']);
      expect(support.affirmativeIn(muddled), isNull);
      expect(support.negativeIn(muddled), isNull);
    });

    test('nothing declared, nothing chosen', () {
      expect(claude.affirmativeIn(menu(['Yes', 'No'])), isNull);
    });
  });

  test('moving the highlight', () {
    const support = AgentMenuSupport(markers: ['❯']);
    expect(support.move(0, 2), '\x1b[B\x1b[B');
    expect(support.move(2, 0), '\x1b[A\x1b[A');
    expect(support.move(1, 1), '');
  });
}
