import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'reader_rich_content.dart';
import 'epub_rich_layout.dart';
import 'app_ui.dart';
import 'reader_tap_surface.dart';

class ReaderAnnotations extends SingleChildRenderObjectWidget {
  const ReaderAnnotations({
    super.key,
    required this.format,
    required this.style,
    required this.scaler,
    required this.prefix,
    required this.onNote,
    this.epubSpans = const [],
    this.paperColor = const Color(0xFFFDFBF7),
    required super.child,
  });
  final ReaderRichParagraph format;
  final TextStyle style;
  final TextScaler scaler;
  final int prefix;
  final ValueChanged<String> onNote;
  final List<EpubInlineSpan> epubSpans;
  final Color paperColor;
  @override
  RenderReaderAnnotations createRenderObject(BuildContext context) =>
      RenderReaderAnnotations(this);
  @override
  void updateRenderObject(
    BuildContext context,
    RenderReaderAnnotations renderObject,
  ) => renderObject.update(this);
}

class RenderReaderAnnotations extends RenderProxyBox
    implements ReaderTapPreviewPolicy {
  RenderReaderAnnotations(this.config) {
    _tap.onTap = () {
      if (_pressed case final id?) config.onNote(id);
    };
  }
  ReaderAnnotations config;
  final _tap = TapGestureRecognizer();
  final _labels = <({TextPainter text, Rect rect, double scale})>[];
  final _links = <({Rect rect, String id})>[];
  final _inlineBorders = <({Rect rect, EpubInlineSpan span})>[];
  String? _pressed;
  void update(ReaderAnnotations value) {
    final layoutChanged =
        value.format != config.format ||
        value.style != config.style ||
        value.scaler != config.scaler ||
        value.epubSpans != config.epubSpans ||
        value.paperColor != config.paperColor ||
        value.prefix != config.prefix;
    config = value;
    if (layoutChanged) markNeedsLayout();
  }

  void _clear() {
    for (final p in _labels) {
      p.text.dispose();
    }
    _labels.clear();
    _links.clear();
    _inlineBorders.clear();
  }

  @visibleForTesting
  List<Rect> get debugRubyRects => _labels.map((p) => p.rect).toList();
  List<Rect> get debugNoteRects => _links.map((p) => p.rect).toList();
  @visibleForTesting
  List<Rect> get debugInlineBorderRects =>
      _inlineBorders.map((p) => p.rect).toList();
  @override
  void performLayout() {
    super.performLayout();
    _clear();
    RenderParagraph? text;
    void visit(RenderObject node) {
      if (node is RenderParagraph) {
        text ??= node;
        return;
      }
      node.visitChildren(visit);
    }

    if (child != null) visit(child!);
    final paragraph = text;
    if (paragraph == null) return;
    final origin = paragraph.localToGlobal(Offset.zero, ancestor: this);
    List<Rect> boxes(int start, int end) => paragraph
        .getBoxesForSelection(
          TextSelection(
            baseOffset: start + config.prefix,
            extentOffset: end + config.prefix,
          ),
        )
        .map((r) => r.toRect().shift(origin))
        .toList();
    for (final ruby in config.format.ruby) {
      final rects = boxes(ruby.start, ruby.end);
      final total = rects.fold<double>(0, (sum, r) => sum + r.width);
      var used = 0.0;
      final letters = ruby.text.characters.toList();
      for (final box in rects) {
        if (total <= 0) continue;
        final start = (used / total * letters.length).floor();
        used += box.width;
        final end = (used / total * letters.length + 1e-8).floor().clamp(
          start,
          letters.length,
        );
        if (end == start) continue;
        final painter = TextPainter(
          textDirection: TextDirection.ltr,
          textScaler: config.scaler,
          textHeightBehavior: const TextHeightBehavior(
            applyHeightToFirstAscent: false,
            applyHeightToLastDescent: false,
          ),
          text: TextSpan(
            text: letters.sublist(start, end).join(),
            style: config.style.copyWith(
              fontSize: (config.style.fontSize ?? 19) * .48,
              height: 1.0,
              letterSpacing: 0,
            ),
          ),
        )..layout();
        final scale = math.min(
          1.0,
          (box.width + 4) / painter.width.clamp(1, double.infinity),
        );
        _labels.add((
          text: painter,
          rect: Rect.fromLTWH(
            box.center.dx - painter.width * scale / 2,
            box.top - painter.height * scale - 1,
            painter.width * scale,
            painter.height * scale,
          ),
          scale: scale,
        ));
      }
    }
    for (final link in config.format.references) {
      for (final rect in boxes(link.start, link.end)) {
        _links.add((rect: rect, id: link.id));
      }
    }
    for (final span in config.epubSpans) {
      if (!span.underline || span.underlineOffsetEm == null) continue;
      final gap = config.scaler.scale(
        (config.style.fontSize ?? 19) *
            (span.fontScale ?? 1) *
            math.max(span.underlineOffsetEm!, 0.24),
      );
      final rects = boxes(span.start, span.end);
      final font = (config.style.fontSize ?? 19) * (span.fontScale ?? 1);
      for (final (index, box) in rects.indexed) {
        // CSS inline borders include the span's horizontal padding. Extend
        // only the outside edges when its text wraps across several boxes.
        final left = index == 0
            ? config.scaler.scale(font * span.underlinePaddingLeftEm)
            : 0.0;
        final right = index == rects.length - 1
            ? config.scaler.scale(font * span.underlinePaddingRightEm)
            : 0.0;
        _inlineBorders.add((
          rect: Rect.fromLTRB(
            box.left - left,
            box.bottom + gap,
            box.right + right,
            box.bottom + gap + 1,
          ),
          span: span,
        ));
      }
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final canvas = context.canvas;
    for (final item in _labels) {
      canvas.save();
      canvas.translate(offset.dx + item.rect.left, offset.dy + item.rect.top);
      canvas.scale(item.scale);
      item.text.paint(canvas, Offset.zero);
      canvas.restore();
    }
    for (final border in _inlineBorders) {
      final rect = border.rect.shift(offset);
      final color = EpubColorAdapter.adaptBorderColor(
        Color(
          border.span.underlineColor ??
              config.style.color?.toARGB32() ??
              0xFF1F1D1A,
        ),
        paperColor: config.paperColor,
        defaultTextColor: config.style.color ?? const Color(0xFF1F1D1A),
      );
      final stroke = Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      final dotted = border.span.underlineStyle == 'dotted';
      final dashed = border.span.underlineStyle == 'dashed';
      if (dotted || dashed) {
        final dash = dotted ? 0.0 : 4.0;
        for (
          var x = rect.left + stroke.strokeWidth / 2;
          x < rect.right;
          x += dotted ? 3.5 : dash + 2
        ) {
          if (dotted) {
            canvas.drawCircle(
              Offset(x, rect.top),
              stroke.strokeWidth / 2,
              stroke,
            );
          } else {
            canvas.drawLine(
              Offset(x, rect.top),
              Offset(math.min(x + dash, rect.right), rect.top),
              stroke,
            );
          }
        }
      } else {
        canvas.drawLine(rect.topLeft, rect.topRight, stroke);
      }
    }
    final paint = Paint()
      ..color = (config.style.color ?? Colors.grey).withValues(alpha: .42)
      ..strokeWidth = 0.8;
    for (final link in _links) {
      if (link.id.startsWith('epub-link:') ||
          link.id.startsWith('epub-action:')) {
        continue;
      }
      canvas.drawLine(
        offset + Offset(link.rect.left, link.rect.bottom - 3),
        offset + Offset(link.rect.right, link.rect.bottom - 3),
        paint,
      );
    }
  }

  Rect _hitRect(({Rect rect, String id}) v) =>
      v.id.startsWith('epub-link:') || v.id.startsWith('epub-action:')
      ? Rect.fromLTRB(
          v.rect.left - 18,
          v.rect.top - 10,
          v.rect.right + 18,
          v.rect.bottom + 10,
        )
      : v.rect.inflate(3);

  @override
  bool hitTestSelf(Offset position) =>
      _links.any((v) => _hitRect(v).contains(position));

  @override
  bool allowsReaderTapPreview(Offset localPosition) =>
      !hitTestSelf(localPosition);
  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (event is PointerDownEvent) {
      final link = _links
          .where((v) => _hitRect(v).contains(event.localPosition))
          .firstOrNull;
      if (link != null) {
        _pressed = link.id;
        _tap.addPointer(event);
      }
    }
  }

  @override
  void dispose() {
    _clear();
    _tap.dispose();
    super.dispose();
  }
}

Future<void> showReaderNote(
  BuildContext context,
  String text, {
  required bool reduceMotion,
  Widget Function(Widget)? surfaceWrapper,
}) => showJellySheet<void>(
  context: context,
  reduceMotion: reduceMotion,
  surfaceWrapper: surfaceWrapper,
  builder: (sheet) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ArchiveSection(title: '注释', code: 'READER / NOTE'),
        const SizedBox(height: 18),
        SelectionArea(
          child: Text(text, style: const TextStyle(fontSize: 16, height: 1.8)),
        ),
        const SizedBox(height: 20),
        GlassTextButton(
          onPressed: () => Navigator.pop(sheet),
          child: const AppText('回到正文'),
        ),
      ],
    ),
  ),
);
