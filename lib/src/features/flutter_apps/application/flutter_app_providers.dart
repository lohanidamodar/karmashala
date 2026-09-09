import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/paths/app_support_directory.dart';
import '../data/dtd_link.dart';
import '../data/dtd_pid_files.dart';
import '../data/vm_service_connector.dart';
import '../data/vm_service_uri_directory.dart';

/// The folder name under application support. Named for what is in it.
const String kVmServiceDirectoryName = 'vmservice';

/// Where `flutter_run` points `--vmservice-out-file` for the runs **this app
/// starts**, created on first use.
///
/// Under application support rather than in the project, because the address
/// is not a fact about the code: it belongs to one run of it, and a project
/// checked out twice would otherwise have two runs writing the same file.
/// Nobody is asked to point a hand-typed run at it — see `AttachedApps`.
final flutterAppDiscoveryDirectoryProvider =
    FutureProvider<VmServiceUriDirectory>((ref) async {
      final support = await appSupportDirectory();
      final directory = VmServiceUriDirectory(
        Directory(p.join(support.path, kVmServiceDirectoryName)),
      );
      await directory.ensureExists();
      return directory;
    });

/// Where the Dart Tooling Daemons on this machine record themselves.
final dtdPidFilesProvider = Provider<DtdPidFiles>(
  (ref) => DtdPidFiles.forEnvironment(
    Platform.environment,
    isWindows: Platform.isWindows,
  ),
);

/// How a channel to a tooling daemon is opened. Overridden in tests.
final dtdChannelOpenerProvider = Provider<DtdChannelOpener>(
  (ref) => openDtdOverWebSocket,
);

/// How a VM service connection is opened. Overridden in tests with a connector
/// that answers JSON-RPC in Dart.
final vmServiceConnectorProvider = Provider<VmServiceConnector>(
  (ref) => connectVmServiceOverWebSocket,
);
