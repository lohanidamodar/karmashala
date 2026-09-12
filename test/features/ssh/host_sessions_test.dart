import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/ssh/application/host_sessions.dart';

/// **Which host sessions a pane can be reattached to, and which cannot.**
///
/// A shell session is named after the pane that opened it, so the pane id can
/// be read back out and a new pane opened under it. An agent's session carries
/// the *agent's* id instead: it belongs to a Karmashala session and is reopened
/// from there, so offering "attach" for one would promise something this
/// dialog cannot do.
void main() {
  const hostId = '87a43888-5b53-4b69-b339-2b7fe003d57f';

  test('a shell session names the pane that opened it', () {
    expect(
      paneIdOfHostSession(
        'karmashala_${hostId}_6729f7b9-2baa-47da-afb6-cc51e038de17',
        hostId,
      ),
      '6729f7b9-2baa-47da-afb6-cc51e038de17',
    );
  });

  test('an agent session belongs to no pane', () {
    expect(
      paneIdOfHostSession(
        'karmashala_bad13a5a-8fb2-4434-8bbb-2bcd4adb74d3',
        hostId,
      ),
      isNull,
    );
  });

  test('another host\'s session is not ours to reattach', () {
    expect(
      paneIdOfHostSession('karmashala_someone-else_pane-1', hostId),
      isNull,
    );
  });

  test('a name with nothing after the host is not a pane id', () {
    expect(paneIdOfHostSession('karmashala_${hostId}_', hostId), isNull);
  });

  test('anything that is not one of ours is left alone', () {
    expect(paneIdOfHostSession('tmux-0', hostId), isNull);
    expect(paneIdOfHostSession('', hostId), isNull);
  });
}
