/// Driving a real Chrome over the DevTools protocol: finding or launching one,
/// attaching to a page, and reading, clicking and typing in it.
///
/// The domain half is the vocabulary — targets, failures and their remedies,
/// key names, element captures, the consent record and the untrusted-content
/// fence. The data half is the machinery: Chrome discovery, the HTTP endpoint,
/// the CDP socket and page, the element picker, page input and the observer.
///
/// Pure Dart. The one thing it does not own is the process: [BrowserLauncher]
/// takes a [BrowserProcessStarter] so the app's own runner spawns the browser
/// without this package reaching back for it.
library;

export 'src/data/browser_launcher.dart';
export 'src/data/browser_process.dart';
export 'src/data/browser_service.dart';
export 'src/data/cdp_connection.dart';
export 'src/data/cdp_page.dart';
export 'src/data/cdp_payloads.dart';
export 'src/data/cdp_protocol.dart';
export 'src/data/cdp_socket.dart';
export 'src/data/chrome_discovery.dart';
export 'src/data/devtools_http_endpoint.dart';
export 'src/data/element_picker.dart';
export 'src/data/input_script.dart';
export 'src/data/page_input.dart';
export 'src/data/page_observer.dart';
export 'src/data/picker_script.dart';
export 'src/data/selector_js.dart';
export 'src/domain/browser_action.dart';
export 'src/domain/browser_consent.dart';
export 'src/domain/browser_failure.dart';
export 'src/domain/browser_key.dart';
export 'src/domain/browser_recovery.dart';
export 'src/domain/browser_target.dart';
export 'src/domain/cdp_message.dart';
export 'src/domain/element_capture.dart';
export 'src/domain/found_element.dart';
export 'src/domain/page_diagnostics.dart';
export 'src/domain/picked_element.dart';
export 'src/domain/untrusted_content.dart';
