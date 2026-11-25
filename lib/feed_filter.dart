import 'package:flutter/foundation.dart';

/// Combined server-side filter parameters for a LightNovel.fun feed or channel.
@immutable
class FeedFilter {
  const FeedFilter({
    String? sortKey,
    String readFilter = 'all',
    String statusFilter = 'all',
    String categoryFilter = 'all',
    this.readTitle,
    this.statusTitle,
    this.categoryTitle,
  }) : sortKey = sortKey == '' ? null : sortKey,
       readFilter = readFilter == '' ? 'all' : readFilter,
       statusFilter = statusFilter == '' ? 'all' : statusFilter,
       categoryFilter = categoryFilter == '' ? 'all' : categoryFilter;

  /// `'updated'` (`按更新时间`) or `'hot'` (`按热度`), or `null` for section default.
  final String? sortKey;

  /// `'all'`, `'unread'`, `'unread_50'`, or `'unread_100'`.
  final String readFilter;

  /// `'all'`, `'serializing'`, `'completed'`, `'epub'`, etc.
  final String statusFilter;

  /// `'all'` or numeric category/tag ID string (e.g. `'416'` for `校园`).
  final String categoryFilter;

  /// Display label resolved for non-default [readFilter].
  final String? readTitle;

  /// Display label resolved for non-default [statusFilter].
  final String? statusTitle;

  /// Display label resolved for non-default [categoryFilter].
  final String? categoryTitle;

  String get normalizedSortKey => (sortKey ?? '').trim();

  bool get isDefault =>
      normalizedSortKey.isEmpty &&
      readFilter == 'all' &&
      statusFilter == 'all' &&
      categoryFilter == 'all';

  int get activeCount {
    var count = 0;
    if (normalizedSortKey.isNotEmpty) count++;
    if (readFilter != 'all') count++;
    if (statusFilter != 'all') count++;
    if (categoryFilter != 'all') count++;
    return count;
  }

  List<String> summaryLabels({String? defaultSortKey}) {
    final labels = <String>[];
    if (normalizedSortKey.isNotEmpty && normalizedSortKey != defaultSortKey) {
      labels.add(sortOptionTitle(normalizedSortKey));
    }
    if (readFilter != 'all') {
      labels.add(
        (readTitle?.trim().isNotEmpty ?? false)
            ? readTitle!.trim()
            : defaultReadTitle(readFilter),
      );
    }
    if (statusFilter != 'all') {
      labels.add(
        (statusTitle?.trim().isNotEmpty ?? false)
            ? statusTitle!.trim()
            : defaultStatusTitle(statusFilter),
      );
    }
    if (categoryFilter != 'all') {
      labels.add(
        (categoryTitle?.trim().isNotEmpty ?? false)
            ? categoryTitle!.trim()
            : categoryFilter,
      );
    }
    return labels;
  }

  static String sortOptionTitle(String key) => switch (key) {
    'hot' => '按热度',
    'updated' => '按更新时间',
    _ => key,
  };

  static String defaultReadTitle(String key) => switch (key) {
    'unread' => '未读过',
    'unread_50' => '未读50章以上',
    'unread_100' => '未读100章以上',
    _ => '全部',
  };

  static String defaultStatusTitle(String key) => switch (key) {
    'completed' => '完结',
    'serializing' => '连载',
    'epub' => 'Epub',
    _ => '全部',
  };

  FeedFilter normalizedFor({required String? defaultSortKey}) {
    final nextSort =
        normalizedSortKey.isEmpty ||
            (defaultSortKey != null && normalizedSortKey == defaultSortKey)
        ? null
        : normalizedSortKey;
    return FeedFilter(
      sortKey: nextSort,
      readFilter: readFilter,
      statusFilter: statusFilter,
      categoryFilter: categoryFilter,
      readTitle: readFilter == 'all' ? null : readTitle,
      statusTitle: statusFilter == 'all' ? null : statusTitle,
      categoryTitle: categoryFilter == 'all' ? null : categoryTitle,
    );
  }

  FeedFilter copyWith({
    String? sortKey,
    bool clearSortKey = false,
    String? readFilter,
    String? statusFilter,
    String? categoryFilter,
    String? readTitle,
    bool clearReadTitle = false,
    String? statusTitle,
    bool clearStatusTitle = false,
    String? categoryTitle,
    bool clearCategoryTitle = false,
  }) => FeedFilter(
    sortKey: clearSortKey ? null : (sortKey ?? this.sortKey),
    readFilter: readFilter ?? this.readFilter,
    statusFilter: statusFilter ?? this.statusFilter,
    categoryFilter: categoryFilter ?? this.categoryFilter,
    readTitle: clearReadTitle ? null : (readTitle ?? this.readTitle),
    statusTitle: clearStatusTitle ? null : (statusTitle ?? this.statusTitle),
    categoryTitle: clearCategoryTitle
        ? null
        : (categoryTitle ?? this.categoryTitle),
  );

  Map<String, Object?> toJson() => {
    if (normalizedSortKey.isNotEmpty) 'sortKey': normalizedSortKey,
    if (readFilter != 'all') 'readFilter': readFilter,
    if (statusFilter != 'all') 'statusFilter': statusFilter,
    if (categoryFilter != 'all') 'categoryFilter': categoryFilter,
    if (readFilter != 'all' && (readTitle?.trim().isNotEmpty ?? false))
      'readTitle': readTitle!.trim(),
    if (statusFilter != 'all' && (statusTitle?.trim().isNotEmpty ?? false))
      'statusTitle': statusTitle!.trim(),
    if (categoryFilter != 'all' &&
        (categoryTitle?.trim().isNotEmpty ?? false))
      'categoryTitle': categoryTitle!.trim(),
  };

  static FeedFilter tryParse(Object? value) {
    if (value is! Map) return const FeedFilter();
    final sortKey = value['sortKey'] is String
        ? (value['sortKey'] as String).trim()
        : null;
    final read = value['readFilter'] is String
        ? (value['readFilter'] as String).trim()
        : 'all';
    final status = value['statusFilter'] is String
        ? (value['statusFilter'] as String).trim()
        : 'all';
    final category = value['categoryFilter'] is String
        ? (value['categoryFilter'] as String).trim()
        : 'all';
    final readTitle = value['readTitle'] is String
        ? (value['readTitle'] as String).trim()
        : null;
    final statusTitle = value['statusTitle'] is String
        ? (value['statusTitle'] as String).trim()
        : null;
    final categoryTitle = value['categoryTitle'] is String
        ? (value['categoryTitle'] as String).trim()
        : null;
    return FeedFilter(
      sortKey: sortKey,
      readFilter: read.isEmpty ? 'all' : read,
      statusFilter: status.isEmpty ? 'all' : status,
      categoryFilter: category.isEmpty ? 'all' : category,
      readTitle: readTitle?.isEmpty == true ? null : readTitle,
      statusTitle: statusTitle?.isEmpty == true ? null : statusTitle,
      categoryTitle: categoryTitle?.isEmpty == true ? null : categoryTitle,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FeedFilter &&
      normalizedSortKey == other.normalizedSortKey &&
      readFilter == other.readFilter &&
      statusFilter == other.statusFilter &&
      categoryFilter == other.categoryFilter;

  @override
  int get hashCode =>
      Object.hash(normalizedSortKey, readFilter, statusFilter, categoryFilter);
}

/// One selectable option for a feed sub-filter (sort, read, status, or category).
@immutable
class FeedFilterChoice {
  const FeedFilterChoice({
    required this.key,
    required this.title,
    this.group = '',
  });

  final String key;
  final String title;
  final String group;

  @override
  bool operator ==(Object other) =>
      other is FeedFilterChoice &&
      key == other.key &&
      title == other.title &&
      group == other.group;

  @override
  int get hashCode => Object.hash(key, title, group);
}

/// Describes the sub-filters supported by a LightNovel.fun website section.
@immutable
class FeedFilterSchema {
  const FeedFilterSchema({
    required this.supportsSort,
    required this.defaultSortKey,
    this.sortOptions = const [],
    this.readOptions = const [],
    this.statusOptions = const [],
    this.categoryOptions = const [],
  });

  const FeedFilterSchema.unsupported()
    : supportsSort = false,
      defaultSortKey = '',
      sortOptions = const [],
      readOptions = const [],
      statusOptions = const [],
      categoryOptions = const [];

  /// Canonical read-progress options supported on filterable LightNovel.fun channels.
  static const List<FeedFilterChoice> canonicalReadOptions = [
    FeedFilterChoice(key: 'all', title: '全部'),
    FeedFilterChoice(key: 'unread', title: '未读过'),
    FeedFilterChoice(key: 'unread_50', title: '未读50章以上'),
    FeedFilterChoice(key: 'unread_100', title: '未读100章以上'),
  ];

  /// Canonical serialization status options.
  static const List<FeedFilterChoice> canonicalStatusOptions = [
    FeedFilterChoice(key: 'all', title: '全部'),
    FeedFilterChoice(key: 'completed', title: '完结'),
    FeedFilterChoice(key: 'serializing', title: '连载'),
  ];

  /// Status options on EPUB channel (`all`, `completed`, `serializing`, `epub`).
  static const List<FeedFilterChoice> canonicalEpubStatusOptions = [
    FeedFilterChoice(key: 'all', title: '全部'),
    FeedFilterChoice(key: 'completed', title: '完结'),
    FeedFilterChoice(key: 'serializing', title: '连载'),
    FeedFilterChoice(key: 'epub', title: 'Epub'),
  ];

  /// Canonical category options reported on LightNovel.fun filterable channels so
  /// chips render immediately with zero waiting before API responses complete.
  static const List<FeedFilterChoice> canonicalCategoryOptions = [
    FeedFilterChoice(key: 'all', title: '全部'),
    FeedFilterChoice(key: '235', title: '异世界'),
    FeedFilterChoice(key: '416', title: '校园'),
    FeedFilterChoice(key: '238', title: '恋爱'),
    FeedFilterChoice(key: '417', title: '青春'),
    FeedFilterChoice(key: '1145', title: '日常'),
    FeedFilterChoice(key: '42', title: '百合'),
    FeedFilterChoice(key: '36', title: '后宫'),
    FeedFilterChoice(key: '1866', title: '搞笑'),
    FeedFilterChoice(key: '137', title: '恋爱喜剧'),
    FeedFilterChoice(key: '471', title: '悬疑'),
    FeedFilterChoice(key: '1052', title: '奇幻'),
    FeedFilterChoice(key: '237', title: '冒险'),
    FeedFilterChoice(key: '911', title: '转生'),
    FeedFilterChoice(key: '711', title: '青梅竹马'),
    FeedFilterChoice(key: '421', title: '美少女'),
    FeedFilterChoice(key: '418', title: '穿越'),
  ];

  /// Returns an instant canonical schema matching a website section before network
  /// metadata finishes loading.
  factory FeedFilterSchema.defaultFor({
    required bool supportsCombinedFilters,
    String defaultSortKey = 'updated',
    bool includeEpubStatus = false,
    bool includeCanonicalCategories = true,
  }) {
    if (!supportsCombinedFilters) {
      return const FeedFilterSchema.unsupported();
    }
    final normalizedDefaultSort =
        defaultSortKey == 'hot' ? 'hot' : 'updated';
    return FeedFilterSchema(
      supportsSort: true,
      defaultSortKey: normalizedDefaultSort,
      sortOptions: normalizedDefaultSort == 'hot'
          ? const [
              FeedFilterChoice(key: 'hot', title: '按热度'),
              FeedFilterChoice(key: 'updated', title: '按更新时间'),
            ]
          : const [
              FeedFilterChoice(key: 'updated', title: '按更新时间'),
              FeedFilterChoice(key: 'hot', title: '按热度'),
            ],
      readOptions: canonicalReadOptions,
      statusOptions: includeEpubStatus
          ? canonicalEpubStatusOptions
          : canonicalStatusOptions,
      categoryOptions: includeCanonicalCategories
          ? canonicalCategoryOptions
          : const [FeedFilterChoice(key: 'all', title: '全部')],
    );
  }

  final bool supportsSort;
  final String defaultSortKey;
  final List<FeedFilterChoice> sortOptions;
  final List<FeedFilterChoice> readOptions;
  final List<FeedFilterChoice> statusOptions;
  final List<FeedFilterChoice> categoryOptions;

  bool get supportsRead => readOptions.any((option) => option.key != 'all');

  bool get supportsStatus =>
      statusOptions.any((option) => option.key != 'all');

  bool get supportsCategory =>
      categoryOptions.any((option) => option.key != 'all');

  bool get hasAnySubFilters =>
      supportsSort || supportsRead || supportsStatus || supportsCategory;

  /// Merges [incoming] options onto this schema without shrinking existing
  /// canonical or previously discovered choices when a filtered response omits items.
  FeedFilterSchema mergeWith(FeedFilterSchema incoming) {
    final nextSortKey = incoming.defaultSortKey.isNotEmpty
        ? incoming.defaultSortKey
        : defaultSortKey;
    return FeedFilterSchema(
      supportsSort: supportsSort || incoming.supportsSort,
      defaultSortKey: nextSortKey,
      sortOptions: sortOptions.isNotEmpty ? sortOptions : incoming.sortOptions,
      readOptions: _mergeChoices(readOptions, incoming.readOptions),
      statusOptions: _mergeChoices(statusOptions, incoming.statusOptions),
      categoryOptions: _mergeChoices(
        categoryOptions,
        incoming.categoryOptions,
      ),
    );
  }

  static List<FeedFilterChoice> _mergeChoices(
    List<FeedFilterChoice> existing,
    List<FeedFilterChoice> incoming,
  ) {
    if (incoming.isEmpty) return existing;
    if (existing.isEmpty) return incoming;
    final byKey = <String, FeedFilterChoice>{
      for (final item in incoming) item.key: item,
    };
    final result = <FeedFilterChoice>[];
    final seen = <String>{};

    void addChoice(FeedFilterChoice choice) {
      if (choice.key.isEmpty || choice.title.isEmpty) return;
      if (seen.add(choice.key)) {
        result.add(choice);
      }
    }

    final incomingAll = byKey['all'];
    if (incomingAll != null) {
      addChoice(incomingAll);
    } else {
      for (final item in existing) {
        if (item.key == 'all') {
          addChoice(item);
          break;
        }
      }
    }

    for (final item in existing) {
      addChoice(byKey[item.key] ?? item);
    }
    for (final item in incoming) {
      addChoice(item);
    }
    return List<FeedFilterChoice>.unmodifiable(result);
  }
}
