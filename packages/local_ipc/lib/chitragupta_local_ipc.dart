library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const _bufferSize = 1024 * 1024;
typedef PipeHandler = FutureOr<String> Function(String request);

class NamedPipeRpcServer {
  NamedPipeRpcServer._(this.pipeName, this._isolate, this._requests);
  final String pipeName;
  final Isolate _isolate;
  final ReceivePort _requests;

  static Future<NamedPipeRpcServer> start(
    String pipeName,
    PipeHandler handler,
  ) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Named pipes require Windows.');
    }
    final requests = ReceivePort();
    final ready = Completer<void>();
    requests.listen((message) async {
      if (message == 'ready') {
        if (!ready.isCompleted) ready.complete();
      } else if (message case [final String request, final SendPort reply]) {
        try {
          reply.send(await handler(request));
        } on Object catch (error) {
          reply.send(jsonEncode({'ok': false, 'error': '$error'}));
        }
      }
    });
    final isolate = await Isolate.spawn(_serve, [pipeName, requests.sendPort]);
    await ready.future.timeout(const Duration(seconds: 5));
    return NamedPipeRpcServer._(pipeName, isolate, requests);
  }

  Future<void> close() async {
    _isolate.kill(priority: Isolate.immediate);
    _requests.close();
  }
}

class NamedPipeRpcClient {
  const NamedPipeRpcClient._();

  static String call(String pipeName, String request) {
    if (!Platform.isWindows) {
      throw UnsupportedError('Named pipes require Windows.');
    }
    final input = Uint8List.fromList(utf8.encode(request));
    if (input.length > _bufferSize) {
      throw ArgumentError('Request exceeds 1 MiB.');
    }
    final name = pipeName.toNativeUtf16();
    final inBuffer = calloc<Uint8>(input.length);
    try {
      inBuffer.asTypedList(input.length).setAll(0, input);
      final handle = CreateFile(
        name,
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        0,
        0,
      );
      if (handle == INVALID_HANDLE_VALUE) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }
      try {
        final written = calloc<Uint32>();
        final outBuffer = calloc<Uint8>(_bufferSize);
        final bytesRead = calloc<Uint32>();
        try {
          if (WriteFile(handle, inBuffer, input.length, written, nullptr) ==
              0) {
            throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
          }
          if (ReadFile(handle, outBuffer, _bufferSize, bytesRead, nullptr) ==
              0) {
            throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
          }
          return utf8.decode(outBuffer.asTypedList(bytesRead.value));
        } finally {
          calloc.free(written);
          calloc.free(outBuffer);
          calloc.free(bytesRead);
        }
      } finally {
        CloseHandle(handle);
      }
    } finally {
      calloc.free(name);
      calloc.free(inBuffer);
    }
  }
}

Future<void> _serve(List<Object> args) async {
  final pipeName = args[0] as String;
  final owner = args[1] as SendPort;
  var first = true;
  while (true) {
    final handle = _createOwnerOnlyPipe(pipeName);
    if (handle == INVALID_HANDLE_VALUE) {
      throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
    }
    try {
      if (first) {
        first = false;
        owner.send('ready');
      }
      final connected =
          ConnectNamedPipe(handle, nullptr) != 0 ||
          GetLastError() == ERROR_PIPE_CONNECTED;
      if (!connected) continue;
      final request = _read(handle);
      final responses = ReceivePort();
      owner.send([request, responses.sendPort]);
      final response = await responses.first as String;
      responses.close();
      _write(handle, response);
      FlushFileBuffers(handle);
      DisconnectNamedPipe(handle);
    } finally {
      CloseHandle(handle);
    }
  }
}

int _createOwnerOnlyPipe(String pipeName) {
  final name = pipeName.toNativeUtf16();
  final descriptor = calloc<Pointer<Void>>();
  final attributes = calloc<SECURITY_ATTRIBUTES>();
  final sddl = 'D:P(A;;GA;;;OW)'.toNativeUtf16();
  try {
    final convert = DynamicLibrary.open('advapi32.dll')
        .lookupFunction<
          Int32 Function(
            Pointer<Utf16>,
            Uint32,
            Pointer<Pointer<Void>>,
            Pointer<Uint32>,
          ),
          int Function(
            Pointer<Utf16>,
            int,
            Pointer<Pointer<Void>>,
            Pointer<Uint32>,
          )
        >('ConvertStringSecurityDescriptorToSecurityDescriptorW');
    if (convert(sddl, 1, descriptor, nullptr) == 0) {
      throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
    }
    attributes.ref
      ..nLength = sizeOf<SECURITY_ATTRIBUTES>()
      ..lpSecurityDescriptor = descriptor.value
      ..bInheritHandle = 0;
    return CreateNamedPipe(
      name,
      PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_MESSAGE |
          PIPE_READMODE_MESSAGE |
          PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS,
      PIPE_UNLIMITED_INSTANCES,
      _bufferSize,
      _bufferSize,
      30000,
      attributes,
    );
  } finally {
    if (descriptor.value.address != 0) LocalFree(descriptor.value);
    calloc.free(name);
    calloc.free(descriptor);
    calloc.free(attributes);
    calloc.free(sddl);
  }
}

String _read(int handle) {
  final buffer = calloc<Uint8>(_bufferSize);
  final read = calloc<Uint32>();
  try {
    if (ReadFile(handle, buffer, _bufferSize, read, nullptr) == 0) {
      throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
    }
    return utf8.decode(buffer.asTypedList(read.value));
  } finally {
    calloc.free(buffer);
    calloc.free(read);
  }
}

void _write(int handle, String response) {
  final bytes = Uint8List.fromList(utf8.encode(response));
  if (bytes.length > _bufferSize) throw StateError('Response exceeds 1 MiB.');
  final buffer = calloc<Uint8>(bytes.length);
  final written = calloc<Uint32>();
  try {
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    if (WriteFile(handle, buffer, bytes.length, written, nullptr) == 0 ||
        written.value != bytes.length) {
      throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
    }
  } finally {
    calloc.free(buffer);
    calloc.free(written);
  }
}
