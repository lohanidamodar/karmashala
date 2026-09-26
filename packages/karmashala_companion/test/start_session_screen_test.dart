/// Starting a session from the phone: the choice is made from what the desktop
/// reported, the permission mode is picked rather than assumed, a retry after
/// a failure resends the same intention, and the screen lands on the session
/// it just started.
library;

import 'dart:async';

import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion/providers.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

class _PendingStartGateway extends FakeCompanionGateway {
  _PendingStartGateway({super.connections = const []})
    : super(
        pairing: CompanionPairing(
          capabilities: CapabilitySet.all,
          hostName: 'Desktop',
          hostId: DeviceId.parse(
            connections.isEmpty ? fakeHostId(0) : connections.first.hostId,
          ),
        ),
        link: CompanionLinkState.connected,
      ) {
    workspace = [workspaceProject()];
  }

  final completer = Completer<RemoteSessionStarted>();
  var calls = 0;

  @override
  Future<List<RemoteWorkspaceProject>> listWorkspace() async => [
    workspaceProject(),
  ];

  @override
  Future<RemoteSessionStarted> startSession({
    required String requestId,
    required String repositoryId,
    required String installationId,
    required String permissionMode,
    String? title,
    String? message,
    bool worktree = false,
  }) {
    calls++;
    return completer.future;
  }
}

const _ask = RemotePermissionOption(
  mode: 'ask',
  label: 'Ask every time',
  summary: 'Rover CLI is told to use it.',
  selectable: true,
);
const _acceptEdits = RemotePermissionOption(
  mode: 'acceptEdits',
  label: 'Accept edits',
  summary: 'Rover CLI takes no flag for this, so its own default applies.',
  selectable: false,
);
const _bypass = RemotePermissionOption(
  mode: 'bypass',
  label: 'Bypass (full autonomy)',
  summary: 'Rover CLI is told to use it.',
  selectable: true,
  dangerous: true,
);

RemoteAgentOption agent({
  String installationId = 'i1',
  String name = 'Rover CLI',
  bool acceptsOpeningMessage = true,
  String defaultMode = 'ask',
}) => RemoteAgentOption(
  installationId: installationId,
  agentId: 'roverCli',
  name: name,
  version: '1.0.0',
  defaultMode: defaultMode,
  acceptsOpeningMessage: acceptsOpeningMessage,
  permissionModes: const [_ask, _acceptEdits, _bypass],
);

RemoteWorkspaceProject workspaceProject({
  String projectId = 'p1',
  String name = 'popupbits',
  String? environmentName,
  List<RemoteCheckoutOption>? checkouts,
}) => RemoteWorkspaceProject(
  projectId: projectId,
  name: name,
  path: '/w/$name',
  environmentName: environmentName,
  checkouts:
      checkouts ??
      [
        RemoteCheckoutOption(
          repositoryId: 'r1',
          name: 'app',
          path: '/w/$name/app',
          branch: 'main',
          environmentName: environmentName,
          agents: [agent()],
        ),
      ],
);

/// The reported case: one project, one repository, checked out twice — once
/// natively and once inside a WSL distribution. Both checkouts are called
/// "app"; only the environment tells them apart.
RemoteWorkspaceProject checkedOutTwice() => RemoteWorkspaceProject(
  projectId: 'p1',
  name: 'popupbits',
  path: r'C:\src\popupbits',
  environmentName: 'Windows',
  checkouts: [
    RemoteCheckoutOption(
      repositoryId: 'r-win',
      name: 'app',
      path: r'C:\src\popupbits\app',
      branch: 'main',
      environmentName: 'Windows',
      agents: [agent()],
    ),
    RemoteCheckoutOption(
      repositoryId: 'r-wsl',
      name: 'app',
      path: '/home/me/popupbits/app',
      branch: 'main',
      environmentName: 'WSL · Ubuntu',
      agents: [agent(installationId: 'i2')],
    ),
  ],
);

FakeCompanionGateway paired({
  List<RemoteWorkspaceProject>? workspace,
  CapabilitySet? capabilities,
}) =>
    FakeCompanionGateway.paired(capabilities: capabilities)
      ..workspace = workspace ?? [workspaceProject()];

void main() {
  group('the form', () {
    testWidgets('offers the desktop own projects, agents and modes', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: paired(),
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      expect(find.text('popupbits'), findsOneWidget);
      expect(find.text('app'), findsOneWidget);
      expect(find.text('Rover CLI'), findsOneWidget);
      expect(
        find.text('Ask every time'),
        findsOneWidget,
        reason: "the desktop's own default is preselected, not one of ours",
      );
      expect(find.text('Start session'), findsOneWidget);
    });

    testWidgets('a mode the agent cannot take is shown and not selectable', (
      tester,
    ) async {
      final gateway = paired();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Ask every time'));
      await tester.pumpAndSettle();

      expect(find.text('Accept edits'), findsOneWidget);
      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Accept edits'),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.enabled, isFalse);
      expect(
        find.textContaining('takes no flag for this'),
        findsOneWidget,
        reason: 'and it says why, in the desktop own words',
      );
    });

    testWidgets('says an agent takes no opening message before one is typed', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: paired(
          workspace: [
            workspaceProject(
              checkouts: [
                RemoteCheckoutOption(
                  repositoryId: 'r1',
                  name: 'app',
                  agents: [agent(acceptsOpeningMessage: false)],
                ),
              ],
            ),
          ],
        ),
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('takes no opening message'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.ancestor(
          of: find.text('First message'),
          matching: find.byType(TextField),
        ),
      );
      expect(field.enabled, isFalse);
    });

    testWidgets('a checkout with no agent installed says so', (tester) async {
      await pumpPhone(
        tester,
        gateway: paired(
          workspace: [
            workspaceProject(
              checkouts: const [
                RemoteCheckoutOption(repositoryId: 'r1', name: 'app'),
              ],
            ),
          ],
        ),
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      expect(find.text('No agent installed here'), findsOneWidget);
      expect(find.text('Start session'), findsNothing);
    });

    testWidgets('a desktop with nothing to start in says so', (tester) async {
      await pumpPhone(
        tester,
        gateway: paired(workspace: const []),
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Nothing to start in'), findsOneWidget);
    });

    testWidgets('an explicit missing project is never replaced by another', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: paired(workspace: [workspaceProject(projectId: 'other')]),
        home: const StartSessionScreen(projectId: 'missing'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Project no longer available'), findsOneWidget);
      expect(find.text('Start session'), findsNothing);
    });

    testWidgets('a removed selected checkout is not replaced silently', (
      tester,
    ) async {
      final gateway = paired(workspace: [checkedOutTwice()]);
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Checkout'));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      await tester.tap(
        find.descendant(of: sheet, matching: find.text('WSL · Ubuntu')),
      );
      await tester.pumpAndSettle();

      gateway.workspace = [workspaceProject()];
      ProviderScope.containerOf(
        tester.element(find.byType(StartSessionScreen)),
      ).invalidate(companionWorkspaceProvider);
      await tester.pumpAndSettle();

      expect(find.text('Checkout changed'), findsOneWidget);
      expect(find.text('Start session'), findsNothing);
      expect(gateway.startedSessions, isEmpty);
    });

    testWidgets('a pending start ignores duplicate taps', (tester) async {
      final gateway = _PendingStartGateway();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Start session'),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(gateway.calls, 1);
      gateway.completer.complete(
        const RemoteSessionStarted(sessionId: 'started', title: 'Started'),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('a pending start does not navigate after host switch', (
      tester,
    ) async {
      final gateway = _PendingStartGateway(
        connections: [
          CompanionConnection(hostId: fakeHostId(0), name: 'A', active: true),
          CompanionConnection(hostId: fakeHostId(1), name: 'B', active: false),
        ],
      );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start session'));
      await tester.pump();
      await gateway.switchTo(fakeHostId(1));
      gateway.completer.complete(
        const RemoteSessionStarted(sessionId: 'old-host', title: 'Old host'),
      );
      await tester.pumpAndSettle();

      expect(find.byType(StartSessionScreen), findsOneWidget);
      expect(find.textContaining('active desktop changed'), findsOneWidget);
    });

    testWidgets('a phone without the grant is told, not left guessing', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: paired(
          capabilities: CapabilitySet(
            CapabilitySet.all.bits & ~Capability.startSession.bit,
          ),
        ),
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Not granted'), findsOneWidget);
      expect(find.text('Start session'), findsNothing);
    });
  });

  group('which environment', () {
    testWidgets('two checkouts of one project are told apart by name alone', (
      tester,
    ) async {
      final gateway = paired(workspace: [checkedOutTwice()]);
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Checkout'));
      await tester.pumpAndSettle();

      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: sheet, matching: find.text('app')),
        findsNWidgets(2),
        reason:
            'both rows carry the same name — the ambiguity that was reported',
      );
      expect(
        find.descendant(of: sheet, matching: find.text('Windows')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('WSL · Ubuntu')),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(of: sheet, matching: find.text('WSL · Ubuntu')),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('WSL · Ubuntu'),
        findsOneWidget,
        reason: 'the settled row keeps saying which environment it picked',
      );
      await tester.tap(find.text('Start session'));
      await tester.pumpAndSettle();
      expect(gateway.startedSessions.single.repositoryId, 'r-wsl');
    });

    testWidgets('two projects of one name are told apart in the picker', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: paired(
          workspace: [
            workspaceProject(environmentName: 'Windows'),
            workspaceProject(projectId: 'p2', environmentName: 'WSL · Ubuntu'),
          ],
        ),
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Project'));
      await tester.pumpAndSettle();

      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: sheet, matching: find.text('Windows')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('WSL · Ubuntu')),
        findsOneWidget,
      );
    });

    testWidgets('a screen reader is told which environment, not just shown', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpPhone(
        tester,
        gateway: paired(workspace: [checkedOutTwice()]),
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('Environment: Windows'),
        findsOneWidget,
        reason: 'the fact is labelled, not left as a bare word on a line',
      );

      await tester.tap(find.text('Checkout'));
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('Environment: WSL, Ubuntu'),
        findsOneWidget,
        reason: 'the separator is spoken as a pause, not as a middle dot',
      );
      handle.dispose();
    });

    testWidgets('an environment with no name falls back to the path', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpPhone(
        tester,
        gateway: paired(),
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel(RegExp('^Environment')),
        findsNothing,
        reason: 'nothing useful to say, so nothing is said',
      );
      expect(
        find.textContaining('/w/popupbits/app'),
        findsOneWidget,
        reason: 'the path still locates the checkout',
      );
      handle.dispose();
    });

    testWidgets('the environment survives a 200% text scale', (tester) async {
      await pumpPhone(
        tester,
        gateway: paired(workspace: [checkedOutTwice()]),
        home: const StartSessionScreen(),
        textScale: 2.0,
      );
      await tester.pumpAndSettle();

      expect(find.text('Windows'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Checkout'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('WSL · Ubuntu'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('starting', () {
    testWidgets('sends the picked mode and lands on the new session', (
      tester,
    ) async {
      final gateway = paired();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.ancestor(of: find.text('Title'), matching: find.byType(TextField)),
        'From the phone',
      );
      await tester.tap(find.text('Ask every time'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bypass (full autonomy)'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start session'));
      await tester.pumpAndSettle();

      expect(gateway.startedSessions, hasLength(1));
      final sent = gateway.startedSessions.single;
      expect(sent.repositoryId, 'r1');
      expect(sent.installationId, 'i1');
      expect(sent.permissionMode, 'bypass');
      expect(sent.title, 'From the phone');
      expect(sent.worktree, isFalse, reason: 'the checkout itself, unasked');
      expect(find.byType(SessionViewScreen), findsOneWidget);
      expect(
        find.byType(StartSessionScreen),
        findsNothing,
        reason: 'the form is replaced, so it cannot be started twice',
      );
    });

    testWidgets('asks for a worktree of its own when switched on', (
      tester,
    ) async {
      final gateway = paired();
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Own worktree'));
      await tester.tap(find.text('Own worktree'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Start session'));
      await tester.tap(find.text('Start session'));
      await tester.pumpAndSettle();

      expect(gateway.startedSessions.single.worktree, isTrue);
    });

    testWidgets('a refusal is shown in the desktop own words', (tester) async {
      final gateway = paired()
        ..startFailure = const GatewayException(
          'The desktop refused: that folder is gone.',
        );
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start session'));
      await tester.pumpAndSettle();

      expect(
        find.text('The desktop refused: that folder is gone.'),
        findsOneWidget,
      );
      expect(find.byType(SessionViewScreen), findsNothing);
    });

    testWidgets('a retry of the same request resends the same key', (
      tester,
    ) async {
      final gateway = paired()
        ..startFailure = const GatewayException('The desktop did not answer.');
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start session'));
      await tester.pumpAndSettle();
      gateway.startFailure = null;
      await tester.tap(find.text('Start session'));
      await tester.pumpAndSettle();

      expect(gateway.startedSessions, hasLength(2));
      expect(
        gateway.startedSessions.first.requestId,
        gateway.startedSessions.last.requestId,
        reason: 'one intention, so the desktop can recognise the retry',
      );
    });

    testWidgets('changing the request mints a new key', (tester) async {
      final gateway = paired()
        ..startFailure = const GatewayException('The desktop did not answer.');
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const StartSessionScreen(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start session'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.ancestor(of: find.text('Title'), matching: find.byType(TextField)),
        'Something else entirely',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start session'));
      await tester.pumpAndSettle();

      expect(
        gateway.startedSessions.first.requestId,
        isNot(gateway.startedSessions.last.requestId),
        reason: 'a different request must not be answered with the last one',
      );
    });
  });

  group('at other sizes', () {
    testWidgets('renders on a tablet-sized surface without overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        buildPhoneApp(gateway: paired(), home: const StartSessionScreen()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Start session'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives a 200% text scale', (tester) async {
      await pumpPhone(
        tester,
        gateway: paired(),
        home: const StartSessionScreen(),
        textScale: 2.0,
      );
      await tester.pumpAndSettle();

      // Twice the text is taller than the phone, so the button is genuinely
      // below the fold — the form must scroll to it rather than clip it.
      await tester.dragUntilVisible(
        find.text('Start session'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('Start session'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the way in', () {
    testWidgets('the projects tab offers it, and only with the grant', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: paired(),
        home: const SessionListScreen(),
      );
      await tester.pumpAndSettle();
      await tester.pump();

      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      expect(find.text('New session'), findsOneWidget);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();

      await pumpPhone(
        tester,
        gateway: paired(
          capabilities: CapabilitySet(
            CapabilitySet.all.bits & ~Capability.startSession.bit,
          ),
        ),
        home: const SessionListScreen(),
      );
      await tester.pumpAndSettle();

      expect(find.text('New session'), findsNothing);
    });

    testWidgets("a project's own screen starts one in that project", (
      tester,
    ) async {
      final gateway = paired()
        ..setSessions([summary('s1', project: 'popupbits', projectId: 'p1')]);
      await pumpPhone(
        tester,
        gateway: gateway,
        home: const ProjectSessionsScreen(projectKey: 'p1'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Start a session'));
      await tester.pumpAndSettle();

      expect(find.byType(StartSessionScreen), findsOneWidget);
      expect(find.text('popupbits'), findsWidgets);
    });
  });
}
