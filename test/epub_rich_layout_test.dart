import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/epub_image_styles.dart';
import 'package:wenku8_flutter/epub_rich_layout.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_book_media.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_image_layout.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_annotations.dart';
import 'package:wenku8_flutter/reader_find.dart';
import 'package:wenku8_flutter/reader_pagination.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_text.dart';

Uint8List _buildRichEpub({
  Map<String, String> overrides = const {},
  Map<String, List<int>> binaryOverrides = const {},
}) {
  final entries = <String, List<int>>{
    'mimetype': utf8.encode('application/epub+zip'),
    'META-INF/container.xml': utf8.encode(
      '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
    ),
    'OPS/book.opf': utf8.encode('''
      <package unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="bookid">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier>
          <dc:title>多看精排测试书</dc:title>
          <dc:creator>测试作者</dc:creator>
        </metadata>
        <manifest>
          <item id="css" href="styles/main.css" media-type="text/css"/>
          <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
          <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
          <item id="cover" href="images/cover.png" media-type="image/png"/>
          <item id="font1" href="fonts/heading.ttf" media-type="font/ttf"/>
        </manifest>
        <spine toc="ncx">
          <itemref idref="c1"/>
        </spine>
      </package>
    '''),
    'OPS/toc.ncx': utf8.encode('''
      <ncx><navMap>
        <navPoint><navLabel><text>第一章 序幕</text></navLabel><content src="text/ch1.xhtml"/></navPoint>
      </navMap></ncx>
    '''),
    'OPS/styles/main.css': utf8.encode('''
      @font-face {
        font-family: "DK-Heading";
        src: url("../fonts/heading.ttf");
      }
      body {
        font-family: "DK-Body";
      }
      h1.chapter-title {
        font-family: "DK-Heading";
        font-size: 1.6em;
        text-align: center;
        color: #8B261D;
        border-bottom: 2px solid #8B261D;
        margin-bottom: 1.2em;
      }
      p.no-indent {
        text-indent: 0;
        text-align: right;
      }
      blockquote.callout {
        background-color: #F4EFE6;
        border-left: 4px solid #8C6239;
        padding: 0.8em;
        margin-left: 1em;
      }
      .duokan-image-single {
        page-break-before: always;
        page-break-after: always;
      }
    '''),
    'OPS/text/ch1.xhtml': utf8.encode('''
      <html xmlns:epub="http://www.idpf.org/2007/ops">
        <head><link rel="stylesheet" href="../styles/main.css"/></head>
        <body>
          <h1 class="chapter-title">第一章 序幕</h1>
          <p class="no-indent">——献给所有热爱阅读的人</p>
          <p>这是带有<ruby>汉字<rp>(</rp><rt>hànzì</rt><rp>)</rp></ruby>注音、<b>加粗</b>、<i>斜体</i>与行内小图标<img src="../images/cover.png" style="width:1em;height:1em"/>以及脚注引用<a epub:type="noteref" href="#fn1">[1]</a>的正文段落。</p>
          <blockquote class="callout"><p>这是一段多看风格的引用框文字。</p></blockquote>
          <hr/>
          <table>
            <tr><th>属性</th><th>数值</th></tr>
            <tr><td>等级</td><td>SSR</td></tr>
          </table>
          <div class="duokan-image-single">
            <img src="../images/cover.png"/>
            <figcaption>图一：全屏插图图注</figcaption>
          </div>
          <aside id="fn1" epub:type="footnote"><p>[1] 这里是被自动抽离出正文的底部注释内容。</p></aside>
        </body>
      </html>
    '''),
    'OPS/images/cover.png': base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
    'OPS/fonts/heading.ttf': List<int>.filled(128, 0x42),
  };
  for (final e in overrides.entries) {
    entries[e.key] = utf8.encode(e.value);
  }
  for (final e in binaryOverrides.entries) {
    entries[e.key] = e.value;
  }
  final archive = Archive();
  for (final e in entries.entries) {
    archive.addFile(
      ArchiveFile(e.key, e.value.length, e.value)..lastModTime = 1704067200,
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  testWidgets('publisher album keeps source coordinates and occupies one leaf', (
    tester,
  ) async {
    final book = parseLocalBook(
      LocalBookInput(
        'album.epub',
        _buildRichEpub(
          overrides: {
            'OPS/text/ch1.xhtml':
                '''<html xmlns="http://www.w3.org/1999/xhtml"><head>
        <style>.duokan-image-gallery { margin-top: 26%; }</style></head><body>
        <div class="duokan-image-gallery">
          <div class="duokan-image-gallery-cell"><img id="art-a" src="../images/cover.png"/>
            <p class="duokan-image-maintitle"><a href="#after">pr-1</a></p></div>
          <div class="duokan-image-gallery-cell"><img id="art-b" src="../images/second.png"/>
            <p class="duokan-image-maintitle"><a href="#after">1-2</a></p></div>
        </div><p id="after">正文保留在相册之后。</p></body></html>''',
          },
          binaryOverrides: {
            'OPS/images/second.png': base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            ),
          },
        ),
      ),
    );
    final content = await ReaderContent.parse(book.bodies.first);
    expect(content.paragraphs.length, 5);
    expect(content.readingOrder, [0, 4]);
    expect(content.galleryParagraphs(0), [0, 1, 2, 3]);
    expect(content.illustrations.length, 2);
    expect(content.epubLayout!.spans[1]!.single.footnoteId, isNotNull);
    final roundTrip = EpubChapterLayout.fromJson(content.epubLayout!.toJson());
    expect(roundTrip.blocks[2]!.imageGallery, 0);
    for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
      final pages = await tester.runAsync(
        () => paginateReader(
          content: content,
          size: const Size(375, 700),
          style: const TextStyle(fontSize: 19, height: 1.72),
          preferences: ReaderPreferences(mode: mode),
          scaler: TextScaler.noScaling,
          localImageSizes: {
            for (final url in content.illustrations) url: const Size(800, 1200),
          },
          current: () => true,
        ),
      );
      expect(pages!.pages.length, 2);
      expect(pages.pages.first.fragments.single.blockStyle!.imageGallery, 0);
      expect(pages.pages.last.fragments.single.paragraph, 4);
      // Existing saved positions inside the old separate images still land
      // on the album, rather than skipping to the following prose.
      expect(pages.pageFor(const ReaderTextAnchor(2, 0)), 0);
      expect(pages.pageFor(const ReaderTextAnchor(3, 0)), 0);
      expect(
        pages.pages.first.fragments.single.rect.bottom,
        lessThanOrEqualTo(700),
      );
    }
  });

  testWidgets(
    'album captures inner drags including its boundary and leaves paper drags to reader',
    (tester) async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final cache = ReaderIllustrationCache(request: (_) async => bytes);
      addTearDown(cache.clearMemory);
      await tester.runAsync(() async {
        await cache.dimensions('https://example.com/a.png');
        await cache.dimensions('https://example.com/b.png');
      });
      var outerPage = 0;
      String? opened;
      for (final size in [const Size(375, 700), const Size(700, 375)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: size.width > size.height
                  ? Brightness.dark
                  : Brightness.light,
            ),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                disableAnimations: true,
                textScaler: TextScaler.linear(1.6),
              ),
              child: Scaffold(
                body: PageView(
                  onPageChanged: (p) => outerPage = p,
                  children: [
                    Align(
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: size.width - 80,
                        height: size.height - 140,
                        child: ReaderIllustrationAlbum(
                          key: ValueKey(size),
                          urls: const [
                            'https://example.com/a.png',
                            'https://example.com/b.png',
                          ],
                          cache: cache,
                          sizedFrame: true,
                          captionBuilder: (p) => Text('图注 ${p + 1}'),
                          onOpen: (url) => opened = url,
                        ),
                      ),
                    ),
                    const Text('下一页'),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final album = find.byType(ReaderIllustrationAlbum);
        await tester.dragFrom(
          tester.getCenter(album) + const Offset(60, -40),
          Offset(-size.width * .7, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('图注 2'), findsOneWidget);
        expect(outerPage, 0);
        await tester.dragFrom(
          tester.getCenter(album) + const Offset(60, -40),
          Offset(-size.width * .7, 0),
        );
        await tester.pumpAndSettle();
        expect(outerPage, 0);
        await tester.tapAt(tester.getCenter(album) - const Offset(0, 40));
        await tester.pumpAndSettle();
        expect(opened, 'https://example.com/b.png');
        await tester.dragFrom(
          Offset(size.width - 60, 30),
          Offset(-size.width * .8, 0),
        );
        await tester.pumpAndSettle();
        expect(outerPage, 1);
        await tester.dragFrom(Offset(60, 30), Offset(size.width * .8, 0));
        await tester.pumpAndSettle();
        expect(outerPage, 0);
        expect(find.text('图注 2'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        outerPage = 0;
      }
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'EPUB parser automatically extracts headings, ruby, inline icons, blockquotes, tables, captions, and footnotes',
    () {
      final book = parseLocalBook(
        LocalBookInput('duokan.epub', _buildRichEpub()),
      );
      expect(book.layouts, hasLength(1));
      final layout = book.layouts.first;
      final paragraphs = book.bodies.first.split('\n\n');

      // 1. Leading chapter heading matched TOC title and was preserved in leadingHeading
      expect(layout.leadingHeading, isNotNull);
      expect(layout.leadingHeading!.text, '第一章 序幕');
      expect(layout.leadingHeading!.style.kind, EpubBlockKind.heading1);
      expect(layout.leadingHeading!.style.align, TextAlign.center);
      expect(layout.leadingHeading!.style.fontFamily, 'DK-Heading');
      expect(layout.leadingHeading!.style.fontScale, closeTo(1.6, 0.01));

      // 2. Footnote <aside> was extracted out of prose into layout.footnotes
      expect(
        paragraphs.any((p) => p.contains('被自动抽离出正文的底部注释内容')),
        isFalse,
      );
      expect(layout.footnotes, contains('fn1'));
      expect(
        layout.footnotes['fn1']!.content,
        contains('这里是被自动抽离出正文的底部注释内容。'),
      );

      // 3. Paragraph 0: right-aligned epigraph with text-indent: 0
      expect(paragraphs[0], '——献给所有热爱阅读的人');
      expect(layout.blocks[0]!.align, TextAlign.end);
      expect(layout.blocks[0]!.indentEm, 0);

      // 4. Paragraph 1: inline ruby, bold, italic, inline image (\uFFFC), and footnote ref
      // all stay in a SINGLE paragraph without splitting on inline <img>!
      expect(paragraphs[1], contains('这是带有汉字注音、加粗、斜体与行内小图标\uFFFC以及脚注引用[1]的正文段落。'));
      final p1Spans = layout.spans[1]!;
      expect(p1Spans.any((s) => s.rubyText == 'hànzì'), isTrue);
      expect(p1Spans.any((s) => s.bold), isTrue);
      expect(p1Spans.any((s) => s.italic), isTrue);
      expect(p1Spans.any((s) => s.inlineImageUrl != null), isTrue);
      expect(p1Spans.any((s) => s.footnoteId == 'fn1'), isTrue);

      // 5. Blockquote callout box model
      final quoteIndex = paragraphs.indexOf('这是一段多看风格的引用框文字。');
      expect(quoteIndex, greaterThanOrEqualTo(0));
      final quoteStyle = layout.blocks[quoteIndex]!;
      expect(quoteStyle.kind, EpubBlockKind.blockquote);
      expect(quoteStyle.backgroundColor, isNotNull);
      expect(quoteStyle.borderLeftWidth, 4.0);

      // 6. Horizontal rule & Table
      final hrIndex = paragraphs.indexOf('───');
      expect(hrIndex, greaterThanOrEqualTo(0));
      expect(layout.blocks[hrIndex]!.kind, EpubBlockKind.hr);

      final tableIndex = paragraphs.indexWhere((p) => p.contains('SSR'));
      expect(tableIndex, greaterThanOrEqualTo(0));
      expect(layout.blocks[tableIndex]!.kind, EpubBlockKind.table);
      expect(layout.blocks[tableIndex]!.tableRows, [
        ['属性', '数值'],
        ['等级', 'SSR'],
      ]);

      // 7. Full-page image and figcaption
      final imgIndex = paragraphs.indexWhere(
        (p) => readerIllustrationUrl(p) != null,
      );
      expect(imgIndex, greaterThanOrEqualTo(0));
      expect(layout.blocks[imgIndex]!.kind, EpubBlockKind.fullPageImage);
      expect(layout.blocks[imgIndex]!.fullPage, isTrue);

      final captionIndex = paragraphs.indexOf('图一：全屏插图图注');
      expect(captionIndex, greaterThanOrEqualTo(0));
      expect(layout.blocks[captionIndex]!.kind, EpubBlockKind.figcaption);

      // 8. Embedded font extracted
      expect(layout.embeddedFonts, containsPair('dk-heading', 'font-0.ttf'));
      expect(book.fonts, contains('font-0.ttf'));
    },
  );

  test(
    'IDPF and Adobe font de-obfuscation restores original embedded font bytes',
    () {
      const uid = 'urn:uuid:12345678-1234-1234-1234-123456789abc';
      final originalFont = Uint8List.fromList(
        List<int>.generate(1200, (i) => (i * 37) & 0xFF),
      );
      final idpfKey = Uint8List.fromList(
        sha1.convert(utf8.encode(uid)).bytes,
      );
      final obfuscated = Uint8List.fromList(originalFont);
      for (var i = 0; i < 1040; i++) {
        obfuscated[i] ^= idpfKey[i % idpfKey.length];
      }
      final restored = EpubFontManager.deobfuscateFont(
        obfuscated,
        algorithm: 'http://www.idpf.org/2008/embedding',
        uniqueIdentifier: uid,
      );
      expect(restored, originalFont);

      final book = parseLocalBook(
        LocalBookInput(
          'obfuscated.epub',
          _buildRichEpub(
            overrides: {
              'META-INF/encryption.xml': '''
                <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <EncryptedData>
                    <EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
                    <CipherData><CipherReference URI="OPS/fonts/heading.ttf"/></CipherData>
                  </EncryptedData>
                </encryption>
              ''',
            },
            binaryOverrides: {'OPS/fonts/heading.ttf': obfuscated},
          ),
        ),
      );
      expect(book.fonts['font-0.ttf'], originalFont);
    },
  );

  test(
    'smart font tiering and theme color adaptation adjust cleanly across light and dark papers',
    () {
      // Dark paper adapts dark EPUB text to readable light color and light callout background to subtle dark surface
      final adaptedText = EpubColorAdapter.adaptTextColor(
        const Color(0xFF221100),
        paperColor: const Color(0xFF141416),
        defaultTextColor: const Color(0xFFE5E1DA),
      );
      expect(adaptedText.computeLuminance(), greaterThan(0.45));

      final adaptedBg = EpubColorAdapter.adaptBackgroundColor(
        const Color(0xFFF6F1E7),
        paperColor: const Color(0xFF141416),
        defaultTextColor: const Color(0xFFE5E1DA),
      );
      expect(adaptedBg, isNotNull);
      expect(adaptedBg!.computeLuminance(), lessThan(0.25));

      // Smart font tiering:
      final layout = const EpubChapterLayout(
        bodyFontFamily: 'DK-Body',
        embeddedFonts: {'dk-body': 'font-0.ttf', 'dk-heading': 'font-1.ttf'},
      );
      const baseStyle = TextStyle(fontFamily: 'UserCustomFont', fontSize: 20);
      // Body paragraph keeps user's custom font when userSelectedCustomFont is true
      final bodyStyle = resolveEpubBlockTextStyle(
        baseStyle: baseStyle,
        blockStyle: const EpubBlockStyle(kind: EpubBlockKind.paragraph),
        bookId: 100,
        epubLayout: layout,
        userSelectedCustomFont: true,
      );
      expect(bodyStyle.fontFamily, 'UserCustomFont');

      // Heading always honors its explicit EPUB heading font even when userSelectedCustomFont is true
      final headingStyle = resolveEpubBlockTextStyle(
        baseStyle: baseStyle,
        blockStyle: const EpubBlockStyle(
          kind: EpubBlockKind.heading1,
          fontFamily: 'DK-Heading',
        ),
        bookId: 100,
        epubLayout: layout,
        userSelectedCustomFont: true,
      );
      expect(headingStyle.fontFamily, 'epub_font_100_font-1.ttf');
      expect(headingStyle.fontSize, closeTo(20 * 1.45, 0.01));
    },
  );

  test(
    'old EPUB imports lazily upgrade rich layout on chapterContent read without altering prose',
    () async {
      final root = await Directory.systemTemp.createTemp('wenku-rich-upgrade-');
      addTearDown(() => root.delete(recursive: true));
      final store = LocalBookStore(root);
      addTearDown(store.dispose);
      await store.load();

      final bytes = _buildRichEpub();
      final book = await store.import(LocalBookInput('rich.epub', bytes));
      final layoutFile = File('${root.path}/${book.id}/c1.layout.json');
      expect(await layoutFile.exists(), isTrue);

      // Simulate an older import before richLayout: 1
      await layoutFile.delete();
      final recordFile = File('${root.path}/${book.id}/book.json');
      final record =
          jsonDecode(await recordFile.readAsString()) as Map<String, dynamic>;
      (record['source'] as Map).remove('richLayout');
      await recordFile.writeAsString(jsonEncode(record));

      final reopened = LocalBookStore(root);
      addTearDown(reopened.dispose);
      await reopened.load();
      final body = await reopened.chapterContent(
        book.id,
        reopened.book(book.id)!.chapters.first,
      );
      expect(await layoutFile.exists(), isTrue);
      final content = await ReaderContent.parse(body);
      expect(content.epubLayout, isNotNull);
      expect(content.epubLayout!.leadingHeading?.text, '第一章 序幕');
      expect(content.epubLayout!.footnotes, contains('fn1'));
    },
  );

  test(
    'horizontal and vertical pagination respect EPUB pageBreakBefore, headings, and inline spans',
    () async {
      final book = parseLocalBook(
        LocalBookInput('paged.epub', _buildRichEpub()),
      );
      final content = await ReaderContent.parse(book.bodies.first);
      expect(content.epubLayout, isNotNull);

      for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
        final pagination = await paginateReader(
          content: content,
          size: const Size(360, 680),
          style: const TextStyle(fontSize: 19, height: 1.7),
          preferences: ReaderPreferences(mode: mode, indent: true),
          scaler: TextScaler.noScaling,
          current: () => true,
        );
        expect(pagination, isNotNull, reason: mode.name);
        expect(pagination!.pages, isNotEmpty, reason: mode.name);
        // First fragment on page 0 is the preserved leadingHeading
        final firstFragment = pagination.pages.first.fragments.first;
        expect(firstFragment.isLeadingHeading, isTrue, reason: mode.name);
        expect(firstFragment.text, '第一章 序幕', reason: mode.name);
      }
    },
  );

  testWidgets(
    'scroll reader renders EPUB rich layout without duplicating chapter title and opens footnote popover on tap',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('wenku-rich-widget-'),
      ))!;
      addTearDown(() => root.delete(recursive: true));
      LocalBookMedia.root = root;
      final store = LocalBookStore(root);
      addTearDown(store.dispose);
      await tester.runAsync(store.load);
      final cache = OfflineCacheStore(Directory('${root.path}/cache'));
      addTearDown(cache.dispose);
      final repo = OfflineNovelRepository(
        remote: const DemoNovelRepository(),
        cache: cache,
        local: store,
      );
      addTearDown(repo.dispose);

      final book = (await tester.runAsync(
        () => store.import(LocalBookInput('duokan.epub', _buildRichEpub())),
      ))!;
      final state = (await tester.runAsync(LibraryState.load))!;
      addTearDown(state.dispose);
      await tester.runAsync(
        () => state.setReaderPreferences(
          const ReaderPreferences(mode: ReaderMode.scroll),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(Brightness.light),
          home: ReaderPage(
            novel: book,
            initialChapter: 0,
            state: state,
            repository: repo,
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }

      // Leading heading is rendered once with ValueKey('reader-chapter-title')
      expect(
        find.byKey(const ValueKey('reader-chapter-title')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('reader-chapter-title')),
          matching: find.text('第一章 序幕'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
      // Ruby and footnote overlays share the paragraph's measured layout.
      final annotations = tester
          .renderObjectList<RenderReaderAnnotations>(
            find.byType(ReaderAnnotations),
          )
          .toList();
      expect(annotations.expand((r) => r.debugRubyRects), isNotEmpty);
      final note = annotations.singleWhere((r) => r.debugNoteRects.isNotEmpty);

      // Tap footnote badge -> opens frosted glass footnote sheet without turning page
      await tester.tapAt(note.localToGlobal(note.debugNoteRects.first.center));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-footnote-sheet')),
        findsOneWidget,
      );
      expect(find.textContaining('这里是被自动抽离出正文的底部注释内容。'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'Duokan light novel markup (info.xhtml, intro.xhtml, chpr.xhtml) preserves container borders/breaks, font shorthands, inline badges, and br line breaks',
    () async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final archive = Archive();
      final files = <String, List<int>>{
        'mimetype': utf8.encode('application/epub+zip'),
        'META-INF/container.xml': utf8.encode(
          '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
        ),
        'OEBPS/content.opf': utf8.encode('''
          <package unique-identifier="BookId" version="2.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:title>突然有了未婚妻 第三卷</dc:title>
              <dc:creator>疎陀陽</dc:creator>
              <dc:identifier id="BookId">urn:uuid:11111111-2222-3333-4444-555555555555</dc:identifier>
            </metadata>
            <manifest>
              <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
              <item id="css" href="Styles/main.css" media-type="text/css"/>
              <item id="cover" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
              <item id="info" href="Text/info.xhtml" media-type="application/xhtml+xml"/>
              <item id="intro" href="Text/intro.xhtml" media-type="application/xhtml+xml"/>
              <item id="chpr" href="Text/chpr.xhtml" media-type="application/xhtml+xml"/>
              <item id="cimg" href="Images/cover.png" media-type="image/png"/>
            </manifest>
            <spine toc="ncx">
              <itemref idref="cover"/>
              <itemref idref="info"/>
              <itemref idref="intro"/>
              <itemref idref="chpr"/>
            </spine>
          </package>
        '''),
        'OEBPS/toc.ncx': utf8.encode('''
          <ncx><navMap>
            <navPoint id="n1" playOrder="1"><navLabel><text>产品信息</text></navLabel><content src="Text/info.xhtml"/></navPoint>
            <navPoint id="n2" playOrder="2"><navLabel><text>简介</text></navLabel><content src="Text/intro.xhtml"/></navPoint>
            <navPoint id="n3" playOrder="3"><navLabel><text>序 章 青梅竹马，与偶尔出现的丑角</text></navLabel><content src="Text/chpr.xhtml"/></navPoint>
          </navMap></ncx>
        '''),
        'OEBPS/Styles/main.css': utf8.encode('''
          p { text-align: justify; text-indent: 2em; line-height: 1.25; margin-top: 0; margin-bottom: 0; }
          p.title { font: bold 1.5em "DK-HEITI","黑体","ht",sans-serif; text-align: right; text-indent: 0em; margin: 2em 0; }
          div.info { margin: 1.5em 0 0 0; padding: 0.75em 0; border-top: 1px dotted; border-bottom: 1px dotted; }
          div.info p { font: 0.8em "DK-KAITI","楷体","kt",serif; text-indent: 0em; line-height: 1.25; margin: 0.25em 0.5em; }
          p.copyright { font: bold 0.9em "DK-HEITI","黑体","ht",sans-serif; color: #ff9b83; text-align: right; text-indent: 0em; margin: 1.5em 0 0 0; }
          p.book { font: bold 1.2em/1.25 "DK-HEITI","黑体","ht",sans-serif; color: #ff9b83; text-indent: 0em; margin: 0 0 0 1.25em; }
          hr.division { margin: 0.2em 0 0.75em 0; border: none; border-top: 0.36em solid #ffe1dc; }
          p.author { font: 0.9em "DK-KAITI","楷体","kt",serif; text-align: right; line-height: 1.5; margin: 0; }
          span.aul { color: #fff; font: normal 0.55em "DK-HEITI","黑体","ht",sans-serif; background-color: #65678a; padding: 0.15em 0.35em; margin: -0.1em 1.25em 0 -0.25em; }
          p.sty1 { font: 0.95em "DK-KAITI","楷体","kt",serif; margin: 1.5em 0 0 2em; }
          .center { text-align: center; text-indent: 0em; }
          div.aupg { margin-top: 3.25em; }
          .pgbkb { page-break-before: always; }
          h1 { font-size: 1.4em; line-height: 1.4; text-align: right; margin: 0 0 2em 0; }
          span.nmb { font: 0.85em "DK-HEITI","黑体","ht",sans-serif; color: #fd4e72; padding: 0 0.2em 0.1em 0.2em; border-bottom: 1px dotted #4fab43; }
        '''),
        'OEBPS/Text/cover.xhtml': utf8.encode('''
          <html><body><div><img src="../Images/cover.png"/></div></body></html>
        '''),
        'OEBPS/Text/info.xhtml': utf8.encode('''
          <html><head><link href="../Styles/main.css" rel="stylesheet" type="text/css"/></head>
          <body>
            <p class="title">产品信息</p>
            <div class="info">
              <p>书名：突然有了未婚妻 第三卷</p>
              <p>作者：疎陀陽</p>
              <p>插画：やすゆき</p>
              <p>感谢您对联创的关注与支持。</p>
            </div>
            <p class="copyright">仅供个人学习交流使用，禁作商业用途</p>
          </body></html>
        '''),
        'OEBPS/Text/intro.xhtml': utf8.encode('''
          <html><head><link href="../Styles/main.css" rel="stylesheet" type="text/css"/></head>
          <body>
            <p class="book">突然有了未婚妻，没想到对方竟然是闻名全校的『蛮横千金』 3</p>
            <hr class="division"/>
            <p class="author"><span class="aul">作者</span>疎陀陽</p>
            <p class="author"><span class="aul">插画</span>やすゆき</p>
            <p class="sty1 center">围绕着迟钝的浩之，<br/>恋爱的暴风狂吹不止？！</p>
            <div class="aupg pgbkb">
              <p>这次是第三集。承蒙各位读者购买本书，在此献上最深的谢意。</p>
              <p>多亏各位的支持，本系列才得以像这样推出续集。</p>
              <p>那么，我们在正篇故事中再见吧。</p>
            </div>
          </body></html>
        '''),
        'OEBPS/Text/chpr.xhtml': utf8.encode('''
          <html><head><link href="../Styles/main.css" rel="stylesheet" type="text/css"/></head>
          <body>
            <h1><span class="nmb">序 章</span><br/>青梅竹马，<span>与偶尔出现的丑角</span></h1>
            <p>「为什么事情会变成这样呢……」</p>
          </body></html>
        '''),
        'OEBPS/Images/cover.png': png,
      };
      for (final e in files.entries) {
        archive.addFile(
          ArchiveFile(e.key, e.value.length, e.value)..lastModTime = 1704067200,
        );
      }
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      final book = parseLocalBook(LocalBookInput('duokan_ln.epub', bytes));
      expect(book.layouts, hasLength(3));

      // Chapter 0 (cover + info.xhtml):
      final c0 = await ReaderContent.parse(book.bodies[0]);
      final l0 = c0.epubLayout!;
      expect(l0.blocks[0]!.kind, EpubBlockKind.fullPageImage);
      expect(l0.blocks[0]!.pageBreakAfter, isTrue);
      expect(l0.leadingHeading!.text, '产品信息');
      expect(l0.leadingHeading!.style.marginTopEm, closeTo(3.0, 0.01));
      // Only first paragraph of div.info has top dotted border, only last has bottom dotted border
      expect(l0.blocks[1]!.borderTopWidth, closeTo(1.0, 0.01));
      expect(l0.blocks[1]!.borderBottomWidth, 0.0);
      expect(l0.blocks[1]!.borderStyle, 'dotted');
      expect(l0.blocks[1]!.marginTopEm, closeTo(1.5, 0.01));
      expect(l0.blocks[1]!.effectivePaddingTopEm, closeTo(0.95, 0.01));
      expect(l0.blocks[1]!.marginLeftEm, 0);
      expect(l0.blocks[1]!.paddingEm, 0.4);
      expect(l0.blocks[2]!.marginTopEm, closeTo(0.2, 0.01));
      expect(
        resolveEpubBlockTextStyle(
          baseStyle: const TextStyle(fontSize: 20, height: 1.72),
          blockStyle: l0.blocks[2],
        ).height,
        closeTo(1.25, 0.01),
      );
      expect(l0.blocks[2]!.borderTopWidth, 0.0);
      expect(l0.blocks[2]!.borderBottomWidth, 0.0);
      expect(l0.blocks[4]!.borderBottomWidth, closeTo(1.0, 0.01));
      expect(l0.blocks[4]!.borderStyle, 'dotted');
      expect(l0.blocks[5]!.textColor, 0xFFFF9B83);

      final p0 = await paginateReader(
        content: c0,
        size: const Size(390, 760),
        style: const TextStyle(fontSize: 19, height: 1.6),
        preferences: const ReaderPreferences(mode: ReaderMode.paged),
        scaler: TextScaler.noScaling,
        current: () => true,
      );
      // Page 0 is cover image alone; Page 1 is all of info.xhtml!
      expect(p0!.pages, hasLength(2));
      expect(p0.pages[0].fragments.single.image, isTrue);
      expect(p0.pages[1].fragments.first.isLeadingHeading, isTrue);
      expect(p0.pages[1].fragments.first.text, '产品信息');

      // Chapter 1 (intro.xhtml):
      final c1 = await ReaderContent.parse(book.bodies[1]);
      final l1 = c1.epubLayout!;
      expect(l1.blocks[0]!.fontScale, closeTo(1.2, 0.01));
      expect(l1.blocks[0]!.textColor, 0xFFFF9B83);
      expect(l1.blocks[1]!.kind, EpubBlockKind.hr);
      expect(l1.blocks[1]!.borderTopWidth, greaterThan(4.0));
      expect(l1.blocks[1]!.borderColor, 0xFFFFE1DC);
      // Inline badge span.aul
      expect(l1.spans[2]!.first.backgroundColor, 0xFF65678A);
      expect(l1.spans[2]!.first.textColor, 0xFFFFFFFF);
      // Only first paragraph of div.aupg has pageBreakBefore: true
      final aupgIdx = c1.paragraphs.indexWhere((p) => p.contains('这次是第三集'));
      expect(l1.blocks[aupgIdx]!.pageBreakBefore, isTrue);
      expect(l1.blocks[aupgIdx + 1]?.pageBreakBefore ?? false, isFalse);
      expect(l1.blocks[aupgIdx + 2]?.pageBreakBefore ?? false, isFalse);

      final p1 = await paginateReader(
        content: c1,
        size: const Size(390, 760),
        style: const TextStyle(fontSize: 19, height: 1.6),
        preferences: const ReaderPreferences(mode: ReaderMode.paged),
        scaler: TextScaler.noScaling,
        current: () => true,
      );
      expect(p1!.pages, hasLength(2));

      // Chapter 2 (chpr.xhtml):
      final c2 = await ReaderContent.parse(book.bodies[2]);
      final l2 = c2.epubLayout!;
      expect(c2.paragraphs[0], '序\u2003章');
      expect(c2.paragraphs[1], '青梅竹马，与偶尔出现的丑角');
      expect(l2.blocks[0]!.marginBottomEm, 0.0);
      expect(l2.blocks[1]!.marginTopEm, 0.0);
      expect(l2.blocks[1]!.marginBottomEm, closeTo(2.8, 0.01));
      expect(l2.spans[0]!.first.textColor, 0xFFFD4E72);
      expect(l2.spans[0]!.first.underline, isTrue);
      expect(l2.spans[0]!.first.underlineColor, 0xFF4FAB43);
      expect(l2.spans[0]!.first.underlineStyle, 'dotted');
      expect(l2.spans[0]!.first.underlineOffsetEm, closeTo(0.18, 0.001));
      expect(l2.spans[0]!.first.underlinePaddingLeftEm, closeTo(0.2, 0.001));
      expect(l2.spans[0]!.first.underlinePaddingRightEm, closeTo(0.2, 0.001));
      expect(l2.blocks[1]!.lineBreakBefore, isTrue);
    },
  );

  test(
    'Duokan floating image shares the page with text and explicit blank lines add space',
    () async {
      final book = parseLocalBook(
        LocalBookInput(
          'float.epub',
          _buildRichEpub(
            overrides: {
              'OPS/styles/main.css': '''
          p { margin: 0.8em 0 0.1em; line-height: 1.125; text-indent: 2em; }
          .float-img { float: right; width: 45%; }
          .float-img img { width: 100%; }
        ''',
              'OPS/text/ch1.xhtml': '''
          <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
          <body><p>没错。</p><br/><p>这段文字前有一个明确的空行。</p>
          <div class="duokan-image-single float-img"><img src="../images/cover.png"/></div>
          <p>第一段文字在图片左侧排列，随着图片宽度改变而重新换行。</p>
          <p>第二段文字仍在图片左侧，段距也会改变它的位置。</p>
          <p>第三段文字继续围绕图片显示。</p></body></html>
        ''',
      },
    )));
    final content = await ReaderContent.parse(book.bodies.first);
    final imageIndex = content.paragraphs.indexWhere(
      (text) => readerIllustrationUrl(text) != null,
    );
    expect(imageIndex, greaterThan(1));
    expect(content.epubLayout!.blocks[imageIndex]!.floatRightWidthFraction,
        closeTo(0.45, 0.001));
    expect(content.formats[1]!.spacing.leading, contains('1.0em'));

    final imageUrl = readerIllustrationUrl(content.paragraphs[imageIndex])!;
    final pagination = await paginateReader(
      content: content,
      size: const Size(390, 760),
      style: const TextStyle(fontSize: 19, height: 1.6),
      preferences: const ReaderPreferences(mode: ReaderMode.paged),
      scaler: TextScaler.noScaling,
      localImageSizes: {imageUrl: const Size(600, 900)},
      current: () => true,
    );
    final page = pagination!.pages.firstWhere((page) => page.fragments.any(
      (fragment) => fragment.paragraph == imageIndex && fragment.image,
    ));
    final image = page.fragments.firstWhere((f) => f.paragraph == imageIndex);
    final prose = page.fragments.firstWhere((f) => f.paragraph == imageIndex + 1);
    expect(image.rect.right, closeTo(390, 0.1));
    expect(image.rect.width, closeTo(390 * .45, 0.1));
    expect(prose.rect.right, lessThan(image.rect.left));
    expect(prose.rect.top, lessThan(image.rect.bottom));
  });

  test('a block after a floating image starts below it', () async {
    final book = parseLocalBook(LocalBookInput('float-rule.epub', _buildRichEpub(
      overrides: {
        'OPS/styles/main.css': '''
          .float-img { float: right; width: 45%; }
          .float-img img { width: 100%; }
        ''',
        'OPS/text/ch1.xhtml': '''
          <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
          <body><div class="float-img"><img src="../images/cover.png"/></div>
          <p>短句。</p><hr/></body></html>
        ''',
      },
    )));
    final content = await ReaderContent.parse(book.bodies.first);
    final imageUrl = readerIllustrationUrl(content.paragraphs.first)!;
    final pagination = await paginateReader(
      content: content,
      size: const Size(390, 760),
      style: const TextStyle(fontSize: 19, height: 1.6),
      preferences: const ReaderPreferences(mode: ReaderMode.paged),
      scaler: TextScaler.noScaling,
      localImageSizes: {imageUrl: const Size(600, 900)},
      current: () => true,
    );
    final fragments = pagination!.pages.first.fragments;
    final image = fragments.firstWhere((fragment) => fragment.image);
    final rule = fragments.firstWhere((fragment) => fragment.rule);
    expect(rule.rect.top, greaterThanOrEqualTo(image.rect.bottom));
  });

  test('front matter keeps its compact publisher spacing', () async {
    final book = parseLocalBook(LocalBookInput('intro.epub', _buildRichEpub(
      overrides: {
        'OPS/styles/main.css': '''
          p { margin: 0.8em 0 0.1em; line-height: 1.125; text-indent: 2em; }
          .intro { margin-top: 0.15em; padding: 0.15em 0.5em 0.25em; }
          .intro p { margin: 0.5em; font-size: 0.93em; line-height: 1.2; text-indent: 0; }
          .intro p.sty1 { margin: 0 0.5em; font-size: 1.05em; text-align: center; }
        ''',
        'OPS/text/ch1.xhtml': '''
          <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
          <body><div class="intro">
            <p class="sty1">围绕着迟钝的浩之，<br/>恋爱的暴风狂吹不止？！</p>
            <p>身为青梅竹马的智美与凉子终于向浩之告白。</p>
            <p>“我们是不会放弃的！”</p>
          </div></body></html>
        ''',
          },
        ),
      ),
    );
    final content = await ReaderContent.parse(book.bodies.first);
    final blocks = content.epubLayout!.blocks;
    expect(content.paragraphs, hasLength(4));
    expect(blocks[2]!.marginTopEm, closeTo(0.465, 0.01));
    expect(blocks[2]!.marginBottomEm, closeTo(0.465, 0.01));
    expect(content.formats[2]!.spacing.before, contains('0.465em'));
    // The container's horizontal 0.5em padding belongs on each paragraph;
    // its vertical padding belongs only at the first/last container boundary.
    expect(blocks[2]!.effectivePaddingTopEm, 0);
    expect(blocks[2]!.effectivePaddingBottomEm, 0);
    expect(epubBlockTopExtra(blocks[2], 20), 0);
    expect(epubBlockBottomExtra(blocks[2], 20), 0);
    expect(
      resolveEpubBlockTextStyle(
        baseStyle: const TextStyle(fontSize: 20, height: 1.72),
        blockStyle: blocks[2],
      ).height,
      closeTo(1.2, 0.01),
    );
    expect(
      resolveEpubBlockTextStyle(
        baseStyle: const TextStyle(fontSize: 20, height: 2.2),
        blockStyle: blocks[2],
      ).height,
      greaterThan(1.2),
    );
    final pagination = await paginateReader(
      content: content,
      size: const Size(390, 760),
      style: const TextStyle(fontSize: 19, height: 1.72),
      preferences: const ReaderPreferences(
        mode: ReaderMode.paged,
        paragraphGap: 48,
        paragraphGapOverride: true,
      ),
      scaler: TextScaler.noScaling,
      current: () => true,
    );
    final fragments = pagination!.pages.first.fragments;
    expect(fragments[1].rect.top - fragments[0].rect.bottom, closeTo(0, 0.1));
    expect(
      fragments[3].rect.top - fragments[2].rect.bottom,
      closeTo(19 * .465, 0.1),
    );
  });

  test(
    'Duokan container padding keeps horizontal and vertical axes separate',
    () {
      final book = parseLocalBook(
        LocalBookInput(
          'container-padding.epub',
          _buildRichEpub(
            overrides: {
              'OPS/styles/main.css': '.wrapper { padding: 0.2em 0.6em 0.3em; }',
              'OPS/text/ch1.xhtml': '''
              <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
              <body><div class="wrapper"><p>第一段。</p><p>中间一段。</p>
              <p>最后一段。</p></div></body></html>
            ''',
            },
          ),
        ),
      );
      final blocks = book.layouts.single.blocks;
      expect(blocks[0]!.paddingEm, 0.6);
      expect(blocks[0]!.effectivePaddingTopEm, 0.2);
      expect(blocks[0]!.effectivePaddingBottomEm, 0);
      expect(blocks[1]!.paddingEm, 0.6);
      expect(blocks[1]!.effectivePaddingTopEm, 0);
      expect(blocks[1]!.effectivePaddingBottomEm, 0);
      expect(blocks[2]!.effectivePaddingTopEm, 0);
      expect(blocks[2]!.effectivePaddingBottomEm, 0.3);
    },
  );

  test(
    'Duokan body images flow with prose independently of paragraph-gap overrides',
    () async {
      final book = parseLocalBook(
        LocalBookInput(
          'body-image.epub',
          _buildRichEpub(
            overrides: {
              'OPS/styles/main.css':
                  '.duokan-image-single img { width: 100%; }',
              'OPS/text/ch1.xhtml': '''
          <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
          <body><p>图片前的文字。</p>
          <div class="duokan-image-single"><img src="../images/cover.png"/></div>
          <p>图片后的文字。</p><p>下一段正文。</p></body></html>
        ''',
            },
          ),
        ),
      );
      final content = await ReaderContent.parse(book.bodies.first);
      final imageUrl = readerIllustrationUrl(content.paragraphs[1])!;
      expect(content.epubLayout?.blocks[1]?.fullPage ?? false, isFalse);
      for (final gap in [0.0, 48.0]) {
        final pagination = await paginateReader(
          content: content,
          size: const Size(390, 760),
          style: const TextStyle(fontSize: 19, height: 1.72),
          preferences: ReaderPreferences(
            mode: ReaderMode.paged,
            paragraphGap: gap,
            paragraphGapOverride: true,
          ),
          scaler: TextScaler.noScaling,
          localImageSizes: {imageUrl: const Size(800, 600)},
          current: () => true,
        );
        expect(pagination!.pages, hasLength(1));
        final fragments = pagination.pages.single.fragments;
        expect(fragments[1].image, isTrue);
        expect(fragments[1].rect.top, closeTo(fragments[0].rect.bottom, 0.1));
        expect(fragments[2].rect.top, closeTo(fragments[1].rect.bottom, 0.1));
        expect(
          fragments[3].rect.top - fragments[2].rect.bottom,
          closeTo(gap, 0.1),
        );
      }
    },
  );

  for (final version in [5, 6, 7, 8, 9, 10, 11]) {
    test(
      'Duokan v$version imports discard stale full-page layout without changing text positions',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'wenku-v5-image-upgrade-',
        );
        addTearDown(() => root.delete(recursive: true));
        final store = LocalBookStore(root);
        addTearDown(store.dispose);
        await store.load();
        final book = await store.import(
          LocalBookInput(
            'v5-image.epub',
            _buildRichEpub(
              overrides: {
                'OPS/styles/main.css':
                    '.duokan-image-single img { width: 100%; }',
                'OPS/text/ch1.xhtml': '''
            <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
            <body><p>前文。</p><div class="duokan-image-single">
            <img src="../images/cover.png"/></div><p>后文。</p></body></html>
          ''',
              },
            ),
          ),
        );
        final before = await ReaderContent.parse(
          await store.chapterContent(book.id, book.chapters.first),
        );
        final recordFile = File('${root.path}/${book.id}/book.json');
        final record =
            jsonDecode(await recordFile.readAsString()) as Map<String, dynamic>;
        (record['source'] as Map)['richLayout'] = version;
        await recordFile.writeAsString(jsonEncode(record));
        final chapterFile = File(
          '${root.path}/${book.id}/c${book.chapters.first.id}.txt',
        );
        await chapterFile.writeAsString(
          (await chapterFile.readAsString()).replaceAll(';ci=24px', ''),
        );
        final layoutFile = File(
          '${root.path}/${book.id}/c${book.chapters.first.id}.layout.json',
        );
        await layoutFile.writeAsString(
          jsonEncode(
            const EpubChapterLayout(
              blocks: {
                1: EpubBlockStyle(
                  kind: EpubBlockKind.fullPageImage,
                  pageBreakBefore: true,
                  pageBreakAfter: true,
                ),
              },
            ).toJson(),
          ),
        );
        final reopened = LocalBookStore(root);
        addTearDown(reopened.dispose);
        await reopened.load();
        final after = await ReaderContent.parse(
          await reopened.chapterContent(book.id, book.chapters.first),
        );
        expect(after.paragraphs, before.paragraphs);
        expect(
          LocalImageLayout.fromParagraph(after.paragraphs[1]).containerInset,
          '24px',
        );
        expect(after.epubLayout?.blocks[1]?.fullPage ?? false, isFalse);
        expect(await layoutFile.exists(), isFalse);
        final updated = jsonDecode(await recordFile.readAsString()) as Map;
        expect((updated['source'] as Map)['richLayout'], 12);
      },
    );
  }

  test(
    'Duokan heading line breaks and CSS title spacing survive paragraph-gap overrides',
    () async {
      final book = parseLocalBook(
        LocalBookInput(
          'heading.epub',
          _buildRichEpub(
            overrides: {
              'OPS/styles/main.css': '''
          h1 { margin: 1.25em 0 1.12em; font-size: 1.16em; text-align: center; }
          span.nmb { font-size: 0.85em; padding: 0 0.36em 0.12em;
            border-bottom: 1px dotted #4fab43; }
        ''',
              'OPS/text/ch1.xhtml': '''
          <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
          <body><h1><span class="nmb">序　章</span><br/>副标题</h1>
          <p>标题之后的正文。</p></body></html>
        ''',
            },
          ),
        ),
      );
      final content = await ReaderContent.parse(book.bodies.first);
      final block = content.epubLayout!.blocks[0]!;
      expect(block.marginTopEm, closeTo(1.25 * 1.16, 0.001));
      expect(
        content.epubLayout!.blocks[1]!.marginBottomEm,
        closeTo(1.12 * 1.16, 0.001),
      );
      final restored = EpubBlockStyle.fromJson(block.toJson());
      expect(restored.separateVerticalPadding, isTrue);
      final span = content.epubLayout!.spans[0]!.first;
      expect(EpubInlineSpan.fromJson(span.toJson()).underlineOffsetEm, 0.18);
      expect(span.copyWithRange(0, 1).underlineOffsetEm, 0.18);
      expect(span.underlinePaddingLeftEm, 0.36);
      expect(span.underlinePaddingRightEm, 0.36);
      expect(
        EpubInlineSpan.fromJson(span.toJson()).underlinePaddingLeftEm,
        0.36,
      );
      expect(span.copyWithRange(0, 1).underlinePaddingRightEm, 0.36);
      expect(
        EpubInlineSpan.fromJson({
          's': 0,
          'e': 1,
          'u': true,
        }).underlinePaddingLeftEm,
        0,
      );
      // Keep visible space after the title underline before the next line.
      expect(
        block.effectivePaddingBottomEm,
        greaterThan(
          (span.underlineOffsetEm! + 0.3) *
              span.fontScale! *
              block.effectiveScale,
        ),
      );
      for (final gap in [0.0, 48.0]) {
        final pagination = await paginateReader(
          content: content,
          size: const Size(390, 760),
          style: const TextStyle(fontSize: 19, height: 1.72),
          preferences: ReaderPreferences(
            mode: ReaderMode.paged,
            paragraphGap: gap,
            paragraphGapOverride: true,
          ),
          scaler: TextScaler.noScaling,
          current: () => true,
        );
        final fragments = pagination!.pages.single.fragments;
        expect(fragments[1].rect.top, closeTo(fragments[0].rect.bottom, 0.1));
        expect(
          fragments[2].rect.top - fragments[1].rect.bottom,
          closeTo(19 * 1.12 * 1.16, 0.1),
        );
      }
    },
  );

  testWidgets(
    'Duokan title border stays below glyphs and keeps its TOC tap target',
    (tester) async {
      const text = '序　章';
      const spans = [
        EpubInlineSpan(
          start: 0,
          end: 3,
          fontScale: 0.85,
          underline: true,
          underlineOffsetEm: 0.12,
          underlinePaddingLeftEm: 0.36,
          underlinePaddingRightEm: 0.36,
          underlineColor: 0xFF4FAB43,
          underlineStyle: 'dotted',
          footnoteId: 'epub-action:toc',
        ),
      ];
      final match = ValueNotifier<ReaderMatch?>(null);
      addTearDown(match.dispose);
      String? tapped;
      for (final scale in [1.0, 1.4]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Center(
                  child: ReaderHighlightText(
                    index: 0,
                    text: text,
                    match: match,
                    style: const TextStyle(fontSize: 24, height: 1.3),
                    textAlign: TextAlign.center,
                    spans: spans,
                    onNote: (id) => tapped = id,
                  ),
                ),
              ),
            ),
          ),
        );
        final annotation = tester.renderObject<RenderReaderAnnotations>(
          find.byType(ReaderAnnotations),
        );
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byType(ReaderAnnotations),
            matching: find.byType(RichText),
          ),
        );
        final boxes = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 3),
        );
        final origin = paragraph.localToGlobal(
          Offset.zero,
          ancestor: annotation,
        );
        expect(
          annotation.debugInlineBorderRects.single.top,
          greaterThan(boxes.single.bottom + origin.dy),
        );
        final border = annotation.debugInlineBorderRects.single;
        final padding = 24 * 0.85 * 0.36 * scale;
        expect(
          border.left,
          closeTo(boxes.single.left + origin.dx - padding, .01),
        );
        expect(
          border.right,
          closeTo(boxes.single.right + origin.dx + padding, .01),
        );
        final built = buildRichParagraphSpans(
          text: text,
          style: const TextStyle(fontSize: 24, height: 1.3),
          indent: false,
          spans: spans,
        );
        final decorated = built.span.children!.whereType<TextSpan>().first;
        expect(
          decorated.style!.decoration!.contains(TextDecoration.underline),
          isFalse,
        );
        await tester.tapAt(
          annotation.localToGlobal(annotation.debugNoteRects.single.center),
        );
        expect(tapped, 'epub-action:toc');
        expect(tester.takeException(), isNull);
      }
    },
  );

  test(
    'Duokan wrapper image width and authored gaps survive reader settings',
    () async {
      final book = parseLocalBook(
        LocalBookInput(
          'width.epub',
          _buildRichEpub(
            overrides: {
              'OPS/styles/main.css': '''
        p { margin: 0.8em 0.5em 0.1em; text-indent: 2em; }
        .img-hr { width: 74%; margin: 0.5em 13%; }
        .duokan-image-single img { width: 100%; }
      ''',
              'OPS/text/ch1.xhtml': '''
        <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
        <body><p>图片之前。</p><div class="duokan-image-single img-hr">
        <img src="../images/cover.png"/></div><p>图片之后。</p></body></html>
      ''',
            },
          ),
        ),
      );
      final content = await ReaderContent.parse(book.bodies.single);
      final image = content.paragraphs[1];
      final url = readerIllustrationUrl(image)!;
      final sizing = LocalImageLayout.fromParagraph(image);
      expect(sizing.containerWidth, '74%');
      expect(
        LocalImageLayout.parseSuffix(sizing.suffix)!.containerWidth,
        '74%',
      );
      for (final width in [320.0, 420.0]) {
        expect(
          sizing
              .resolve(
                natural: const Size(800, 600),
                available: Size(width, 760),
              )
              .width,
          closeTo(width * .74, .01),
        );
        for (final gap in [0.0, 48.0]) {
          final pages = await paginateReader(
            content: content,
            size: Size(width, 760),
            style: const TextStyle(fontSize: 20, height: 1.5),
            preferences: ReaderPreferences(
              mode: ReaderMode.paged,
              paragraphGap: gap,
              paragraphGapOverride: true,
            ),
            scaler: TextScaler.noScaling,
            localImageSizes: {url: const Size(800, 600)},
            current: () => true,
          );
          final fragments = pages!.pages.single.fragments;
          expect(fragments[1].rect.width, closeTo(width * .74, .01));
          expect(fragments[1].rect.left, closeTo(width * .13, .01));
          expect(
            fragments[1].rect.top - fragments[0].rect.bottom,
            closeTo(10, .1),
          );
          expect(
            fragments[2].rect.top - fragments[1].rect.bottom,
            closeTo(10, .1),
          );
        }
      }
    },
  );

  testWidgets(
    'Duokan percentage title insets match text measurement at different widths',
    (tester) async {
      final book = parseLocalBook(
        LocalBookInput(
          'insets.epub',
          _buildRichEpub(
            overrides: {
              'OPS/styles/main.css':
                  '.title { margin: 0.25em auto 0.25em 5%; font-size: 1.15em; text-indent: 0; }',
              'OPS/text/ch1.xhtml': '''
        <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
        <body><p class="title">书名标题。</p><p>正文。</p></body></html>
      ''',
            },
          ),
        ),
      );
      final style = book.layouts.single.blocks[0]!;
      final restored = EpubBlockStyle.fromJson(style.toJson());
      expect(restored.relativeInsets['margin-left'], .05);
      expect(restored.marginLeftEm, 0);
      for (final width in [320.0, 420.0]) {
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: ReaderBlockDecoration(
                  blockStyle: restored,
                  fontSize: 20,
                  paperColor: Colors.white,
                  onPaperColor: Colors.black,
                  accentColor: Colors.blue,
                  child: SizedBox(key: key, height: 20),
                ),
              ),
            ),
          ),
        );
        expect(
          tester.getTopLeft(find.byKey(key)).dx,
          closeTo(width * .05, .01),
        );
        expect(
          tester.getSize(find.byKey(key)).width,
          closeTo(
            width - epubBlockHorizontalInset(restored, 20, width: width),
            .01,
          ),
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  test(
    'Duokan author paragraphs retain gaps and container margins collapse',
    () async {
      for (final forcedPage in [false, true]) {
        final book = parseLocalBook(
          LocalBookInput(
            'authors.epub',
            _buildRichEpub(
              overrides: {
                'OPS/styles/main.css':
                    '''
        p { margin: 0.8em 0 0.1em; text-indent: 2em; }
        .aupg { margin-top: 3.25em; ${forcedPage ? "page-break-before: always;" : ""} }
        .aupg p { margin: 0.2em auto 0.5em; font-size: 0.95em; text-indent: 0; }
        .aupg .aut { margin: 1.2em auto 0.4em; padding: 0.15em 23% 0.1em;
          border-top: 1px dotted; border-bottom: 1px dotted;
          font: bold 1.2em/1.25 serif; text-align: center; }
      ''',
                'OPS/text/ch1.xhtml': '''
        <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
        <body><div class="aupg"><p class="aut">作者</p><p>第一段。</p>
        <p>第二段。</p><p>第三段。</p></div></body></html>
      ''',
              },
            ),
          ),
        );
        final content = await ReaderContent.parse(book.bodies.single);
        final blocks = content.epubLayout!.blocks;
        expect(blocks[0]!.marginTopEm, closeTo(forcedPage ? 4.69 : 3.25, .001));
        expect(blocks[0]!.relativeInsets['padding-left'], .23);
        expect(blocks[1]!.marginBottomEm, .475);
        expect(blocks[2]!.marginTopEm, .19);
        for (final gap in [0.0, 48.0]) {
          final pages = await paginateReader(
            content: content,
            size: const Size(390, 760),
            style: const TextStyle(fontSize: 20, height: 1.5),
            preferences: ReaderPreferences(
              mode: ReaderMode.paged,
              paragraphGap: gap,
              paragraphGapOverride: true,
            ),
            scaler: TextScaler.noScaling,
            current: () => true,
          );
          final fragments = pages!.pages.single.fragments;
          expect(fragments.first.rect.top, closeTo(forcedPage ? 93.8 : 65, .1));
          expect(
            fragments[2].rect.top - fragments[1].rect.bottom,
            closeTo(9.5, .1),
          );
          expect(
            fragments[3].rect.top - fragments[2].rect.bottom,
            closeTo(9.5, .1),
          );
        }
      }
    },
  );

  testWidgets('Duokan thin CSS rule and split heading keep matching extents', (
    tester,
  ) async {
    final book = parseLocalBook(
      LocalBookInput(
        'rule.epub',
        _buildRichEpub(
          overrides: {
            'OPS/styles/main.css': '''
        .intro .sty1 { font-size: 1.05em; font-weight: bold; text-align: center;
          text-indent: 0; line-height: 1.2; margin: 0; }
        hr { height: 0.1em; margin: 0.5em 0 1.25em; border: none; border-top: 0.36em solid pink; }
        .intro p { font-size: 0.93em; text-indent: 0; margin: 0.5em; }
      ''',
            'OPS/text/ch1.xhtml': '''
        <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
        <body><div class="intro"><p class="sty1">第一行标题<br/>第二行标题</p>
        <hr/><p>简介正文。</p></div></body></html>
      ''',
          },
        ),
      ),
    );
    final content = await ReaderContent.parse(book.bodies.single);
    final blocks = content.epubLayout!.blocks;
    expect(
      resolveEpubBlockTextStyle(
        baseStyle: const TextStyle(fontSize: 20, height: 1.5),
        blockStyle: blocks[0],
      ).height,
      closeTo(1.2, .01),
    );
    final rule = EpubBlockStyle.fromJson(blocks[2]!.toJson());
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: ReaderHorizontalRule(
            key: key,
            color: Colors.black,
            blockStyle: rule,
            fontSize: 20,
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(key)).height, closeTo(9.2, .01));
    final pages = await tester.runAsync(
      () => paginateReader(
        content: content,
        size: const Size(390, 760),
        style: const TextStyle(fontSize: 20, height: 1.5),
        preferences: const ReaderPreferences(
          mode: ReaderMode.paged,
          paragraphGap: 48,
          paragraphGapOverride: true,
        ),
        scaler: TextScaler.noScaling,
        current: () => true,
      ),
    );
    final fragments = pages!.pages.single.fragments;
    expect(fragments[1].rect.top - fragments[0].rect.bottom, closeTo(0, .1));
    expect(fragments[2].rect.height, closeTo(9.2, .01));
    expect(fragments[2].rect.top - fragments[1].rect.bottom, closeTo(10, .1));
    expect(fragments[3].rect.top - fragments[2].rect.bottom, closeTo(25, .1));
    expect(tester.takeException(), isNull);
  });

  test(
    'Duokan bleed widths stay fixed while ordinary blocks follow page margins',
    () async {
      final book = parseLocalBook(
        LocalBookInput(
          'bleed.epub',
          _buildRichEpub(
            overrides: {
              'OPS/styles/main.css': '''
        .page-margin-no { duokan-bleed: leftright; }
        .page-margin-no p { margin: 0.8em 0.5em 0.1em; }
        .info p { font: 0.8em sans-serif; }
        .aupg p { font-size: 0.95em; }
      ''',
              'OPS/text/ch1.xhtml': '''
        <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
        <body><div class="page-margin-no"><div class="info"><p>制作信息</p></div>
        <p>正文。</p></div><div class="aupg"><p>作者介绍。</p></div></body></html>
      ''',
            },
          ),
        ),
      );
      final content = await ReaderContent.parse(book.bodies.single);
      final blocks = content.epubLayout!.blocks;
      expect(content.hasHorizontalBleed, isTrue);
      expect(
        EpubBlockStyle.fromJson(blocks[0]!.toJson()).horizontalBleed,
        isTrue,
      );
      expect(blocks[1]!.marginLeftEm, .5);
      expect(blocks[2]!.horizontalBleed, isFalse);
      for (final margin in [10.0, 26.0, 48.0]) {
        final prefs = ReaderPreferences(mode: ReaderMode.paged, margin: margin);
        final padding = readerPublisherPagePadding(
          content,
          prefs,
          EdgeInsets.fromLTRB(margin, 32, margin, 40),
        );
        expect(padding.horizontal, 0);
        final pages = await paginateReader(
          content: content,
          size: const Size(390, 760),
          style: const TextStyle(fontSize: 20, height: 1.5),
          preferences: prefs,
          pageMarginsInside: true,
          scaler: TextScaler.noScaling,
          current: () => true,
        );
        final fragments = pages!.pages.single.fragments;
        expect(fragments[0].rect.left, 0);
        expect(fragments[0].rect.width, 390);
        expect(fragments[1].rect.width, 390);
        expect(fragments[2].rect.left, margin);
        expect(fragments[2].rect.width, 390 - margin * 2);
      }
    },
  );

  testWidgets(
    'Duokan paged host preserves bleed and normal block widths after reflow',
    (tester) async {
      const content = ReaderContent(
        ['制作信息', '作者介绍'],
        epubLayout: EpubChapterLayout(
          blocks: {
            0: EpubBlockStyle(horizontalBleed: true),
            1: EpubBlockStyle(pageBreakBefore: true),
          },
        ),
      );
      final controller = ReaderPagedController();
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final margin in [10.0, 48.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPagedView(
              content: content,
              controller: controller,
              preferences: ReaderPreferences(
                mode: ReaderMode.paged,
                margin: margin,
              ),
              style: const TextStyle(fontSize: 20, height: 1.3),
              title: '简介',
              bookTitle: '测试书',
              padding: EdgeInsets.fromLTRB(margin, 32, margin, 40),
              reduceMotion: true,
              pageBuilder: (_) => const SizedBox.expand(),
              onReady: () {},
              onChanged: () {},
              onUserScroll: () {},
              onBoundary: (_) {},
            ),
          ),
        );
        for (var i = 0; i < 20 && !controller.ready; i++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(controller.ready, isTrue);
        await tester.pump();
        expect(controller.pageSize!.width, 390);
        final pages = controller.debugPagination!.pages;
        expect(pages[0].fragments.single.rect.width, 390);
        expect(pages[1].fragments.single.rect.left, margin);
        expect(pages[1].fragments.single.rect.width, 390 - margin * 2);
        final footer = find.byKey(const ValueKey('reader-bottom-location'));
        expect(tester.getRect(footer).left, margin);
        expect(tester.getRect(footer).right, 390 - margin);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'Duokan box em units use the local font while rem and px stay fixed',
    () {
      final book = parseLocalBook(
        LocalBookInput(
          'units.epub',
          _buildRichEpub(
            overrides: {
              'OPS/styles/main.css': '''
        .local { font-size: 0.8em; margin: 0.5em; padding: 0.25em; }
        .root { font-size: 0.8em; margin: 0.5rem; padding: 8px; }
        .large { font-size: 1.2em; margin: 0.5em; padding: 0.25em; }
      ''',
              'OPS/text/ch1.xhtml': '''
        <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
        <body><p class="local">小字号</p><p class="root">固定单位</p>
        <p class="large">大字号</p></body></html>
      ''',
            },
          ),
        ),
      );
      final blocks = book.layouts.single.blocks;
      expect(blocks[0]!.marginLeftEm, closeTo(.4, .001));
      expect(blocks[0]!.paddingEm, closeTo(.2, .001));
      expect(blocks[1]!.marginLeftEm, closeTo(.5, .001));
      expect(blocks[1]!.paddingEm, closeTo(.5, .001));
      expect(blocks[2]!.marginLeftEm, closeTo(.6, .001));
      expect(blocks[2]!.paddingEm, closeTo(.3, .001));
    },
  );

  test('Duokan font shorthand resets inherited weight and leading', () {
    final book = parseLocalBook(
      LocalBookInput(
        'font.epub',
        _buildRichEpub(
          overrides: {
            'OPS/styles/main.css':
                '.info { font-weight: bold; font-style: italic; line-height: 2; } .info p { font: 0.8em sans-serif; text-indent: 0; }',
            'OPS/text/ch1.xhtml':
                '<html><head><link rel="stylesheet" href="../styles/main.css"/></head><body><div class="info"><p>制作信息</p></div></body></html>',
          },
        ),
      ),
    );
    final block = book.layouts.single.blocks[0]!;
    expect(block.fontWeight, 400);
    expect(block.italic, isFalse);
    expect(block.lineHeight, 1.15);
    expect(
      resolveEpubBlockTextStyle(
        baseStyle: const TextStyle(fontSize: 18, height: 1.3),
        blockStyle: block,
      ).height,
      closeTo(1.15, .001),
    );
  });

  testWidgets('Duokan plate previews keep gutters and authored top placement', (
    tester,
  ) async {
    final book = parseLocalBook(
      LocalBookInput(
        'plates.epub',
        _buildRichEpub(
          overrides: {
            'OPS/styles/main.css':
                '.duokan-image-single img { width: 100%; } .pgbkb { page-break-before: always; }',
            'OPS/text/ch1.xhtml': '''
        <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
        <body><div class="duokan-image-single" style="margin-top:25%">
        <img src="../images/cover.png"/></div>
        <div class="duokan-image-single pgbkb" style="margin-top:42%">
        <img src="../images/cover.png"/><p class="duokan-image-maintitle">1-1</p>
        </div></body></html>
      ''',
          },
        ),
      ),
    );
    final content = await ReaderContent.parse(book.bodies.single);
    final url = readerIllustrationUrl(content.paragraphs.first)!;
    final layout = LocalImageLayout.fromParagraph(content.paragraphs.first);
    expect(content.imageOnly, isTrue);
    EdgeInsets? stablePadding;
    for (final margin in [0.0, 8.0, 44.0, 80.0]) {
      final prefs = ReaderPreferences(
        mode: ReaderMode.paged,
        margin: margin,
        marginTop: margin,
        marginBottom: margin,
      );
      final padding = readerPublisherPagePadding(
        content,
        prefs,
        EdgeInsets.fromLTRB(margin, 35 + margin, margin, 40 + margin),
      );
      stablePadding ??= padding;
      expect(padding, stablePadding);
    }
    final natural = const Size(1200, 1800);
    final pages = await tester.runAsync(
      () => paginateReader(
        content: content,
        size: const Size(390, 760),
        style: const TextStyle(fontSize: 20, height: 1.5),
        preferences: const ReaderPreferences(mode: ReaderMode.paged),
        scaler: TextScaler.noScaling,
        localImageSizes: {url: natural},
        current: () => true,
      ),
    );
    expect(pages!.pages, hasLength(2));
    final portrait = pages.pages[0].fragments.single;
    expect(portrait.rect.top, closeTo(342 * .25, .1));
    expect(portrait.rect.width, closeTo(342, .1));
    final second = pages.pages[1].fragments;
    expect(second.first.rect.top, closeTo(342 * .42, .1));
    expect(second.last.rect.bottom, lessThanOrEqualTo(760));
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          child: Center(
            child: SizedBox(
              width: 390,
              child: ReaderIllustrationFrame(
                preserveSize: true,
                imageSize: natural,
                localLayout: layout,
                fontSize: 20,
                child: SizedBox(key: key),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(key)), portrait.rect.size);
    expect(tester.takeException(), isNull);
  });

  test(
    'Duokan side-by-side plates preserve table spacing and paper gutters',
    () async {
      final book = parseLocalBook(
        LocalBookInput(
          'bookmarks.epub',
          _buildRichEpub(
            overrides: {
              'OPS/styles/main.css': '''
              table.abreast { margin: 45% 0 0; }
              table.abreast td { padding: 0; }
            ''',
              'OPS/text/ch1.xhtml': '''
              <html><head><link rel="stylesheet" href="../styles/main.css"/></head>
              <body><table class="abreast"><tr>
                <td><img src="../images/cover.png"/></td>
                <td><img src="../images/cover.png"/></td>
              </tr><tr><td colspan="2"><p>书签</p></td></tr></table></body></html>
            ''',
            },
          ),
        ),
      );
      final content = await ReaderContent.parse(book.bodies.single);
      final imageIndex = content.paragraphs.indexWhere(
        (text) => readerIllustrationUrl(text) != null,
      );
      final block = content.epubLayout!.blocks[imageIndex]!;
      expect(block.sideBySideImageUrls, hasLength(2));
      expect(block.relativeInsets['margin-top'], closeTo(.45, .001));

      final url = readerIllustrationUrl(content.paragraphs[imageIndex])!;
      final pages = await paginateReader(
        content: content,
        size: const Size(390, 760),
        style: const TextStyle(fontSize: 20, height: 1.5),
        preferences: const ReaderPreferences(mode: ReaderMode.paged),
        scaler: TextScaler.noScaling,
        localImageSizes: {url: const Size(600, 900)},
        current: () => true,
      );
      final image = pages!.pages
          .expand((page) => page.fragments)
          .firstWhere((fragment) => fragment.paragraph == imageIndex);
      expect(image.rect.left, closeTo(readerPublisherImageGutter, .1));
      expect(image.rect.right, closeTo(390 - readerPublisherImageGutter, .1));
      expect(
        image.rect.top,
        closeTo((390 - readerPublisherImageGutter * 2) * .45, .1),
      );
    },
  );
}
