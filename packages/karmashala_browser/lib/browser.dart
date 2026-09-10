/// Driving a real Chrome over the DevTools protocol: finding or launching one,
/// attaching to a page, and reading, clicking and typing in it. Pure Dart — the
/// one thing it does not own is the process, which [BrowserLauncher] is handed.
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
export 'src/domain/project_scoped_browser_consent.dart';
export 'src/domain/untrusted_content.dart';
