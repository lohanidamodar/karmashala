import 'package:chitragupta/src/features/terminal/application/terminal_search_controller.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_layout.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

void main() {
  late ProviderContainer container;
  late TerminalSessionsController sessions;
  late String paneId;

  setUp(() {
    container = fakeTerminalContainer();
    addTearDown(container.dispose);
    sessions = container.read(terminalSessionsControllerProvider.notifier);
    sessions.openTab(TerminalProfile.powerShell);
    paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    sessions.instanceFor(paneId)!.terminal.write('alpha\r\nbeta\r\nalpha\r\n');
  });

  TerminalSearchController search() =>
      container.read(terminalSearchControllerProvider.notifier);

  TerminalSearchState state() =>
      container.read(terminalSearchControllerProvider);

  int highlightCount() =>
      sessions.instanceFor(paneId)!.controller.highlights.length;

  test('open then query reports the match count and selects the first', () {
    search()
      ..open(paneId)
      ..setQuery('alpha');

    expect(state().visible, isTrue);
    expect(state().paneId, paneId);
    expect(state().matchCount, 2);
    expect(state().currentIndex, 0);
    expect(highlightCount(), 2);
  });

  test('next and previous wrap around', () {
    search()
      ..open(paneId)
      ..setQuery('alpha')
      ..next();
    expect(state().currentIndex, 1);

    search().next();
    expect(state().currentIndex, 0, reason: 'wraps past the last match');

    search().previous();
    expect(state().currentIndex, 1, reason: 'wraps back past the first');
  });

  test('case sensitivity narrows the results', () {
    sessions.instanceFor(paneId)!.terminal.write('ALPHA\r\n');
    search()
      ..open(paneId)
      ..setQuery('ALPHA');
    expect(state().matchCount, 3);

    search().toggleCaseSensitive();
    expect(state().caseSensitive, isTrue);
    expect(state().matchCount, 1);
  });

  test('an empty query clears matches and highlights', () {
    search()
      ..open(paneId)
      ..setQuery('alpha')
      ..setQuery('');

    expect(state().matchCount, 0);
    expect(highlightCount(), 0);
  });

  test('a query with no hits reports zero without throwing', () {
    search()
      ..open(paneId)
      ..setQuery('nothing here');
    expect(state().matchCount, 0);
    expect(state().currentIndex, 0);
    expect(highlightCount(), 0);
    search()
      ..next()
      ..previous();
    expect(state().matchCount, 0);
  });

  test('highlights are capped and the cap is reported', () {
    final terminal = sessions.instanceFor(paneId)!.terminal;
    for (var i = 0; i < 600; i++) {
      terminal.write('needle\r\n');
    }

    search()
      ..open(paneId)
      ..setQuery('needle');

    expect(state().matchCount, greaterThan(500));
    expect(state().truncated, isTrue);
    expect(highlightCount(), lessThanOrEqualTo(500));
  });

  test('close drops every highlight', () {
    search()
      ..open(paneId)
      ..setQuery('alpha')
      ..close();

    expect(state().visible, isFalse);
    expect(highlightCount(), 0);
  });

  test('switching the searched pane clears the previous pane highlights', () {
    search()
      ..open(paneId)
      ..setQuery('alpha');
    expect(highlightCount(), 2);

    final second = sessions.splitPane(
      SplitAxis.horizontal,
      TerminalProfile.commandPrompt,
    )!;
    search().open(second);

    expect(highlightCount(), 0, reason: 'the first pane is no longer searched');
    expect(state().paneId, second);
    expect(state().query, isEmpty);
  });

  test('searching a pane that has gone away is a no-op', () {
    search()
      ..open('a-pane-that-never-existed')
      ..setQuery('alpha');
    expect(state().matchCount, 0);
  });
}
