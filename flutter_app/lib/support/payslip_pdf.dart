import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:uuid/uuid.dart';

import '../data/payslip.dart';

/// Opening a payslip PDF and reading its text with pdfium (pdfrx) — the PDFKit part of `PayslipReader` (Payslip.swift).
class PayslipPdf {
  /// The saved payslip password (usually the ID number): only in the system's secure storage, on this device.
  static const _storage = FlutterSecureStorage();
  static const _passwordKey = 'maskoret-payslip-password';

  static Future<String?> savedPassword() async {
    try {
      return await _storage.read(key: _passwordKey);
    } catch (_) {
      return null;
    }
  }

  static Future<void> savePassword(String password) => _storage.write(key: _passwordKey, value: password);

  /// Asks for a PDF and copies it to a temporary file of its own (deleted by [discard]); null when nothing was picked.
  static Future<File?> pick() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      dialogTitle: 'קריאת תלוש PDF',
    );
    if (picked.isEmpty) return null;
    final bytes = await picked.first.xFile.readAsBytes();
    final copy = File('${(await getTemporaryDirectory()).path}/payslip-${const Uuid().v4()}.pdf');
    await copy.writeAsBytes(bytes, flush: true);
    // The picker's own copy (Android/iOS keep one in the cache).
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {}
    }
    return copy;
  }

  static Future<void> discard(File? file) async {
    try {
      await file?.delete();
    } catch (_) {}
  }

  static Future<PdfDocument> _open(File file, String? password) async {
    await pdfrxFlutterInitialize();
    try {
      return await PdfDocument.openFile(file.path, passwordProvider: createSimplePasswordProvider(password));
    } on PdfPasswordException {
      throw password == null || password.isEmpty ? PayslipError.needsPassword : PayslipError.wrongPassword;
    } catch (_) {
      throw PayslipError.unreadable;
    }
  }

  static Future<bool> isLocked(File file) async {
    try {
      await (await _open(file, null)).dispose();
      return false;
    } on PayslipError catch (e) {
      return e == PayslipError.needsPassword;
    }
  }

  /// Opens the PDF (with the password when it's locked) and reads it.
  static Future<PayslipReading> read(File file, String? password) async {
    final doc = await _open(file, password);
    final pages = <String>[];
    try {
      for (final page in doc.pages) {
        final text = await page.loadText();
        if (text != null) pages.add(text.fullText);
      }
    } finally {
      await doc.dispose();
    }
    final text = pages.join('\n');
    if (!text.contains(RegExp(r'\d'))) throw PayslipError.noText;
    final reading = PayslipParser.parse(text);
    if (!reading.isUseful) throw PayslipError.notFound;
    return reading;
  }
}
