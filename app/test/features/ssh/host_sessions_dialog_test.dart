import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/ssh/application/host_install_controller.dart';
import 'package:karmashala/src/features/ssh/application/host_sessions.dart';
import 'package:karmashala/src/features/ssh/presentation/host_sessions_dialog.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/host.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';
import 'fake_host_box.dart';
import '../../support/test_machine.dart';

class _Access extends RemoteAccessController {
  _Access(super.ref);

  @override
  Future<void> sync() async {}
}

/// Sessions on a machine whose host is there only once [box] has one.
class _Sessions implements HostSessionsService {
  _Sessions(this.box, this.whenAbsent);

  final FakeHostBox box;
  final HostDeployment whenAbsent;
  var asks = 0;

  @override
  Future<List<SessionSummary>> list(SshHost host) async {
    asks++;
    if (box.installed.isEmpty) {
      throw HostSessionsUnavailable(
        'No session host on ${host.address}: ${whenAbsent.reason}',
        deployment: whenAbsent,
      );
    }
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late TestMachine db;
  setUp(() => db = TestMachine());

  HostDeployment cannotInstall() => HostDeployment(
    status: HostDeploymentStatus.cannotInstall,
    observedAt: testTime.subtract(const Duration(minutes: 1)),
    reason: 'Could not write the bundle on do-box.',
  );

  Widget dialog(FakeHostBox box, _Sessions sessions) => ProviderScope(
    overrides: [
      ...fakeTerminalOverrides(machine: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      remoteAccessControllerProvider.overrideWith(_Access.new),
      hostSessionsServiceProvider.overrideWithValue(sessions),
      hostInstallerFactoryProvider.overrideWithValue(
        (host) => installerOver(box),
      ),
    ],
    child: MaterialApp(home: HostSessionsDialog(host: boxHost)),
  );

  testWidgets('a machine with no host says why, what to do, and offers the '
      'button — then lists', (tester) async {
    final box = FakeHostBox();
    final sessions = _Sessions(box, cannotInstall());
    await tester.pumpWidget(dialog(box, sessions));
    await settleHostBox(tester);

    expect(find.textContaining('Could not write the bundle'), findsOneWidget);
    expect(find.textContaining('no root is needed'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Install'));
    await settleHostBox(tester);

    expect(box.uploads, hasLength(1));
    expect(sessions.asks, 2, reason: 'installed, so it asked again');
    expect(find.text('This host is holding nothing.'), findsOneWidget);
  });

  testWidgets('the failure survives the window matrix', (tester) async {
    final box = FakeHostBox();
    await expectSurvivesWindowMatrix(
      tester,
      build: () => dialog(box, _Sessions(box, cannotInstall())),
      because: 'a sentence, a remedy and a button where a list would be',
    );
  });
}
