import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_agent_reporting/karmashala_agent_reporting.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A test run once deleted every agent's real hook endpoint file: a shutdown
/// under test retired the endpoints in the stores the real locator found. The
/// writers refuse the real home under a test runner, whoever calls them.
void main() {
  group('refuseRealHomeUnderTest', () {
    final home = p.join(p.separator, 'users', 'someone');
    final temp = p.join(home, 'tmp');
    final environment = {'HOME': home, 'USERPROFILE': home};

    void check(String path, {required bool underTest}) =>
        refuseRealHomeUnderTest(
          path,
          environment: environment,
          temp: temp,
          underTest: underTest,
          report: (_, _) {},
        );

    test('refuses a store in the real home while a test runs', () {
      expect(
        () => check(p.join(home, '.claude'), underTest: true),
        throwsA(isA<RealHomeUnderTestError>()),
      );
      expect(
        () => check(home, underTest: true),
        throwsA(isA<RealHomeUnderTestError>()),
      );
    });

    test('allows the temp folder, even inside the home', () {
      check(p.join(temp, 'karmashala_x', '.claude'), underTest: true);
    });

    test('allows anything outside the home', () {
      check(p.join(p.separator, 'elsewhere', '.claude'), underTest: true);
    });

    test('allows the real home outside a test', () {
      check(p.join(home, '.claude'), underTest: false);
    });

    test('reports the refusal as well as throwing it', () {
      final reported = <Object>[];
      expect(
        () => refuseRealHomeUnderTest(
          p.join(home, '.codex'),
          environment: environment,
          temp: temp,
          underTest: true,
          report: (error, _) => reported.add(error),
        ),
        throwsA(isA<RealHomeUnderTestError>()),
      );
      expect(reported.single, isA<RealHomeUnderTestError>());
    });
  });

  group('every agent-store writer, pointed at the real home', () {
    final realHome =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']!;
    // Never created: if the guard were missing, there is nothing here to lose.
    final storeHome = p.join(
      realHome,
      '.karmashala-real-home-guard-$pid',
      '.claude',
    );
    final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
    const hooks = AgentHookInstaller();
    const skills = AgentSkillInstaller();

    /// What [act] threw and what reached the test's zone. A caller that
    /// swallows the throw — the app's sweep does — still fails the test.
    Future<(Object?, List<Object>)> run(Future<Object?> Function() act) async {
      final reported = <Object>[];
      Object? thrown;
      await runZonedGuarded(() async {
        try {
          await act();
        } on Object catch (error) {
          thrown = error;
        }
      }, (error, _) => reported.add(error));
      return (thrown, reported);
    }

    final cases = <String, Future<Object?> Function()>{
      'hook install': () => hooks.install(
        descriptor: claude,
        storeHome: storeHome,
        endpoint: const AgentHookEndpoint(port: 1, token: 't'),
        environment: EnvironmentKind.windowsNative,
      ),
      'hook uninstall': () =>
          hooks.uninstall(descriptor: claude, storeHome: storeHome),
      'endpoint retirement': () =>
          hooks.retireEndpoint(descriptor: claude, storeHome: storeHome),
      'skill install': () => skills.install(
        descriptor: claude,
        storeHome: storeHome,
        skills: const [
          KarmashalaSkill(name: 'karmashala-x', description: 'x', body: 'x'),
        ],
        deadline: SkillSweepDeadline()..giveUp(),
      ),
      'skill uninstall': () =>
          skills.uninstall(descriptor: claude, storeHome: storeHome),
      'spool drain': () => const AgentHookSpool().drain(
        Directory(p.join(storeHome, 'karmashala-agent-hook.spool')),
      ),
    };

    for (final MapEntry(key: name, value: act) in cases.entries) {
      test('$name is refused and reported', () async {
        final (thrown, reported) = await run(act);
        expect(thrown, isA<RealHomeUnderTestError>());
        expect(reported.single, isA<RealHomeUnderTestError>());
        expect(Directory(p.dirname(storeHome)).existsSync(), isFalse);
      });
    }
  });
}
