/// Opening a session is idempotent, and says so.
///
/// A reply lost between the app and the host used to cost a second agent in
/// the same worktree: the pane failed, and the retry opened another. The host's
/// record of the session id is the receipt, so a lost or refused open is
/// checked against it and the session that is there is adopted.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';

import 'fake_host_access.dart';

void main() {
  const id = 'karmashala_local_p1';

  Future<HostPaneLink> linkOn(ScriptedHostChannel channel) => HostPaneLink.open(
    channel,
    clientId: 'pane-p1',
    attachBound: const Duration(milliseconds: 100),
  );

  Future<HostAttachment> open(HostPaneLink link) => link.openSession(
    sessionId: id,
    argv: const ['/bin/sh'],
    columns: 80,
    rows: 24,
  );

  test('an open whose reply was lost adopts the session it started', () async {
    final channel = ScriptedHostChannel(<String>{})..loseOpenReply = true;
    final link = await linkOn(channel);
    var adopted = false;

    final attachment = await link.openOrAdopt(
      id,
      () => open(link),
      adopted: () => adopted = true,
    );

    expect(attachment.sessionId, id);
    expect(adopted, isTrue);
    expect(channel.all<OpenMessage>(), hasLength(1), reason: 'opened twice');
    expect(channel.all<AttachMessage>(), hasLength(1));
  });

  test('a session the host already holds is adopted, not refused', () async {
    final channel = ScriptedHostChannel({id});
    final link = await linkOn(channel);
    var adopted = false;

    final attachment = await link.openOrAdopt(
      id,
      () => open(link),
      adopted: () => adopted = true,
    );

    expect(attachment.sessionId, id);
    expect(adopted, isTrue);
  });

  test('an open that really failed is reported as it failed', () async {
    // Nothing answers, and the check finds no session: the open never happened.
    final channel = _SilentOpenChannel();
    final link = await linkOn(channel);

    await expectLater(
      link.openOrAdopt(id, () => open(link)),
      throwsA(
        isA<HostLinkException>().having((e) => e.timedOut, 'timedOut', isTrue),
      ),
    );
  });

  test('an ordinary open is not checked at all', () async {
    final channel = ScriptedHostChannel(<String>{});
    final link = await linkOn(channel);
    var adopted = false;

    await link.openOrAdopt(id, () => open(link), adopted: () => adopted = true);

    expect(adopted, isFalse);
    expect(channel.all<AttachMessage>(), isEmpty);
  });
}

/// A host that drops the open on the floor, so there is nothing to adopt.
class _SilentOpenChannel extends ScriptedHostChannel {
  _SilentOpenChannel() : super(<String>{});

  @override
  void push(HostMessage message) {
    if (message is AttachedMessage) return;
    super.push(message);
  }

  @override
  void add(Uint8List bytes) {
    super.add(bytes);
    // Forget whatever the open recorded: it never reached a process.
    liveSessions.clear();
  }
}
