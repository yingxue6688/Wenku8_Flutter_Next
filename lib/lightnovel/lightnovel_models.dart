import 'package:flutter/material.dart' show Color, immutable;

import '../catalog.dart';

/// Defensive JSON map helper.
///
/// PHP-backed LightNovel endpoints often serialize empty objects (e.g.
/// `poster_user`, `legacy_resources`, `prev_chapter`) as empty array `[]`.
/// Returning `null` for lists and non-map values prevents type-cast crashes.
Map<String, dynamic>? asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        if (entry.key != null) '${entry.key}': entry.value,
    };
  }
  return null;
}

/// Defensive JSON list helper returning an empty list for non-list values.
List<dynamic> asList(Object? value) =>
    value is List<dynamic> ? value : (value is List ? List<dynamic>.from(value) : const []);

/// Defensive integer parser accepting `int`, finite `num`, or numeric `String`.
int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.isFinite ? value.toInt() : null;
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed);
  }
  return null;
}

/// Defensive double parser accepting finite `num` or numeric `String`.
double? asDouble(Object? value) {
  if (value is double) return value.isFinite ? value : null;
  if (value is int) return value.toDouble();
  if (value is num) return value.isFinite ? value.toDouble() : null;
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final parsed = double.tryParse(trimmed);
    return parsed != null && parsed.isFinite ? parsed : null;
  }
  return null;
}

/// Defensive string parser accepting `String`, `num`, or `bool`.
String? asString(Object? value) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return null;
}

/// Returns a trimmed string when non-empty, or `null` otherwise.
String? asNonEmptyString(Object? value) {
  final text = asString(value)?.trim();
  return text == null || text.isEmpty ? null : text;
}

/// Defensive `0|1` / boolean parser.
bool asBool01(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value.isFinite ? value != 0 : fallback;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case '1':
      case 'true':
      case 'yes':
        return true;
      case '0':
      case 'false':
      case 'no':
      case '':
        return false;
    }
  }
  return fallback;
}

String? _normalizeMediaUrl(String? raw) {
  final trimmed = raw?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (trimmed.startsWith('//')) return 'https:$trimmed';
  return trimmed;
}

@immutable
class LightNovelPagination {
  const LightNovelPagination({
    required this.page,
    required this.pageSize,
    this.total,
    this.pageCount,
    this.hasNext = false,
    this.hasPrev = false,
  });

  final int page;
  final int pageSize;
  final int? total;
  final int? pageCount;
  final bool hasNext;
  final bool hasPrev;

  bool get hasMore =>
      hasNext || (pageCount != null && page < pageCount!);

  factory LightNovelPagination.fromResponse(
    Map<String, dynamic> data, {
    required int requestedPage,
    int defaultPageSize = 20,
    int itemCount = 0,
  }) {
    final p = asMap(data['pagination']);
    final pi = asMap(data['page_info']);

    final page = asInt(p?['page']) ?? asInt(pi?['cur']) ?? requestedPage;
    final pageSize =
        asInt(p?['page_size']) ??
        asInt(p?['pageSize']) ??
        asInt(pi?['size']) ??
        defaultPageSize;
    final total =
        asInt(p?['total']) ?? asInt(pi?['count']) ?? asInt(data['total']);
    final pageCount =
        asInt(p?['page_count']) ??
        asInt(p?['pageCount']) ??
        (total != null && pageSize > 0 ? (total / pageSize).ceil() : null);

    final bool? rawHasNext;
    if (data.containsKey('has_next')) {
      rawHasNext = asBool01(data['has_next']);
    } else if (pi != null && pi.containsKey('has_next')) {
      rawHasNext = asBool01(pi['has_next']);
    } else {
      rawHasNext = null;
    }

    final hasNext = itemCount > 0 &&
        (rawHasNext ??
            (pageCount != null
                ? page < pageCount
                : itemCount >= pageSize));

    final hasPrev = pi != null && pi.containsKey('has_prev')
        ? asBool01(pi['has_prev'])
        : page > 1;

    return LightNovelPagination(
      page: page,
      pageSize: pageSize,
      total: total,
      pageCount: pageCount,
      hasNext: hasNext,
      hasPrev: hasPrev,
    );
  }
}

@immutable
class LightNovelBookCard {
  const LightNovelBookCard({
    required this.bookId,
    required this.title,
    this.authorName = '',
    this.illustratorName,
    this.summary = '',
    this.summaryShort = '',
    this.coverUrl,
    this.bannerUrl,
    this.updatedAt,
    this.latestChapterPublishedAt,
    this.createdAt,
    this.defaultVolumeId = 0,
    this.defaultChapterId = 0,
    this.wordCount = 0,
    this.volumeCount = 0,
    this.chapterCount = 0,
    this.publishedChapterCount = 0,
    this.serialStatus = 'serializing',
    this.isCompleted = false,
    this.epubReady = false,
    this.ratingScore10,
    this.ratingStarsAverage,
    this.ratingCount = 0,
    this.ratingDisplayable = false,
    this.displayBadgeCode,
    this.displayBadgeText,
    this.workTypeCode,
    this.workTypeText,
    this.tags = const [],
    this.posterUser,
    this.readState,
  });

  final int bookId;
  final String title;
  final String authorName;
  final String? illustratorName;
  final String summary;
  final String summaryShort;
  final String? coverUrl;
  final String? bannerUrl;
  final String? updatedAt;
  final String? latestChapterPublishedAt;
  final String? createdAt;
  final int defaultVolumeId;
  final int defaultChapterId;
  final int wordCount;
  final int volumeCount;
  final int chapterCount;
  final int publishedChapterCount;
  final String serialStatus;
  final bool isCompleted;
  final bool epubReady;
  final double? ratingScore10;
  final double? ratingStarsAverage;
  final int ratingCount;
  final bool ratingDisplayable;
  final String? displayBadgeCode;
  final String? displayBadgeText;
  final String? workTypeCode;
  final String? workTypeText;
  final List<String> tags;
  final Map<String, dynamic>? posterUser;
  final Map<String, dynamic>? readState;

  static const _palettes = <List<Color>>[
    [Color(0xFF5E87B8), Color(0xFF222C5B)],
    [Color(0xFF66C9BC), Color(0xFF276A8F)],
    [Color(0xFFE6A5B7), Color(0xFF8F658E)],
    [Color(0xFFE9B277), Color(0xFFB76E6E)],
  ];

  static List<Color> paletteForBook(int bookId) =>
      _palettes[bookId.abs() % _palettes.length];

  factory LightNovelBookCard.fromJson(Map<String, dynamic> json) {
    final readState = asMap(json['read_state']);
    final workType = asMap(json['work_type']);
    final posterUser = asMap(json['poster_user']);

    final rawTags = <String>[];
    final seenTags = <String>{};
    void addTagList(Object? source) {
      for (final item in asList(source)) {
        final tag = asNonEmptyString(item);
        if (tag != null && seenTags.add(tag)) {
          rawTags.add(tag);
        }
      }
    }

    addTagList(json['tags']);
    addTagList(json['visible_tags']);

    final serialStatus = asNonEmptyString(json['serial_status']) ?? 'serializing';
    final isCompleted =
        asBool01(json['is_completed']) || serialStatus == 'completed';

    String? badgeCode = asNonEmptyString(json['display_badge_code']);
    String? badgeText = asNonEmptyString(json['display_badge_text']);
    if (badgeText == null) {
      for (final rawBadge in asList(json['discovery_badges'])) {
        final badge = asMap(rawBadge);
        final text = asNonEmptyString(badge?['text']);
        if (text != null) {
          badgeText = text;
          badgeCode ??= asNonEmptyString(badge?['code']);
          break;
        }
      }
    }

    final summary = (asString(json['summary']) ?? '').replaceAll('\r\n', '\n').trim();
    final summaryShort = (asString(json['summary_short']) ?? '')
        .replaceAll('\r\n', '\n')
        .trim();

    return LightNovelBookCard(
      bookId: asInt(json['book_id']) ?? asInt(json['id']) ?? 0,
      title: (asString(json['title']) ?? '').trim(),
      authorName: (asString(json['author_name']) ?? asString(json['author']) ?? '')
          .trim(),
      illustratorName: asNonEmptyString(json['illustrator_name']),
      summary: summary.isNotEmpty ? summary : summaryShort,
      summaryShort: summaryShort,
      coverUrl: _normalizeMediaUrl(asNonEmptyString(json['cover_url'])),
      bannerUrl: _normalizeMediaUrl(asNonEmptyString(json['banner_url'])),
      updatedAt:
          asNonEmptyString(json['updated_at']) ??
          asNonEmptyString(json['latest_chapter_published_at']),
      latestChapterPublishedAt:
          asNonEmptyString(json['latest_chapter_published_at']),
      createdAt: asNonEmptyString(json['created_at']),
      defaultVolumeId:
          asInt(json['default_volume_id']) ??
          asInt(readState?['default_volume_id']) ??
          0,
      defaultChapterId:
          asInt(json['default_chapter_id']) ??
          asInt(readState?['default_chapter_id']) ??
          0,
      wordCount: asInt(json['word_count']) ?? 0,
      volumeCount:
          asInt(json['volume_count']) ?? asInt(readState?['volume_count']) ?? 0,
      chapterCount:
          asInt(json['chapter_count']) ??
          asInt(json['published_chapter_count']) ??
          asInt(readState?['published_chapter_count']) ??
          0,
      publishedChapterCount:
          asInt(json['published_chapter_count']) ??
          asInt(readState?['published_chapter_count']) ??
          0,
      serialStatus: serialStatus,
      isCompleted: isCompleted,
      epubReady: asBool01(json['epub_ready']),
      ratingScore10: asDouble(json['rating_score_10']),
      ratingStarsAverage: asDouble(json['rating_stars_average']),
      ratingCount: asInt(json['rating_count']) ?? 0,
      ratingDisplayable: asBool01(json['rating_displayable']),
      displayBadgeCode: badgeCode,
      displayBadgeText: badgeText,
      workTypeCode: asNonEmptyString(workType?['code']),
      workTypeText: asNonEmptyString(workType?['text']),
      tags: List<String>.unmodifiable(rawTags),
      posterUser: posterUser,
      readState: readState,
    );
  }

  /// Maps this LightNovel book card cleanly onto the existing [Novel] model.
  Novel toNovel() {
    final normalizedTags = tags
        .map((tag) => tag.replaceAll(RegExp(r'\s+'), '').trim())
        .where((tag) => tag.isNotEmpty)
        .toList();
    final effectiveSummary = cleanNovelSummary(
      summary.isNotEmpty ? summary : summaryShort,
    );
    return Novel(
      id: bookId,
      title: title.isNotEmpty ? title : '书籍 $bookId',
      author: authorName.isNotEmpty ? authorName : '佚名',
      genre: normalizedTags.join(' '),
      summary: effectiveSummary,
      colors: paletteForBook(bookId),
      isComplete: isCompleted,
      coverUrl: coverUrl,
      lastUpdate: updatedAt,
      chapterCount: chapterCount > 0 ? chapterCount : publishedChapterCount,
      illustrator: illustratorName,
      rating: ratingScore10,
      wordCount: wordCount > 0 ? wordCount : null,
      badge: displayBadgeText,
    );
  }
}

@immutable
class LightNovelChannel {
  const LightNovelChannel({
    required this.code,
    required this.label,
    this.kind = '',
    this.jumpType = '',
    this.jumpValue = '',
    this.workType = '',
  });

  final String code;
  final String label;
  final String kind;
  final String jumpType;
  final String jumpValue;
  final String workType;

  factory LightNovelChannel.fromJson(Map<String, dynamic> json) {
    final filter = asMap(json['filter']);
    final payload = asMap(json['filter_payload']);
    return LightNovelChannel(
      code: (asString(json['code']) ?? '').trim(),
      label: (asString(json['label']) ?? asString(json['title']) ?? '').trim(),
      kind: (asString(json['kind']) ?? '').trim(),
      jumpType: (asString(json['jump_type']) ?? '').trim(),
      jumpValue: (asString(json['jump_value']) ?? '').trim(),
      workType:
          (asString(filter?['work_type']) ??
                  asString(payload?['work_type']) ??
                  asString(json['code']) ??
                  '')
              .trim(),
    );
  }
}

@immutable
class LightNovelTagItem {
  const LightNovelTagItem({
    required this.tagId,
    required this.name,
    this.displayGroup = '',
    this.tagKind = '',
    this.alias = '',
  });

  final int tagId;
  final String name;
  final String displayGroup;
  final String tagKind;
  final String alias;

  factory LightNovelTagItem.fromJson(Map<String, dynamic> json) =>
      LightNovelTagItem(
        tagId: asInt(json['tag_id']) ?? asInt(json['id']) ?? 0,
        name: (asString(json['name']) ?? asString(json['title']) ?? '').trim(),
        displayGroup: (asString(json['display_group']) ?? '').trim(),
        tagKind: (asString(json['tag_kind']) ?? '').trim(),
        alias: (asString(json['alias']) ?? '').trim(),
      );
}

@immutable
class LightNovelFilterOption {
  const LightNovelFilterOption({
    required this.key,
    required this.title,
    this.displayGroup = '',
  });

  final String key;
  final String title;
  final String displayGroup;

  factory LightNovelFilterOption.fromJson(Map<String, dynamic> json) =>
      LightNovelFilterOption(
        key: (asString(json['key']) ?? '').trim(),
        title: (asString(json['title']) ?? asString(json['name']) ?? '').trim(),
        displayGroup: (asString(json['display_group']) ?? '').trim(),
      );

  static List<LightNovelFilterOption> extractCategories(
    Map<String, dynamic> data,
  ) {
    final filters = asMap(data['filters']);
    final seen = <String>{};
    final result = <LightNovelFilterOption>[];
    for (final raw in asList(filters?['category_options'])) {
      final map = asMap(raw);
      if (map == null) continue;
      final option = LightNovelFilterOption.fromJson(map);
      if (option.key.isEmpty ||
          option.key == 'all' ||
          option.title.isEmpty ||
          option.title == '全部') {
        continue;
      }
      if (seen.add(option.title)) {
        result.add(option);
      }
    }
    return List<LightNovelFilterOption>.unmodifiable(result);
  }

  static List<LightNovelFilterOption> _extractFilterOptions(
    Map<String, dynamic> data,
    String field,
  ) {
    final filters = asMap(data['filters']);
    final seen = <String>{};
    final result = <LightNovelFilterOption>[];
    for (final raw in asList(filters?[field])) {
      final map = asMap(raw);
      if (map == null) continue;
      final option = LightNovelFilterOption.fromJson(map);
      if (option.key.isEmpty || option.title.isEmpty) continue;
      if (seen.add(option.key)) {
        result.add(option);
      }
    }
    return List<LightNovelFilterOption>.unmodifiable(result);
  }

  /// Extracts combined feed read-progress options (including `'all'` when present).
  static List<LightNovelFilterOption> extractReadOptions(
    Map<String, dynamic> data,
  ) => _extractFilterOptions(data, 'read_options');

  /// Extracts combined feed status options (including `'all'` when present).
  static List<LightNovelFilterOption> extractStatusOptions(
    Map<String, dynamic> data,
  ) => _extractFilterOptions(data, 'status_options');

  /// Extracts all category options (preserving `'all:全部'` at the head when present).
  static List<LightNovelFilterOption> extractAllCategories(
    Map<String, dynamic> data,
  ) => _extractFilterOptions(data, 'category_options');
}

@immutable
class LightNovelTaxonomy {
  const LightNovelTaxonomy({
    required this.channels,
    required this.tags,
    this.tabs = const [],
  });

  final List<LightNovelChannel> channels;
  final List<LightNovelTagItem> tags;
  final List<Map<String, dynamic>> tabs;

  factory LightNovelTaxonomy.fromJson(Map<String, dynamic> json) {
    final channels = <LightNovelChannel>[
      for (final raw in asList(json['channels']))
        if (asMap(raw) case final map?) LightNovelChannel.fromJson(map),
    ];
    final tags = <LightNovelTagItem>[
      for (final raw in asList(json['tags']))
        if (asMap(raw) case final map?) LightNovelTagItem.fromJson(map),
    ];
    final tabs = <Map<String, dynamic>>[
      for (final raw in asList(json['tabs'])) ?asMap(raw),
    ];
    return LightNovelTaxonomy(
      channels: List<LightNovelChannel>.unmodifiable(
        channels.where((c) => c.code.isNotEmpty && c.label.isNotEmpty),
      ),
      tags: List<LightNovelTagItem>.unmodifiable(
        tags.where((t) => t.name.isNotEmpty),
      ),
      tabs: List<Map<String, dynamic>>.unmodifiable(tabs),
    );
  }
}

@immutable
class LightNovelVolumeMeta {
  const LightNovelVolumeMeta({
    required this.volumeId,
    required this.bookId,
    required this.title,
    this.originTitle = '',
    this.intro = '',
    this.sortIndex = 0,
    this.isLocked = false,
    this.status = 0,
    this.chapterCount = 0,
    this.firstChapterId = 0,
    this.lastChapterId = 0,
    this.volumeCommentCount = 0,
    this.createdAt,
    this.updatedAt,
  });

  final int volumeId;
  final int bookId;
  final String title;
  final String originTitle;
  final String intro;
  final int sortIndex;
  final bool isLocked;
  final int status;
  final int chapterCount;
  final int firstChapterId;
  final int lastChapterId;
  final int volumeCommentCount;
  final String? createdAt;
  final String? updatedAt;

  factory LightNovelVolumeMeta.fromJson(Map<String, dynamic> json) =>
      LightNovelVolumeMeta(
        volumeId: asInt(json['volume_id']) ?? asInt(json['id']) ?? 0,
        bookId: asInt(json['book_id']) ?? 0,
        title: (asString(json['title']) ?? '').trim(),
        originTitle: (asString(json['origin_title']) ?? '').trim(),
        intro: (asString(json['intro']) ?? '').trim(),
        sortIndex: asInt(json['sort_index']) ?? 0,
        isLocked: asBool01(json['is_locked']),
        status: asInt(json['status']) ?? 0,
        chapterCount: asInt(json['chapter_count']) ?? 0,
        firstChapterId: asInt(json['first_chapter_id']) ?? 0,
        lastChapterId: asInt(json['last_chapter_id']) ?? 0,
        volumeCommentCount: asInt(json['volume_comment_count']) ?? 0,
        createdAt: asNonEmptyString(json['created_at']),
        updatedAt: asNonEmptyString(json['updated_at']),
      );
}

@immutable
class LightNovelChapterMeta {
  const LightNovelChapterMeta({
    required this.chapterId,
    required this.bookId,
    required this.volumeId,
    required this.chapterNo,
    required this.title,
    this.status = 0,
    this.wordCount = 0,
    this.publishedAt,
    this.updatedAt,
    this.accessType = 'public',
    this.coinPrice = 0,
    this.coinChapter = false,
    this.coinListPrice = 0,
    this.freeNode = 0,
    this.previewPercent = 0,
    this.locked = false,
    this.unlocked = true,
    this.braveRequired = false,
    this.braveAllowed = false,
    this.coinAllowed = false,
    this.readPercent,
    this.progressPercent,
    this.readFinished = false,
    this.lastPosition,
    this.lastReadAt,
  });

  final int chapterId;
  final int bookId;
  final int volumeId;
  final int chapterNo;
  final String title;
  final int status;
  final int wordCount;
  final String? publishedAt;
  final String? updatedAt;
  final String accessType;
  final int coinPrice;
  final bool coinChapter;
  final int coinListPrice;
  final int freeNode;
  final int previewPercent;
  final bool locked;
  final bool unlocked;
  final bool braveRequired;
  final bool braveAllowed;
  final bool coinAllowed;
  final double? readPercent;
  final double? progressPercent;
  final bool readFinished;
  final int? lastPosition;
  final String? lastReadAt;

  bool get isLocked => locked && !unlocked;
  bool get isCoinLocked => isLocked && accessType == 'coin';
  bool get isBraveLocked =>
      isLocked && (braveRequired || accessType == 'brave');

  factory LightNovelChapterMeta.fromJson(Map<String, dynamic> json) {
    final locked = asBool01(json['locked']);
    final unlocked = json.containsKey('unlocked')
        ? asBool01(json['unlocked'])
        : !locked;
    return LightNovelChapterMeta(
      chapterId: asInt(json['chapter_id']) ?? asInt(json['id']) ?? 0,
      bookId: asInt(json['book_id']) ?? 0,
      volumeId: asInt(json['volume_id']) ?? 0,
      chapterNo: asInt(json['chapter_no']) ?? asInt(json['sort_index']) ?? 0,
      title: (asString(json['title']) ?? '').trim(),
      status: asInt(json['status']) ?? 0,
      wordCount: asInt(json['word_count']) ?? 0,
      publishedAt: asNonEmptyString(json['published_at']),
      updatedAt: asNonEmptyString(json['updated_at']),
      accessType: asNonEmptyString(json['access_type']) ?? 'public',
      coinPrice: asInt(json['coin_price']) ?? 0,
      coinChapter: asBool01(json['coin_chapter']),
      coinListPrice: asInt(json['coin_list_price']) ?? 0,
      freeNode: asInt(json['free_node']) ?? 0,
      previewPercent: asInt(json['preview_percent']) ?? 0,
      locked: locked,
      unlocked: unlocked,
      braveRequired: asBool01(json['brave_required']),
      braveAllowed: asBool01(json['brave_allowed']),
      coinAllowed: asBool01(json['coin_allowed']),
      readPercent: asDouble(json['read_percent']),
      progressPercent: asDouble(json['progress_percent']),
      readFinished: asBool01(json['read_finished']),
      lastPosition: asInt(json['last_position']),
      lastReadAt: asNonEmptyString(json['last_read_at']),
    );
  }
}

@immutable
class LightNovelResourceInfo {
  const LightNovelResourceInfo({
    required this.resKey,
    this.resId = 0,
    this.type = 'image',
    this.url,
    this.width,
    this.height,
  });

  final String resKey;
  final int resId;
  final String type;
  final String? url;
  final int? width;
  final int? height;

  factory LightNovelResourceInfo.fromJson(
    String key,
    Map<String, dynamic> json,
  ) => LightNovelResourceInfo(
    resKey: asNonEmptyString(json['res_key']) ?? key,
    resId: asInt(json['res_id']) ?? 0,
    type: asNonEmptyString(json['type']) ?? 'image',
    url: _normalizeMediaUrl(asNonEmptyString(json['url'])),
    width: asInt(json['width']),
    height: asInt(json['height']),
  );
}

@immutable
class LightNovelChapterDetail {
  const LightNovelChapterDetail({
    required this.chapterId,
    required this.bookId,
    required this.volumeId,
    this.volumeTitle = '',
    this.chapterNo = 0,
    this.title = '',
    this.wordCount = 0,
    this.publishedAt,
    this.updatedAt,
    this.locked = false,
    this.unlocked = true,
    this.accessType = 'public',
    this.coinPrice = 0,
    this.coinChapter = false,
    this.coinListPrice = 0,
    this.freeNode = 0,
    this.previewPercent = 0,
    this.braveRequired = false,
    this.braveAllowed = false,
    this.coinAllowed = false,
    this.previewTruncated = false,
    this.renderPreviewSource,
    this.selectionScope,
    this.bodyHtml = '',
    this.bodyText = '',
    this.bodyVersion,
    this.charCount = 0,
    this.checksum,
    this.resInfo = const {},
    this.prevChapterId,
    this.nextChapterId,
  });

  final int chapterId;
  final int bookId;
  final int volumeId;
  final String volumeTitle;
  final int chapterNo;
  final String title;
  final int wordCount;
  final String? publishedAt;
  final String? updatedAt;
  final bool locked;
  final bool unlocked;
  final String accessType;
  final int coinPrice;
  final bool coinChapter;
  final int coinListPrice;
  final int freeNode;
  final int previewPercent;
  final bool braveRequired;
  final bool braveAllowed;
  final bool coinAllowed;
  final bool previewTruncated;
  final String? renderPreviewSource;
  final String? selectionScope;
  final String bodyHtml;
  final String bodyText;
  final String? bodyVersion;
  final int charCount;
  final String? checksum;
  final Map<String, LightNovelResourceInfo> resInfo;
  final int? prevChapterId;
  final int? nextChapterId;

  bool get isLockedPreview =>
      (locked && !unlocked) ||
      previewTruncated ||
      selectionScope == 'preview_only' ||
      renderPreviewSource == 'paid_preview';

  LightNovelChapterMeta toChapterMeta() => LightNovelChapterMeta(
    chapterId: chapterId,
    bookId: bookId,
    volumeId: volumeId,
    chapterNo: chapterNo,
    title: title,
    wordCount: wordCount,
    publishedAt: publishedAt,
    updatedAt: updatedAt,
    accessType: accessType,
    coinPrice: coinPrice,
    coinChapter: coinChapter,
    coinListPrice: coinListPrice,
    freeNode: freeNode,
    previewPercent: previewPercent,
    locked: locked,
    unlocked: unlocked,
    braveRequired: braveRequired,
    braveAllowed: braveAllowed,
    coinAllowed: coinAllowed,
  );

  factory LightNovelChapterDetail.fromJson(Map<String, dynamic> json) {
    final snapshot = asMap(json['body_snapshot']);
    final renderPreview = asMap(json['render_preview']);
    final navigation = asMap(json['navigation']);
    final prevChapter = asMap(navigation?['prev_chapter']);
    final nextChapter = asMap(navigation?['next_chapter']);
    final legacyResources = asMap(json['legacy_resources']);
    final rawResInfo = asMap(legacyResources?['res_info']);

    final parsedResInfo = <String, LightNovelResourceInfo>{};
    if (rawResInfo != null) {
      for (final entry in rawResInfo.entries) {
        final item = asMap(entry.value);
        if (item != null) {
          final info = LightNovelResourceInfo.fromJson(entry.key, item);
          parsedResInfo[entry.key] = info;
          if (info.resKey != entry.key) {
            parsedResInfo[info.resKey] = info;
          }
        }
      }
    }

    final locked = asBool01(json['locked']);
    final unlocked = json.containsKey('unlocked')
        ? asBool01(json['unlocked'])
        : !locked;

    return LightNovelChapterDetail(
      chapterId: asInt(json['chapter_id']) ?? asInt(json['id']) ?? 0,
      bookId: asInt(json['book_id']) ?? 0,
      volumeId: asInt(json['volume_id']) ?? 0,
      volumeTitle: (asString(json['volume_title']) ?? '').trim(),
      chapterNo: asInt(json['chapter_no']) ?? 0,
      title: (asString(json['title']) ?? '').trim(),
      wordCount: asInt(json['word_count']) ?? 0,
      publishedAt: asNonEmptyString(json['published_at']),
      updatedAt: asNonEmptyString(json['updated_at']),
      locked: locked,
      unlocked: unlocked,
      accessType: asNonEmptyString(json['access_type']) ?? 'public',
      coinPrice: asInt(json['coin_price']) ?? 0,
      coinChapter: asBool01(json['coin_chapter']),
      coinListPrice: asInt(json['coin_list_price']) ?? 0,
      freeNode: asInt(json['free_node']) ?? 0,
      previewPercent: asInt(json['preview_percent']) ?? 0,
      braveRequired: asBool01(json['brave_required']),
      braveAllowed: asBool01(json['brave_allowed']),
      coinAllowed: asBool01(json['coin_allowed']),
      previewTruncated: asBool01(json['preview_truncated']),
      renderPreviewSource: asNonEmptyString(renderPreview?['source']),
      selectionScope: asNonEmptyString(snapshot?['selection_scope']),
      bodyHtml: asString(snapshot?['body_html']) ?? '',
      bodyText: asString(snapshot?['body_text']) ?? '',
      bodyVersion: asNonEmptyString(snapshot?['body_version']),
      charCount: asInt(snapshot?['char_count']) ?? 0,
      checksum: asNonEmptyString(snapshot?['checksum']),
      resInfo: Map<String, LightNovelResourceInfo>.unmodifiable(parsedResInfo),
      prevChapterId: asInt(prevChapter?['chapter_id']),
      nextChapterId: asInt(nextChapter?['chapter_id']),
    );
  }
}
