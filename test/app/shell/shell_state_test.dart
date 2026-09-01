import 'package:karmashala/src/app/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  group('ShellController', () {
    test('defaults to the explorer pane with the explorer visible', () {
      final state = container.read(shellControllerProvider);
      expect(state.focusedPane, ShellPane.explorer);
      expect(state.explorerPaneVisible, isTrue);
    });

    test('focusPane updates the focused pane', () {
      container
          .read(shellControllerProvider.notifier)
          .focusPane(ShellPane.detail);
      expect(
        container.read(shellControllerProvider).focusedPane,
        ShellPane.detail,
      );
    });

    test('toggleExplorerPane flips visibility', () {
      final controller = container.read(shellControllerProvider.notifier);
      controller.toggleExplorerPane();
      expect(
        container.read(shellControllerProvider).explorerPaneVisible,
        isFalse,
      );
      controller.toggleExplorerPane();
      expect(
        container.read(shellControllerProvider).explorerPaneVisible,
        isTrue,
      );
    });
  });
}
