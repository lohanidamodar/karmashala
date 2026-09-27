// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// `COORD` — the size a pseudoconsole is created and resized with. Passed **by
/// value**, which is why it is a `Struct` rather than a pair of ints.
final class Coord extends Struct {
  @Int16()
  external int X;
  @Int16()
  external int Y;
}

/// `PROCESS_INFORMATION`. Only the handle and the pid are read; the thread
/// handle is closed immediately, as `CreateProcess` requires.
final class ProcessInformation extends Struct {
  @IntPtr()
  external int hProcess;
  @IntPtr()
  external int hThread;
  @Uint32()
  external int dwProcessId;
  @Uint32()
  external int dwThreadId;
}

/// `STARTUPINFOEXW`, laid out field by field so the ABI is the compiler's
/// problem: `lpAttributeList` at the wrong offset still returns TRUE.
final class StartupInfoExW extends Struct {
  @Uint32()
  external int cb;
  external Pointer<Utf16> lpReserved;
  external Pointer<Utf16> lpDesktop;
  external Pointer<Utf16> lpTitle;
  @Uint32()
  external int dwX;
  @Uint32()
  external int dwY;
  @Uint32()
  external int dwXSize;
  @Uint32()
  external int dwYSize;
  @Uint32()
  external int dwXCountChars;
  @Uint32()
  external int dwYCountChars;
  @Uint32()
  external int dwFillAttribute;
  @Uint32()
  external int dwFlags;
  @Uint16()
  external int wShowWindow;
  @Uint16()
  external int cbReserved2;
  external Pointer<Uint8> lpReserved2;
  @IntPtr()
  external int hStdInput;
  @IntPtr()
  external int hStdOutput;
  @IntPtr()
  external int hStdError;
  external Pointer<Void> lpAttributeList;
}

/// `PROCESSENTRY32W`, for the parent-pid walk. `szExeFile` is never read; it is
/// here so `dwSize` matches, which `Process32FirstW` rejects the call over.
final class ProcessEntry32W extends Struct {
  @Uint32()
  external int dwSize;
  @Uint32()
  external int cntUsage;
  @Uint32()
  external int th32ProcessID;
  @IntPtr()
  external int th32DefaultHeapID;
  @Uint32()
  external int th32ModuleID;
  @Uint32()
  external int cntThreads;
  @Uint32()
  external int th32ParentProcessID;
  @Int32()
  external int pcPriClassBase;
  @Uint32()
  external int dwFlags;
  @Array(260)
  external Array<Uint16> szExeFile;
}

/// `ProcThreadAttributeValue(22, FALSE, TRUE, FALSE)`, spelled as the macro's
/// arithmetic so it can be checked against the SDK header.
const int kProcThreadAttributePseudoConsole = 22 | 0x00020000;

/// `ProcThreadAttributeValue(7, FALSE, TRUE, FALSE)` —
/// `PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY` (0x00020007).
const int kProcThreadAttributeMitigationPolicy = 7 | 0x00020000;

/// The redirection-trust (Redirection Guard) creation flag, turned **off**
/// for a pane's child (BACKLOG §2): which of the policy's DWORD64 words it
/// sits in, and its bits there. **Not in the SDK**: 10.0.26100's winbase.h
/// defines POLICY2 fields only up to bit 56 (`FSCTL_SYSTEM_CALL_DISABLE`), and
/// Windows 11 26200 fails `CreateProcess` with error 87 for this value
/// (2026-09-27), so every child is started again without it.
const int kRedirectionTrustPolicyWord = 1;
const int kRedirectionTrustAlwaysOff = 0x2 << 60;

/// The words `UpdateProcThreadAttribute` is handed for the mitigation policy:
/// the redirection-trust bit in its word, every other policy left to Windows'
/// default (zero). Two DWORD64s, the size Windows 10 accepts.
List<int> redirectionTrustOffPolicy() {
  final words = List<int>.filled(2, 0);
  words[kRedirectionTrustPolicyWord] = kRedirectionTrustAlwaysOff;
  return words;
}

/// How many attributes a pane's list carries: the pseudoconsole, and the
/// mitigation policy when [mitigation] is asked for.
int paneAttributeCount({required bool mitigation}) => mitigation ? 2 : 1;

const int kExtendedStartupInfoPresent = 0x00080000;

/// Started suspended, so it is in the job before it can start a child of its
/// own; resumed once assigned.
const int kCreateSuspended = 0x00000004;
const int kCreateUnicodeEnvironment = 0x00000400;
const int kStartfUseStdHandles = 0x00000100;
const int kInfinite = 0xFFFFFFFF;
const int kWaitObject0 = 0x00000000;
const int kTh32csSnapProcess = 0x00000002;
const int kProcessTerminate = 0x0001;
const int kProcessQueryLimitedInformation = 0x1000;
const int kSynchronize = 0x00100000;
const int kErrorBrokenPipe = 109;

/// `JobObjectExtendedLimitInformation`, and the one limit that matters here:
/// when the last handle to the job closes, everything in it is killed.
const int kJobObjectExtendedLimitInformation = 9;
const int kJobObjectLimitKillOnJobClose = 0x00002000;

/// `sizeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)` on x64, and the byte offset of
/// `BasicLimitInformation.LimitFlags` inside it; every other field is zero.
const int kJobExtendedLimitBytes = 144;
const int kJobLimitFlagsOffset = 16;
const int kErrorInsufficientBuffer = 122;

/// `ERROR_INVALID_PARAMETER`: what a Windows that does not know a mitigation
/// bit answers `CreateProcess` or `UpdateProcThreadAttribute` with.
const int kErrorInvalidParameter = 87;

typedef CreatePseudoConsoleNative =
    Int32 Function(Coord, IntPtr, IntPtr, Uint32, Pointer<IntPtr>);
typedef CreatePseudoConsoleDart =
    int Function(Coord, int, int, int, Pointer<IntPtr>);

typedef ResizePseudoConsoleNative = Int32 Function(IntPtr, Coord);
typedef ResizePseudoConsoleDart = int Function(int, Coord);

/// kernel32 as this process sees it, plus the three ConPTY entry points. One
/// instance per isolate: a `DynamicLibrary` cannot travel over a `SendPort`.
class Kernel32 {
  Kernel32._(
    DynamicLibrary lib,
    this.createPseudoConsole,
    this.resizePseudoConsole,
    this.closePseudoConsole,
  ) : createPipe = lib
          .lookup<
            NativeFunction<
              Int32 Function(
                Pointer<IntPtr>,
                Pointer<IntPtr>,
                Pointer<Void>,
                Uint32,
              )
            >
          >('CreatePipe')
          .asFunction(),
      createProcessW = lib
          .lookup<
            NativeFunction<
              Int32 Function(
                Pointer<Utf16>,
                Pointer<Utf16>,
                Pointer<Void>,
                Pointer<Void>,
                Int32,
                Uint32,
                Pointer<Void>,
                Pointer<Utf16>,
                Pointer<StartupInfoExW>,
                Pointer<ProcessInformation>,
              )
            >
          >('CreateProcessW')
          .asFunction(),
      initializeProcThreadAttributeList = lib
          .lookup<
            NativeFunction<
              Int32 Function(Pointer<Void>, Uint32, Uint32, Pointer<IntPtr>)
            >
          >('InitializeProcThreadAttributeList')
          .asFunction(),
      updateProcThreadAttribute = lib
          .lookup<
            NativeFunction<
              Int32 Function(
                Pointer<Void>,
                Uint32,
                IntPtr,
                Pointer<Void>,
                IntPtr,
                Pointer<Void>,
                Pointer<IntPtr>,
              )
            >
          >('UpdateProcThreadAttribute')
          .asFunction(),
      deleteProcThreadAttributeList = lib
          .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
            'DeleteProcThreadAttributeList',
          )
          .asFunction(),
      readFile = lib
          .lookup<
            NativeFunction<
              Int32 Function(
                IntPtr,
                Pointer<Uint8>,
                Uint32,
                Pointer<Uint32>,
                Pointer<Void>,
              )
            >
          >('ReadFile')
          .asFunction(),
      writeFile = lib
          .lookup<
            NativeFunction<
              Int32 Function(
                IntPtr,
                Pointer<Uint8>,
                Uint32,
                Pointer<Uint32>,
                Pointer<Void>,
              )
            >
          >('WriteFile')
          .asFunction(),
      closeHandle = lib
          .lookup<NativeFunction<Int32 Function(IntPtr)>>('CloseHandle')
          .asFunction(),
      terminateProcess = lib
          .lookup<NativeFunction<Int32 Function(IntPtr, Uint32)>>(
            'TerminateProcess',
          )
          .asFunction(),
      waitForSingleObject = lib
          .lookup<NativeFunction<Uint32 Function(IntPtr, Uint32)>>(
            'WaitForSingleObject',
          )
          .asFunction(),
      getExitCodeProcess = lib
          .lookup<NativeFunction<Int32 Function(IntPtr, Pointer<Uint32>)>>(
            'GetExitCodeProcess',
          )
          .asFunction(),
      getLastError = lib
          .lookup<NativeFunction<Uint32 Function()>>('GetLastError')
          .asFunction(),
      openProcess = lib
          .lookup<NativeFunction<IntPtr Function(Uint32, Int32, Uint32)>>(
            'OpenProcess',
          )
          .asFunction(),
      createToolhelp32Snapshot = lib
          .lookup<NativeFunction<IntPtr Function(Uint32, Uint32)>>(
            'CreateToolhelp32Snapshot',
          )
          .asFunction(),
      process32FirstW = lib
          .lookup<
            NativeFunction<Int32 Function(IntPtr, Pointer<ProcessEntry32W>)>
          >('Process32FirstW')
          .asFunction(),
      process32NextW = lib
          .lookup<
            NativeFunction<Int32 Function(IntPtr, Pointer<ProcessEntry32W>)>
          >('Process32NextW')
          .asFunction(),
      createJobObjectW = lib
          .lookup<
            NativeFunction<IntPtr Function(Pointer<Void>, Pointer<Utf16>)>
          >('CreateJobObjectW')
          .asFunction(),
      setInformationJobObject = lib
          .lookup<
            NativeFunction<
              Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32)
            >
          >('SetInformationJobObject')
          .asFunction(),
      assignProcessToJobObject = lib
          .lookup<NativeFunction<Int32 Function(IntPtr, IntPtr)>>(
            'AssignProcessToJobObject',
          )
          .asFunction(),
      resumeThread = lib
          .lookup<NativeFunction<Uint32 Function(IntPtr)>>('ResumeThread')
          .asFunction();

  /// Null on a Windows older than 10 1809, so the host can refuse with a
  /// sentence rather than die at the first `open`.
  final CreatePseudoConsoleDart? createPseudoConsole;
  final ResizePseudoConsoleDart? resizePseudoConsole;
  final void Function(int)? closePseudoConsole;

  final int Function(Pointer<IntPtr>, Pointer<IntPtr>, Pointer<Void>, int)
  createPipe;
  final int Function(
    Pointer<Utf16>,
    Pointer<Utf16>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    int,
    Pointer<Void>,
    Pointer<Utf16>,
    Pointer<StartupInfoExW>,
    Pointer<ProcessInformation>,
  )
  createProcessW;
  final int Function(Pointer<Void>, int, int, Pointer<IntPtr>)
  initializeProcThreadAttributeList;
  final int Function(
    Pointer<Void>,
    int,
    int,
    Pointer<Void>,
    int,
    Pointer<Void>,
    Pointer<IntPtr>,
  )
  updateProcThreadAttribute;
  final void Function(Pointer<Void>) deleteProcThreadAttributeList;
  final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
  readFile;
  final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
  writeFile;
  final int Function(int) closeHandle;
  final int Function(int, int) terminateProcess;
  final int Function(int, int) waitForSingleObject;
  final int Function(int, Pointer<Uint32>) getExitCodeProcess;
  final int Function() getLastError;
  final int Function(int, int, int) openProcess;
  final int Function(int, int) createToolhelp32Snapshot;
  final int Function(int, Pointer<ProcessEntry32W>) process32FirstW;
  final int Function(int, Pointer<ProcessEntry32W>) process32NextW;
  final int Function(Pointer<Void>, Pointer<Utf16>) createJobObjectW;
  final int Function(int, int, Pointer<Void>, int) setInformationJobObject;
  final int Function(int, int) assignProcessToJobObject;
  final int Function(int) resumeThread;

  /// Whether this machine can host a pseudoconsole at all.
  bool get providesPseudoConsole => createPseudoConsole != null;

  /// Which library carried the ConPTY entry points — measured, not assumed.
  String get ptyLibrary =>
      providesPseudoConsole ? 'kernel32.dll' : 'kernel32.dll (no ConPTY)';

  static Kernel32 open() {
    final lib = DynamicLibrary.open('kernel32.dll');
    CreatePseudoConsoleDart? create;
    ResizePseudoConsoleDart? resize;
    void Function(int)? close;
    try {
      create = lib
          .lookup<NativeFunction<CreatePseudoConsoleNative>>(
            'CreatePseudoConsole',
          )
          .asFunction();
      resize = lib
          .lookup<NativeFunction<ResizePseudoConsoleNative>>(
            'ResizePseudoConsole',
          )
          .asFunction();
      close = lib
          .lookup<NativeFunction<Void Function(IntPtr)>>('ClosePseudoConsole')
          .asFunction();
    } on ArgumentError {
      // Windows 10 before 1809. Left null; the launcher refuses with a sentence.
    }
    return Kernel32._(lib, create, resize, close);
  }
}

/// Windows' quoting rules are the *callee's*, not a shell's: `CreateProcessW`
/// takes one string. Ported from `flutter_pty`'s `append_quoted_argument`.
///
/// Quoted only when it has to be. A C runtime reads `"-d"` and `-d` alike, but
/// `wsl.exe` and `cmd.exe` read their command line raw: quoting every argument
/// made `wsl.exe` take `"-d"` for the command to run (measured 2026-09-22,
/// `zsh:1: command not found: -d`), so no WSL pane could start in the host.
String quoteWindowsArgument(String argument) {
  if (argument.isNotEmpty && !argument.contains(RegExp(r'[ \t\n\v"]'))) {
    return argument;
  }
  final out = StringBuffer('"');
  var backslashes = 0;
  for (final rune in argument.runes) {
    if (rune == 0x5C) {
      backslashes++;
      continue;
    }
    if (rune == 0x22) {
      out.write('\\' * (backslashes * 2 + 1));
      out.write('"');
      backslashes = 0;
      continue;
    }
    out.write('\\' * backslashes);
    backslashes = 0;
    out.writeCharCode(rune);
  }
  // A trailing run would otherwise escape the closing quote itself.
  out.write('\\' * (backslashes * 2));
  out.write('"');
  return out.toString();
}

String windowsCommandLine(List<String> argv) =>
    argv.map(quoteWindowsArgument).join(' ');
