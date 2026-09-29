import 'dart:async';

import 'package:karmashala_host_protocol/host_access.dart';

/// **This client's one link to a server** (slice 5e): every pane, the data
/// API and the lifecycle feed ride it, each pane under its own ref. Kept per
/// [HostSessionAccess]; a link that ends is replaced on the next ask, and
/// two asks at once share one dial.
class SharedHostLinks {
  SharedHostLinks._();

  /// What this client calls itself to the server — its presence name, and
  /// the write token's holder. The app sets it to this machine's name.
  static String clientName = 'karmashala';

  static final _byAccess = Expando<_Shared>('shared host link');

  /// The live link to [access]'s server, dialling it when there is none —
  /// dialling only: nothing is started. Throws [HostLinkException] (or the
  /// channel's own error) when the server will not answer.
  static Future<HostClientLink> linkTo(
    HostSessionAccess access, {
    HostDeployment? deployment,
    Duration bound = const Duration(seconds: 20),
  }) => (_byAccess[access] ??= _Shared()).link(access, deployment, bound);

  /// The link [access] holds now, if it is up; dials nothing.
  static HostClientLink? current(HostSessionAccess access) {
    final link = _byAccess[access]?._link;
    return link == null || link.isClosed ? null : link;
  }

  /// Each new link to [access]'s server, once it has said hello.
  static Stream<HostClientLink> opened(HostSessionAccess access) =>
      (_byAccess[access] ??= _Shared())._opened.stream;

  /// Hangs up [access]'s link, if any, and abandons a dial in progress:
  /// what it later opens is closed, never kept. Panes on it redial.
  static Future<void> drop(HostSessionAccess access) async {
    final shared = _byAccess[access];
    if (shared == null) return;
    final link = shared._link;
    shared._link = null;
    final channel = shared._abandonDial();
    await channel?.close();
    await link?.close();
  }
}

class _Shared {
  HostClientLink? _link;
  Future<HostClientLink>? _dialling;
  final _opened = StreamController<HostClientLink>.broadcast();

  /// Bumped by a drop; a dial that started under another is abandoned.
  var _generation = 0;

  /// The dial's channel until its hello is answered, so a drop can end it.
  RemoteChannel? _channel;

  Future<HostClientLink> link(
    HostSessionAccess access,
    HostDeployment? deployment,
    Duration bound,
  ) {
    final live = _link;
    if (live != null && !live.isClosed) return Future.value(live);
    final dialling = _dialling;
    if (dialling != null) return dialling;
    late final Future<HostClientLink> dial;
    dial = _dial(access, deployment, bound).whenComplete(() {
      if (identical(_dialling, dial)) _dialling = null;
    });
    return _dialling = dial;
  }

  RemoteChannel? _abandonDial() {
    _generation++;
    _dialling = null;
    final channel = _channel;
    _channel = null;
    return channel;
  }

  Future<HostClientLink> _dial(
    HostSessionAccess access,
    HostDeployment? deployment,
    Duration bound,
  ) async {
    final generation = _generation;
    const dropped = HostLinkException('The link was dropped while dialling.');
    // Never measured here: a reading can start a server, and that is the
    // supervisor's alone. Only an SSH host's path matters to the command.
    final channel = await access.exec(
      deployment == null ? 'attach' : '${deployment.remotePath} attach',
    );
    if (generation != _generation) {
      await channel.close();
      throw dropped;
    }
    _channel = channel;
    final HostClientLink link;
    try {
      link = await HostClientLink.open(
        channel,
        clientId: SharedHostLinks.clientName,
        bound: bound,
      );
    } finally {
      if (identical(_channel, channel)) _channel = null;
    }
    if (generation != _generation) {
      await link.close();
      throw dropped;
    }
    _link = link;
    _opened.add(link);
    return link;
  }
}
