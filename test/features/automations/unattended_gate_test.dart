import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/automations/domain/unattended_gate.dart';
import 'package:karmashala/src/features/settings/domain/permission_risk.dart';

/// The rules that keep an agent from starting with nobody watching.
///
/// One test per rule, and one for the order they are applied in — the order is
/// what decides which sentence a person is shown when two things are wrong at
/// once, and it is chosen so the first sentence is the one they can act on.
void main() {
  UnattendedGateInput input({
    bool verificationEnabled = true,
    int projectCheckCount = 1,
    bool agentInstalled = true,
    PermissionRisk? permits = PermissionRisk.autoRun,
    String permissionLabel = 'Automatic',
    String permissionEvidence = '',
    UnattendedReach reach = UnattendedReach.reachable,
    String reachReason = '',
  }) => UnattendedGateInput(
    repositoryName: 'app',
    verificationEnabled: verificationEnabled,
    projectCheckCount: projectCheckCount,
    agentName: 'Claude Code',
    agentInstalled: agentInstalled,
    permits: permits,
    permissionLabel: permissionLabel,
    permissionEvidence: permissionEvidence,
    reach: reach,
    reachReason: reachReason,
  );

  test('a workspace with everything in place is not refused', () {
    expect(unattendedRefusal(input()), isNull);
    expect(canRunUnattended(input()), isTrue);
  });

  group('verification is mandatory when nobody is watching', () {
    test('verification off is refused, and the sentence names the checkout', () {
      final refusal = unattendedRefusal(input(verificationEnabled: false));
      expect(refusal?.kind, UnattendedRefusalKind.verificationDisabled);
      expect(refusal!.reason, contains('Verification is off for app'));
      expect(refusal.reason, contains('project check'));
    });

    test('verification on with no check at all is refused', () {
      final refusal = unattendedRefusal(input(projectCheckCount: 0));
      expect(refusal?.kind, UnattendedRefusalKind.noProjectChecks);
      expect(refusal!.reason, contains('no project check'));
    });

    test('one check is enough', () {
      expect(unattendedRefusal(input(projectCheckCount: 1)), isNull);
    });
  });

  group('a mode that prompts is refused, never downgraded', () {
    test('"ask every time" is refused, with the mode named', () {
      final refusal = unattendedRefusal(
        input(
          permits: PermissionRisk.ask,
          permissionLabel: 'Ask every time',
          permissionEvidence: '2.1.245 string table: "default (ask each time)"',
        ),
      );
      expect(refusal?.kind, UnattendedRefusalKind.permissionModeCanPrompt);
      expect(refusal!.reason, contains('"Ask every time"'));
      expect(refusal.reason, contains('nobody there to answer'));
      // Refused with its stated reason, not silently widened to something else.
      expect(refusal.reason, contains('rather than quietly widened'));
      expect(refusal.reason, contains('default (ask each time)'));
    });

    test('"accept edits" still asks before commands, so it is refused too', () {
      final refusal = unattendedRefusal(
        input(permits: PermissionRisk.acceptEdits, permissionLabel: 'Accept edits'),
      );
      expect(refusal?.kind, UnattendedRefusalKind.permissionModeCanPrompt);
    });

    test('the three rungs that do not prompt are allowed', () {
      for (final risk in const [
        PermissionRisk.readOnly,
        PermissionRisk.autoRun,
        PermissionRisk.bypass,
      ]) {
        expect(
          unattendedRefusal(input(permits: risk)),
          isNull,
          reason: '${risk.name} does not stop for a human',
        );
        expect(permissionModeCanPrompt(risk), isFalse);
      }
    });

    test('an agent that is no longer installed is refused, not substituted', () {
      final refusal = unattendedRefusal(input(agentInstalled: false));
      expect(refusal?.kind, UnattendedRefusalKind.agentUnavailable);
      expect(refusal!.reason, contains('no longer installed'));
      expect(refusal.reason, contains('Nothing is substituted'));
    });

    test('an agent whose modes were never established is refused, not assumed', () {
      final refusal = unattendedRefusal(input(permits: null));
      expect(refusal?.kind, UnattendedRefusalKind.permissionModeUnknown);
      expect(refusal!.reason, contains('has not established'));
      expect(refusal.reason, contains('Claude Code'));
    });
  });

  group('the environment must be reachable from here', () {
    test('nothing naming where it would run is refused', () {
      final refusal = unattendedRefusal(
        input(
          reach: UnattendedReach.unnamed,
          reachReason: 'No checkout, so nothing says where its commands would run',
        ),
      );
      expect(refusal?.kind, UnattendedRefusalKind.environmentUnnamed);
      expect(refusal!.reason, contains('cannot say where'));
      expect(refusal.reason, contains('nothing says where its commands would run'));
    });

    test('an SSH checkout with no way to dial it is refused, in the resolver\'s words', () {
      final refusal = unattendedRefusal(
        input(
          reach: UnattendedReach.unreachable,
          reachReason:
              'No SSH connection pool is configured; cannot run commands in ssh:1',
        ),
      );
      expect(refusal?.kind, UnattendedRefusalKind.environmentUnreachable);
      expect(refusal!.reason, contains('cannot reach where'));
      expect(refusal.reason, contains('No SSH connection pool is configured'));
      expect(refusal.reason, contains('cannot be armed'));
    });
  });

  test('the checkout is named before the mode, and the mode before the machine', () {
    // Everything wrong at once: the first sentence is the one the arm form can
    // offer a fix for.
    final all = input(
      verificationEnabled: false,
      projectCheckCount: 0,
      permits: PermissionRisk.ask,
      reach: UnattendedReach.unreachable,
    );
    expect(
      unattendedRefusal(all)?.kind,
      UnattendedRefusalKind.verificationDisabled,
    );
    expect(
      unattendedRefusal(input(projectCheckCount: 0, permits: PermissionRisk.ask))
          ?.kind,
      UnattendedRefusalKind.noProjectChecks,
    );
    expect(
      unattendedRefusal(
        input(permits: PermissionRisk.ask, reach: UnattendedReach.unreachable),
      )?.kind,
      UnattendedRefusalKind.permissionModeCanPrompt,
    );
  });

  test('a refusal is never wordless', () {
    for (final refusal in [
      unattendedRefusal(input(verificationEnabled: false)),
      unattendedRefusal(input(projectCheckCount: 0)),
      unattendedRefusal(input(permits: null)),
      unattendedRefusal(input(permits: PermissionRisk.ask)),
      unattendedRefusal(input(reach: UnattendedReach.unnamed)),
      unattendedRefusal(input(reach: UnattendedReach.unreachable)),
    ]) {
      expect(refusal, isNotNull);
      expect(refusal!.reason.trim(), isNotEmpty);
      expect(refusal.toString(), refusal.reason);
    }
  });
}
