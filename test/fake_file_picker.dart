import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The phone's file picker and save dialog, answered without asking anyone.
class FakeFilePicker extends FilePickerPlatform {
  /// What the next pick hands over.
  List<PlatformFile> next = const [];

  /// What the save dialog was last handed.
  ({String name, Uint8List bytes})? saved;

  /// The app's own copy a download handed Android's save dialog, which the
  /// download should have removed by the time it is done.
  String? savedFrom;

  /// False to have the user dismiss Android's save dialog.
  bool save = true;

  /// Every saved download Open was asked to open.
  final List<String> opened = [];

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => next;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    saved = (name: fileName, bytes: bytes);
    return Uri.parse('content://downloads/$fileName');
  }
}

/// A [FakeFilePicker] in place of the phone's own until the test ends, and
/// in place of MainActivity's save dialog, which downloads on Android go to
/// instead of file_picker's: it is handed a path, read here while it is there.
FakeFilePicker useFakePicker() {
  final picker = FakeFilePicker();
  final real = FilePickerPlatform.instance;
  FilePickerPlatform.instance = picker;
  addTearDown(() => FilePickerPlatform.instance = real);

  const android = MethodChannel('sshbox/share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(android, (call) async {
    final arguments = call.arguments;
    if (arguments is! Map) return null;
    switch (call.method) {
      case 'saveAs':
        final from = picker.savedFrom = arguments['path']! as String;
        final name = arguments['name']! as String;
        picker.saved = (name: name, bytes: File(from).readAsBytesSync());
        return picker.save ? 'content://downloads/$name' : null;
      case 'open':
        picker.opened.add(arguments['uri']! as String);
        return true;
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(android, null));
  return picker;
}
