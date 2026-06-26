import 'package:chitragupta/src/app/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  group('ShellController', () {
    test('defaults to the sessions pane with projects visible', () {
      final state = container.read(shellControllerProvider);
      expect(state.focusedPane, ShellPane.sessions);
      expect(state.projectsPaneVisible, isTrue);
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

    test('toggleProjectsPane flips visibility', () {
      final controller = container.read(shellControllerProvider.notifier);
      controller.toggleProjectsPane();
      expect(
        container.read(shellControllerProvider).projectsPaneVisible,
        isFalse,
      );
      controller.toggleProjectsPane();
      expect(
        container.read(shellControllerProvider).projectsPaneVisible,
        isTrue,
      );
    });
  });
}
