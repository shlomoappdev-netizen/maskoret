import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:uuid/uuid.dart';

import '../data/payslip.dart';
import 'app_log.dart';

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

  /// Scanned pages are read on the device with ML Kit (Android); Windows has no local recognizer here, so a scan
  /// there asks to type the net. Nothing is ever sent anywhere.
  static bool get ocrSupported => Platform.isAndroid;

  /// The numbers on scanned pages (ML Kit's Latin model, bundled in the app, so only digits matter here), one
  /// per line, top to bottom and right to left — the order a Hebrew payslip is read in (recognizeNumbers in Payslip.swift).
  static Future<String> _recognizeNumbers(PdfDocument doc) async {
    if (!ocrSupported) return '';
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final dir = await getTemporaryDirectory();
    final lines = <String>[];
    try {
      for (final page in doc.pages) {
        const scale = 3.0;
        final w = page.width * scale, h = page.height * scale;
        final rendered = await page.render(fullWidth: w, fullHeight: h, backgroundColor: 0xffffffff);
        if (rendered == null) continue;
        final image = await rendered.createImage();
        rendered.dispose();
        final png = await image.toByteData(format: ImageByteFormat.png);
        image.dispose();
        if (png == null) continue;
        final file = File('${dir.path}/payslip-page-${const Uuid().v4()}.png');
        try {
          await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
          final result = await recognizer.processImage(InputImage.fromFilePath(file.path));
          final found = [for (final b in result.blocks) ...b.lines];
          // Rows by their middle (1/200 of the page), top first; in a row, right to left.
          final rows = <int, List<TextLine>>{};
          for (final l in found) {
            rows.putIfAbsent((l.boundingBox.center.dy / h * 200).round(), () => []).add(l);
          }
          for (final key in rows.keys.toList()..sort()) {
            for (final l in rows[key]!..sort((a, b) => b.boundingBox.left.compareTo(a.boundingBox.left))) {
              lines.add(l.text.replaceAll(' / ', '/'));
            }
          }
        } finally {
          try {
            await file.delete();
          } catch (_) {}
        }
      }
    } finally {
      await recognizer.close();
    }
    return lines.join('\n');
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
    var text = '';
    try {
      for (final page in doc.pages) {
        final t = await page.loadText();
        if (t != null) pages.add(t.fullText);
      }
      text = pages.join('\n');
      // A scanned payslip (an image, no text layer): read its numbers on the device.
      if (!text.contains(RegExp(r'\d'))) {
        try {
          text = await _recognizeNumbers(doc);
        } catch (e) {
          AppLog.add('payslip', 'זיהוי הספרות בתלוש סרוק נכשל: $e');
        }
      }
    } finally {
      await doc.dispose();
    }
    if (!text.contains(RegExp(r'\d'))) throw ocrSupported ? PayslipError.noText : PayslipError.noTextLayer;
    final reading = PayslipParser.parse(text);
    if (!reading.isUseful) throw PayslipError.notFound;
    return reading;
  }
}
