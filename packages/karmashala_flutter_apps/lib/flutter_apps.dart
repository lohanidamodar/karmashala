/// Everything about a Flutter app that is not the app: where its project is,
/// which SDK would build it, where the running VM service is, and what can be
/// asked of it once attached.
///
/// * **domain** — the value types and the pure rules: a project and its
///   platforms, an SDK reading and its refusals, a VM service URI and the four
///   routes to one (an out-file, an adb-logcat announcement, an mDNS record, a
///   DTD registration), a log record, an error summary, a widget selection.
/// * **data** — the readers and links that produce them: the project scanner,
///   the SDK probe, the out-file directory watcher, the DTD channel and its pid
///   files, and `FlutterAppLink` over `package:vm_service`.
///
/// Nothing here holds a database, a provider or a widget: a scan takes a
/// `CommandRunner`, a link takes a socket, and the app composes them.
library;

export 'src/domain/app_log_record.dart';
export 'src/domain/attached_app.dart';
export 'src/domain/dtd_instance.dart';
export 'src/domain/flutter_app_failure.dart';
export 'src/domain/flutter_app_registry.dart';
export 'src/domain/flutter_command_run.dart';
export 'src/domain/flutter_error_summary.dart';
export 'src/domain/flutter_preflight.dart';
export 'src/domain/flutter_project.dart';
export 'src/domain/flutter_sdk.dart';
export 'src/domain/vm_service_announcement.dart';
export 'src/domain/vm_service_log_line.dart';
export 'src/domain/vm_service_mdns.dart';
export 'src/domain/vm_service_out_file.dart';
export 'src/domain/vm_service_uri.dart';
export 'src/domain/widget_selection.dart';

export 'src/data/dtd_link.dart';
export 'src/data/dtd_pid_files.dart';
export 'src/data/flutter_app_link.dart';
export 'src/data/flutter_project_scanner.dart';
export 'src/data/flutter_sdk_service.dart';
export 'src/data/vm_service_connector.dart';
export 'src/data/vm_service_uri_directory.dart';
