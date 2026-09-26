/// Attention-inbox news → the server's companion, which pushes it: new items
/// are told, listed items do not repeat, imported and delivery kinds stay on
/// the desktop. (The sealed push itself is the companion server's, tested in
/// `packages/karmashala_companion_server/test/link/`.)
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/application/host_companion_link.dart';
import 'package:karmashala/src/features/remote/application/host_companion_providers.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';

import '../../support/fake_data_server.dart';
import '../../support/fake_host_lifecycle.dart';
import '../../support/memory_server_config.dart';
import 'fake_bindings.dart';

InboxItem _item(
  String openId, {
  InboxItemKind kind = InboxItemKind.finished,
  bool imported = false,
  String label = 'Fix the tests',
}) => InboxItem(
  session: WatchedSession(
    key: AgentSessionKey('claude-code', 'ext-$openId'),
    label: label,
    openId: openId,
    imported: imported,
  ),
  kind: kind,
  at: DateTime.utc(2026, 8, 31, 12),
);

AttentionInbox _inbox(List<InboxItem> items) => AttentionInbox(items: items);

void main() {
  late FakeHostLifecycle host;
  late HostCompanionLink link;
  late RemoteAccessController controller;

  List<CompanionNoticeMessage> attention() => [
    for (final notice in host.companionNotices)
      if (notice.kind == CompanionNoticeKind.attention) notice,
  ];

  setUp(() async {
    host = FakeHostLifecycle();
    final fake = FakeRemoteBindings()..addSession('s1');
    link = HostCompanionLink(
      bindings: () => fake.bindings,
      deviceById: (_) async => null,
    );
    final container = ProviderContainer(
      overrides: [
        await FakeDataServer().override(),
        serverConfigIn(MemoryServerConfigSource()),
        companionAtHostProvider.overrideWithValue(true),
        hostCompanionLinkProvider.overrideWithValue(link),
        remoteAccessControllerProvider.overrideWith(RemoteAccessController.new),
      ],
    );
    addTearDown(container.dispose);
    controller = container.read(remoteAccessControllerProvider);
    link.attached((await host.open())!);
  });

  test('a new finished item is told to the server once', () {
    controller.onInboxChanged(AttentionInbox.empty, _inbox([_item('s1')]));

    final told = attention().single;
    expect(told.sessionId, 's1');
    expect(told.title, 'Fix the tests');
    expect(told.attention, 'finished');
  });

  test('only the newly arrived item is told', () {
    final already = _item('s1');
    controller.onInboxChanged(
      _inbox([already]),
      _inbox([_item('s2', kind: InboxItemKind.failed), already]),
    );

    expect(
      [for (final n in attention()) (n.sessionId, n.attention)],
      [('s2', 'failed')],
    );
  });

  test('needs-approval news carries the wire word needs_approval', () {
    controller.onInboxChanged(
      AttentionInbox.empty,
      _inbox([_item('s1', kind: InboxItemKind.needsApproval)]),
    );

    expect(attention().single.attention, 'needs_approval');
  });

  test('imported sessions and delivery kinds stay on the desktop', () {
    controller.onInboxChanged(
      AttentionInbox.empty,
      _inbox([
        _item('s1', imported: true),
        _item('s2', kind: InboxItemKind.checksFailed),
        _item('s3', kind: InboxItemKind.readyToMerge),
        _item('s4', kind: InboxItemKind.changesRequested),
      ]),
    );

    expect(attention(), isEmpty);
  });

  test('with no link to the server, inbox news drops quietly', () {
    link.detached();
    controller.onInboxChanged(AttentionInbox.empty, _inbox([_item('s1')]));

    expect(attention(), isEmpty);
  });
}
