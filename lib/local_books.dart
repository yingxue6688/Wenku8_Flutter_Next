import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, TextAlign;
import 'package:flutter/services.dart' show PlatformException;
import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as html;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import 'catalog.dart';
import 'book_identity.dart';
import 'book_tag_catalog.dart';
import 'book_import_limits.dart';
import 'local_book_media.dart';
import 'local_epub_media.dart';
import 'local_epub_navigation.dart';
import 'local_book_archive.dart';
import 'local_book_import_issues.dart';
export 'local_book_import_issues.dart';
import 'local_book_series.dart';
import 'epub_image_styles.dart';
import 'personal_images.dart';
import 'local_text_import.dart';
import 'local_text_rules.dart' show defaultLocalHeadingCandidate;
import 'local_text_storage.dart';
import 'local_text_reference.dart';
import 'local_linked_text_index.dart';
import 'local_document_reference.dart';
import 'local_document_input.dart';
import 'local_markup_decode.dart';
import 'local_epub_markup.dart';
import 'local_import_options.dart';
import 'reader_content.dart' show readerIllustrationUrl;
import 'reader_rich_content.dart';
import 'reader_block_spacing.dart';
import 'epub_rich_layout.dart';
import 'epub_rich_text.dart';
import 'reader_coordinate_map.dart';

export 'book_identity.dart' show localBookIdStart, isLocalBook;

part 'local_book_handoff.dart';
part 'local_book_maintenance.dart';
part 'local_book_links.dart';
part 'local_document_links.dart';
part 'local_book_navigation.dart';

class ImportedBook {
  const ImportedBook(
    this.novel,
    this.digest,
    this.bodies,
    this.images, {
    this.layouts = const [],
    this.fonts = const {},
    this.seriesHint,
    this.warnings = const [],
    this.origins = const [],
    this.damagedResources = const {},
    this.damagedChapters = const {},
  });
  final Novel novel;
  final String digest;
  final List<String> bodies;
  final Map<String, Uint8List> images;
  final List<EpubChapterLayout> layouts;
  final Map<String, Uint8List> fonts;
  final LocalSeriesHint? seriesHint;
  final List<String> warnings;
  final List<String> origins;
  final Map<String, String> damagedResources;
  final Map<int, String> damagedChapters;
}

class LocalBookInput {
  const LocalBookInput(this.name, this.bytes, {this.text});
  final String name;
  final Uint8List bytes;

  /// Text decoded by the document bridge (Unicode, GB18030 or Big5).
  final String? text;
}

Iterable<String> _boundedParagraphs(String text) sync* {
  for (var start = 0; start < text.length;) {
    var end = (start + 4000).clamp(0, text.length);
    if (end < text.length) {
      final last = text.codeUnitAt(end - 1);
      if (last >= 0xD800 && last <= 0xDBFF) end--;
    }
    yield text.substring(start, end);
    start = end;
  }
}

String _metadataText(String value) {
  if (value.length <= 2048) return value;
  var end = 2048;
  final last = value.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return value.substring(0, end);
}

ImportedBook parseLocalBook(
  LocalBookInput input, {
  bool autoTitles = true,
  bool inlineEpubImages = true,
  bool preserveRichText = true,
}) {
  _validateInput(input.name, input.bytes.length);
  // Content identity makes re-import and cross-device sync address the same
  // book. The complete digest also detects the rare truncated-ID collision.
  final digest = sha256.convert(input.bytes).toString();
  final id =
      localBookIdStart |
      (int.parse(digest.substring(0, 8), radix: 16) & 0x1fffffff);
  final name = input.name.replaceAll('\\', '/').split('/').last;
  if (name.toLowerCase().endsWith('.epub')) {
    return _epub(
      input,
      id,
      digest,
      autoTitles: autoTitles,
      mergeUnlistedIllustrations: inlineEpubImages,
      preserveRichText: preserveRichText,
    );
  }
  if (!name.toLowerCase().endsWith('.txt')) {
    throw const FormatException('目前支持 TXT 与 EPUB 格式');
  }
  final text = (input.text ?? utf8.decode(input.bytes)).replaceFirst(
    '\uFEFF',
    '',
  );
  final lines = text.replaceAll(RegExp(r'\r\n?'), '\n').split('\n');
  final chapters = <NovelChapter>[];
  final bodies = <String>[];
  final buffer = <String>[];
  var title = name.substring(0, name.length - 4);
  var volume = '';
  var volumeId = 0;
  var hasTitle = false;
  void flush() {
    if (buffer.isEmpty) return;
    // Bound unstructured TXT chapters as well as memory and lazy text layout.
    final paragraphs = <String>[];
    for (final line in buffer) {
      paragraphs.addAll(_boundedParagraphs(line));
    }
    var part = 0;
    for (var start = 0; start < paragraphs.length;) {
      final chunk = <String>[];
      var length = 0;
      while (start < paragraphs.length && length < 100000) {
        final p = paragraphs[start++];
        length += p.length;
        chunk.add(p);
      }
      final displayTitle = hasTitle || autoTitles ? title : '正文';
      final section = chunk.length == paragraphs.length
          ? displayTitle
          : '$displayTitle · 片段 ${++part}';
      chapters.add(
        NovelChapter(
          section,
          '',
          id: chapters.length + 1,
          volumeId: volumeId,
          volumeTitle: volume,
        ),
      );
      bodies.add(chunk.join('\n\n'));
    }
    buffer.clear();
  }

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final candidate = line.length <= 90
        ? defaultLocalHeadingCandidate(line)
        : line;
    if (line.length <= 90 && localTextVolumePattern.hasMatch(candidate)) {
      flush();
      volume = candidate;
      volumeId++;
      title = candidate;
      hasTitle = true;
    } else if (line.length <= 90 &&
        localTextChapterPattern.hasMatch(candidate)) {
      flush();
      title = candidate;
      hasTitle = true;
    } else {
      buffer.add(line);
    }
  }
  flush();
  if (chapters.isEmpty) throw const FormatException('文件中没有可阅读的正文');
  return ImportedBook(
    _novel(id, name.substring(0, name.length - 4), '', chapters),
    digest,
    bodies,
    const {},
  );
}

void _validateInput(String name, int size) {
  if (size <= 0) throw const FormatException('文件为空，请重新下载原书');
  if (!RegExp(r'\.(txt|epub)$', caseSensitive: false).hasMatch(name)) {
    throw const FormatException('目前支持 TXT 与 EPUB 格式');
  }
  if (size > localBookByteLimit(name)) {
    throw FormatException(localBookSizeMessage(name));
  }
}

Novel _novel(
  int id,
  String title,
  String author,
  List<NovelChapter> chapters, {
  String? cover,
  BookNavigation? navigation,
  String summary = '已保存到本地书库，可离线阅读。',
}) => Novel(
  id: id,
  title: _metadataText(title),
  author: author.isEmpty ? '本地书籍' : _metadataText(author),
  genre: '本地导入',
  summary: summary,
  colors: const [Color(0xFF646464), Color(0xFF303030)],
  chapters: List.unmodifiable(chapters),
  chapterCount: chapters.length,
  isComplete: true,
  coverUrl: cover,
  navigation: navigation,
);

/// Entries are decoded lazily, only after declared sizes and names are checked.
/// No archive-supplied path is ever used as a filesystem destination.
Archive boundedZip(
  Uint8List bytes, {
  int maxSize = 160 * 1024 * 1024,
  int maxEntrySize = 40 * 1024 * 1024,
}) => readLocalBookArchive(
  InputMemoryStream(bytes),
  maxSize: maxSize,
  maxEntrySize: maxEntrySize,
);

ImportedBook _epub(
  LocalBookInput input,
  int id,
  String digest, {
  Archive? archive,
  void Function(String name, ArchiveFile file)? saveImage,
  void Function(ArchiveFile file)? verifyImage,
  Map<String, String>? damagedEntries,
  void Function(int index, String body)? saveBody,
  void Function(int index, String body)? appendBody,
  void Function(int index, EpubChapterLayout layout)? saveLayout,
  void Function(String name, Uint8List bytes)? saveFont,
  bool autoTitles = true,
  bool mergeUnlistedIllustrations = true,
  bool preserveRichText = true,
  int richLayoutLevel = 2,
  Map<String, String> imageNames = const {},
  bool coverOnly = false,
  bool normalizeMarkup = true,
}) {
  final zip = archive ?? boundedZip(input.bytes, maxSize: 1024 * 1024 * 1024);
  final files = {
    for (final f in zip)
      if (f.isFile) f.name: f,
  };
  final recovery = damagedEntries != null;
  final damage = damagedEntries ?? <String, String>{};
  String read(String path) {
    if (damage[path] case final reason?) {
      throw LocalBookArchiveCorruption(path, reason);
    }
    final file = files[path];
    if (file == null) throw FormatException('EPUB 缺少资源：$path');
    if (file.size > 8 * 1024 * 1024) {
      throw FormatException('EPUB 文本资源超过 8 MiB：$path');
    }
    try {
      return decodeLocalMarkup(readLocalBookArchiveEntry(file));
    } on LocalBookArchiveCorruption catch (error) {
      if (recovery) damage[path] = error.reason;
      rethrow;
    }
  }

  final container = XmlDocument.parse(read('META-INF/container.xml'));
  final packageReference = container.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'rootfile')
      .firstOrNull
      ?.getAttribute('full-path');
  if (packageReference == null || packageReference.trim().isEmpty) {
    throw const FormatException('EPUB 缺少书籍索引，请重新获取完整原书');
  }
  // `base` is already a decoded ZIP filename. Re-encode its segments before
  // using it as a URL, so a literal #, ? or % cannot change relative resolution.
  Uri baseUri(String base) => Uri(
    scheme: 'https',
    host: 'local',
    pathSegments: ['', if (base.isNotEmpty) ...base.split('/')],
  );
  final urlEdgeWhitespace = RegExp(r'^[\x00-\x20]+|[\x00-\x20]+$');
  final urlTabsAndNewlines = RegExp(r'[\t\n\r]');
  Uri resolveUri(String base, String href) => baseUri(base).resolve(
    href.replaceAll(urlEdgeWhitespace, '').replaceAll(urlTabsAndNewlines, ''),
  );
  String resolve(String base, String href) {
    final uri = resolveUri(base, href);
    if (uri.scheme != 'https' || uri.host != 'local') {
      throw const FormatException('EPUB 引用了外部资源');
    }
    return Uri.decodeComponent(uri.path.substring(1));
  }

  final opfPath = resolve('', packageReference);
  final package = XmlDocument.parse(read(opfPath));
  final elements = package.descendants.whereType<XmlElement>().toList();
  String field(String name) =>
      elements
          .where((e) => e.name.local == name)
          .firstOrNull
          ?.innerText
          .trim() ??
      '';
  final manifest =
      <String, ({String path, String type, String props, String fallback})>{};
  final external = <String>{};
  final warnings = <String>[];
  for (final item in elements.where((e) => e.name.local == 'item')) {
    final id = item.getAttribute('id'), href = item.getAttribute('href');
    if (id == null || href == null) continue;
    try {
      manifest[id] = (
        path: resolve(opfPath, href),
        type: (item.getAttribute('media-type') ?? '').trim().toLowerCase(),
        props: item.getAttribute('properties') ?? '',
        fallback: item.getAttribute('fallback')?.trim() ?? '',
      );
    } on FormatException {
      // EPUB can list optional remote styles/fonts. Import is offline: do not
      // fetch them, and do not reject local prose because of an unused asset.
      external.add(id);
    }
  }
  final htmlPaths = {
    for (final item in manifest.values)
      if (item.type == 'text/html') item.path,
  };
  html.Document parseDocument(String path) => parseLocalEpubMarkup(
    read(path),
    normalizeEmptyRawText: normalizeMarkup && !htmlPaths.contains(path),
  );
  final uidAttr = elements
      .where((e) => e.name.local == 'package')
      .firstOrNull
      ?.getAttribute('unique-identifier');
  final uniqueIdentifier =
      (uidAttr == null
              ? null
              : elements
                    .where(
                      (e) =>
                          e.name.local == 'identifier' &&
                          e.getAttribute('id') == uidAttr,
                    )
                    .firstOrNull
                    ?.innerText
                    .trim()) ??
      field('identifier');
  final encryptionAlgorithms = <String, String>{};
  if (files.containsKey('META-INF/encryption.xml') ||
      damage.containsKey('META-INF/encryption.xml')) {
    final encryptionXml = read('META-INF/encryption.xml');
    final encryption = XmlDocument.parse(encryptionXml);
    for (final data in encryption.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'EncryptedData',
    )) {
      final entries = data.descendants.whereType<XmlElement>();
      final algorithm = entries
          .where((e) => e.name.local == 'EncryptionMethod')
          .firstOrNull
          ?.getAttribute('Algorithm');
      final reference = entries
          .where((e) => e.name.local == 'CipherReference')
          .firstOrNull
          ?.getAttribute('URI');
      final path = reference == null ? null : resolve('', reference);
      final font = manifest.values.where((e) => e.path == path).firstOrNull;
      // Only font obfuscation is allowed; never encryption of prose or images.
      if (!const {
            'http://www.idpf.org/2008/embedding',
            'http://ns.adobe.com/pdf/enc#RC',
          }.contains(algorithm) ||
          font == null ||
          !(font.type.startsWith('font/') ||
              const {
                'application/font-sfnt',
                'application/vnd.ms-opentype',
                'application/x-font-otf',
                'application/x-font-ttf',
                'application/x-font-truetype',
                'application/font-woff',
              }.contains(font.type))) {
        throw const FormatException('不支持受 DRM 保护的 EPUB，请选择未加密的完整原书');
      }
      if (path != null && algorithm != null) {
        encryptionAlgorithms[path] = algorithm;
      }
    }
  }
  ({String path, String fragment}) target(String base, String href) => (
    path: resolve(base, href),
    fragment: Uri.decodeComponent(resolveUri(base, href).fragment),
  );
  final labels =
      <({String path, String fragment}), ({String title, String volume})>{};
  String targetKey(({String path, String fragment}) to) =>
      '${to.path}#${to.fragment}';
  final ncx = manifest.values
      .where((e) => e.type == 'application/x-dtbncx+xml')
      .firstOrNull;
  if (ncx != null) {
    try {
      final nav = XmlDocument.parse(read(ncx.path));
      void walk(XmlElement node, String parent, [int depth = 0]) {
        final points = node.childElements.where(
          (e) => e.name.local == 'navPoint',
        );
        for (final point in points) {
          final title =
              point.childElements
                  .where((e) => e.name.local == 'navLabel')
                  .firstOrNull
                  ?.innerText
                  .trim() ??
              '';
          final href = point.childElements
              .where((e) => e.name.local == 'content')
              .firstOrNull
              ?.getAttribute('src');
          final children = point.childElements.any(
            (e) => e.name.local == 'navPoint',
          );
          if (href != null) {
            try {
              labels[target(ncx.path, href)] = (
                title: title,
                volume: children ? title : parent,
              );
            } on FormatException {
              // External navigation links are not local chapter boundaries.
            }
          }
          walk(point, children ? title : parent, depth + 1);
        }
      }

      for (final node in nav.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'navMap',
      )) {
        walk(node, '');
      }
    } on FormatException {
      // Authored navigation below diagnoses this optional NCX once. If a valid
      // EPUB3 NAV replaces it, the unused broken fallback needs no warning.
    }
  }
  final epubNav = manifest.values
      .where((e) => hasEpubToken(e.props, 'nav'))
      .firstOrNull;
  if (epubNav != null) {
    try {
      final document = parseDocument(epubNav.path);
      final nav = epubTableOfContents(document);
      void walk(html.Element root, String parent, [int depth = 0]) {
        for (final li in root.children.where((e) => e.localName == 'li')) {
          final a = li.children.where((e) => e.localName == 'a').firstOrNull;
          final ol = li.children.where((e) => e.localName == 'ol').firstOrNull;
          final title = epubNavigationLabel(
            a ?? li.children.where((e) => e.localName == 'span').firstOrNull,
          );
          final href = a?.attributes['href'];
          if (href != null) {
            try {
              labels[target(epubNav.path, href)] = (
                title: title,
                volume: ol == null ? parent : title,
              );
            } on FormatException {
              // Keep valid internal entries when a navigation also has a link
              // to an external website.
            }
          }
          if (ol != null) walk(ol, title, depth + 1);
        }
      }

      final ol = nav?.querySelector('ol');
      if (ol != null) walk(ol, '');
    } on FormatException {
      warnings.add('原书导航无法读取，已按原书顺序和正文标题恢复章节。');
    }
  }
  final images = <String, Uint8List>{};
  final imagePaths = <String, String>{};
  final unavailableImages = <String>{};
  const rasterExtensions = {
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/gif': 'gif',
    'image/webp': 'webp',
  };
  final imageTypesByPath = {
    for (final entry in manifest.values)
      if (rasterExtensions.containsKey(entry.type)) entry.path: entry.type,
  };
  final verifiedImagePaths = <String>{};
  String? addImage(String path, {bool cover = false, bool required = false}) {
    if (damage[path] case final reason?) {
      if (required) throw LocalBookArchiveCorruption(path, reason);
      return null;
    }
    final file = files[path];
    final originalExtension = path.split('.').last.toLowerCase();
    final ext =
        ['png', 'jpg', 'jpeg', 'webp', 'gif'].contains(originalExtension)
        ? originalExtension
        : rasterExtensions[imageTypesByPath[path]];
    if (file == null || file.size > 8 * 1024 * 1024 || ext == null) {
      return null;
    }
    Uint8List? verifiedBytes;
    try {
      if (required && !verifiedImagePaths.contains(path)) {
        if (saveImage == null || verifyImage == null) {
          verifiedBytes = readLocalBookArchiveEntry(file);
        } else {
          verifyImage(file);
        }
        verifiedImagePaths.add(path);
      }
      // A preceding inline reference may have indexed this image without reading
      // it. An image used as the chapter itself must be checked before returning.
      if (imagePaths.containsKey(path) && !cover) return imagePaths[path];
      var name =
          imageNames[path] ??
          (cover ? 'cover.$ext' : 'img-${imagePaths.length}.$ext');
      if (!imageNames.containsKey(path) && !cover) {
        var index = imagePaths.length;
        while (imageNames.values.contains(name)) {
          name = 'img-${++index}.$ext';
        }
      }
      if (saveImage == null) {
        images[name] = verifiedBytes ?? readLocalBookArchiveEntry(file);
        verifiedImagePaths.add(path);
      } else {
        saveImage(name, file);
      }
      return imagePaths[path] = 'wenku-local://$id/$name';
    } on LocalBookArchiveCorruption catch (error) {
      if (!recovery) rethrow;
      damage[path] = error.reason;
      if (required) rethrow;
      return null;
    }
  }

  final coverId = elements
      .where((e) => e.name.local == 'meta' && e.getAttribute('name') == 'cover')
      .firstOrNull
      ?.getAttribute('content');
  final cover =
      manifest[coverId] ??
      manifest.values
          .where((e) => hasEpubToken(e.props, 'cover-image'))
          .firstOrNull;
  String? coverPath = cover?.path;
  // A broken optional cover reference must not reject an otherwise readable
  // book. EPUB2 guide entries may name XHTML/SVG wrappers rather than images.
  try {
    coverPath ??= elements
        .where(
          (e) =>
              e.name.local == 'reference' && e.getAttribute('type') == 'cover',
        )
        .map((e) => e.getAttribute('href'))
        .whereType<String>()
        .map((href) => resolve(opfPath, href))
        .firstOrNull;
    if (coverPath != null &&
        RegExp(r'\.(x?html?|svg)$', caseSensitive: false).hasMatch(coverPath)) {
      final doc = parseDocument(coverPath);
      final image = doc.querySelector('img, image');
      final href =
          image?.attributes['src'] ??
          image?.attributes['href'] ??
          image?.attributes.entries
              .where((e) => e.key.toString() == 'xlink:href')
              .firstOrNull
              ?.value;
      coverPath = href == null ? null : resolve(coverPath, href);
    }
  } on FormatException {
    coverPath = null;
  }
  coverPath ??= manifest.values
      .where(
        (e) =>
            e.type.startsWith('image/') &&
            RegExp(
              r'(^|[/_.-])cover([_.-]|$)',
              caseSensitive: false,
            ).hasMatch(e.path),
      )
      .firstOrNull
      ?.path;
  final coverUrl = coverPath == null ? null : addImage(coverPath, cover: true);
  if (coverOnly) {
    return ImportedBook(
      _novel(id, field('title'), field('creator'), const [], cover: coverUrl),
      digest,
      const [],
      images,
    );
  }
  final chapters = <NovelChapter>[];
  final origins = <String>[];
  final bodies = <String>[];
  final layouts = <EpubChapterLayout>[];
  final fonts = <String, Uint8List>{};
  final fontPaths = <String, String>{};
  final embeddedFonts = <String, String>{};
  String? addFont(String family, String path) {
    final key = family.toLowerCase();
    if (fontPaths.containsKey(path)) {
      final existing = fontPaths[path]!;
      embeddedFonts[key] = existing;
      return existing;
    }
    final file = files[path];
    final ext = path.split('.').last.toLowerCase();
    if (file == null ||
        file.size > 16 * 1024 * 1024 ||
        !['ttf', 'otf', 'ttc', 'woff'].contains(ext)) {
      return null;
    }
    try {
      final rawBytes = readLocalBookArchiveEntry(file);
      if (rawBytes.isEmpty) return null;
      final bytes = EpubFontManager.deobfuscateFont(
        rawBytes,
        algorithm: encryptionAlgorithms[path],
        uniqueIdentifier: uniqueIdentifier,
      );
      final name = 'font-${fontPaths.length}.$ext';
      if (saveFont == null) {
        fonts[name] = bytes;
      } else {
        saveFont(name, bytes);
      }
      EpubFontManager.registerMemoryFont(id, name, bytes);
      EpubFontManager.registerMemoryFont(id, key, bytes);
      fontPaths[path] = name;
      embeddedFonts[key] = name;
      return name;
    } on LocalBookArchiveCorruption {
      return null;
    }
  }
  final damagedChapters = <int, String>{};
  final leadingIllustrations = <String>[];
  final leadingIllustrationParagraphs = <String>[];
  final noteDocuments = <String, html.Document?>{};
  final anchors = <String, BookReadingTarget>{};
  final linkTargets = <String>{};
  final leadingAnchors = <String, ({int paragraph, int offset})>{};
  var leadingParagraphs = 0, lastBodyParagraphs = 0;
  var lastBodyBytes = 0;
  var currentVolume = '';
  var volumeId = 0;
  for (final item in elements.where((e) => e.name.local == 'itemref')) {
    if (item.getAttribute('linear') == 'no') continue;
    if (external.contains(item.getAttribute('idref'))) {
      throw const FormatException('EPUB 正文依赖外部资源，请选择包含完整正文的原书');
    }
    var candidate = manifest[item.getAttribute('idref')];
    if (candidate == null) {
      throw const FormatException('EPUB 的正文索引不完整，请重新获取完整原书');
    }
    const textTypes = {'application/xhtml+xml', 'text/html'};
    final fallbacks = <String>{};
    while (!textTypes.contains(candidate!.type) &&
        !rasterExtensions.containsKey(candidate.type) &&
        candidate.fallback.isNotEmpty &&
        fallbacks.add(candidate.fallback)) {
      candidate = manifest[candidate.fallback];
      if (candidate == null) {
        throw const FormatException('EPUB 的正文备用资源缺失，请重新获取完整原书');
      }
    }
    final file = candidate;
    final imagePage = rasterExtensions.containsKey(file.type);
    if (!textTypes.contains(file.type) && !imagePage) {
      throw FormatException('EPUB 正文使用暂不支持的类型：${file.type}，且没有可读取的备用内容');
    }
    late html.Document document;
    try {
      if (imagePage && addImage(file.path, required: true) == null) {
        throw const FormatException('EPUB 正文图片缺失或超过 8 MiB，请选择完整原书');
      }
      document = imagePage
          ? (html.parse('<html><body></body></html>')
              ..body!.append(
                html.Element.tag('img')
                  ..attributes['src'] = Uri(
                    pathSegments: ['', ...file.path.split('/')],
                  ).toString(),
              ))
          : parseDocument(file.path);
    } on LocalBookArchiveCorruption catch (error) {
      if (!recovery || error.path != file.path) rethrow;
      damage[file.path] = error.reason;
      final labelsForPath = labels.entries
          .where((e) => e.key.path == file.path)
          .toList();
      if (labelsForPath.isEmpty) {
        labelsForPath.add(
          MapEntry(
            (path: file.path, fragment: ''),
            (title: file.path.split('/').last, volume: currentVolume),
          ),
        );
      }
      for (final entry in labelsForPath) {
        final nextVolume = entry.value.volume.isEmpty
            ? currentVolume
            : entry.value.volume;
        if (nextVolume != currentVolume) {
          currentVolume = nextVolume;
          volumeId++;
        }
        final chapterId = chapters.length + 1;
        chapters.add(
          NovelChapter(
            '${_metadataText(entry.value.title)}（原文件损坏）',
            '',
            id: chapterId,
            volumeTitle: currentVolume,
            volumeId: volumeId,
          ),
        );
        final origin = '${file.path}#${entry.key.fragment}';
        origins.add(origin);
        anchors[origin] = BookReadingTarget(chapterId);
        anchors.putIfAbsent(
          '${file.path}#',
          () => BookReadingTarget(chapterId),
        );
        damagedChapters[chapterId] = file.path;
        if (saveBody == null) bodies.add('');
        if (saveLayout == null) layouts.add(const EpubChapterLayout());
      }
      lastBodyParagraphs = 0;
      lastBodyBytes = 0;
      continue;
    }
    String? readCss(String href) {
      try {
        final path = resolve(file.path, href);
        return files.containsKey(path) ? read(path) : null;
      } on FormatException {
        return null;
      }
    }

    final styles = epubStyleProperties(document, readCss);
    final styleRules = resolveEpubStyles(document, file.path, readCss);
    for (final entry in styles.entries) {
      final merged = <String, String>{
        ...entry.value,
        ...?styleRules.elementProps[entry.key],
      };
      if (merged.isNotEmpty) {
        styleRules.elementProps[entry.key] = merged;
      }
    }
    final imageLayouts = {
      for (final image in document.querySelectorAll('img, image'))
        image: epubImageLayout(image, styleRules.elementProps),
    };
    for (final face in styleRules.fontFaces.values) {
      try {
        final cssPath = face.baseHref == file.path
            ? file.path
            : resolve(file.path, face.baseHref);
        final fontPath = resolve(cssPath, face.href);
        addFont(face.family, fontPath);
      } on FormatException {
        /* External or malformed font URLs are ignored. */
      }
    }
    for (final a in document.querySelectorAll('a[href]')) {
      final href = a.attributes['href'];
      if (href == null) continue;
      try {
        final to = target(file.path, href);
        if (files.containsKey(to.path)) {
          linkTargets.add(targetKey(to));
        }
      } on FormatException {
        /* External links remain plain readable text. */
      }
    }
    final navColumnTargets = <String>[];
    if (document.querySelector('.content-container img') != null) {
      for (final a in document.querySelectorAll('nav ol li a[href]')) {
        final href = a.attributes['href'];
        if (href == null) continue;
        try {
          final to = target(file.path, href);
          if (!files.containsKey(to.path)) continue;
          final baseName = to.path.split('/').last.toLowerCase();
          if (baseName.startsWith('cover') ||
              baseName.startsWith('flyleaf') ||
              baseName.startsWith('ills') ||
              baseName.startsWith('nav')) {
            continue;
          }
          final key = targetKey(to);
          linkTargets.add(key);
          navColumnTargets.add('epub-link:$key');
        } on FormatException {
          /* Ignore external links. */
        }
      }
    }
    final navPath = epubNav?.path;
    final navInSpine =
        navPath != null &&
        elements.any(
          (e) =>
              e.name.local == 'itemref' &&
              e.getAttribute('linear') != 'no' &&
              manifest[e.getAttribute('idref')]?.path == navPath,
        );
    final tocTargetKey =
        navInSpine && files.containsKey(navPath) && file.path != navPath
        ? '$navPath#'
        : null;
    if (tocTargetKey != null) {
      linkTargets.add(tocTargetKey);
    }
    for (final el in document.querySelectorAll(
      'script, style, nav, noscript',
    )) {
      el.remove();
    }
    final initialLabel = labels[(path: file.path, fragment: '')];
    final boundaries = {
      for (final e in labels.entries)
        if (e.key.path == file.path && e.key.fragment.isNotEmpty)
          e.key.fragment: e.value,
    };
    final footnotes = extractEpubFootnotes(
      document,
      boundaries.keys.toSet(),
      resolveExternalFootnoteTarget: (href) {
        try {
          final to = target(file.path, href);
          if (to.fragment.isEmpty ||
              to.path == file.path ||
              !files.containsKey(to.path)) {
            return null;
          }
          if (!noteDocuments.containsKey(to.path)) {
            if (noteDocuments.length >= 6) {
              noteDocuments.remove(noteDocuments.keys.first);
            }
            try {
              noteDocuments[to.path] = parseDocument(to.path);
            } catch (_) {
              noteDocuments[to.path] = null;
            }
          }
          final extDoc = noteDocuments[to.path];
          if (extDoc == null) return null;
          for (final el in extDoc.querySelectorAll('[id], [name]')) {
            final id = el.id.isNotEmpty ? el.id : (el.attributes['name'] ?? '');
            if (id == to.fragment) return el;
          }
          return null;
        } on FormatException {
          return null;
        }
      },
    );
    var currentOrigin = '${file.path}#';
    var currentAnchors = <String, ({int paragraph, int offset})>{};
    parseEpubDocumentChapters(
      document: document,
      filePath: file.path,
      imageLayouts: imageLayouts,
      styleRules: styleRules,
      footnotes: footnotes,
      embeddedFonts: Map<String, String>.of(embeddedFonts),
      initialLabel: initialLabel,
      boundaries: boundaries,
      resolveAndAddImage: (src) {
        try {
          final path = resolve(file.path, src);
          final url = addImage(path);
          if (url == null) unavailableImages.add(path);
          return url;
        } on FormatException {
          unavailableImages.add(src);
          return null;
        }
      },
      resolveLinkTarget: (href) {
        try {
          final to = target(file.path, href);
          if (files.containsKey(to.path)) {
            final key = targetKey(to);
            linkTargets.add(key);
            return 'epub-link:$key';
          }
        } on FormatException {
          /* External links remain plain readable text. */
        }
        return null;
      },
      tocTargetKey: tocTargetKey,
      navColumnTargets: navColumnTargets,
      splitBoundedParagraphs: _boundedParagraphs,
      onChapterAnchors: (origin, chapterAnchors) {
        currentOrigin = origin;
        currentAnchors = chapterAnchors;
      },
      onChapter: (label, heading, output, rawLayout) {
        final title = label?.title.isNotEmpty == true
            ? label!.title
            : heading?.isNotEmpty == true
            ? heading!
            : autoTitles
            ? '第 ${chapters.length + 1} 章'
            : '正文片段 ${chapters.length + 1}';
        var chapterLayout = rawLayout;
        if (output.isNotEmpty && output.first == title && output.length > 1) {
          final removedText = output.removeAt(0);
          final headingStyle =
              rawLayout.blocks[0] ??
              const EpubBlockStyle(kind: EpubBlockKind.heading1);
          final headingSpans = rawLayout.spans[0] ?? const <EpubInlineSpan>[];
          chapterLayout = EpubChapterLayout(
            blocks: {
              for (final e in rawLayout.blocks.entries)
                if (e.key > 0) e.key - 1: e.value,
            },
            spans: {
              for (final e in rawLayout.spans.entries)
                if (e.key > 0) e.key - 1: e.value,
            },
            footnotes: rawLayout.footnotes,
            leadingHeading: EpubHeadingBlock(
              text: removedText,
              style: headingStyle.isHeading
                  ? headingStyle
                  : headingStyle.copyWith(kind: EpubBlockKind.heading1),
              spans: headingSpans,
            ),
            bodyFontFamily: rawLayout.bodyFontFamily,
            embeddedFonts: rawLayout.embeddedFonts,
          );
          for (final key in currentAnchors.keys.toList()) {
            final at = currentAnchors[key]!;
            currentAnchors[key] = (
              paragraph: max(0, at.paragraph - 1),
              offset: at.paragraph == 0 ? 0 : at.offset,
            );
          }
        }
        final unlistedIllustration =
            mergeUnlistedIllustrations &&
            !damagedChapters.containsKey(chapters.lastOrNull?.id) &&
            label?.title.isNotEmpty != true &&
            heading?.isNotEmpty != true &&
            output.isNotEmpty &&
            output.every((p) => readerIllustrationUrl(p) != null);
        final count = output.length;
        final plainBody = output.join('\n\n');
        if (plainBody.isEmpty) {
          currentAnchors.clear();
          return;
        }
        void place(int chapterId, int base) {
          for (final entry in currentAnchors.entries) {
            if (anchors.length < 50000) {
              anchors.putIfAbsent(
                entry.key,
                () => BookReadingTarget(
                  chapterId,
                  paragraph:
                      base + entry.value.paragraph.clamp(0, max(0, count - 1)),
                  offset: entry.value.offset,
                ),
              );
            }
          }
          currentAnchors.clear();
        }

        if (unlistedIllustration) {
          if (chapters.isEmpty) {
            leadingIllustrations.add(plainBody);
            leadingIllustrationParagraphs.addAll(output);
            for (final e in currentAnchors.entries) {
              leadingAnchors[e.key] = (
                paragraph: leadingParagraphs + e.value.paragraph,
                offset: e.value.offset,
              );
            }
            leadingParagraphs += count;
            currentAnchors.clear();
          } else {
            place(chapters.last.id, lastBodyParagraphs);
            lastBodyParagraphs += count;
            lastBodyBytes += utf8.encode(plainBody).length + 2;
            if (lastBodyBytes > 8 * 1024 * 1024) {
              throw const FormatException('EPUB 单章超过 8 MB');
            }
            if (saveBody == null) {
              bodies[bodies.length - 1] += '\n\n$plainBody';
              if (layouts.isNotEmpty) {
                EpubLayoutRegistry.register(bodies.last, layouts.last);
              }
            } else {
              appendBody!(chapters.length, '\n\n$plainBody');
            }
          }
          return;
        }
        final allOutput = <String>[
          ...leadingIllustrationParagraphs,
          ...output,
        ];
        if (leadingIllustrations.isNotEmpty) {
          leadingIllustrations.clear();
          leadingIllustrationParagraphs.clear();
          if (leadingParagraphs > 0) {
            chapterLayout = EpubChapterLayout(
              blocks: {
                for (var i = 0; i < leadingParagraphs; i++)
                  i: const EpubBlockStyle(
                    kind: EpubBlockKind.fullPageImage,
                    pageBreakBefore: true,
                    pageBreakAfter: true,
                  ),
                for (final e in chapterLayout.blocks.entries)
                  e.key + leadingParagraphs: e.value,
              },
              spans: {
                for (final e in chapterLayout.spans.entries)
                  e.key + leadingParagraphs: e.value,
              },
              footnotes: chapterLayout.footnotes,
              leadingHeading: chapterLayout.leadingHeading,
              bodyFontFamily: chapterLayout.bodyFontFamily,
              embeddedFonts: chapterLayout.embeddedFonts,
            );
          }
        }
        final formats = <int, ReaderRichParagraph>{};
        final chapterNotes = <String, String>{
          for (final fn in chapterLayout.footnotes.values) fn.id: fn.content,
        };
        for (var idx = 0; idx < allOutput.length; idx++) {
          final paraText = allOutput[idx];
          final blockStyle = chapterLayout.blocks[idx];
          final inlineSpans = chapterLayout.spans[idx];
          final align = switch (blockStyle?.textAlign) {
            TextAlign.center => 'center',
            TextAlign.right || TextAlign.end => 'right',
            TextAlign.left || TextAlign.start => 'left',
            TextAlign.justify => 'justify',
            _ => '',
          };
          final rule =
              blockStyle?.kind == EpubBlockKind.hr || paraText == '───';
          final breakBefore = blockStyle?.pageBreakBefore ?? false;
          final breakAfter = blockStyle?.pageBreakAfter ?? false;
          final isTightStyledBlock =
              blockStyle != null &&
              (blockStyle.isHeading ||
                  blockStyle.fontScale != null ||
                  blockStyle.textIndentEm == 0 ||
                  blockStyle.textAlign == TextAlign.center ||
                  blockStyle.textAlign == TextAlign.end ||
                  blockStyle.hasBoxDecoration);
          final spacing = blockStyle == null
              ? const ReaderBlockSpacing()
              : ReaderBlockSpacing(
                  before: [
                    if (blockStyle.marginTopEm > 0)
                      '${blockStyle.marginTopEm}em',
                    if (blockStyle.relativeInsets['margin-top']
                        case final value?)
                      '${value * 100}%',
                    if (blockStyle.marginTopEm == 0 &&
                        !blockStyle.relativeInsets.containsKey('margin-top') &&
                        isTightStyledBlock)
                      '0em',
                  ],
                  after: [
                    if (blockStyle.marginBottomEm > 0)
                      '${blockStyle.marginBottomEm}em',
                    if (blockStyle.relativeInsets['margin-bottom']
                        case final value?)
                      '${value * 100}%',
                    if (blockStyle.marginBottomEm == 0 &&
                        !blockStyle.relativeInsets.containsKey(
                          'margin-bottom',
                        ) &&
                        isTightStyledBlock)
                      '0em',
                  ],
                  leading: blockStyle.blankLinesEm > 0
                      ? ['${blockStyle.blankLinesEm}em']
                      : const [],
                );
          final emphasis = <ReaderEmphasis>[];
          final ruby = <ReaderRuby>[];
          final refs = <ReaderNoteReference>[];
          if (blockStyle?.isHeading == true && paraText.isNotEmpty) {
            emphasis.add(ReaderEmphasis(0, paraText.length, 1));
          }
          if (inlineSpans != null) {
            for (final s in inlineSpans) {
              final start = s.start.clamp(0, paraText.length);
              final end = s.end.clamp(start, paraText.length);
              if (end <= start) continue;
              var mask = 0;
              if (s.bold) mask |= 1;
              if (s.italic) mask |= 2;
              if (s.underline && s.underlineOffsetEm == null || s.strike) mask |= 4;
              if (mask != 0) emphasis.add(ReaderEmphasis(start, end, mask));
              if (s.rubyText != null && s.rubyText!.isNotEmpty) {
                ruby.add(ReaderRuby(start, end, s.rubyText!));
              }
              if (s.footnoteId != null && s.footnoteId!.isNotEmpty) {
                refs.add(ReaderNoteReference(start, end, s.footnoteId!));
              }
            }
          }
          final fmt = ReaderRichParagraph(
            alignment: align,
            rule: rule,
            breakBefore: breakBefore,
            breakAfter: breakAfter,
            spacing: spacing,
            emphasis: emphasis,
            ruby: ruby,
            references: refs,
          );
          if (!fmt.empty) {
            formats[idx] = fmt;
          }
        }
        var body = preserveRichText
            ? ReaderRichBody(
                allOutput,
                formats: formats,
                notes: chapterNotes,
                revision: 'epub-rich-v$richLayoutLevel',
                epubLayout: chapterLayout.isEmpty ? null : chapterLayout,
              ).encode()
            : allOutput.join('\n\n');
        for (final e in leadingAnchors.entries) {
          anchors[e.key] = BookReadingTarget(
            chapters.length + 1,
            paragraph: e.value.paragraph,
            offset: e.value.offset,
          );
        }
        leadingAnchors.clear();
        place(chapters.length + 1, leadingParagraphs);
        lastBodyParagraphs = leadingParagraphs + count;
        leadingParagraphs = 0;
        lastBodyBytes = utf8.encode(body).length;
        if (lastBodyBytes > 8 * 1024 * 1024) {
          throw const FormatException('EPUB 单章超过 8 MB');
        }
        final nextVolume = label?.volume ?? currentVolume;
        if (nextVolume != currentVolume) {
          currentVolume = nextVolume;
          volumeId++;
        }
        chapters.add(
          NovelChapter(
            _metadataText(title),
            '',
            id: chapters.length + 1,
            volumeTitle: currentVolume,
            volumeId: volumeId,
          ),
        );
        origins.add(currentOrigin);
        EpubLayoutRegistry.register(body, chapterLayout);
        if (saveBody == null) {
          bodies.add(body);
        } else {
          saveBody(chapters.length, body);
        }
        if (saveLayout == null) {
          layouts.add(chapterLayout);
        } else {
          saveLayout(chapters.length, chapterLayout);
        }
      },
    );
  }
  if (chapters.isEmpty && leadingIllustrations.isNotEmpty) {
    final body = leadingIllustrations.join('\n\n');
    chapters.add(const NovelChapter('插图', '', id: 1));
    origins.add('illustrations-only');
    for (final e in leadingAnchors.entries) {
      anchors[e.key] = BookReadingTarget(
        1,
        paragraph: e.value.paragraph,
        offset: e.value.offset,
      );
    }
    if (saveBody == null) {
      bodies.add(body);
    } else {
      saveBody(1, body);
    }
    if (saveLayout == null) {
      layouts.add(const EpubChapterLayout());
    } else {
      saveLayout(1, const EpubChapterLayout());
    }
  }
  if (chapters.isEmpty) throw const FormatException('EPUB 未找到可阅读的正文');
  if (damagedChapters.length == chapters.length) {
    throw const FormatException('EPUB 没有可恢复的完整正文，请重新获取原书');
  }
  if (unavailableImages.isNotEmpty) {
    warnings.add(
      '原书有 ${unavailableImages.length} 张图片缺失、超过大小限制或暂不支持，其余正文和原书文件已保留。',
    );
  }
  final title = field('title');
  final preferredNcx =
      manifest[elements
          .where((e) => e.name.local == 'spine')
          .firstOrNull
          ?.getAttribute('toc')];
  final authored =
      readEpubNavigation(
            navPath: manifest.values
                .where((e) => hasEpubToken(e.props, 'nav'))
                .firstOrNull
                ?.path,
            ncxPath: preferredNcx?.type == 'application/x-dtbncx+xml'
                ? preferredNcx!.path
                : ncx?.path,
            read: read,
            resolve: target,
            contains: (path) =>
                files.containsKey(path) || damage.containsKey(path),
            warnings: warnings,
            normalizeMarkup:
                normalizeMarkup && !htmlPaths.contains(epubNav?.path),
          )
          .where((entry) {
            // A TOC's own top-level "#" link is not missing prose. Keep it only when
            // that NAV document actually produced a reading destination.
            return entry.key != '${epubNav?.path}#' ||
                anchors.containsKey(entry.key);
          })
          .toList(growable: false);
  final wantedTargets = {...linkTargets, ...authored.map((e) => e.key)};
  // Some EPUB generators retain stale NCX fragments after splitting HTML.
  // Keep exact anchors first. A TOC entry may fall back only to its own
  // document's real reading start, never another spine item or an invented ID.
  final navigationFallbacks = <String, BookReadingTarget>{
    for (final entry in authored)
      if (!anchors.containsKey(entry.key) && entry.key != entry.documentKey)
        entry.key: ?anchors[entry.documentKey],
  };
  final navigation = BookNavigation(
    [
      for (final e in authored)
        if (anchors[e.key] ?? navigationFallbacks[e.key] case final at?)
          BookNavigationEntry(
            damagedChapters.containsKey(at.chapterId)
                ? '${e.title}（原文件损坏）'
                : e.title,
            at,
            depth: e.depth,
          ),
    ],
    targets: Map.unmodifiable({
      for (final e in anchors.entries)
        if (wantedTargets.contains(e.key)) e.key: e.value,
      ...navigationFallbacks,
    }),
  );
  if (navigationFallbacks.isNotEmpty) {
    warnings.add('原书有 ${navigationFallbacks.length} 个目录定位标记无法精确定位，已转到对应文档开头。');
  }
  if (navigation.entries.length < authored.length) {
    warnings.add(
      '原书有 ${authored.length - navigation.entries.length} 个目录目标暂未解析，其他目录和正文仍可阅读。',
    );
  }
  if (recovery && damage.isNotEmpty) {
    warnings.add(
      '已导入可读部分：${damagedChapters.length} 个章节无法读取，已发现 ${damage.length} 处资源问题。损坏章节保留在原书顺序中，请重新获取完整原件；新文件内容不同会作为新书导入，不会猜测合并进度与书签。',
    );
  }
  String meta(String name) =>
      elements
          .where(
            (e) =>
                e.name.local == 'meta' &&
                (e.getAttribute('name') == name ||
                    e.getAttribute('property') == name),
          )
          .map((e) => e.getAttribute('content') ?? e.innerText.trim())
          .firstOrNull ??
      '';
  final collection = meta('calibre:series').isNotEmpty
      ? meta('calibre:series')
      : meta('belongs-to-collection');
  final collectionNumber = double.tryParse(
    meta('calibre:series_index').isNotEmpty
        ? meta('calibre:series_index')
        : meta('group-position'),
  );
  return ImportedBook(
    _novel(
      id,
      title.isEmpty
          ? input.name.replaceFirst(
              RegExp(r'\.epub$', caseSensitive: false),
              '',
            )
          : title,
      field('creator'),
      chapters,
      cover: coverUrl,
      navigation: navigation,
      summary: damage.isEmpty
          ? '已保存到本地书库，可离线阅读。'
          : '已导入可读部分，${damagedChapters.length} 个章节无法读取，已发现 ${damage.length} 处资源问题。原文件未改动，请重新获取完整原件。',
    ),
    digest,
    bodies,
    images,
    layouts: layouts,
    fonts: fonts,
    warnings: List.unmodifiable(warnings),
    origins: List.unmodifiable(origins),
    damagedResources: Map.unmodifiable(damage),
    damagedChapters: Map.unmodifiable(damagedChapters),
    seriesHint:
        collection.isNotEmpty &&
            collectionNumber != null &&
            collectionNumber.isFinite &&
            collectionNumber > 0
        ? LocalSeriesHint(_metadataText(collection), collectionNumber)
        : inferLocalSeries(title) ?? inferLocalSeries(input.name),
  );
}

class _ImportJob {
  const _ImportJob({
    required this.root,
    required this.name,
    required this.known,
    this.input,
    this.path,
    this.text,
    this.decodedPath,
    this.options = const LocalImportOptions(),
    this.optionsById = const {},
    this.epubLayouts = const {},
    this.preserveDirectory = false,
    this.linkedOriginal,
    this.document,
    this.freshOriginal = false,
    this.recoverDamagedEpub = false,
    this.knownIncomplete = const {},
  });
  final String root, name;
  final Map<int, String> known;
  final LocalBookInput? input;
  final String? path, text, decodedPath;
  final LocalImportOptions options;
  final Map<int, LocalImportOptions> optionsById;
  final Map<int, bool> epubLayouts;
  final bool preserveDirectory;
  final Map<String, dynamic>? linkedOriginal;
  final LocalDocumentInput? document;
  final bool freshOriginal;
  final bool recoverDamagedEpub;
  final Set<int> knownIncomplete;
}

class _ImportedFile {
  const _ImportedFile(this.id, this.digest, [this.novel, this.source]);
  final int id;
  final String digest;
  final Novel? novel;
  final Map<String, dynamic>? source;
}

/// Originals and image indices stay on disk. Only the chapter directory comes
/// back across the port; illustrations are read on demand from the EPUB.
Future<_ImportedFile> _importOriginal(_ImportJob job) async {
  final file = job.path == null ? null : File(job.path!);
  final document =
      job.document ??
      (file == null ? null : LocalDocumentInput.file(file.path));
  final size = job.input?.bytes.length ?? document!.length;
  _validateInput(job.name, size);
  final digest = job.input == null
      ? (await sha256.bind(document!.bytes()).first).toString()
      : sha256.convert(job.input!.bytes).toString();
  final id =
      localBookIdStart |
      (int.parse(digest.substring(0, 8), radix: 16) & 0x1fffffff);
  final suppliedOptions = (job.optionsById[id] ?? job.options).effective;
  final isEpub = job.name.toLowerCase().endsWith('.epub');
  final isText = job.name.toLowerCase().endsWith('.txt');
  final direct = job.linkedOriginal?['direct'] == true;
  if (direct && !job.freshOriginal && job.linkedOriginal!['digest'] != digest) {
    throw const FormatException('原文件已变化，请重新选择原文件');
  }
  if (isEpub &&
      job.preserveDirectory &&
      job.epubLayouts.containsKey(id) &&
      job.epubLayouts[id] != suppliedOptions.inlineEpubImages) {
    throw const FormatException('这本书与已保存阅读记录的目录不同，请先统一两端目录');
  }
  // New manual imports use the refined EPUB directory. Restore/sync honors
  // the source book's stored layout, including old bundles with no options.
  final options = isEpub && !job.preserveDirectory
      ? suppliedOptions.withEpubImageLayout(
          job.epubLayouts[id] ??
              (job.optionsById.containsKey(id)
                  ? suppliedOptions.inlineEpubImages
                  : true),
        )
      : suppliedOptions;
  if (job.known[id] case final previous?) {
    if (previous != digest) {
      throw const FormatException('本地书籍标识冲突，原书已保留');
    }
    if (!job.recoverDamagedEpub && job.knownIncomplete.contains(id)) {
      throw const FormatException('书库中仅保存了这本书的可读部分，不能作为完整原书同步或恢复；请重新获取完整原件');
    }
    return _ImportedFile(id, digest);
  }
  final staging = Directory('${job.root}/.$id-import');
  if (await staging.exists()) await staging.delete(recursive: true);
  await staging.create(recursive: true);
  LocalDocumentBuffer? buffer;
  try {
    final media = <String, String>{};
    late ImportedBook parsed;
    if (isEpub) {
      buffer = document?.open();
      final verifiedImages = <String>{};
      final stream = buffer?.stream ?? InputMemoryStream(job.input!.bytes);
      final recovered = job.recoverDamagedEpub
          ? readLocalBookArchiveForRecovery(stream, maxSize: 1024 * 1024 * 1024)
          : null;
      parsed = _epub(
        LocalBookInput(job.name, Uint8List(0)),
        id,
        digest,
        archive:
            recovered?.archive ??
            readLocalBookArchive(stream, maxSize: 1024 * 1024 * 1024),
        damagedEntries: recovered?.damagedEntries,
        autoTitles: options.autoTitles,
        mergeUnlistedIllustrations: options.inlineEpubImages,
        verifyImage: (image) {
          // Covers may already have been consumed before the spine reaches the
          // same image. Retain only verification state, not expanded images.
          if (!verifiedImages.contains(image.name)) {
            readLocalBookArchiveEntry(image);
            verifiedImages.add(image.name);
          }
        },
        saveBody: (index, body) =>
            File('${staging.path}/c$index.txt').writeAsStringSync(body),
        appendBody: (index, body) => File(
          '${staging.path}/c$index.txt',
        ).writeAsStringSync(body, mode: FileMode.append),
        saveImage: (name, image) {
          media[name] = image.name;
          // Covers remain immediately readable for large book lists. All other
          // illustrations retain their original bytes in the single EPUB copy.
          if (name.startsWith('cover.')) {
            final bytes = readLocalBookArchiveEntry(image);
            verifiedImages.add(image.name);
            File('${staging.path}/$name').writeAsBytesSync(bytes);
          }
        },
        saveFont: (name, bytes) =>
            File('${staging.path}/$name').writeAsBytesSync(bytes),
        saveLayout: (index, layout) {
          if (!layout.isEmpty) {
            File(
              '${staging.path}/c$index.layout.json',
            ).writeAsStringSync(jsonEncode(layout.toJson()));
          }
        },
      );
    } else if (isText &&
        (options.customToc || file != null && job.text == null)) {
      final suppliedText = job.input?.text ?? job.text;
      late File textFile;
      if (suppliedText != null || file == null) {
        textFile = await File(
          '${staging.path}/.directory-source.txt',
        ).writeAsString(suppliedText ?? utf8.decode(job.input!.bytes));
      } else {
        textFile = File(job.decodedPath ?? file.path);
      }
      final chapters = await importTextChapters(
        textFile,
        job.name,
        (index, body) =>
            writeCompressedLocalText(File('${staging.path}/c$index.txt'), body),
        options: options,
      );
      if (textFile.path.startsWith('${staging.path}/')) await textFile.delete();
      parsed = ImportedBook(
        _novel(
          id,
          job.name
              .replaceAll('\\', '/')
              .split('/')
              .last
              .replaceFirst(RegExp(r'\.txt$', caseSensitive: false), ''),
          '',
          chapters,
        ),
        digest,
        const [],
        const {},
      );
    } else {
      parsed = parseLocalBook(
        job.input ??
            LocalBookInput(job.name, await file!.readAsBytes(), text: job.text),
        autoTitles: options.autoTitles,
        inlineEpubImages: options.inlineEpubImages,
      );
    }
    final text = job.input?.text ?? job.text;
    final source = <String, dynamic>{
      'name': job.name,
      'digest': digest,
      if (parsed.damagedResources.isNotEmpty)
        'epubImportIssues': [
          for (final entry in parsed.damagedResources.entries)
            {
              'path': entry.key,
              'reason': entry.value,
              'kind': parsed.damagedChapters.containsValue(entry.key)
                  ? 'chapter'
                  : RegExp(
                      r'\.(png|jpe?g|gif|webp)$',
                      caseSensitive: false,
                    ).hasMatch(entry.key)
                  ? 'image'
                  : 'resource',
              'chapterIds': [
                for (final chapter in parsed.damagedChapters.entries)
                  if (chapter.value == entry.key) chapter.key,
              ],
            },
        ],
      'encoding': text == null && job.decodedPath == null ? 'utf8' : 'decoded',
      'parser': options.inlineEpubImages ? 3 : 2,
      'imageSizing': 1,
      if (isEpub) 'richLayout': 12,
      if (isEpub) 'richText': 2,
      if (isEpub) 'epubNavigation': 1,
      if (isEpub) 'publisherSpacing': 1,
      if (isEpub) 'publisherLanguages': epubPublisherLanguageVersion,
      if (isEpub) 'epubMarkup': epubMarkupVersion,
      'importedAt': DateTime.now().millisecondsSinceEpoch,
      if (!options.isDefault) 'importOptions': options.toJson(),
      if (parsed.seriesHint != null) 'seriesHint': parsed.seriesHint!.toJson(),
      if (parsed.warnings.isNotEmpty) 'importWarnings': parsed.warnings,
      if (job.linkedOriginal != null)
        'linkedOriginal': {
          ...job.linkedOriginal!,
          if (job.freshOriginal) 'digest': digest,
        },
    };
    if (direct) {
      // The live descriptor belongs to the importer; no original is copied.
    } else if (file == null) {
      await File(
        '${staging.path}/original',
      ).writeAsBytes(job.input!.bytes, flush: true);
    } else {
      await file.copy('${staging.path}/original');
    }
    if (text != null) {
      writeCompressedLocalText(File('${staging.path}/decoded.txt'), text);
    } else if (job.decodedPath != null) {
      final decoded = File(job.decodedPath!);
      final original = File('${staging.path}/original');
      if (await original.length() == await decoded.length() &&
          await sameLocalTextBytes(original.openRead(), decoded.openRead())) {
        source['encoding'] = 'utf8';
      } else {
        await decoded
            .openRead()
            .transform(gzip.encoder)
            .pipe(File('${staging.path}/decoded.txt.gz').openWrite());
      }
    }
    for (var i = 0; i < parsed.bodies.length; i++) {
      final body = File('${staging.path}/c${i + 1}.txt');
      if (isText) {
        writeCompressedLocalText(body, parsed.bodies[i]);
      } else {
        body.writeAsStringSync(parsed.bodies[i]);
      }
    }
    for (var i = 0; i < parsed.layouts.length; i++) {
      if (!parsed.layouts[i].isEmpty) {
        File(
          '${staging.path}/c${i + 1}.layout.json',
        ).writeAsStringSync(jsonEncode(parsed.layouts[i].toJson()));
      }
    }
    for (final image in parsed.images.entries) {
      File('${staging.path}/${image.key}').writeAsBytesSync(image.value);
    }
    for (final font in parsed.fonts.entries) {
      File('${staging.path}/${font.key}').writeAsBytesSync(font.value);
    }
    if (job.linkedOriginal != null) {
      for (final chapter in parsed.novel.chapters) {
        final body = File('${staging.path}/c${chapter.id}.txt');
        if (await body.exists()) await compactLocalText(body);
      }
    }
    if (media.isNotEmpty) {
      final index = jsonEncode({
        'version': 1,
        'entries': media,
        if (parsed.damagedResources.isNotEmpty) 'recoverDamagedEpub': true,
      });
      if (utf8.encode(index).length > 1024 * 1024) {
        throw const FormatException('本地插图索引过大');
      }
      await File(
        '${staging.path}/media.json',
      ).writeAsString(index, flush: true);
    }
    final metadata = jsonEncode({
      'version': 1,
      'novel': parsed.novel.toSnapshot(),
      'source': source,
      'chapters': [
        for (final c in parsed.novel.chapters)
          {
            'id': c.id,
            'title': c.title,
            'volumeId': c.volumeId,
            'volumeTitle': c.volumeTitle,
          },
      ],
    });
    if (utf8.encode(metadata).length > 4 * 1024 * 1024) {
      throw const FormatException('书籍目录过大，请拆分原书后导入');
    }
    await File(
      '${staging.path}/book.json',
    ).writeAsString(metadata, flush: true);
    await staging.rename('${job.root}/$id');
    return _ImportedFile(id, digest, parsed.novel, source);
  } on ArchiveException {
    throw const FormatException('EPUB 压缩文件损坏，请重新下载原书');
  } finally {
    buffer?.close();
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}

class _ImageSizingJob {
  const _ImageSizingJob(
    this.root,
    this.name,
    this.id,
    this.digest,
    this.inlineEpubImages, [
    this.original,
  ]);
  final String root, name, digest;
  final int id;
  final bool inlineEpubImages;
  final LocalDocumentInput? original;
}

class _RichLayoutUpgradeData {
  const _RichLayoutUpgradeData(
    this.bodies,
    this.layouts,
    this.fonts,
    this.mediaEntries,
    this.navigation,
  );
  final List<String> bodies;
  final List<EpubChapterLayout> layouts;
  final Map<String, Uint8List> fonts;
  final Map<String, String> mediaEntries;
  final BookNavigation? navigation;
}

List<String> _readImageSizing(_ImageSizingJob job) {
  final stream = InputFileStream('${job.root}/${job.id}/original');
  try {
    return _epub(
      LocalBookInput(job.name, Uint8List(0)),
      job.id,
      job.digest,
      archive: readLocalBookArchive(stream, maxSize: 512 * 1024 * 1024),
      saveImage: (_, _) {},
      // Keep the stored directory layout and bookmark offsets; this migration
      // changes image sizing only.
      mergeUnlistedIllustrations: job.inlineEpubImages,
      preserveRichText: false,
    ).bodies;
  } finally {
    stream.closeSync();
  }
}

_RichLayoutUpgradeData _readRichLayout(_ImageSizingJob job) {
  final folder = '${job.root}/${job.id}';
  final mediaFile = File('$folder/media.json');
  final mediaEntries = <String, String>{};
  if (mediaFile.existsSync()) {
    try {
      final raw = jsonDecode(mediaFile.readAsStringSync());
      if (raw is Map && raw['entries'] is Map) {
        for (final entry in (raw['entries'] as Map).entries) {
          if (entry.key is String && entry.value is String) {
            mediaEntries[entry.key as String] = entry.value as String;
          }
        }
      }
    } catch (_) {
      /* Proceed with fresh media discovery if media.json is unreadable. */
    }
  }
  final imageNames = {
    for (final e in mediaEntries.entries) e.value: e.key,
  };
  final buffer = job.original?.open();
  final stream =
      buffer?.stream ?? InputFileStream('$folder/original');
  try {
    final parsed = _epub(
      LocalBookInput(job.name, Uint8List(0)),
      job.id,
      job.digest,
      archive: readLocalBookArchive(stream, maxSize: 512 * 1024 * 1024),
      imageNames: imageNames,
      saveImage: (name, file) => mediaEntries[name] = file.name,
      mergeUnlistedIllustrations: job.inlineEpubImages,
    );
    return _RichLayoutUpgradeData(
      parsed.bodies,
      parsed.layouts,
      parsed.fonts,
      mediaEntries,
      parsed.novel.navigation,
    );
  } finally {
    if (buffer != null) {
      buffer.close();
    } else {
      stream.closeSync();
    }
  }
}

class _LocalLibrarySnapshot {
  const _LocalLibrarySnapshot(
    this.books,
    this.sources,
    this.series,
    this.seriesError, {
    this.covers = const {},
    this.coverError,
    this.epubLayouts = const {},
    this.epubLayoutError,
  });
  final Map<int, Novel> books;
  final Map<int, Map<String, dynamic>> sources;
  final Map<int, LocalBookSeries> series;
  final String? seriesError;
  final Map<int, String> covers;
  final String? coverError;
  final Map<int, bool> epubLayouts;
  final String? epubLayoutError;
}

// Metadata can contain thousands of chapters per book. Read, decode and build
// those directories together off the UI isolate; do not ship JSON back for the
// first visible frame to parse. Originals and chapter bodies are never opened.
Future<_LocalLibrarySnapshot> _loadLocalLibrary(String path) async {
  final directory = Directory(path);
  await directory.create(recursive: true);
  final books = <int, Novel>{};
  final sources = <int, Map<String, dynamic>>{};
  await for (final entity in directory.list()) {
    if (entity is! Directory) continue;
    final id = int.tryParse(
      entity.uri.pathSegments.where((p) => p.isNotEmpty).last,
    );
    if (id == null || !isLocalBook(id)) continue;
    try {
      final metadata = File('${entity.path}/book.json');
      if (await metadata.length() > 4 * 1024 * 1024) continue;
      final map =
          jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
      final novel = Novel.fromSnapshot(Map<String, dynamic>.from(map['novel']));
      if (novel.id != id) continue;
      final chapters = (map['chapters'] as List)
          .map(
            (c) => NovelChapter(
              c['title'],
              '',
              id: c['id'],
              volumeId: c['volumeId'] ?? 0,
              volumeTitle: c['volumeTitle'] ?? '',
            ),
          )
          .toList();
      if (chapters.isEmpty || chapters.any((c) => c.id <= 0)) continue;
      final source = Map<String, dynamic>.from(map['source']);
      books[id] = novel.withChapters(chapters);
      sources[id] = source;
    } catch (_) {
      /* An interrupted staged import is never shown as a book. */
    }
  }
  final series = <int, LocalBookSeries>{};
  String? seriesError;
  final seriesFile = File('${directory.path}/series.json');
  if (await seriesFile.exists()) {
    try {
      if (await seriesFile.length() > 4 * 1024 * 1024) {
        throw const FormatException('分卷记录过大');
      }
      for (final entry in decodeLocalSeries(
        jsonDecode(await seriesFile.readAsString()),
      )) {
        series[entry.id] = entry;
      }
    } catch (_) {
      seriesError = '分卷记录读取失败，独立原书仍可阅读，请恢复同步副本';
    }
  }
  var covers = <int, String>{};
  String? coverError;
  try {
    covers = await _loadLocalCovers(path);
  } catch (_) {
    coverError = '自定义封面记录读取失败，原书封面与正文仍保留';
  }
  var epubLayouts = <int, bool>{};
  String? epubLayoutError;
  try {
    final file = File('$path/epub-layouts.json');
    if (await file.exists()) {
      if (await file.length() > 1024 * 1024) {
        throw const FormatException('目录兼容记录过大');
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map || raw.length > 10000) {
        throw const FormatException('目录兼容记录格式有误');
      }
      for (final entry in raw.entries) {
        final id = int.tryParse('${entry.key}');
        if (id == null ||
            !isLocalBook(id) ||
            id > 0x7fffffff ||
            entry.value is! bool) {
          throw const FormatException('目录兼容记录格式有误');
        }
        epubLayouts[id] = entry.value;
      }
    }
  } catch (_) {
    epubLayouts = {};
    epubLayoutError = '已保存的 EPUB 目录记录读取失败；现有原书仍可阅读，已停止重新导入以保护阅读位置';
  }
  return _LocalLibrarySnapshot(
    books,
    sources,
    series,
    seriesError,
    covers: covers,
    coverError: coverError,
    epubLayouts: epubLayouts,
    epubLayoutError: epubLayoutError,
  );
}

Future<Map<int, String>> _loadLocalCovers(String path) async {
  final file = File('$path/covers.json');
  if (!await file.exists()) return {};
  if (await file.length() > 1024 * 1024) throw const FormatException('封面记录过大');
  final value = jsonDecode(await file.readAsString());
  if (value is! Map || value.length > 10000) {
    throw const FormatException('封面记录有误');
  }
  final records = <int, String>{};
  for (final entry in value.entries) {
    final id = int.tryParse('${entry.key}');
    if (id == null ||
        id < localBookIdStart ||
        id > 0x7fffffff ||
        entry.value is! String ||
        !RegExp(r'^cover-custom-[0-9]+\.png$').hasMatch(entry.value)) {
      throw const FormatException('封面记录有误');
    }
    if (await File('$path/$id/${entry.value}').exists()) {
      records[id] = entry.value;
    }
  }
  return records;
}

/// Durable originals are separate from disposable network caches.
class LocalBookStore extends ChangeNotifier
    implements LocalBookImportWarningAccess {
  LocalBookStore(
    this.directory, {
    LocalTextAccess? textAccess,
    LocalDocumentAccess? documentAccess,
  }) : textAccess = textAccess ?? PlatformLocalTextAccess(),
       documentAccess = documentAccess ?? PlatformLocalDocumentAccess();
  final Directory directory;
  final LocalTextAccess textAccess;
  final LocalDocumentAccess documentAccess;
  final Map<int, LocalTextIndex> _linkedIndices = {};
  final Map<int, Novel> _books = {};
  final Map<int, Map<String, dynamic>> _sources = {};
  final Map<int, bool> _epubLayouts = {};
  String? _epubLayoutError;
  final Map<int, LocalBookSeries> _series = {};
  final Map<int, Novel> _seriesBooks = {};
  final Map<int, Map<int, ({int bookId, int chapterId})>> _seriesChapters = {};
  final Map<int, String?> _seriesCovers = {};
  final Map<int, String> _coverOverrides = {};
  final Map<int, ({Novel source, String url, Novel result})> _coveredBooks = {};
  String? coverError;
  String? seriesError;
  Future<void> _writes = Future.value();
  final _imageUpgrades = <int, Future<void>>{};
  final _layoutUpgrades = <int, Future<void>>{};
  bool _disposed = false;
  List<Novel>? _visibleBooks;
  @override
  void notifyListeners() {
    _visibleBooks = null;
    super.notifyListeners();
  }

  List<Novel> get books {
    if (_visibleBooks case final snapshot?) return snapshot;
    final members = <int>{
      for (final id in _seriesBooks.keys)
        ..._series[id]!.volumes.map((v) => v.bookId),
    };
    return _visibleBooks = List.unmodifiable([
      ..._books.values.where((b) => !members.contains(b.id)).map(_withCover),
      ..._seriesBooks.values.map(_withCover),
    ]);
  }

  List<Novel> get originals => List.unmodifiable(_books.values.map(_withCover));
  String? readingIdentity(int id) {
    if (_sources[id] case final source? when source['digest'] is String) {
      // Match both the original and its directory interpretation. The same
      // file imported with different TXT rules is not the same anchor space.
      final structure = jsonEncode([
        source['digest'],
        importOptionsFor(id).effective.toJson()..remove('autoTitles'),
        source['parser'] ?? 1,
        source['richText'] ?? 0,
      ]);
      return 'local:${sha256.convert(utf8.encode(structure))}';
    }
    final series = _series[id];
    if (series == null) return null;
    final parts = [for (final v in series.volumes) readingIdentity(v.bookId)];
    return parts.any((p) => p == null) ? null : 'series:${parts.join('|')}';
  }

  List<LocalBookSeries> get series =>
      List.unmodifiable(_seriesBooks.keys.map((id) => _series[id]!));
  List<LocalBookSeries> get seriesDefinitions =>
      List.unmodifiable(_series.values);

  /// A dissolved series still maps stale cloud positions to the original
  /// volumes. Its chapter map is retained, but it is not a visible book.
  Novel? seriesSnapshot(int id) {
    if (_seriesBooks[id] case final current?) return current;
    final series = _series[id];
    if (series == null ||
        series.volumes.any(
          (v) => _books[v.bookId]?.chapters.length != v.chapterIds.length,
        )) {
      return null;
    }
    final first = _books[series.volumes.first.bookId]!;
    return Novel.fromSnapshot({
      ...first.toSnapshot(),
      'id': id,
      'title': series.title,
      'author': series.author,
      'summary': series.summary,
      'genre': localBookGenre(series.tags ?? const [], series: true),
      'coverUrl': null,
      'navigation': _seriesNavigation(series)?.toJson(),
    }).withChapters([
      for (final volume in series.volumes)
        for (final (i, chapter) in _books[volume.bookId]!.chapters.indexed)
          NovelChapter(
            chapter.title,
            '',
            id: volume.chapterIds[i],
            volumeId: volume.bookId,
            volumeTitle: volume.title,
          ),
    ]);
  }

  LocalBookSeries? seriesFor(int id) {
    if (_seriesBooks.containsKey(id)) return _series[id];
    return series
        .where((s) => s.volumes.any((v) => v.bookId == id))
        .firstOrNull;
  }

  Novel? book(int id) {
    final value = _seriesBooks[id] ?? _books[id];
    return value == null ? null : _withCover(value);
  }

  Novel _withCover(Novel source) {
    final name = _coverOverrides[source.id];
    if (name == null) return source;
    final url = 'wenku-local://${source.id}/$name';
    final cached = _coveredBooks[source.id];
    if (identical(cached?.source, source) && cached?.url == url) {
      return cached!.result;
    }
    final result = Novel.fromSnapshot({
      ...source.toSnapshot(),
      'coverUrl': url,
    }).withChapters(source.chapters);
    _coveredBooks[source.id] = (source: source, url: url, result: result);
    return result;
  }

  bool hasCustomCover(int id) => _coverOverrides.containsKey(id);

  Future<void> _writeCovers(Map<int, String> covers) async {
    if (coverError != null) throw FormatException(coverError!);
    await directory.create(recursive: true);
    final next = File('${directory.path}/covers.json.next');
    try {
      await next.writeAsString(
        jsonEncode({for (final e in covers.entries) '${e.key}': e.value}),
        flush: true,
      );
      await next.rename('${directory.path}/covers.json');
    } finally {
      if (await next.exists()) await next.delete();
    }
    _coverOverrides
      ..clear()
      ..addAll(covers);
  }

  Future<Novel> setCover(int id, String path) async {
    final bytes = await preparePersonalImage(path, cover: true);
    return _setCoverBytes(id, bytes);
  }

  List<Novel> volumeCoverChoices(int id) => [
    if (_seriesBooks.containsKey(id))
      for (final volume in _series[id]!.volumes) ?book(volume.bookId),
  ].where((book) => book.coverUrl != null).toList(growable: false);

  Future<Novel> setVolumeCover(int id, int volumeId) async {
    final source = volumeCoverChoices(
      id,
    ).where((book) => book.id == volumeId).firstOrNull;
    if (source == null) throw const FormatException('请选择本合订本中有封面的分卷');
    final bytes = await preparePersonalImageBytes(
      await LocalBookMedia.load(source.coverUrl!),
      cover: true,
    );
    return _setCoverBytes(id, bytes);
  }

  Future<Novel> _setCoverBytes(int id, Uint8List bytes) async {
    late Novel result;
    final work = _writes.catchError((Object _) {}).then((_) async {
      if (!contains(id)) throw const FormatException('本地书籍已不存在');
      final old = _coverOverrides[id];
      final name = 'cover-custom-${DateTime.now().microsecondsSinceEpoch}.png';
      final file = File('${directory.path}/$id/$name');
      await file.parent.create(recursive: true);
      try {
        await file.writeAsBytes(bytes, flush: true);
        await _writeCovers({..._coverOverrides, id: name});
      } catch (_) {
        if (await file.exists()) await file.delete();
        rethrow;
      }
      LocalBookMedia.evict(id);
      _coveredBooks.remove(id);
      await _refreshSeries();
      if (old != null) {
        final previous = File('${directory.path}/$id/$old');
        if (await previous.exists()) await previous.delete();
      }
      result = book(id)!;
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
    return result;
  }

  Future<Novel> restoreCover(int id) async {
    late Novel result;
    final work = _writes.catchError((Object _) {}).then((_) async {
      if (!contains(id)) throw const FormatException('本地书籍已不存在');
      final old = _coverOverrides[id];
      await _writeCovers({..._coverOverrides}..remove(id));
      _coveredBooks.remove(id);
      LocalBookMedia.evict(id);
      await _refreshSeries();
      if (old != null) {
        final file = File('${directory.path}/$id/$old');
        if (await file.exists()) await file.delete();
      }
      result = book(id)!;
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
    return result;
  }

  int importedAt(int id) =>
      _sources[id]?['importedAt'] as int? ??
      _series[id]?.volumes.map((v) => importedAt(v.bookId)).fold<int>(0, max) ??
      0;
  bool contains(int id) => book(id) != null;
  List<String> importWarnings(int id) {
    final originals = _series[id]?.volumes.map((v) => v.bookId) ?? [id];
    return {
      for (final original in originals)
        if (_sources[original]?['importWarnings'] case final List warnings)
          ...warnings.whereType<String>(),
    }.toList(growable: false);
  }

  @override
  Listenable get importWarningChanges => this;

  @override
  List<LocalBookImportIssue> importIssues(int id) {
    final originals = _series[id]?.volumes.map((v) => v.bookId) ?? [id];
    final issues = <LocalBookImportIssue>[];
    for (final original in originals) {
      final stored = _sources[original]?['epubImportIssues'];
      if (stored is! List) continue;
      for (final raw in stored.whereType<Map>()) {
        if (raw['path'] is! String || raw['reason'] is! String) continue;
        final ids =
            (raw['chapterIds'] is List ? raw['chapterIds'] as List : const [])
                .whereType<int>()
                .toList();
        issues.add(
          LocalBookImportIssue(
            bookId: original,
            path: raw['path'] as String,
            reason: raw['reason'] as String,
            kind: LocalBookImportIssueKind.values.firstWhere(
              (kind) => kind.name == raw['kind'],
              orElse: () => LocalBookImportIssueKind.resource,
            ),
            chapterIds: List.unmodifiable(ids),
            chapterTitles: List.unmodifiable([
              for (final chapter
                  in _books[original]?.chapters ?? const <NovelChapter>[])
                if (ids.contains(chapter.id)) chapter.title,
            ]),
          ),
        );
      }
    }
    return List.unmodifiable(issues);
  }

  bool isIncompleteBook(int id) => importIssues(id).isNotEmpty;

  @override
  bool shouldShowImportWarning(int id) => importIssues(
    id,
  ).any((issue) => _sources[issue.bookId]?['hideImportWarning'] != true);

  @override
  Future<void> setImportWarningHidden(int id, bool hidden) async {
    final work = _writes.catchError((Object _) {}).then((_) async {
      final originals = importIssues(id).map((issue) => issue.bookId).toSet();
      for (final original in originals) {
        if ((_sources[original]?['hideImportWarning'] == true) == hidden) {
          continue;
        }
        final source = {..._sources[original]!};
        if (hidden) {
          source['hideImportWarning'] = true;
        } else {
          source.remove('hideImportWarning');
        }
        await _replaceLinkedSource(original, source);
      }
    });
    _writes = work;
    await work;
  }

  LocalSeriesHint? seriesHint(int id) =>
      LocalSeriesHint.fromJson(_sources[id]?['seriesHint']) ??
      inferLocalSeries(_books[id]?.title ?? '') ??
      inferLocalSeries(_sources[id]?['name'] ?? '');

  List<Novel> relatedVolumes(int id) {
    final hint = seriesHint(id);
    if (hint == null || seriesFor(id) != null) return const [];
    final author = _books[id]?.author ?? '';
    bool matches(Novel b) {
      final hints = _seriesBooks.containsKey(b.id)
          ? _series[b.id]!.volumes.map((v) => seriesHint(v.bookId))
          : [seriesHint(b.id)];
      final sameTitle =
          seriesTitleKey(b.title) == hint.key ||
          hints.any((h) => h?.key == hint.key);
      return sameTitle &&
          (author == '本地书籍' ||
              b.author == '本地书籍' ||
              seriesTitleKey(author) == seriesTitleKey(b.author));
    }

    return books.where((b) => b.id != id && matches(b)).toList();
  }

  static Future<LocalBookStore> forApp() async {
    final store = LocalBookStore(
      Directory(
        '${(await getApplicationSupportDirectory()).path}/local-books-v1',
      ),
    );
    await store.load();
    return store;
  }

  Future<void> load() async {
    final loaded = await compute(
      _loadLocalLibrary,
      directory.path,
      debugLabel: 'local-library-metadata',
    );
    if (_disposed) return;
    _linkedIndices.clear();
    _books
      ..clear()
      ..addAll(loaded.books);
    _sources
      ..clear()
      ..addAll(loaded.sources);
    LocalBookMedia.root = directory;
    LocalBookMedia.importWarnings = this;
    LocalBookMedia.externalImage = (id, name) => _directOriginal(id)
        ? _withOriginalInput(
            id,
            (input) => compute(readLocalEpubImageFromInput, (
              directory: '${directory.path}/$id',
              name: name,
              original: input,
            )),
          )
        : null;
    LocalBookMedia.externalImages = (id, names) => _directOriginal(id)
        ? _withOriginalInput(
            id,
            (input) => compute(readLocalEpubImagesFromInput, (
              directory: '${directory.path}/$id',
              names: names,
              original: input,
            ), debugLabel: 'local-epub-image-batch'),
          )
        : null;
    _epubLayouts
      ..clear()
      ..addAll(loaded.epubLayouts);
    _epubLayoutError = loaded.epubLayoutError;
    _series
      ..clear()
      ..addAll(loaded.series);
    seriesError = loaded.seriesError;
    _coveredBooks.clear();
    _coverOverrides
      ..clear()
      ..addAll(loaded.covers);
    coverError = loaded.coverError;
    await _refreshSeries();
    if (!_disposed) notifyListeners();
  }

  Future<Novel> import(
    LocalBookInput input, {
    LocalImportOptions options = const LocalImportOptions(),
    bool requireMatchingOptions = false,
    Map<int, LocalImportOptions> optionsById = const {},
    bool recoverDamagedEpub = false,
  }) => _import(
    input.name,
    input: input,
    options: options,
    requireMatchingOptions: requireMatchingOptions,
    optionsById: optionsById,
    recoverDamagedEpub: recoverDamagedEpub,
  );

  Future<Novel> importFile(
    String name,
    String path, {
    String? text,
    String? decodedPath,
    LocalImportOptions options = const LocalImportOptions(),
    bool recoverDamagedEpub = false,
  }) => _import(
    name,
    path: path,
    text: text,
    decodedPath: decodedPath,
    options: options,
    recoverDamagedEpub: recoverDamagedEpub,
  );

  Future<Novel> _import(
    String name, {
    LocalBookInput? input,
    String? path,
    String? text,
    String? decodedPath,
    LocalImportOptions options = const LocalImportOptions(),
    bool requireMatchingOptions = false,
    Map<int, LocalImportOptions> optionsById = const {},
    Map<String, dynamic>? linkedOriginal,
    LocalDocumentInput? document,
    String? linkedOriginalReference,
    bool renewOriginalReference = false,
    bool recoverDamagedEpub = false,
  }) async {
    late Novel result;
    final work = _writes.catchError((Object _) {}).then((_) async {
      if (_epubLayoutError != null && name.toLowerCase().endsWith('.epub')) {
        throw FormatException(_epubLayoutError!);
      }
      var selectedOriginal = linkedOriginal;
      Future<_ImportedFile> readOriginal(
        LocalDocumentInput? selectedInput, {
        bool freshOriginal = false,
      }) => compute(
        _importOriginal,
        _ImportJob(
          root: directory.path,
          name: name,
          input: input,
          path: path,
          text: text,
          decodedPath: decodedPath,
          options: options.effective,
          optionsById: optionsById,
          epubLayouts: _epubLayouts,
          preserveDirectory: requireMatchingOptions,
          linkedOriginal: selectedOriginal,
          document: selectedInput,
          freshOriginal: freshOriginal,
          recoverDamagedEpub: recoverDamagedEpub,
          knownIncomplete: {
            for (final id in _sources.keys)
              if (isIncompleteBook(id)) id,
          },
          known: {
            for (final e in _sources.entries)
              e.key: e.value['digest'] as String,
            for (final id in _series.keys) id: 'reserved-series',
          },
        ),
        debugLabel: 'local-book-import',
      );
      final _ImportedFile imported;
      if (linkedOriginalReference != null) {
        imported = await (documentAccess as LocalDocumentImportAccess)
            .withFreshInput(linkedOriginalReference, (input, header) {
              selectedOriginal = {
                'reference': header.reference,
                'size': header.size,
                'modified': header.modified,
                'name': name,
                'direct': true,
              };
              return readOriginal(input, freshOriginal: true);
            });
        selectedOriginal = {...selectedOriginal!, 'digest': imported.digest};
      } else {
        imported = await readOriginal(document);
      }
      if (requireMatchingOptions &&
          imported.novel == null &&
          importOptionsFor(imported.id).directoryIdentity !=
              (optionsById[imported.id] ?? options).directoryIdentity) {
        throw const FormatException(
          '这本书与同步文件使用的目录规则不同，已保留本机目录和阅读记录；请先在两端统一目录规则',
        );
      }
      if (imported.novel != null) {
        _books[imported.id] = imported.novel!;
        _sources[imported.id] = imported.source!;
        await _refreshSeries(originals: {imported.id});
        if (!_disposed) notifyListeners();
      } else if (renewOriginalReference &&
          selectedOriginal != null &&
          _sources[imported.id]?['linkedOriginal'] is Map) {
        final before = _documentSource(imported.id);
        final after = LocalDocumentSource.fromJson(selectedOriginal);
        if (before.digest == after.digest &&
            before.size == after.size &&
            (before.reference != after.reference ||
                before.modified != after.modified)) {
          await _replaceLinkedSource(imported.id, {
            ..._sources[imported.id]!,
            'linkedOriginal': {
              ...Map<String, dynamic>.from(
                _sources[imported.id]!['linkedOriginal'],
              ),
              ...after.toJson(),
            },
          });
          if (before.reference != after.reference) {
            await _releaseUnusedTextReference(before.reference);
          }
        }
      }
      result = _books[imported.id]!;
    });
    _writes = work;
    try {
      await work;
    } catch (error) {
      var inputBytes = input?.bytes.length;
      if (inputBytes == null && path != null) {
        try {
          inputBytes = await File(path).length();
        } catch (_) {
          /* Preserve the original error. */
        }
      }

      rethrow;
    }
    return result;
  }

  Future<String> chapterContent(int id, NovelChapter chapter) async {
    if (!contains(id) || !book(id)!.chapters.any((c) => c.id == chapter.id)) {
      throw const FormatException('本地书籍或章节不存在，请重新导入原书');
    }
    final source = _seriesChapters[id]?[chapter.id];
    final base = source?.bookId ?? id;
    final chapterId = source?.chapterId ?? chapter.id;
    if (importIssues(
      base,
    ).any((issue) => issue.chapterIds.contains(chapterId))) {
      throw const FormatException(
        '原文件本章数据损坏，需完整原件恢复。其他可读章节仍可阅读；请重新获取完整原件后重新导入，内容不同会作为新书保留，不会覆盖原有进度与书签。',
      );
    }
    if (isLinkedText(base)) {
      try {
        final index = _linkedIndex(base);
        final at = _books[base]!.chapters.indexWhere(
          (c) => c.id == (source?.chapterId ?? chapter.id),
        );
        return await index.body(textAccess, at);
      } catch (error) {
        throw LocalTextReferenceFailure(base, linkedTextFailureMessage(error));
      }
    }
    if (_sources[base]?['linkedOriginal'] is Map) {
      try {
        await documentAccess.withInput(_documentSource(base), (_) async {});
      } catch (error) {
        throw LocalTextReferenceFailure(base, linkedTextFailureMessage(error));
      }
    }
    final file = File(
      '${directory.path}/$base/${{'layout-rich-v1', 'layout-rich-v2', 'layout-markup-v1'}.contains(_sources[base]?['layoutFolder']) ? '${_sources[base]!['layoutFolder']}/' : ''}c$chapterId.txt',
    );
    var body = await readLocalText(file);
    final isEpub = (_sources[base]?['name'] as String? ?? '')
        .toLowerCase()
        .endsWith('.epub');
    if (_sources[base]?['imageSizing'] != 1 &&
        isEpub &&
        body.contains('<!--image-->')) {
      try {
        await _imageUpgrades.putIfAbsent(base, () => _upgradeImageSizing(base));
        body = await readLocalText(file);
      } catch (_) {
        // A missing/damaged original must not make saved prose unreadable.
        // Its images still get natural-size rendering from their own headers.
      }
    }
    if (_sources[base]?['richLayout'] != 12 && isEpub) {
      try {
        await _layoutUpgrades.putIfAbsent(base, () => _upgradeRichLayout(base));
        final upgradedFile = File(
          '${directory.path}/$base/${{'layout-rich-v1', 'layout-rich-v2', 'layout-markup-v1'}.contains(_sources[base]?['layoutFolder']) ? '${_sources[base]!['layoutFolder']}/' : ''}c$chapterId.txt',
        );
        body = await readLocalText(upgradedFile);
      } catch (_) {
        // Keep saved prose readable if the original file cannot be re-parsed.
      }
    }
    EpubChapterLayout? loadedLayout;
    final layoutFile = File(
      '${directory.path}/$base/c$chapterId.layout.json',
    );
    if (await layoutFile.exists()) {
      try {
        final layout = EpubChapterLayout.fromJson(
          jsonDecode(await layoutFile.readAsString()),
        );
        if (!layout.isEmpty) {
          loadedLayout = layout;
          await EpubFontManager.ensureLoaded(
            bookId: base,
            embeddedFonts: layout.embeddedFonts,
            bookDirectory: Directory('${directory.path}/$base'),
          );
          EpubLayoutRegistry.register(body, layout);
        }
      } catch (_) {
        // Ignore corrupted layout metadata and fall back to plain prose.
      }
    }
    if (!body.contains(ReaderRichBody.prefix)) {
      if ((_sources[base]?['richText'] as int? ?? 0) >= 1 ||
          loadedLayout != null) {
        final encoded = ReaderRichBody(
          body.split('\n\n'),
          revision: 'epub-rich-v${_sources[base]?['richText'] ?? 2}',
          epubLayout: loadedLayout,
        ).encode();
        if (loadedLayout != null) {
          EpubLayoutRegistry.register(encoded, loadedLayout);
        }
        return encoded;
      }
    } else if (loadedLayout != null) {
      try {
        final decoded = ReaderRichBody.decode(body);
        if (decoded.epubLayout == null || decoded.epubLayout!.blocks.isEmpty) {
          final encoded = ReaderRichBody(
            decoded.paragraphs,
            formats: decoded.formats,
            notes: decoded.notes,
            revision: decoded.revision,
            coordinateMap: decoded.coordinateMap,
            epubLayout: loadedLayout,
          ).encode();
          EpubLayoutRegistry.register(encoded, loadedLayout);
          return encoded;
        }
      } catch (_) {
        /* Keep existing body if decoding fails. */
      }
    }
    return body;
  }

  Future<void> _upgradeRichLayout(int id) async {
    final work = _writes.catchError((Object _) {}).then((_) async {
      final source = _sources[id], book = _books[id];
      if (source == null || book == null || source['richLayout'] == 12) return;
      final upgraded = await _withOriginalInput(
        id,
        (original) => compute(
          _readRichLayout,
          _ImageSizingJob(
            directory.path,
            source['name'] as String,
            id,
            source['digest'] as String,
            importOptionsFor(id).inlineEpubImages,
            original,
          ),
        ),
      );
      if (upgraded.bodies.length != book.chapters.length ||
          upgraded.layouts.length != book.chapters.length) {
        throw const FormatException('原书目录与本地目录不一致');
      }
      final prefix = {
        'layout-rich-v1',
        'layout-rich-v2',
        'layout-markup-v1',
      }.contains(source['layoutFolder'])
          ? '${source['layoutFolder']}/'
          : '';
      for (final font in upgraded.fonts.entries) {
        final fontFile = File('${directory.path}/$id/${font.key}');
        if (!await fontFile.exists()) {
          await fontFile.writeAsBytes(font.value, flush: true);
        }
      }
      if (upgraded.mediaEntries.isNotEmpty) {
        final mediaTarget = File('${directory.path}/$id/media.json');
        var recoverDamaged = false;
        if (await mediaTarget.exists()) {
          try {
            final oldMedia = jsonDecode(await mediaTarget.readAsString());
            if (oldMedia is Map && oldMedia['recoverDamagedEpub'] == true) {
              recoverDamaged = true;
            }
          } catch (_) {}
        }
        final mediaNext = File('${mediaTarget.path}.layout-next');
        try {
          await mediaNext.writeAsString(
            jsonEncode({
              'version': 1,
              'entries': upgraded.mediaEntries,
              if (recoverDamaged) 'recoverDamagedEpub': true,
            }),
            flush: true,
          );
          await mediaNext.rename(mediaTarget.path);
          LocalBookMedia.evict(id);
        } finally {
          if (await mediaNext.exists()) await mediaNext.delete();
        }
      }
      for (var i = 0; i < upgraded.layouts.length; i++) {
        final chapterId = book.chapters[i].id;
        final layout = upgraded.layouts[i];
        if (!layout.isEmpty) {
          final target = File('${directory.path}/$id/c$chapterId.layout.json');
          final next = File('${target.path}.layout-next');
          try {
            await next.writeAsString(jsonEncode(layout.toJson()), flush: true);
            await next.rename(target.path);
          } finally {
            if (await next.exists()) await next.delete();
          }
        } else {
          // A corrected image classification may remove the last rich block.
          // Do not let a v5 sidecar restore its obsolete full-page flag.
          final stale = File('${directory.path}/$id/c$chapterId.layout.json');
          if (await stale.exists()) await stale.delete();
        }
        final chapterFile = File(
          '${directory.path}/$id/${prefix}c$chapterId.txt',
        );
        if (await localTextExists(chapterFile)) {
          try {
            final beforeRaw = await readLocalText(chapterFile);
            final before = ReaderRichBody.decode(beforeRaw);
            final next = ReaderRichBody.decode(upgraded.bodies[i]);
            final updatedBody = ReaderRichBody(
              next.paragraphs,
              formats: next.formats,
              notes: next.notes,
              revision: next.revision.isNotEmpty
                  ? next.revision
                  : 'epub-rich-v2',
              coordinateMap: ReaderCoordinateMap.between(
                before.paragraphs,
                next.paragraphs,
                sourceRevision: before.revision,
                previous: before.coordinateMap,
              ),
              epubLayout: layout.isEmpty ? next.epubLayout : layout,
            ).encode();
            final nextFile = File('${chapterFile.path}.layout-next');
            try {
              await nextFile.writeAsString(updatedBody, flush: true);
              await nextFile.rename(chapterFile.path);
              if (source['linkedOriginal'] is Map) {
                await compactLocalText(chapterFile);
              }
            } finally {
              if (await nextFile.exists()) await nextFile.delete();
            }
          } catch (_) {
            /* Keep existing chapter text if coordinate mapping fails. */
          }
        }
      }
      final target = File('${directory.path}/$id/book.json');
      final record =
          jsonDecode(await target.readAsString()) as Map<String, dynamic>;
      final currentSource = Map<String, dynamic>.from(
        record['source'] as Map? ?? source,
      );
      final changedSource = {...currentSource, 'richLayout': 12, 'richText': 2};
      record['source'] = changedSource;
      if (upgraded.navigation != null && record['novel'] is Map) {
        final novelMap = Map<String, dynamic>.from(record['novel'] as Map);
        novelMap['navigation'] = upgraded.navigation!.toJson();
        record['novel'] = novelMap;
        _books[id] = Novel.fromSnapshot(novelMap).withChapters(book.chapters);
      }
      final next = File('${target.path}.layout-next');
      try {
        await next.writeAsString(jsonEncode(record), flush: true);
        await next.rename(target.path);
      } finally {
        if (await next.exists()) await next.delete();
      }
      _sources[id] = changedSource;
    });
    _writes = work;
    await work;
  }

  Future<void> _upgradeImageSizing(int id) async {
    final work = _writes.catchError((Object _) {}).then((_) async {
      final source = _sources[id], book = _books[id];
      if (source == null || book == null || source['imageSizing'] == 1) return;
      final bodies = await compute(
        _readImageSizing,
        _ImageSizingJob(
          directory.path,
          source['name'] as String,
          id,
          source['digest'] as String,
          importOptionsFor(id).inlineEpubImages,
        ),
      );
      if (bodies.length != book.chapters.length) {
        throw const FormatException('原书目录与本地目录不一致');
      }
      final replacements = <File, String>{};
      String plain(String body) => body
          .split('\n\n')
          .map((paragraph) {
            final url = readerIllustrationUrl(paragraph);
            return url?.startsWith('wenku-local:') == true
                ? '<!--image-->$url<!--image-->'
                : paragraph;
          })
          .join('\n\n');
      for (var i = 0; i < bodies.length; i++) {
        if (book.chapters[i].id != i + 1) {
          throw const FormatException('本地章节标识已改变');
        }
        final target = File('${directory.path}/$id/c${i + 1}.txt');
        final before = await target.readAsString();
        if (plain(before) != plain(bodies[i])) {
          throw const FormatException('原书正文与本地正文不一致');
        }
        if (before != bodies[i]) replacements[target] = bodies[i];
      }
      // Only sizing suffixes may change: chapter IDs, prose offsets, paragraph
      // counts, user metadata and series references are untouched.
      for (final replacement in replacements.entries) {
        final next = File('${replacement.key.path}.image-size-next');
        try {
          await next.writeAsString(replacement.value, flush: true);
          await next.rename(replacement.key.path);
        } finally {
          if (await next.exists()) await next.delete();
        }
      }
      final target = File('${directory.path}/$id/book.json');
      final record =
          jsonDecode(await target.readAsString()) as Map<String, dynamic>;
      final changedSource = {...source, 'imageSizing': 1};
      record['source'] = changedSource;
      final next = File('${target.path}.image-size-next');
      try {
        await next.writeAsString(jsonEncode(record), flush: true);
        await next.rename(target.path);
      } finally {
        if (await next.exists()) await next.delete();
      }
      _sources[id] = changedSource;
    });
    _writes = work;
    await work;
  }

  Future<void> _refreshSeries({
    Set<int>? coverOriginals,
    Set<int>? originals,
  }) async {
    if (coverOriginals == null) await _repairMarkupSeries(originals: originals);
    final incremental = coverOriginals != null || originals != null;
    final affected = _series.values
        .where(
          (s) =>
              !s.deleted &&
              (!incremental ||
                  coverOriginals?.contains(s.volumes.first.bookId) == true ||
                  s.volumes.any((v) => originals?.contains(v.bookId) == true)),
        )
        .toList();
    if (incremental && affected.isEmpty) return;
    final novels = <int, Novel>{if (incremental) ..._seriesBooks};
    final references = <int, Map<int, ({int bookId, int chapterId})>>{
      if (incremental) ..._seriesChapters,
    };
    for (final series in affected) {
      novels.remove(series.id);
      references.remove(series.id);
      if (series.volumes.any(
        (v) =>
            _books[v.bookId] == null ||
            _books[v.bookId]!.chapters.length != v.chapterIds.length,
      )) {
        continue;
      }
      final chapters = <NovelChapter>[];
      final refs = <int, ({int bookId, int chapterId})>{};
      for (final volume in series.volumes) {
        final original = _books[volume.bookId]!;
        for (final (i, chapter) in original.chapters.indexed) {
          final id = volume.chapterIds[i];
          chapters.add(
            NovelChapter(
              chapter.title,
              '',
              id: id,
              volumeId: volume.bookId,
              volumeTitle: volume.title,
            ),
          );
          refs[id] = (bookId: volume.bookId, chapterId: chapter.id);
        }
      }
      final first = book(series.volumes.first.bookId)!;
      String? cover;
      final uri = Uri.tryParse(first.coverUrl ?? '');
      if (uri != null && LocalBookMedia.valid(uri)) {
        final source = File('${directory.path}/${uri.host}${uri.path}');
        final folder = Directory('${directory.path}/${series.id}');
        final target = File('${folder.path}${uri.path}');
        if (await source.exists()) {
          await folder.create(recursive: true);
          if (coverOriginals?.contains(series.volumes.first.bookId) == true ||
              (_seriesCovers.containsKey(series.id) &&
                  _seriesCovers[series.id] != first.coverUrl) ||
              !await target.exists()) {
            final next = await source.copy('${target.path}.next');
            await next.rename(target.path);
            LocalBookMedia.evict(series.id);
          }
          cover = 'wenku-local://${series.id}${uri.path}';
        }
      }
      _seriesCovers[series.id] = first.coverUrl;
      novels[series.id] = Novel.fromSnapshot({
        ...first.toSnapshot(),
        'id': series.id,
        'title': series.title,
        'author': series.author,
        'summary': series.summary,
        'genre': localBookGenre(series.tags ?? const [], series: true),
        'coverUrl': cover,
        'chapterCount': chapters.length,
        'navigation': _seriesNavigation(series)?.toJson(),
      }).withChapters(chapters);
      references[series.id] = refs;
    }
    _seriesBooks
      ..clear()
      ..addAll(novels);
    _seriesChapters
      ..clear()
      ..addAll(references);
  }

  Map<String, Object> exportSeries() => encodeLocalSeries(_series.values);

  Future<void> _writeSeries(Map<int, LocalBookSeries> next) async {
    if (seriesError != null) throw FormatException(seriesError!);
    final valid = decodeLocalSeries(encodeLocalSeries(next.values));
    if (valid.any((s) => _books.containsKey(s.id))) {
      throw const FormatException('合订本标识与原书冲突，原书已保留');
    }
    final target = File('${directory.path}/series.json');
    final pending = File('${target.path}.next');
    final content = jsonEncode(encodeLocalSeries(valid));
    if (utf8.encode(content).length > 4 * 1024 * 1024) {
      throw const FormatException('本地分卷记录超过 4 MiB，请减少合订本中的章节数量');
    }
    try {
      await pending.writeAsString(content, flush: true);
      await pending.rename(target.path);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
    _series
      ..clear()
      ..addEntries(valid.map((s) => MapEntry(s.id, s)));
    await _refreshSeries();
  }

  /// The caller confirms membership and order. Original files stay untouched.
  Future<Novel> saveSeries({
    int? id,
    required String title,
    required List<({int bookId, String title})> volumes,
  }) async {
    late Novel result;
    final work = _writes.catchError((Object _) {}).then((_) async {
      if (title.trim().isEmpty || title.trim().length > 160) {
        throw const FormatException('合订本书名需要 1～160 个字');
      }
      if (volumes.any(
        (v) => v.title.trim().isEmpty || v.title.trim().length > 160,
      )) {
        throw const FormatException('每卷名称需要 1～160 个字');
      }
      if (volumes.length < 2 ||
          volumes.any((v) => !_books.containsKey(v.bookId))) {
        throw const FormatException('请至少选择两本已导入的分卷');
      }
      if (volumes.map((v) => v.bookId).toSet().length != volumes.length) {
        throw const FormatException('同一分卷不能重复添加');
      }
      for (final volume in volumes) {
        final owner = _series.values
            .where(
              (s) =>
                  !s.deleted && s.volumes.any((v) => v.bookId == volume.bookId),
            )
            .firstOrNull;
        if (owner != null && owner.id != id) {
          throw FormatException(
            '《${_books[volume.bookId]!.title}》已属于《${owner.title}》，请在该书的管理分卷中添加',
          );
        }
      }
      var identity = id;
      final previous = id == null ? null : _series[id];
      if (id != null && (previous == null || previous.deleted)) {
        throw const FormatException('合订本已变化，请返回后重试');
      }
      final random = Random.secure();
      while (identity == null ||
          _books.containsKey(identity) ||
          (id == null && _series.containsKey(identity))) {
        identity = localBookIdStart | random.nextInt(0x20000000);
      }
      var nextChapter = previous?.nextChapterId ?? 1;
      final members = <LocalSeriesVolume>[];
      for (final volume in volumes) {
        final book = _books[volume.bookId]!;
        final old = previous?.volumes
            .where((v) => v.bookId == book.id)
            .firstOrNull;
        final ids =
            old?.chapterIds ??
            List.generate(book.chapters.length, (_) => nextChapter++);
        members.add(
          LocalSeriesVolume(
            bookId: book.id,
            title: volume.title.trim(),
            chapterIds: List.unmodifiable(ids),
          ),
        );
      }
      final first = _books[volumes.first.bookId]!;
      final now = DateTime.now().millisecondsSinceEpoch;
      final changed = LocalBookSeries(
        id: identity,
        title: title.trim(),
        author: previous?.author ?? first.author,
        summary: previous?.summary ?? first.summary,
        tags: previous?.tags,
        volumes: List.unmodifiable(members),
        nextChapterId: nextChapter,
        updatedAt: max(now, (previous?.updatedAt ?? 0) + 1),
      );
      await _writeSeries({..._series, identity: changed});
      result = _seriesBooks[identity]!;
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
    return result;
  }

  Future<void> dissolveSeries(int id) async {
    final work = _writes.catchError((Object _) {}).then((_) async {
      final series = _series[id];
      if (series == null || series.deleted) return;
      await _writeSeries({
        ..._series,
        id: series.copyWith(
          deleted: true,
          updatedAt: max(
            DateTime.now().millisecondsSinceEpoch,
            series.updatedAt + 1,
          ),
        ),
      });
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
  }

  Future<void> mergeSeries(Object? raw) async {
    final incoming = decodeLocalSeries(raw);
    final work = _writes.catchError((Object _) {}).then((_) async {
      final next = {..._series};
      for (final series in incoming) {
        final old = next[series.id];
        if (old == null ||
            series.updatedAt > old.updatedAt ||
            (series.updatedAt == old.updatedAt &&
                jsonEncode(
                      series.toJson(),
                    ).compareTo(jsonEncode(old.toJson())) >
                    0)) {
          next[series.id] = series.copyWith(tags: series.tags ?? old?.tags);
        }
      }
      await _writeSeries(next);
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
  }

  static Map<String, dynamic> validateMetadata(Object? raw) {
    if (raw is! Map || raw.length > 2000) {
      throw const FormatException('本地书籍信息格式有误');
    }
    final result = <String, dynamic>{};
    for (final e in raw.entries) {
      final id = e.key is String ? int.tryParse(e.key) : null, v = e.value;
      if (id == null ||
          !isLocalBook(id) ||
          id > 0x7fffffff ||
          v is! Map ||
          v['title'] is! String ||
          v['title'].trim().isEmpty ||
          v['title'].length > 160 ||
          v['author'] is! String ||
          v['author'].length > 160 ||
          v['summary'] is! String ||
          v['summary'].length > 4000 ||
          v['at'] is! int ||
          v['at'] < 0) {
        throw const FormatException('书名限 160 字，作者限 160 字，简介限 4000 字');
      }
      result['$id'] = {
        'title': v['title'].trim(),
        'author': v['author'].trim(),
        'summary': v['summary'].trim(),
        if (v.containsKey('tags')) 'tags': decodeBookTags(v['tags']),
        'at': v['at'],
      };
    }
    return result;
  }

  Map<String, dynamic> exportMetadata() => {
    for (final e in _sources.entries)
      if (e.value['userMetadata'] != null)
        '${e.key}': {
          ...Map<String, dynamic>.from(e.value['userMetadata']),
          if (e.value['userMetadata']['tags'] case final List tags)
            'tags': List<String>.from(tags),
        },
  };
  Future<void> _writeMetadata(int id, Map<String, dynamic> value) async {
    final current = _books[id];
    if (current == null) return;
    // Older clients have no tags field. Their title edits must not clear tags
    // already saved on this device, including the next backup's metadata.
    final previous = _sources[id]?['userMetadata'] as Map?;
    final metadata = {
      ...value,
      if (!value.containsKey('tags') && previous?.containsKey('tags') == true)
        'tags': previous!['tags'],
    };
    final changed = Novel.fromSnapshot({
      ...current.toSnapshot(),
      'title': value['title'],
      'author': value['author'],
      'summary': value['summary'],
      if (metadata.containsKey('tags'))
        'genre': localBookGenre((metadata['tags'] as List).cast<String>()),
    }).withChapters(current.chapters);
    final source = {..._sources[id]!, 'userMetadata': metadata};
    final target = File('${directory.path}/$id/book.json');
    final json =
        jsonDecode(await target.readAsString()) as Map<String, dynamic>;
    json['novel'] = changed.toSnapshot();
    json['source'] = source;
    final next = File('${target.path}.next');
    try {
      await next.writeAsString(jsonEncode(json), flush: true);
      await next.rename(target.path);
    } finally {
      if (await next.exists()) await next.delete();
    }
    _sources[id] = source;
    _books[id] = changed;
  }

  /// Omitting [tags] preserves existing tags; an empty iterable clears them.
  Future<Novel> updateMetadata(
    int id, {
    required String title,
    required String author,
    required String summary,
    Iterable<String>? tags,
  }) async {
    late Novel result;
    final work = _writes.catchError((Object _) {}).then((_) async {
      if (!contains(id)) throw const FormatException('本地书籍已不存在');
      final previousAt = (_sources[id]?['userMetadata']?['at'] as int?) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final valid = validateMetadata({
        '$id': {
          'title': title,
          'author': author,
          'summary': summary,
          'tags': normalizeBookTags(tags ?? book(id)!.tags),
          'at': now > previousAt ? now : previousAt + 1,
        },
      });
      if (_seriesBooks.containsKey(id)) {
        final value = valid['$id'];
        await _writeSeries({
          ..._series,
          id: _series[id]!.copyWith(
            title: value['title'],
            author: value['author'],
            summary: value['summary'],
            tags: (value['tags'] as List).cast<String>(),
            updatedAt: max(value['at'] as int, _series[id]!.updatedAt + 1),
          ),
        });
      } else {
        await _writeMetadata(id, Map<String, dynamic>.from(valid['$id']));
        await _refreshSeries();
      }
      result = book(id)!;
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
    return result;
  }

  Future<void> mergeMetadata(Object? metadata) async {
    final valid = validateMetadata(metadata);
    final work = _writes.catchError((Object _) {}).then((_) async {
      for (final e in valid.entries) {
        final id = int.parse(e.key),
            incoming = Map<String, dynamic>.from(e.value);
        if (!contains(id)) continue;
        final previous = _sources[id]?['userMetadata'] as Map?;
        if (previous == null ||
            incoming['at'] > previous['at'] ||
            (incoming['at'] == previous['at'] &&
                jsonEncode(incoming).compareTo(jsonEncode(previous)) > 0)) {
          await _writeMetadata(id, incoming);
        }
      }
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
  }

  LocalImportOptions importOptionsFor(int id) {
    final source = _sources[id];
    if (source == null && _epubLayouts.containsKey(id)) {
      return LocalImportOptions(inlineEpubImages: _epubLayouts[id]!);
    }
    if (source == null) throw const FormatException('本地原书不存在');
    return LocalImportOptions.fromJson(source['importOptions']).effective;
  }

  /// Directory semantics survive removal of an original so a later reimport
  /// cannot silently move saved reading positions or bookmarks.
  Map<int, LocalImportOptions> get retainedImportOptions => {
    for (final entry in _epubLayouts.entries)
      entry.key: LocalImportOptions(inlineEpubImages: entry.value),
  };

  Future<void> _writeEpubLayouts(Map<int, bool> layouts) async {
    if (_epubLayoutError != null) throw FormatException(_epubLayoutError!);
    if (layouts.length > 10000) throw const FormatException('已保存的本地目录记录过多');
    await directory.create(recursive: true);
    final next = File('${directory.path}/epub-layouts.json.next');
    try {
      await next.writeAsString(
        jsonEncode({
          for (final entry in layouts.entries) '${entry.key}': entry.value,
        }),
        flush: true,
      );
      await next.rename('${directory.path}/epub-layouts.json');
    } finally {
      if (await next.exists()) await next.delete();
    }
    _epubLayouts
      ..clear()
      ..addAll(layouts);
  }

  /// Reading-only sync may arrive before an original. Remember its EPUB layout
  /// before exposing positions; TXT import rules remain user-controlled.
  Future<void> rememberEpubLayouts(Map<int, bool> layouts) async {
    final valid = {
      for (final entry in layouts.entries)
        if (isLocalBook(entry.key) && entry.key <= 0x7fffffff)
          entry.key: entry.value,
    };
    if (valid.isEmpty) return;
    final work = _writes.catchError((Object _) {}).then((_) async {
      if (valid.entries.any(
        (e) =>
            _epubLayouts.containsKey(e.key) && _epubLayouts[e.key] != e.value,
      )) {
        throw const FormatException('两端使用的 EPUB 目录不同，已保留原有阅读记录');
      }
      if (valid.entries.every((e) => _epubLayouts[e.key] == e.value)) return;
      await _writeEpubLayouts({..._epubLayouts, ...valid});
    });
    _writes = work;
    await work;
  }

  Future<LocalBookInput> original(int id) async {
    final source = _sources[id];
    if (source == null) throw const FormatException('本地原书不存在');
    if (isLinkedText(id)) {
      final index = _linkedIndex(id);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in textAccess.bytes(index.source)) {
        bytes.add(chunk);
      }
      return LocalBookInput(
        source['name'],
        bytes.takeBytes(),
        text: index.source.encoding.toUpperCase() == 'UTF-8'
            ? null
            : await index
                  .decodedBytes(textAccess)
                  .transform(utf8.decoder)
                  .join(),
      );
    }
    final folder = '${directory.path}/$id';
    final decoded = File('$folder/decoded.txt');
    return LocalBookInput(
      source['name'],
      await _withOriginalInput(id, (input) async {
        final bytes = BytesBuilder(copy: false);
        await for (final part in input.bytes()) {
          bytes.add(part);
        }
        return bytes.takeBytes();
      }),
      text: await localTextExists(decoded)
          ? await readLocalText(decoded)
          : null,
    );
  }

  Future<void> remove(int id) async {
    final work = _writes.catchError((Object _) {}).then((_) async {
      final series = _series[id];
      final ids = [id];
      if (series != null && !series.deleted) {
        ids.addAll(series.volumes.map((v) => v.bookId));
        await _writeSeries({
          ..._series,
          id: series.copyWith(
            deleted: true,
            updatedAt: max(
              DateTime.now().millisecondsSinceEpoch,
              series.updatedAt + 1,
            ),
          ),
        });
      } else if (seriesFor(id) != null) {
        throw const FormatException('请先将合订本恢复为独立书籍，再删除单卷');
      }
      final layouts = {
        for (final value in ids)
          if ((_sources[value]?['name'] as String? ?? '')
              .toLowerCase()
              .endsWith('.epub'))
            value: importOptionsFor(value).inlineEpubImages,
      };
      if (layouts.isNotEmpty) {
        await _writeEpubLayouts({..._epubLayouts, ...layouts});
      }
      if (ids.any(_coverOverrides.containsKey)) {
        await _writeCovers(
          {..._coverOverrides}..removeWhere((key, _) => ids.contains(key)),
        );
      }
      for (final value in ids) {
        final reference = isLinkedText(value)
            ? _linkedIndex(value).source.reference
            : _sources[value]?['linkedOriginal']?['reference'] as String?;
        final folder = Directory('${directory.path}/$value');
        if (await folder.exists()) await folder.delete(recursive: true);
        _books.remove(value);
        _sources.remove(value);
        _linkedIndices.remove(value);
        if (reference != null) await _releaseUnusedTextReference(reference);
        _coveredBooks.remove(value);
        LocalBookMedia.evict(value);
      }
      await _refreshSeries();
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
  }

  @override
  void dispose() {
    _disposed = true;
    if (identical(LocalBookMedia.importWarnings, this)) {
      LocalBookMedia.importWarnings = null;
    }
    super.dispose();
  }
}
