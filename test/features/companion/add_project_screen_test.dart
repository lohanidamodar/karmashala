import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/companion/application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala/src/features/companion/presentation/add_project_screen.dart';
import 'package:karmashala/src/features/companion/presentation/project_sessions_screen.dart';
import 'package:karmashala_remote/remote.dart';

import 'companion_test_support.dart';

class _AddGateway extends FakeCompanionGateway {
  _AddGateway({
    CapabilitySet? capabilities,
    super.link = CompanionLinkState.connected,
    super.connections = const [],
  }) : super(
         pairing: CompanionPairing(
           capabilities: capabilities ?? CapabilitySet.all,
           hostName: 'Desktop',
           hostId: DeviceId.parse(fakeHostId(0)),
         ),
       );

  final calls = <({String requestId, String name, String path})>[];
  final projects = <RemoteWorkspaceProject>[];
  Completer<RemoteWorkspaceProject>? pending;
  Object? failure;
  int projectLists = 0;
  int workspaceLists = 0;
  final projectHostIds = <String?>[];
  final workspaceHostIds = <String?>[];

  @override
  Future<List<RemoteWorkspaceProject>> listProjects() async {
    projectLists++;
    projectHostIds.add(pairing?.hostId?.value);
    return List.unmodifiable(projects);
  }

  @override
  Future<List<RemoteWorkspaceProject>> listWorkspace() async {
    workspaceLists++;
    workspaceHostIds.add(pairing?.hostId?.value);
    return List.unmodifiable(projects);
  }

  @override
  Future<RemoteWorkspaceProject> addProject({
    required String requestId,
    required String name,
    required String path,
  }) async {
    calls.add((requestId: requestId, name: name, path: path));
    final error = failure;
    if (error != null) throw error;
    final waiter = pending;
    if (waiter != null) return waiter.future;
    return RemoteWorkspaceProject(projectId: requestId, name: name, path: path);
  }
}

Future<void> _fill(WidgetTester tester, {String name = 'Demo', String path = r'C:\work\demo'}) async {
  await tester.enterText(find.byType(TextField).at(0), name);
  await tester.enterText(find.byType(TextField).at(1), path);
}

Future<void> _tapAdd(WidgetTester tester) async {
  final button = find.byType(FilledButton);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

void main() {
  testWidgets('permission denied does not expose the form', (tester) async {
    final gateway = _AddGateway(capabilities: CapabilitySet.none);
    await pumpPhone(tester, gateway: gateway, home: const AddProjectScreen());
    expect(find.text('Not granted'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('blank name or path is validated without a gateway call', (tester) async {
    final gateway = _AddGateway();
    await pumpPhone(tester, gateway: gateway, home: const AddProjectScreen());
    await _tapAdd(tester);
    expect(find.text('Enter a project name.'), findsOneWidget);
    expect(gateway.calls, isEmpty);
    await tester.enterText(find.byType(TextField).first, 'Demo');
    await _tapAdd(tester);
    expect(find.text('Enter the project path on your desktop.'), findsOneWidget);
    expect(gateway.calls, isEmpty);
  });

  testWidgets('valid submission navigates to the new project', (tester) async {
    final gateway = _AddGateway();
    await pumpPhone(tester, gateway: gateway, home: const AddProjectScreen());
    await _fill(tester);
    await _tapAdd(tester);
    await tester.pumpAndSettle();
    expect(find.byType(ProjectSessionsScreen), findsOneWidget);
    expect(gateway.calls.single.name, 'Demo');
    expect(gateway.calls.single.path, r'C:\work\demo');
  });

  testWidgets('failed call retains both values and retry reuses request id', (tester) async {
    final gateway = _AddGateway()..failure = const GatewayException('Desktop refused the project.');
    await pumpPhone(tester, gateway: gateway, home: const AddProjectScreen());
    await _fill(tester);
    await _tapAdd(tester);
    await tester.pump();
    expect(find.text('Desktop refused the project.'), findsOneWidget);
    expect(find.text('Demo'), findsOneWidget);
    expect(find.text(r'C:\work\demo'), findsOneWidget);
    gateway.failure = null;
    await _tapAdd(tester);
    await tester.pumpAndSettle();
    expect(gateway.calls, hasLength(2));
    expect(gateway.calls[0].requestId, gateway.calls[1].requestId);
  });

  testWidgets('duplicate taps while pending make one call', (tester) async {
    final gateway = _AddGateway()
      ..pending = Completer<RemoteWorkspaceProject>();
    await pumpPhone(tester, gateway: gateway, home: const AddProjectScreen());
    await _fill(tester);
    await _tapAdd(tester);
    await _tapAdd(tester);
    expect(gateway.calls, hasLength(1));
    gateway.pending!.complete(const RemoteWorkspaceProject(
      projectId: 'p1', name: 'Demo', path: r'C:\work\demo',
    ));
    await tester.pumpAndSettle();
  });

  testWidgets('offline submission makes no call', (tester) async {
    final gateway = _AddGateway(link: CompanionLinkState.disconnected);
    await pumpPhone(tester, gateway: gateway, home: const AddProjectScreen());
    await _fill(tester);
    await _tapAdd(tester);
    expect(find.textContaining('Connect to your desktop'), findsOneWidget);
    expect(gateway.calls, isEmpty);
  });

  testWidgets('a host switch while pending does not navigate', (tester) async {
    final gateway = _AddGateway(
      connections: [
        CompanionConnection(hostId: fakeHostId(0), name: 'One', active: true),
        CompanionConnection(hostId: fakeHostId(1), name: 'Two', active: false),
      ],
    )..pending = Completer<RemoteWorkspaceProject>();
    await pumpPhone(tester, gateway: gateway, home: const AddProjectScreen());
    await _fill(tester);
    await _tapAdd(tester);
    await gateway.switchTo(fakeHostId(1));
    gateway.pending!.complete(const RemoteWorkspaceProject(
      projectId: 'p1', name: 'Demo', path: r'C:\work\demo',
    ));
    await tester.pumpAndSettle();
    expect(find.byType(AddProjectScreen), findsOneWidget);
    expect(find.textContaining('active desktop changed'), findsOneWidget);
  });

  testWidgets('phone and tablet layouts do not overflow', (tester) async {
    final gateway = _AddGateway();
    await pumpPhone(tester, gateway: gateway, home: const AddProjectScreen(), size: kPhoneSize);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(buildPhoneApp(gateway: gateway, home: const AddProjectScreen()));
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('project/workspace pulls ignore session churn and refresh on host changes', () async {
    final gateway = _AddGateway(
      connections: [
        CompanionConnection(hostId: fakeHostId(0), name: 'One', active: true),
        CompanionConnection(hostId: fakeHostId(1), name: 'Two', active: false),
      ],
    );
    final container = ProviderContainer(
      overrides: [companionGatewayProvider.overrideWithValue(gateway)],
    );
    addTearDown(container.dispose);
    // Keep the providers alive like the visible projects screen does. A bare
    // read.future can auto-dispose between emissions and would not prove that
    // session churn is harmless while the screen is open.
    final projectsVisible = container.listen(
      companionProjectsProvider,
      (previous, next) {},
      fireImmediately: true,
    );
    final workspaceVisible = container.listen(
      companionWorkspaceProvider,
      (previous, next) {},
      fireImmediately: true,
    );
    final sessionsVisible = container.listen(
      companionSessionsProvider,
      (previous, next) {},
      fireImmediately: true,
    );
    addTearDown(projectsVisible.close);
    addTearDown(workspaceVisible.close);
    addTearDown(sessionsVisible.close);

    await Future.wait([
      container.read(companionProjectsProvider.future),
      container.read(companionWorkspaceProvider.future),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(gateway.projectLists, 1);
    expect(gateway.workspaceLists, 1);
    for (var i = 0; i < 20; i++) {
      gateway.setSessions([summary('s$i')]);
    }
    await Future<void>.delayed(Duration.zero);
    expect(gateway.projectLists, 1);
    expect(gateway.workspaceLists, 1);

    gateway.setLink(CompanionLinkState.disconnected);
    await Future<void>.delayed(Duration.zero);
    expect(gateway.projectLists, 1);
    expect(gateway.workspaceLists, 1);
    await gateway.reconnect();
    await Future<void>.delayed(Duration.zero);
    await Future.wait([
      container.read(companionProjectsProvider.future),
      container.read(companionWorkspaceProvider.future),
    ]);
    expect(gateway.projectLists, 2);
    expect(gateway.workspaceLists, 2);

    await gateway.switchTo(fakeHostId(1));
    await Future<void>.delayed(Duration.zero);
    await Future.wait([
      container.read(companionProjectsProvider.future),
      container.read(companionWorkspaceProvider.future),
    ]);
    expect(gateway.projectLists, 3);
    expect(gateway.workspaceLists, 3);
    expect(gateway.projectHostIds.last, fakeHostId(1));
    expect(gateway.workspaceHostIds.last, fakeHostId(1));
  });
}
