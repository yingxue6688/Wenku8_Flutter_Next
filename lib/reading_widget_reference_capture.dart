import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'reading_widget_reference.dart';
import 'reading_widget_skin.dart';
import 'reading_widget_snapshot.dart';

Future<void> warmReadingDesktopImages(ReadingWidgetSnapshot snapshot) async {}

Future<Uint8List> renderReadingDesktopCard(
  ReadingWidgetSnapshot snapshot,
  ReadingDesktopSize size, {
  Brightness brightness = Brightness.light,
  bool paintQuote = true,
}) async {
  final dimensions = switch (size) {
    ReadingDesktopSize.small => const Size(340, 340),
    ReadingDesktopSize.medium => const Size(728, 340),
    ReadingDesktopSize.large => const Size(728, 728),
  };
  final dark =
      snapshot.skin == ReadingWidgetSkin.night ||
      snapshot.skin == ReadingWidgetSkin.film ||
      brightness == Brightness.dark;
  final bg = dark ? const Color(0xFF101419) : const Color(0xFFF4F0E6);
  final accent = dark ? const Color(0xFFDCB65E) : const Color(0xFF4F8985);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & dimensions);
  final rrect = RRect.fromRectAndRadius(
    Offset.zero & dimensions,
    const Radius.circular(44),
  );
  canvas.drawRRect(rrect, Paint()..color = bg);
  canvas.drawRect(
    Rect.fromLTWH(32, dimensions.height - 24, dimensions.width - 64, 6),
    Paint()..color = accent,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    dimensions.width.toInt(),
    dimensions.height.toInt(),
  );
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<Map<String, Uint8List>> renderReadingDesktopCards(
  ReadingWidgetSnapshot snapshot,
) async {
  final result = <String, Uint8List>{};
  for (final size in ReadingDesktopSize.values) {
    result[size.name] = await renderReadingDesktopCard(snapshot, size);
  }
  return result;
}
