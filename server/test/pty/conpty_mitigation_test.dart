import 'dart:ffi';

import 'package:karmashala_host/src/pty/win32.dart';
import 'package:test/test.dart';

/// What a ConPTY child is started with beyond its command line: its
/// pseudoconsole attribute and the suspended start that puts it in its job
/// first. The arithmetic only — what Windows does with it is in the
/// slice 5a verification list.
void main() {
  test('the pseudoconsole attribute is ProcThreadAttributeValue(22, 0, 1, 0), '
      'and it is the only one a pane carries', () {
    expect(kProcThreadAttributePseudoConsole, 0x00020016);
    expect(kPaneAttributeCount, 1);
  });

  test('the child starts suspended and in its job', () {
    expect(kCreateSuspended, 0x4);
    expect(kJobObjectLimitKillOnJobClose, 0x2000);
    expect(kJobObjectExtendedLimitInformation, 9);
  });

  test('STARTUPINFOEXW is the x64 size CreateProcess checks in cb', () {
    // 104 bytes of STARTUPINFOW and the attribute list pointer.
    expect(sizeOf<StartupInfoExW>(), 112);
  });
}
