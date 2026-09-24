import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/dropped_paths.dart';

void main() {
  test('a plain local path goes in as it is, with a trailing space', () {
    expect(
      droppedPathsText(
        ['/Users/me/shot.png'],
        reach: PaneReach.local,
        windowsHost: false,
      ),
      '/Users/me/shot.png ',
    );
  });

  test('a POSIX path with a space or a quote is single-quoted', () {
    expect(
      droppedPathsText(
        ["/tmp/a b/it's.png", '/tmp/c.txt'],
        reach: PaneReach.local,
        windowsHost: false,
      ),
      r"'/tmp/a b/it'\''s.png' /tmp/c.txt ",
    );
  });

  test('a Windows path with a space is double-quoted', () {
    expect(
      droppedPathsText(
        [r'C:\My Files\a.png'],
        reach: PaneReach.local,
        windowsHost: true,
      ),
      r'"C:\My Files\a.png" ',
    );
  });

  test('a WSL pane gets the drive as its mount', () {
    expect(
      droppedPathsText(
        [r'C:\src\My App\a.png'],
        reach: PaneReach.wsl,
        windowsHost: true,
      ),
      "'/mnt/c/src/My App/a.png' ",
    );
  });

  test('a WSL pane refuses a path it has no mount for', () {
    expect(
      droppedPathsText(
        [r'\\server\share\a.png'],
        reach: PaneReach.wsl,
        windowsHost: true,
      ),
      isNull,
    );
  });

  test('an SSH pane refuses: the file is not on that machine', () {
    expect(
      droppedPathsText(['/tmp/a'], reach: PaneReach.ssh, windowsHost: false),
      isNull,
    );
  });
}
