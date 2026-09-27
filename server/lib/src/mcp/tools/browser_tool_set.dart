import 'package:karmashala_browser/tools.dart';

import '../../browser/server_browser.dart';
import 'server_tool_set.dart';

/// `browser_*`: the server's browser (slice 3d), driven by the package's
/// [BrowserTools] under the calling session's project consent. Every client's
/// pane follows what an agent does to it. Never handed to the app.
class BrowserToolSet extends ServerToolSet {
  const BrowserToolSet(this.browser);

  final ServerBrowser browser;

  @override
  List<Map<String, Object?>> get schemas => browserToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(() async {
    if (tool == 'browser_pick' && browser.headless) {
      throw StateError(ServerBrowser.headlessPickRefusal);
    }
    try {
      return await BrowserTools(
        browser.service,
        consent: browser.consent.consentFor(callerSessionId),
      ).call(tool, arguments);
    } finally {
      await browser.afterUse();
    }
  });
}
