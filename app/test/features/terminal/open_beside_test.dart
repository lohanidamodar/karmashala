import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import 'fake_instance.dart';

/// Quick open's Ctrl+Enter, "open to the side" (owner, 2026-10-02): whatever a
/// row opens lands in a new group split off to the right of the one the
/// keyboard was in — VS Code's behaviour, through one request every open verb
/// honours rather than a flag on each of them.
void main() {
  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: fakeTerminalOverrides());
    addTearDown(container.dispose);
    return container;
  }

  TerminalSessionsController controllerOf(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider.notifier);

  TerminalSessionsState stateOf(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider);

  test('a new tab opens in a new group to the right of the focused one', () {
    final container = makeContainer();
    final controller = controllerOf(container);
    final first = controller.openTab(TerminalProfile.powerShell);
    final origin = stateOf(container).focusedGroupId!;

    late String opened;
    controller.openBeside(
      () => opened = controller.openTab(TerminalProfile.powerShell),
    );

    final state = stateOf(container);
    expect(state.workspace!.groups, hasLength(2));
    expect(controller.tabsInGroup(origin).map((tab) => tab.id), [first]);
    final beside = controller.groupOfTab(opened)!;
    expect(beside, isNot(origin));
    expect(state.focusedGroupId, beside);
    expect(state.activeTabId, opened);
    expect(
      state.workspace!.groups.last.id,
      beside,
      reason: 'beside is after: to the right',
    );
    expect(
      state.workspace!.rects()[opened]!.left,
      greaterThan(state.workspace!.rects()[first]!.left),
    );
  });

  test('what the focused group showed stays in front of it', () {
    final container = makeContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    final shown = controller.openTab(TerminalProfile.powerShell);
    final origin = stateOf(container).focusedGroupId!;

    controller.openBeside(() => controller.openTab(TerminalProfile.powerShell));

    expect(controller.activeTabInGroup(origin), shown);
  });

  test('the tab in front, among others, moves beside when asked for', () {
    final container = makeContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    final front = controller.openTab(TerminalProfile.powerShell);
    final origin = stateOf(container).focusedGroupId!;

    controller.openBeside(() => controller.activateTab(front));

    expect(controller.groupOfTab(front), isNot(origin));
    expect(stateOf(container).workspace!.groups, hasLength(2));
  });

  test('a tab alone in the focused group stays: its group would be empty', () {
    final container = makeContainer();
    final controller = controllerOf(container);
    final only = controller.openTab(TerminalProfile.powerShell);

    controller.openBeside(() => controller.activateTab(only));

    expect(stateOf(container).workspace!.groups, hasLength(1));
    expect(controller.besideRequested, isFalse);
  });

  test('a tab already in another group is revealed there, not moved', () {
    final container = makeContainer();
    final controller = controllerOf(container);
    final left = controller.openTab(TerminalProfile.powerShell);
    controller.splitWorkspace(SplitAxis.horizontal);
    final right = controller.openTab(TerminalProfile.powerShell);
    controller.openTab(TerminalProfile.powerShell);
    final rightGroup = controller.groupOfTab(right)!;
    controller.focusGroup(controller.groupOfTab(left)!);

    controller.openBeside(() => controller.activateTab(right));

    final state = stateOf(container);
    expect(state.workspace!.groups, hasLength(2));
    expect(controller.groupOfTab(right), rightGroup);
    expect(state.activeTabId, right);
  });

  test('with nothing open there is nothing to be beside', () {
    final container = makeContainer();
    final controller = controllerOf(container);

    late String opened;
    controller.openBeside(
      () => opened = controller.openTab(TerminalProfile.powerShell),
    );

    expect(stateOf(container).workspace!.groups, hasLength(1));
    expect(stateOf(container).activeTabId, opened);
  });

  test('an empty group the user split into is filled where it is', () {
    final container = makeContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    final empty = controller.splitWorkspace(SplitAxis.horizontal)!;

    late String opened;
    controller.openBeside(
      () => opened = controller.openTab(TerminalProfile.powerShell),
    );

    expect(stateOf(container).workspace!.groups, hasLength(2));
    expect(controller.groupOfTab(opened), empty);
  });

  test('one request moves one tab: the next open is an ordinary one', () {
    final container = makeContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    late String beside;
    controller.openBeside(
      () => beside = controller.openTab(TerminalProfile.powerShell),
    );

    final next = controller.openTab(TerminalProfile.powerShell);

    expect(stateOf(container).workspace!.groups, hasLength(2));
    expect(controller.groupOfTab(next), controller.groupOfTab(beside));
    expect(controller.besideRequested, isFalse);
  });

  test('an open that finds nothing leaves no request behind', () {
    final container = makeContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    final origin = stateOf(container).focusedGroupId!;

    controller.openBeside(() {});
    final later = controller.openTab(TerminalProfile.powerShell);

    expect(controller.besideRequested, isFalse);
    expect(controller.groupOfTab(later), origin);
  });

  test(
    'an open that is still resuming keeps its request until it lands',
    () async {
      final container = makeContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      final origin = stateOf(container).focusedGroupId!;

      late String opened;
      controller.openBeside(() async {
        await Future<void>.delayed(Duration.zero);
        opened = controller.openTab(TerminalProfile.powerShell);
      });
      expect(controller.besideRequested, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 1));

      expect(controller.groupOfTab(opened), isNot(origin));
      expect(controller.besideRequested, isFalse);
    },
  );
}
