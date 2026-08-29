import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_instance.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

/// A process-free [TerminalInstance] so the controller can be tested without
/// spawning a real PTY.
class FakeTerminalInstance implements TerminalInstance {
  FakeTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    this.workingDirectory,
    this.restored,
  }) {
    terminal = Terminal(maxLines: 1000)..resize(40, 10);
    if (restored != null && restored!.isNotEmpty) terminal.write(restored!);
  }

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;
  @override
  final String? workingDirectory;

  /// What the factory was handed to replay — asserted on by the restore tests.
  final String? restored;

  @override
  late final Terminal terminal;
  @override
  final TerminalController controller = TerminalController();
  @override
  final FocusNode focusNode = FocusNode();
  @override
  final ScrollController scrollController = ScrollController();

  bool disposed = false;

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    focusNode.dispose();
    scrollController.dispose();
  }
}

/// A container whose terminals are fakes, optionally over a real in-memory
/// database so persistence can be exercised.
ProviderContainer fakeTerminalContainer({AppDatabase? database}) {
  return ProviderContainer(
    overrides: [
      if (database != null) databaseProvider.overrideWithValue(database),
      terminalInstanceFactoryProvider.overrideWithValue(
        ({
          required id,
          required profile,
          workingDirectory,
          restoredScrollback,
        }) => FakeTerminalInstance(
          id: id,
          title: profile.label,
          profileId: profile.id,
          workingDirectory: workingDirectory,
          restored: restoredScrollback,
        ),
      ),
    ],
  );
}
