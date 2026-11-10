import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'reading_widget_design.dart';
import 'reading_widget_skin.dart';
import 'reading_widget_snapshot.dart';

enum ReadingDesktopSize { small, medium, large }

class ReadingDesktopCard extends StatelessWidget {
  const ReadingDesktopCard({
    super.key,
    required this.data,
    required this.size,
    this.brightness = Brightness.light,
    this.quoteText,
    this.quoteSource = '',
    this.quoteCount = 0,
    this.paintQuote = true,
  });

  final ReadingWidgetSnapshot data;
  final ReadingDesktopSize size;
  final Brightness brightness;
  final String? quoteText;
  final String quoteSource;
  final int quoteCount;
  final bool paintQuote;

  @override
  Widget build(BuildContext context) {
    final dark =
        data.skin == ReadingWidgetSkin.night ||
        data.skin == ReadingWidgetSkin.film ||
        brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF101419) : const Color(0xFFF4F0E6);
    final fg = dark ? const Color(0xFFF6F1E6) : const Color(0xFF272C29);
    final accent = dark ? const Color(0xFFDCB65E) : const Color(0xFF4F8985);
    final dimensions = switch (size) {
      ReadingDesktopSize.small => const Size(170, 170),
      ReadingDesktopSize.medium => const Size(364, 170),
      ReadingDesktopSize.large => const Size(364, 364),
    };
    final title = switch (data.design) {
      ReadingWidgetDesign.focus => '????',
      ReadingWidgetDesign.week => '?????',
      ReadingWidgetDesign.calendar => '????',
      ReadingWidgetDesign.memory => '????',
      ReadingWidgetDesign.quote => '???',
      ReadingWidgetDesign.classic => data.theme.label,
    };
    final primary = data.design == ReadingWidgetDesign.quote
        ? (paintQuote ? (quoteText ?? '??????????') : '')
        : '${widgetMinutes(data.verifiedTodaySeconds)} ??';
    return Container(
      width: dimensions.width,
      height: dimensions.height,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(
            title,
            style: TextStyle(
              fontSize: 12,
              color: fg.withValues(alpha: 0.68),
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          if (primary.isNotEmpty)
            AppText(
              primary,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: data.design == ReadingWidgetDesign.quote ? 15 : 28,
                color: accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          const Spacer(),
          Container(height: 2, color: accent.withValues(alpha: 0.45)),
          const SizedBox(height: 6),
          AppText(
            data.design == ReadingWidgetDesign.quote && quoteSource.isNotEmpty
                ? quoteSource
                : widgetDate(data.localDay),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }
}
