import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import 'fake_instance.dart';

/// **Closing a tab hands the keyboard back to where you were.**
///
/// It used to go to whichever surviving tab sat first in the group, so closing
/// the one you had just opened threw you to the far end of the strip. The tab
/// before it is the one you were working in, and it is the one you get.
void main() {
  ({ProviderContainer container, TerminalSessionsController controller})
  open() {
    final container = fakeTerminalContainer();
    addTearDown(container.dispose);
    return (
      container: container,
      controller: container.read(terminalSessionsControllerProvider.notifier),
    );
  }

  String? activeOf(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider).activeTabId;

  test('closing the active tab returns to the one before it', () {
    final app = open();
    final first = app.controller.openTab(TerminalProfile.powerShell);
    final second = app.controller.openTab(TerminalProfile.powerShell);
    final third = app.controller.openTab(TerminalProfile.powerShell);

    // Where the user actually was: second, then third.
    app.controller.activateTab(second);
    app.controller.activateTab(third);
    expect(activeOf(app.container), third);

    app.controller.closeTab(third);

    expect(
      activeOf(app.container),
      second,
      reason: 'the first tab is where this used to land',
    );
    expect(activeOf(app.container), isNot(first));
  });

  test('and keeps going back as tabs are closed', () {
    final app = open();
    final first = app.controller.openTab(TerminalProfile.powerShell);
    final second = app.controller.openTab(TerminalProfile.powerShell);
    final third = app.controller.openTab(TerminalProfile.powerShell);

    app.controller.activateTab(first);
    app.controller.activateTab(second);
    app.controller.activateTab(third);

    app.controller.closeTab(third);
    expect(activeOf(app.container), second);
    app.controller.closeTab(second);
    expect(activeOf(app.container), first);
  });

  test('a tab closed while another is on screen moves nothing', () {
    final app = open();
    final first = app.controller.openTab(TerminalProfile.powerShell);
    final second = app.controller.openTab(TerminalProfile.powerShell);
    app.controller.activateTab(second);

    app.controller.closeTab(first);

    expect(activeOf(app.container), second);
  });

  test('closing the last tab leaves nothing active, not a stale id', () {
    final app = open();
    final only = app.controller.openTab(TerminalProfile.powerShell);

    app.controller.closeTab(only);

    expect(activeOf(app.container), isNull);
  });
}
