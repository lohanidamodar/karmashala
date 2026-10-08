import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// Claude Code 2.1.287's project-MCP checklist, captured in a real ConPTY at
/// 160 columns (`live_prompt_probe_test.dart`, 2026-10-08, a `.mcp.json`
/// naming `alpha` and `beta`). [at] is the highlighted row: 0 and 1 the
/// servers, 2 "Enable selected"; [ticks] the boxes.
List<String> mcpScreen({
  int at = 0,
  List<bool> ticks = const [true, true],
  bool narrow = false,
}) {
  String box(bool tick) => tick ? '[✔]' : '[ ]';
  String mark(int row) => row == at ? '❯' : ' ';
  return [
    '─' * (narrow ? 80 : 160),
    '  2 new MCP servers found in this project',
    '  Select any you wish to enable.',
    '',
    if (narrow) ...[
      '  MCP servers may execute code or access system resources. All tool calls',
      '  require approval. Learn more in the MCP documentation.',
    ] else
      '  MCP servers may execute code or access system resources. All tool '
          'calls require approval. Learn more in the MCP documentation.',
    '',
    '  ${mark(0)} ${box(ticks[0])} alpha',
    '  ${mark(1)} ${box(ticks[1])} beta',
    '  ${mark(2)}    Enable selected',
    ' Space to select · Esc to reject all',
  ];
}

/// The single-server form of the same prompt: a plain menu, captured likewise.
const _oneServer = [
  '  New MCP server found in this project: alpha',
  '',
  '  MCP servers may execute code or access system resources. All tool calls '
      'require approval. Learn more in the MCP documentation.',
  '',
  '    Use this MCP server',
  '    Use this and all future MCP servers in this project',
  '  ❯ Continue without using this MCP server',
  '',
  '  Enter to confirm · Esc to cancel',
];

void main() {
  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
  final menus = claude.menus!;

  group('the checklist is read whole', () {
    test('its boxes, its ticks and its submit row', () {
      final menu = readScreenMenu(mcpScreen(), menus)!;
      expect(menu.isChecklist, isTrue);
      expect(menu.options, ['alpha', 'beta', 'Enable selected']);
      expect(menu.checked, [true, true, null]);
      expect(menu.boxes, [0, 1]);
      expect(menu.submit, 2);
      expect(menu.highlighted, 0);
      expect(menu.prompt, [
        '2 new MCP servers found in this project',
        'Select any you wish to enable.',
        'MCP servers may execute code or access system resources. All tool '
            'calls require approval. Learn more in the MCP documentation.',
      ]);
    });

    test('with the highlight on "Enable selected", as the owner saw it', () {
      final menu = readScreenMenu(mcpScreen(at: 2), menus)!;
      expect(menu.highlighted, 2);
      expect(menu.options, ['alpha', 'beta', 'Enable selected']);
    });

    test('an unticked box reads as unticked', () {
      final menu = readScreenMenu(
        mcpScreen(at: 1, ticks: [false, true]),
        menus,
      )!;
      expect(menu.checked, [false, true, null]);
      expect(menu.highlighted, 1);
    });

    test('the same checklist keeps its id as the highlight and ticks move', () {
      final ids = {
        for (final at in [0, 1, 2])
          for (final ticks in [
            [true, true],
            [false, true],
            [false, false],
          ])
            readScreenMenu(mcpScreen(at: at, ticks: ticks), menus)!.id,
      };
      expect(ids, hasLength(1));
    });

    test('wrapped at 80 columns it reads the same options', () {
      final menu = readScreenMenu(mcpScreen(narrow: true), menus)!;
      expect(menu.options, ['alpha', 'beta', 'Enable selected']);
      expect(menu.checked, [true, true, null]);
    });

    test('a single-choice menu is not a checklist', () {
      final menu = readScreenMenu(_oneServer, menus)!;
      expect(menu.isChecklist, isFalse);
      expect(menu.options, [
        'Use this MCP server',
        'Use this and all future MCP servers in this project',
        'Continue without using this MCP server',
      ]);
      expect(menu.highlighted, 2);
    });

    test('Esc declines the checklist safely; no option means approve', () {
      final menu = readScreenMenu(mcpScreen(), menus)!;
      expect(menus.cancelDeclinesIn(menu), isTrue);
      expect(menus.affirmativeIn(menu), isNull);
      expect(menus.toggle, ' ');
      expect(menus.cancel, '\x1b');
    });
  });

  group('the startup prompt is declared', () {
    final rules = claude.launch.firstRunPrompt;

    test('plural, at 160 and at 80 columns, and wrapped mid-word', () {
      for (final screen in [
        mcpScreen(),
        mcpScreen(narrow: true),
        [' 2 new MCP servers fou', 'nd in this project', ' Space to select'],
      ]) {
        final prompt = rules.otherOn(screen);
        expect(prompt?.asks, "which of this project's MCP servers to enable");
        expect(rules.matchedBy(screen), isFalse, reason: 'it is not trust');
      }
    });

    test('at 200 columns, rows padded wide', () {
      final wide = [for (final row in mcpScreen()) row.padRight(200)];
      expect(rules.otherOn(wide), isNotNull);
    });

    test('singular', () {
      expect(
        rules.otherOn(_oneServer)?.asks,
        "which of this project's MCP servers to enable",
      );
    });

    test('folder trust is still trust, and not another prompt', () {
      const trust = [
        ' Quick safety check: Is this a project you created or one you trust?',
        ' ❯ No, exit',
        '   Yes, I trust this folder',
      ];
      expect(rules.matchedBy(trust), isTrue);
      expect(rules.otherOn(trust), isNull);
    });

    test('an ordinary screen is neither', () {
      const idle = ['❯ ', '⏸ manual mode on · ? for shortcuts'];
      expect(rules.matchedBy(idle), isFalse);
      expect(rules.otherOn(idle), isNull);
    });
  });
}
