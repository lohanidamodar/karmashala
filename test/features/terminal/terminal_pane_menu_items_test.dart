import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';

/// Which entries a pane's right-click menu offers, for which pane.
void main() {
  List<String> values(List<PopupMenuEntry<String>> items) => [
    for (final item in items)
      if (item is PopupMenuItem<String>) item.value! else '—',
  ];

  List<PopupMenuEntry<String>> menu({
    bool hasSelection = false,
    bool capturable = false,
    bool notesEnabled = true,
    bool recording = false,
    bool canWriteMp4 = true,
    bool inSplit = false,
  }) => terminalPaneMenuItems(
    hasSelection: hasSelection,
    capturable: capturable,
    notesEnabled: notesEnabled,
    recording: recording,
    canWriteMp4: canWriteMp4,
    inSplit: inSplit,
  );

  test('a lone pane with nothing selected', () {
    final items = menu();
    expect(values(items), [
      'copy',
      'paste',
      'find',
      '—',
      'record',
      '—',
      'split-pane-right',
      'split-pane-down',
      '—',
      'end',
    ]);
    // Copy stays, disabled: it says what a selection would allow.
    expect((items.first as PopupMenuItem<String>).enabled, isFalse);
  });

  test('a selection that caught text offers the captures', () {
    expect(
      values(menu(hasSelection: true, capturable: true)),
      containsAllInOrder(['copy', '—', 'todo', 'note', '—', 'record']),
    );
    expect(
      (menu(hasSelection: true).first as PopupMenuItem<String>).enabled,
      isTrue,
    );
  });

  test('with Notes off, the note capture is absent rather than disabled', () {
    final entries = values(menu(capturable: true, notesEnabled: false));
    expect(entries, contains('todo'));
    expect(entries, isNot(contains('note')));
  });

  test('only a pane in a split can be moved out or closed from here', () {
    expect(values(menu()), isNot(contains('close')));
    expect(
      values(menu(inSplit: true)),
      containsAllInOrder(['split-pane-down', '—', 'untangle', 'close', '—']),
    );
  });
}
