import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:test/test.dart';

/// "Check the result" carries its own command; a step from before it did is
/// given its checkout's project checks, once.
void main() {
  final at = DateTime.utc(2026, 10, 8);
  ProjectCheck check(String id, String name, List<String> argv) => ProjectCheck(
    id: id,
    repositoryId: 'r1',
    name: name,
    command: argv,
    createdAt: at,
  );

  group('carrying project checks into the step', () {
    test('an empty check step takes each check, one a line', () {
      final carried = carryProjectChecks(AutomationSteps.standard, [
        check('c1', 'tests', ['flutter', 'test']),
        check('c2', 'analyze', ['dart', 'analyze', '--fatal-infos']),
      ])!;
      final step = carried.of(AutomationStepKind.check)!;
      expect(step.checkCommands, [
        'flutter test',
        'dart analyze --fatal-infos',
      ]);
      expect(step.refusal, isNull);
    });

    test('one check keeps its name', () {
      final carried = carryProjectChecks(AutomationSteps.standard, [
        check('c1', 'the suite', ['flutter', 'test']),
      ])!;
      expect(carried.of(AutomationStepKind.check)!.name, 'the suite');
    });

    test('an argument with a space survives the round trip', () {
      final carried = carryProjectChecks(AutomationSteps.standard, [
        check('c1', 'run', ['tool', 'a b']),
      ])!;
      final checks = checksOfStep(
        carried.of(AutomationStepKind.check)!,
        automationId: 'a',
        repositoryId: 'r1',
        at: at,
      );
      expect(checks.single.command, ['tool', 'a b']);
      expect(checks.single.name, 'run');
    });

    test('once: a step that has a command is left alone', () {
      final first = carryProjectChecks(AutomationSteps.standard, [
        check('c1', 'tests', ['flutter', 'test']),
      ])!;
      expect(
        carryProjectChecks(first, [
          check('c2', 'other', ['make']),
        ]),
        isNull,
      );
    });

    test('no checks, or no check step, carries nothing', () {
      expect(carryProjectChecks(AutomationSteps.standard, const []), isNull);
      expect(
        carryProjectChecks(AutomationSteps(const []), [
          check('c1', 'tests', ['flutter', 'test']),
        ]),
        isNull,
      );
    });

    test('the other steps stay as they were', () {
      final steps = AutomationSteps(const [
        AutomationStep(kind: AutomationStepKind.check),
        AutomationStep(kind: AutomationStepKind.notify, text: 'done'),
      ]);
      final carried = carryProjectChecks(steps, [
        check('c1', 'tests', ['flutter', 'test']),
      ])!;
      expect(carried.of(AutomationStepKind.notify), steps.after.last);
    });
  });

  group('the step itself', () {
    test('a check step with no command cannot be saved', () {
      expect(
        const AutomationStep(kind: AutomationStepKind.check).refusal,
        contains('Say what command'),
      );
    });

    test('its name and command survive the stored column', () {
      final steps = AutomationSteps(const [
        AutomationStep(
          kind: AutomationStepKind.check,
          text: 'flutter test\ndart analyze',
          name: 'the suite',
        ),
      ]);
      expect(AutomationSteps.fromColumn(steps.toColumn()), steps);
    });

    test('several commands are named by themselves', () {
      final checks = checksOfStep(
        const AutomationStep(
          kind: AutomationStepKind.check,
          text: 'flutter test\n\n  dart analyze  ',
          name: 'ignored for several',
        ),
        automationId: 'a',
        repositoryId: 'r1',
        at: at,
      );
      expect(checks.map((c) => c.name), ['flutter test', 'dart analyze']);
      expect(checks.map((c) => c.id), ['a-check-1', 'a-check-2']);
    });
  });
}
