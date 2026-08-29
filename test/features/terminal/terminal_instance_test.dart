import 'package:chitragupta/src/features/terminal/data/terminal_instance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an error instance carries its identity and disposes cleanly', () {
    final instance = ErrorTerminalInstance(
      id: 'p1',
      title: 'PowerShell',
      profileId: 'powershell',
      workingDirectory: r'C:\ws',
      message: 'boom',
    );
    expect(instance.profileId, 'powershell');
    expect(instance.workingDirectory, r'C:\ws');
    expect(instance.terminal.buffer.lines[0].getText(), contains('boom'));
    instance.dispose();
  });

  test('an instance owns a focus node and a scroll controller', () {
    final instance = ErrorTerminalInstance(
      id: 'p1',
      title: 'PowerShell',
      profileId: 'powershell',
      message: 'boom',
    );
    expect(instance.focusNode, isNotNull);
    expect(instance.scrollController, isNotNull);
    // Disposing twice must be safe — a pane can be closed while shutting down.
    instance
      ..dispose()
      ..dispose();
  });

  test('restored scrollback lands in the buffer before anything else', () {
    final instance = ErrorTerminalInstance(
      id: 'p1',
      title: 'PowerShell',
      profileId: 'powershell',
      message: 'later',
      restoredScrollback: 'earlier',
    );
    final text = [
      for (var i = 0; i < 5; i++)
        instance.terminal.buffer.lines[i].getText().trim(),
    ];
    expect(text.first, 'earlier');
    expect(text.join('\n'), contains('restored'));
    expect(text.join('\n'), contains('later'));
    expect(
      text.indexWhere((l) => l.contains('restored')),
      lessThan(text.indexWhere((l) => l.contains('later'))),
      reason: 'the marker separates replayed history from new output',
    );
    instance.dispose();
  });

  test('no marker is written when there is nothing to restore', () {
    final instance = ErrorTerminalInstance(
      id: 'p1',
      title: 'PowerShell',
      profileId: 'powershell',
      message: 'only this',
    );
    expect(instance.terminal.buffer.lines[0].getText(), contains('only this'));
    instance.dispose();
  });
}
