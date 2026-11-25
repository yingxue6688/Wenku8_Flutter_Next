import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../catalog.dart';
import 'lightnovel_models.dart';

/// Thrown when a LightNovel.fun chapter requires coin unlock or brave access
/// and the response only carries a truncated preview.
class LightNovelLockedChapterException implements LockedChapterException {
  LightNovelLockedChapterException({
    required this.chapterId,
    required this.coinPrice,
    required this.accessType,
    required this.braveRequired,
    required this.previewText,
    String? message,
    this.bookId = 0,
    this.previewPercent = 0,
  }) : message =
           (message != null && message.trim().isNotEmpty)
           ? message.trim()
           : defaultMessage(
               coinPrice: coinPrice,
               accessType: accessType,
               braveRequired: braveRequired,
             );

  final int chapterId;
  final int bookId;
  @override
  final int coinPrice;
  final String accessType;
  final bool braveRequired;
  final int previewPercent;
  final String previewText;
  @override
  final String message;

  @override
  String? get preview => previewText;

  static String defaultMessage({
    required int coinPrice,
    required String accessType,
    required bool braveRequired,
  }) {
    if (braveRequired || accessType == 'brave') {
      return '本章需要勇者权限才能阅读完整内容';
    }
    if (coinPrice > 0) {
      return '本章需要 $coinPrice 轻币解锁';
    }
    return '本章尚未解锁，暂仅提供试读内容';
  }

  @override
  String toString() => message;
}

/// Structured output from [LightNovelContentNormalizer].
class LightNovelNormalizedContent {
  const LightNovelNormalizedContent({
    required this.text,
    required this.isLockedPreview,
    this.imageUrls = const [],
  });

  final String text;
  final bool isLockedPreview;
  final List<String> imageUrls;
}

/// Normalizes LightNovel.fun chapter detail payloads (`body_html` / `body_text`
/// + `legacy_resources.res_info`) into clean `\n\n`-delimited reader prose and
/// standalone `<!--image--><url><!--image-->` paragraphs consumable by
/// `ReaderContent.parse`.
class LightNovelContentNormalizer {
  const LightNovelContentNormalizer._();

  static const _blockTags = {
    'p',
    'div',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
    'blockquote',
    'pre',
    'section',
    'article',
    'header',
    'footer',
    'aside',
    'figure',
    'figcaption',
    'tr',
    'dt',
    'dd',
  };

  static const _ignoredTags = {'script', 'style', 'noscript', 'template'};
  static const _cellTags = {'td', 'th'};

  static final _mediaTagPattern = RegExp(
    r'\[(res|img)(?:=[^\]\n]*)?\](.*?)\[/\1\]',
    caseSensitive: false,
    dotAll: true,
  );

  static final _breakBbCodePattern = RegExp(
    r'\[/?(?:br|hr|p)\s*/?\]',
    caseSensitive: false,
  );

  static final _strayBbCodePattern = RegExp(
    r'\[/?(?:b|i|u|s|del|strike|em|strong|sup|sub|color|bgcolor|backcolor|'
    r'fontcolor|highlight|size|font|align|left|right|center|justify|indent|'
    r'url|email|quote|code|hide|spoiler|fold|ruby|rt|rp|list|li|table|tr|td|'
    r'th|attach|media|video|audio|img|res)(?:=[^\]\n]*)?\]',
    caseSensitive: false,
  );

  /// Normalizes a [LightNovelChapterDetail] without throwing on locked state.
  static LightNovelNormalizedContent normalizeDetail(
    LightNovelChapterDetail detail,
  ) {
    final extracted = _normalize(
      bodyHtml: detail.bodyHtml,
      bodyText: detail.bodyText,
      resInfo: detail.resInfo,
    );
    return LightNovelNormalizedContent(
      text: extracted.text,
      isLockedPreview: detail.isLockedPreview,
      imageUrls: extracted.imageUrls,
    );
  }

  /// Normalizes a [LightNovelChapterDetail], throwing
  /// [LightNovelLockedChapterException] with cleaned preview text attached when
  /// the chapter is locked and truncated.
  static String normalizeDetailOrThrow(LightNovelChapterDetail detail) {
    final normalized = normalizeDetail(detail);
    if (normalized.isLockedPreview) {
      throw LightNovelLockedChapterException(
        chapterId: detail.chapterId,
        bookId: detail.bookId,
        coinPrice: detail.coinPrice,
        accessType: detail.accessType,
        braveRequired: detail.braveRequired,
        previewPercent: detail.previewPercent,
        previewText: normalized.text,
      );
    }
    return normalized.text;
  }

  /// Normalizes raw `body_html` / `body_text` + optional `res_info` directly.
  static String normalizeBody({
    String? bodyHtml,
    String? bodyText,
    Map<String, LightNovelResourceInfo> resInfo = const {},
  }) => _normalize(
    bodyHtml: bodyHtml ?? '',
    bodyText: bodyText ?? '',
    resInfo: resInfo,
  ).text;

  static ({String text, List<String> imageUrls}) _normalize({
    required String bodyHtml,
    required String bodyText,
    required Map<String, LightNovelResourceInfo> resInfo,
  }) {
    final paragraphs = <String>[];
    final imageUrls = <String>[];

    if (bodyHtml.trim().isNotEmpty) {
      final fragment = html_parser.parseFragment(bodyHtml);
      final buffer = StringBuffer();

      void flushText() {
        if (buffer.isEmpty) return;
        final segment = buffer.toString();
        buffer.clear();
        _emitTextSegment(segment, resInfo, paragraphs, imageUrls);
      }

      void walk(dom.Node node) {
        if (node is dom.Text) {
          buffer.write(node.text);
          return;
        }
        if (node is! dom.Element) {
          for (final child in node.nodes) {
            walk(child);
          }
          return;
        }
        final tag = node.localName?.toLowerCase() ?? '';
        if (_ignoredTags.contains(tag)) return;

        if (tag == 'br' || tag == 'hr') {
          flushText();
          return;
        }

        if (tag == 'img') {
          flushText();
          final rawSrc =
              node.attributes['src'] ??
              node.attributes['data-src'] ??
              node.attributes['data-original'];
          final resKey = node.attributes['data-res-key']?.trim();
          final resolved =
              _validImageUrl(rawSrc) ??
              (resKey != null ? _resolveResourceImageUrl(resKey, resInfo) : null);
          if (resolved != null) {
            paragraphs.add('<!--image-->$resolved<!--image-->');
            imageUrls.add(resolved);
          } else {
            paragraphs.add('[插图]');
          }
          return;
        }

        if (_blockTags.contains(tag)) {
          flushText();
          for (final child in node.nodes) {
            walk(child);
          }
          flushText();
          return;
        }

        if (_cellTags.contains(tag) && buffer.isNotEmpty) {
          buffer.write(' ');
        }
        for (final child in node.nodes) {
          walk(child);
        }
      }

      for (final node in fragment.nodes) {
        walk(node);
      }
      flushText();
    } else if (bodyText.trim().isNotEmpty) {
      _emitTextSegment(bodyText, resInfo, paragraphs, imageUrls);
    }

    return (
      text: paragraphs.join('\n\n'),
      imageUrls: List<String>.unmodifiable(imageUrls),
    );
  }

  static void _emitTextSegment(
    String segment,
    Map<String, LightNovelResourceInfo> resInfo,
    List<String> paragraphs,
    List<String> imageUrls,
  ) {
    final normalizedNewlines = segment
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(_breakBbCodePattern, '\n');

    var cursor = 0;
    for (final match in _mediaTagPattern.allMatches(normalizedNewlines)) {
      if (match.start > cursor) {
        _emitPlainLines(
          normalizedNewlines.substring(cursor, match.start),
          paragraphs,
        );
      }
      final tagName = match.group(1)!.toLowerCase();
      final payload = match.group(2)?.trim() ?? '';
      final resolved = tagName == 'res'
          ? _resolveResourceImageUrl(payload, resInfo)
          : _validImageUrl(payload);
      if (resolved != null) {
        paragraphs.add('<!--image-->$resolved<!--image-->');
        imageUrls.add(resolved);
      } else if (payload.isNotEmpty) {
        paragraphs.add('[插图]');
      }
      cursor = match.end;
    }

    if (cursor < normalizedNewlines.length) {
      _emitPlainLines(normalizedNewlines.substring(cursor), paragraphs);
    }
  }

  static void _emitPlainLines(String raw, List<String> paragraphs) {
    final cleaned = raw
        .replaceAll(_strayBbCodePattern, '')
        .replaceAll('\u00A0', ' ');
    for (final line in cleaned.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        paragraphs.add(trimmed);
      }
    }
  }

  static String? _resolveResourceImageUrl(
    String key,
    Map<String, LightNovelResourceInfo> resInfo,
  ) {
    final trimmedKey = key.trim();
    if (trimmedKey.isEmpty) return null;
    final info = resInfo[trimmedKey];
    if (info != null) {
      if (info.type.isNotEmpty && info.type.toLowerCase() != 'image') {
        return null;
      }
      final url = _validImageUrl(info.url);
      if (url != null) return url;
    }
    return _validImageUrl(trimmedKey);
  }

  static String? _validImageUrl(String? raw) {
    var trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.startsWith('//')) {
      trimmed = 'https:$trimmed';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && ![80, 443].contains(uri.port))) {
      return null;
    }
    return uri.toString();
  }
}
