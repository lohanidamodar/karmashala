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

  test('moving the highlight', () {
    const support = AgentMenuSupport(markers: ['❯']);
    expect(support.move(0, 2), '\x1b[B\x1b[B');
    expect(support.move(2, 0), '\x1b[A\x1b[A');
    expect(support.move(1, 1), '');
  });
}
