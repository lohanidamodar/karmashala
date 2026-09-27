import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../data/data_streams.dart';
import 'attached_apps.dart';

/// `kFlutterLogsStream`: one attached app's console, by app id — what the
/// link holds, then each line as it arrives. A re-attach replaces the link,
/// ending this stream; the client opens it again on the next
/// `FlutterAppsChanged`.
class FlutterLogsSource implements DataStreamSource {
  const FlutterLogsSource(this._apps);

  final ServerAttachedApps _apps;

  @override
  DataStreamFeed open(String key) {
    final link = _apps.linkFor(key);
    if (link == null) {
      throw DataRefused.notFound(
        _apps.registry.byId(key) == null
            ? 'no Flutter app "$key" is known to this server'
            : 'the server is not attached to "$key", so there is no console '
                  'to follow',
      );
    }
    return DataStreamFeed([
      for (final record in link.console) record.toJson(),
    ], link.logs.map((record) => record.toJson()));
  }
}
