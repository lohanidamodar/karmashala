import 'dart:ffi';

import 'package:karmashala_host/src/pty/win32.dart';
import 'package:test/test.dart';

/// What a ConPTY child is started with beyond its command line: the
/// redirection-trust policy (BACKLOG §2) and the suspended start that puts it
/// in its job first. The arithmetic only — what Windows does with it is in the
/// slice 5a verification list.
void main() {
  test('the mitigation attribute is ProcThreadAttributeValue(7, 0, 1, 0)', () {
    expect(kProcThreadAttributeMitigationPolicy, 0x00020007);
    expect(kProcThreadAttributePseudoConsole, 0x00020016);
  });

  test('the policy is two DWORD64s with only redirection trust set', () {
    final words = redirectionTrustOffPolicy();
    expect(words, hasLength(2));
    expect(words[kRedirectionTrustPolicyWord], kRedirectionTrustAlwaysOff);
    for (var i = 0; i < words.length; i++) {
      if (i != kRedirectionTrustPolicyWord) expect(words[i], 0);
    }
    // ALWAYS_OFF is the policy's value 2 in its own nibble, never ALWAYS_ON.
    expect(kRedirectionTrustAlwaysOff >>> 60, 0x2);
    expect(sizeOf<Uint64>() * words.length, 16);
  });

  test('the attribute list has room for the policy only when it is asked', () {
    expect(paneAttributeCount(mitigation: true), 2);
    expect(paneAttributeCount(mitigation: false), 1);
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
