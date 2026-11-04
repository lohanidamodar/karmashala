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

  // Rows from hosted Codex 0.166 sessions, replayed from their recorded output
  // (2026-11-04), paths neutralised. The command approval has no rule above
  // it: what the menu reads as its prompt ran up into the transcript, which
  // Codex redraws while it waits — so the id changed under a waiting answer,
  // and the answer was refused as "the prompt changed".
  group('Codex 0.166', () {
    final codexMenus = AgentRegistry.builtIn.byId(AgentIds.codex)!.menus!;

    List<String> approval(List<String> transcript, {List<String>? options}) => [
      ...transcript,
      '',
      '',
      '  Would you like to run the following command?',
      '',
      '  Environment: local',
      '',
      '  Reason: May I run Dart package setup outside the sandbox?',
      '',
      r'  $ dart pub get *> pub_get.log; $result = $LASTEXITCODE;',
      r'  Get-Content pub_get.log; exit $result',
      '',
      '',
      ...?options,
      if (options == null) ...[
        '› 1. Yes, proceed (y)',
        "  2. Yes, and don't ask again for commands that start with `dart pub",
        '     get` (p)',
        '  3. No, and tell Codex what to do differently (esc)',
      ],
      '',
      '  Press enter to confirm or esc to cancel',
    ];

    test('a command approval reads its own words, not the transcript', () {
      final menu = readScreenMenu(
        approval(const [
          '• Exited (status 255) dart pub get',
          '  └ #9      main (dartdev.dart:13)',
          '    + 24 lines (ctrl+t to expand)',
          '• Running dart pub get *> pub_get.log',
          '    + Show details',
        ]),
        codexMenus,
      )!;
      expect(menu.options, [
        'Yes, proceed (y)',
        "Yes, and don't ask again for commands that start with `dart pub "
            'get` (p)',
        'No, and tell Codex what to do differently (esc)',
      ]);
      expect(menu.prompt.first, 'Would you like to run the following command?');
      expect(menu.prompt.last, r'Get-Content pub_get.log; exit $result');
    });

    test('the transcript redrawn above a waiting approval keeps its id', () {
      final before = readScreenMenu(
        approval(const ['• Running dart pub get', '    + Show details']),
        codexMenus,
      )!;
      final after = readScreenMenu(
        approval(const [
          '• Viewed image 21_dusk2.png',
          '    + Show details',
          '• Edited 2 files (+82 -0)',
          '• Running dart pub get',
          '    + Show details',
        ]),
        codexMenus,
      )!;
      expect(after.id, before.id);
    });

    test('a redraw that leaves one blank row still ends at the heading', () {
      final apart = readScreenMenu(
        approval(const ['• Ran dart pub get', '  └ Resolving dependencies...']),
        codexMenus,
      )!;
      final rows = approval(const [
        '• Ran dart pub get',
        '  └ Resolving dependencies...',
        '    Downloading pack',
      ]);
      // One of the two blank rows under the transcript drawn over.
      rows.removeAt(3);
      final close = readScreenMenu(rows, codexMenus)!;
      expect(
        close.prompt.first,
        'Would you like to run the following command?',
      );
      expect(close.id, apart.id);
    });

    test('the footer under a menu still drawing is not an option', () {
      final menu = readScreenMenu(
        approval(
          const [],
          options: const [
            '› 1. Yes, proceed (y)',
            '  2. Yes, and don\'t ask again for commands that start with `dart`',
            '  3. No, and tell Codex',
            r'  GPT-6.1 Terra medium · ~\work\demo',
            '  ? for shortcuts                    ⚠ 1 warning · f2 to view',
          ],
        ),
        codexMenus,
      )!;
      expect(menu.options, hasLength(3));
      expect(menu.options.last, 'No, and tell Codex');
    });

    test('options left over from an earlier draw are not this menu', () {
      final menu = readScreenMenu(const [
        '  Trust this folder? Codex can read, edit, and run files here.',
        '',
        '  1. Trust and continue',
        '  2. Quit',
        '› 1. Trust and continue',
        '  2. Quit',
        '',
        '  enter continue · esc quit',
      ], codexMenus)!;
      expect(menu.options, ['Trust and continue', 'Quit']);
      expect(menu.highlighted, 0);
    });

    test('a message sent to Codex, wrapped, is no menu', () {
      expect(
        readScreenMenu(const [
          '  Worked for 6m 21s • 7:23 AM',
          '',
          '',
          '› [message from the Karmashala session "Tiny Temple: 3D cozy temple',
          '  game (flutter_scene on beej)" (4272b910-9135-4724-9321-',
          '  6bf9aadfff3e)]',
          '',
          '› Ask Codex to do anything',
          '',
          r'  GPT-6.1 Terra medium · ~\work\demo',
        ], codexMenus),
        isNull,
      );
    });

    test('folder trust reads whole, its prompt from the heading', () {
      final menu = readScreenMenu(const [
        '╰──────────────────────────────────────────────╯',
        '',
        '  Folder access',
        r'  C:\work\demo',
        '',
        '  Trust this folder? Codex can read, edit, and run files here, subject',
        '  to your permission settings. Your trust decision will be saved.',
        '',
        '› 1. Trust and continue',
        '  2. Quit',
        '',
        '  enter continue · esc quit',
      ], codexMenus)!;
      expect(menu.options, ['Trust and continue', 'Quit']);
      expect(menu.prompt.first, 'Folder access');
      expect(codexMenus.affirmativeIn(menu), 0);
      expect(codexMenus.negativeIn(menu), 1);
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
