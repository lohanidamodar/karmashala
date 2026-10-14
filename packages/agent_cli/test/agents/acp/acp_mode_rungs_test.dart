import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// Where an ACP agent's modes sit on Karmashala's rungs: declared for a
/// shipped agent, written by a person for one they added, and matched by a
/// mode's id or, failing that, its name.
void main() {
  group('mode lines', () {
    test('parse, case-insensitive rungs, and format back', () {
      final parsed = parseAcpModeRungLines(
        'Plan = read-only\n\n  Agent=ASK \nAutopilot = bypass',
      );
      expect(parsed.refusal, isNull);
      expect(parsed.rungs, {
        'Plan': PermissionRisk.readOnly,
        'Agent': PermissionRisk.ask,
        'Autopilot': PermissionRisk.bypass,
      });
      expect(
        formatAcpModeRungLines(parsed.rungs),
        'Plan = read-only\nAgent = ask\nAutopilot = bypass',
      );
    });

    test('a line out of shape is refused in words', () {
      for (final bad in ['Plan', 'Plan = wide-open', '= ask']) {
        expect(
          parseAcpModeRungLines(bad).refusal,
          allOf(contains('is not a mode line'), contains('accept-edits')),
          reason: bad,
        );
      }
    });
  });

  test("a person's row places its modes, read by id or by name", () {
    final spec = acpAgentAdapter(
      AcpAgentRow(
        id: 'r1',
        name: 'Copilot',
        command: 'copilot',
        createdAt: DateTime.utc(2026),
        modeRungs: const {
          'Agent': PermissionRisk.ask,
          'Plan': PermissionRisk.readOnly,
          'Autopilot': PermissionRisk.bypass,
        },
      ),
    ).acp!;
    const url = 'https://agentclientprotocol.com/protocol/session-modes';
    final offered = [
      (id: '$url#agent', name: 'Agent'),
      (id: '$url#plan', name: 'Plan'),
      (id: '$url#autopilot', name: 'Autopilot'),
    ];
    expect(
      spec.rungOfOffered('$url#autopilot', 'Autopilot'),
      PermissionRisk.bypass,
    );
    expect(spec.rungOfOffered('$url#agent', null), isNull);
    expect(spec.modeForOffered(PermissionRisk.readOnly, offered), '$url#plan');
    expect(spec.modeForOffered(PermissionRisk.autoRun, offered), isNull);
  });

  test('a row with no modes placed declares none', () {
    final spec = acpAgentAdapter(
      AcpAgentRow(
        id: 'r1',
        name: 'X',
        command: 'x',
        createdAt: DateTime.utc(2026),
      ),
    ).acp!;
    expect(spec.modeNames, isEmpty);
  });

  test("Antigravity's shipped modes are placed as its own words say", () {
    final spec = antigravityAcpDescriptor.acp!;
    expect(spec.rungOfMode('default'), PermissionRisk.ask);
    expect(spec.rungOfMode('auto_edit'), PermissionRisk.acceptEdits);
    expect(spec.rungOfMode('yolo'), PermissionRisk.bypass);
    expect(
      spec.modeFor(PermissionRisk.readOnly, ['default', 'auto_edit', 'yolo']),
      isNull,
    );
  });

  test("a person's placed modes are the session's permission axis: safest "
      'first, the one that asks by default, a bypass dangerous', () {
    AcpAgentRow row(Map<String, PermissionRisk> rungs) => AcpAgentRow(
      id: 'r1',
      name: 'X',
      command: 'x',
      createdAt: DateTime.utc(2026),
      modeRungs: rungs,
    );
    final support = acpAgentAdapter(
      row(const {
        'Yolo': PermissionRisk.bypass,
        'Edit': PermissionRisk.acceptEdits,
        'Plan': PermissionRisk.readOnly,
      }),
    ).descriptor.launch.permission;
    final axis = support.axes.single;
    expect(axis.values.map((v) => v.id), ['Plan', 'Edit', 'Yolo']);
    // No mode asks, so the one that accepts edits is the default.
    expect(axis.defaultValueId, 'Edit');
    expect(support.isDangerous(PermissionSelection({'mode': 'Yolo'})), isTrue);
    expect(
      support.riskOf(PermissionSelection({'mode': 'Plan'})),
      PermissionRisk.readOnly,
    );

    // Nothing to default to but a bypass, or nothing placed: none declared.
    expect(
      acpRowPermission(row(const {'Yolo': PermissionRisk.bypass})).isKnown,
      isFalse,
    );
    expect(acpRowPermission(row(const {})).isKnown, isFalse);
    // A `;` would not survive the stored selection.
    expect(
      acpRowPermission(
        row(const {'a;b': PermissionRisk.ask, 'Plan': PermissionRisk.readOnly}),
      ).axes.single.values.map((v) => v.id),
      ['Plan'],
    );
  });
}
