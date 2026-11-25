import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_search_field.dart';
import 'app_ui.dart';
import 'book_tag_catalog.dart';
import 'catalog.dart';
import 'discovery_ui.dart';
import 'publication_catalog.dart';
import 'tag_catalogue.dart';

/// Selected LightNovel.fun discovery source and combined sub-filters.
///
/// Website top-bar sections (`排行`, `热度`, `新书`, `轻小说`, `原创`, `同人`,
/// `EPUB`) select the feed endpoint, while [filter] carries optional `sort`,
/// `read_filter`, `status_filter`, and `category_filter` parameters for
/// channels that expose them. Free multi-tag filtering uses [tags].
class DiscoverySelection {
  const DiscoverySelection({
    this.sort,
    this.tags,
    this.publication,
    this.filter = const FeedFilter(),
  });

  final NovelSort? sort;
  final Set<String>? tags;
  final PublicationLibrary? publication;
  final FeedFilter filter;
}

/// Top-level LightNovel.fun website section represented in the discovery bar.
enum WebsiteSectionKind {
  rank,
  hot,
  newBooks,
  channel,
}

class DiscoveryFilters extends StatefulWidget {
  const DiscoveryFilters({
    super.key,
    required this.sort,
    required this.books,
    this.filter = const FeedFilter(),
    this.selectedTags = const {},
    this.availableTags = const [],
    this.restrictToAvailableTags = false,
    this.availableSorts,
    this.sortLabels = const {},
    this.blockedTags = const {},
    this.onBlockedTagsChanged,
    this.editingBlockedTags = false,
    this.publicationCatalog,
    this.selectedPublication,
    this.preparePublications,
    this.siteFilterCatalog,
  });

  final NovelSort sort;
  final List<Novel> books;
  final FeedFilter filter;
  final Set<String> selectedTags;
  final Iterable<String> availableTags;
  final bool restrictToAvailableTags;
  final Iterable<NovelSort>? availableSorts;
  final Map<NovelSort, String> sortLabels;
  final Set<String> blockedTags;
  final Future<void> Function(Set<String>)? onBlockedTagsChanged;
  final bool editingBlockedTags;
  final PublicationCatalog? publicationCatalog;
  final PublicationLibrary? selectedPublication;
  final Future<void> Function()? preparePublications;
  final SiteFeedFilterCatalog? siteFilterCatalog;

  static const defaultChannels = <PublicationLibrary>[
    PublicationLibrary(1, '轻小说'),
    PublicationLibrary(2, '原创'),
    PublicationLibrary(3, '同人'),
    PublicationLibrary(4, 'EPUB'),
  ];

  static const rankScenes = <(NovelSort sort, String label)>[
    (NovelSort.weekVisit, '综合热度'),
    (NovelSort.goodNum, '新书榜'),
    (NovelSort.dayVisit, '今日热榜'),
    (NovelSort.weekVote, '轻小说榜'),
    (NovelSort.monthVisit, '全站周榜'),
  ];

  static const hotScenes = <(NovelSort sort, String label)>[
    (NovelSort.allVisit, '热门'),
    (NovelSort.lastUpdate, '最近更新'),
    (NovelSort.allVote, '好书推荐'),
  ];

  static bool isRankSort(NovelSort? sort) => switch (sort) {
    NovelSort.weekVisit ||
    NovelSort.dayVisit ||
    NovelSort.weekVote ||
    NovelSort.dayVote ||
    NovelSort.monthVisit ||
    NovelSort.monthVote ||
    NovelSort.goodNum => true,
    _ => false,
  };

  static bool isHotTabSort(NovelSort? sort) => switch (sort) {
    NovelSort.allVisit || NovelSort.lastUpdate || NovelSort.allVote => true,
    _ => false,
  };

  static WebsiteSectionKind sectionFor({
    NovelSort? sort,
    PublicationLibrary? publication,
  }) {
    if (publication != null) return WebsiteSectionKind.channel;
    if (isRankSort(sort)) return WebsiteSectionKind.rank;
    if (sort == NovelSort.postDate) return WebsiteSectionKind.newBooks;
    return WebsiteSectionKind.hot;
  }

  static bool supportsChannelSubFilters({
    NovelSort? sort,
    PublicationLibrary? publication,
  }) {
    final kind = sectionFor(sort: sort, publication: publication);
    return kind == WebsiteSectionKind.channel ||
        kind == WebsiteSectionKind.newBooks;
  }

  static String rankSceneLabel(NovelSort sort) {
    for (final (candidate, label) in rankScenes) {
      if (candidate == sort) return label;
    }
    return sort.label;
  }

  static String hotSceneLabel(NovelSort sort) {
    for (final (candidate, label) in hotScenes) {
      if (candidate == sort) return label;
    }
    return sort.label;
  }

  @override
  State<DiscoveryFilters> createState() => _DiscoveryFiltersState();
}

class _DiscoveryFiltersState extends State<DiscoveryFilters> {
  late bool _editingBlocked =
      widget.editingBlockedTags && widget.onBlockedTagsChanged != null;

  late NovelSort? _draftSort = widget.selectedPublication == null
      ? widget.sort
      : null;
  late PublicationLibrary? _draftPublication = widget.selectedPublication;
  late FeedFilter _draftFilter = widget.selectedTags.isEmpty
      ? widget.filter
      : const FeedFilter();

  late final blocked = {...widget.blockedTags};
  final query = TextEditingController();
  bool _saving = false;
  String? _saveError;

  List<PublicationLibrary>? _publications;
  bool _loadingPublications = false;
  String? _publicationError;
  bool _requestedPublicationTab = false;

  late FeedFilterSchema? _schema = _fallbackSchemaForDraft();
  int _schemaGeneration = 0;

  bool _isBlockedSelected(String tag) =>
      blocked.any((value) => _tagKey(value) == _tagKey(tag));

  String _tagKey(String value) => value.trim().toLowerCase();

  @override
  void initState() {
    super.initState();
    if (!_editingBlocked) {
      if (widget.publicationCatalog != null) {
        unawaited(_loadPublications(refresh: false));
      }
      unawaited(_loadSchemaForDraft());
    }
  }

  Future<void> _loadPublications({bool refresh = false}) async {
    final catalog = widget.publicationCatalog;
    if (catalog == null || _loadingPublications) return;
    setState(() {
      _loadingPublications = true;
      _publicationError = null;
    });
    try {
      await widget.preparePublications?.call();
      if (!mounted) return;
      final libraries = await catalog.publicationLibraries(refresh: refresh);
      if (mounted) setState(() => _publications = libraries);
    } catch (_) {
      if (mounted) {
        setState(() => _publicationError = '频道分类暂未载入，请重试。');
      }
    } finally {
      if (mounted) setState(() => _loadingPublications = false);
    }
  }

  FeedFilterSchema _fallbackSchemaForDraft() {
    if (!DiscoveryFilters.supportsChannelSubFilters(
      sort: _draftSort,
      publication: _draftPublication,
    )) {
      return const FeedFilterSchema.unsupported();
    }
    return FeedFilterSchema.defaultFor(
      supportsCombinedFilters: true,
      defaultSortKey: _draftSort == NovelSort.allVisit ? 'hot' : 'updated',
      includeEpubStatus: _draftPublication?.id == 4,
    );
  }

  Future<void> _loadSchemaForDraft() async {
    final publication = _draftPublication;
    final sort = publication == null ? _draftSort : null;
    if (!DiscoveryFilters.supportsChannelSubFilters(
      sort: sort,
      publication: publication,
    )) {
      setState(() {
        _schemaGeneration++;
        _schema = const FeedFilterSchema.unsupported();
      });
      return;
    }

    final fallback = _fallbackSchemaForDraft();
    final catalog = widget.siteFilterCatalog;
    if (catalog == null) {
      setState(() {
        _schemaGeneration++;
        _schema = fallback;
      });
      return;
    }

    final cached = catalog.cachedFeedFilters(
      sort: sort,
      publication: publication,
    );
    if (cached != null) {
      setState(() {
        _schemaGeneration++;
        _schema = fallback.mergeWith(cached);
      });
      return;
    }

    final generation = ++_schemaGeneration;
    setState(() {
      _schema = fallback;
    });
    try {
      final loaded = await catalog.loadFeedFilters(
        sort: sort,
        publication: publication,
      );
      if (mounted && generation == _schemaGeneration) {
        setState(() {
          _schema = fallback.mergeWith(loaded);
        });
      }
    } catch (_) {
      if (mounted && generation == _schemaGeneration) {
        setState(() {
          _schema = fallback;
        });
      }
    }
  }

  void _selectHomeTab(WebsiteSectionKind kind) {
    final NovelSort targetSort = switch (kind) {
      WebsiteSectionKind.rank =>
        DiscoveryFilters.isRankSort(_draftSort)
            ? _draftSort!
            : NovelSort.weekVisit,
      WebsiteSectionKind.hot =>
        DiscoveryFilters.isHotTabSort(_draftSort)
            ? _draftSort!
            : NovelSort.allVisit,
      WebsiteSectionKind.newBooks => NovelSort.postDate,
      WebsiteSectionKind.channel => NovelSort.lastUpdate,
    };
    if (_draftPublication == null && _draftSort == targetSort) return;
    setState(() {
      _requestedPublicationTab = false;
      _draftPublication = null;
      _draftSort = targetSort;
      _draftFilter = const FeedFilter();
    });
    unawaited(_loadSchemaForDraft());
  }

  void _selectRankScene(NovelSort sort) {
    setState(() {
      _requestedPublicationTab = false;
      _draftPublication = null;
      _draftSort = sort;
      _draftFilter = const FeedFilter();
      _schema = const FeedFilterSchema.unsupported();
    });
  }

  void _selectHotScene(NovelSort sort) {
    setState(() {
      _requestedPublicationTab = false;
      _draftPublication = null;
      _draftSort = sort;
      _draftFilter = const FeedFilter();
      _schema = const FeedFilterSchema.unsupported();
    });
  }

  void _selectPublicationChannel(PublicationLibrary library) {
    setState(() {
      _requestedPublicationTab = true;
      _draftPublication = library;
      _draftSort = null;
      _draftFilter = const FeedFilter();
    });
    unawaited(_loadSchemaForDraft());
  }

  void _applySelection() {
    final schema = _schema;
    final supports = DiscoveryFilters.supportsChannelSubFilters(
      sort: _draftSort,
      publication: _draftPublication,
    );
    final normalized = supports
        ? _draftFilter.normalizedFor(defaultSortKey: schema?.defaultSortKey)
        : const FeedFilter();
    Navigator.pop<DiscoverySelection>(
      context,
      DiscoverySelection(
        sort: _draftPublication == null
            ? (_draftSort ?? NovelSort.allVisit)
            : null,
        publication: _draftPublication,
        filter: normalized,
      ),
    );
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  void addBlockedTags(String value) {
    final tags = tagSearchTerms(value);
    setState(() {
      for (final tag in tags) {
        if (!_isBlockedSelected(tag)) blocked.add(tag);
      }
      query.clear();
      _saveError = null;
    });
  }

  Future<void> _applyBlocked() async {
    if (_saving || widget.onBlockedTagsChanged == null) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.onBlockedTagsChanged!(Set.unmodifiable(blocked));
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveError = '屏蔽标签保存失败，请重试。';
        });
      }
    }
  }

  Widget _sectionLabelHeader(String title) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: AppText(
        title,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          letterSpacing: .2,
          color: scheme.onSurface.withValues(alpha: .76),
        ),
      ),
    );
  }

  List<PublicationLibrary> get _channelTabs {
    if (_publications != null) return _publications!;
    if (_publicationError != null) return const [];
    return DiscoveryFilters.defaultChannels;
  }

  Widget _buildWebsiteTopTabs() {
    final activeKind = DiscoveryFilters.sectionFor(
      sort: _draftSort,
      publication: _draftPublication,
    );
    final channels = _channelTabs;
    return DiscoverChannelTabStrip(
      key: const PageStorageKey('discover-sheet-top-tabs'),
      padding: EdgeInsets.zero,
      items: [
        DiscoverChannelTabItem(
          keyName: 'rank',
          label: '排行',
          tabKey: const ValueKey('discover-section-rank'),
          selected: activeKind == WebsiteSectionKind.rank,
          onTap: () => _selectHomeTab(WebsiteSectionKind.rank),
        ),
        DiscoverChannelTabItem(
          keyName: 'hot',
          label: '热度',
          tabKey: const ValueKey('discover-section-hot'),
          selected: activeKind == WebsiteSectionKind.hot,
          onTap: () => _selectHomeTab(WebsiteSectionKind.hot),
        ),
        DiscoverChannelTabItem(
          keyName: 'postDate',
          label: '新书',
          tabKey: const ValueKey('discover-section-postDate'),
          selected: activeKind == WebsiteSectionKind.newBooks,
          onTap: () => _selectHomeTab(WebsiteSectionKind.newBooks),
        ),
        for (final channel in channels)
          DiscoverChannelTabItem(
            keyName: 'pub-${channel.id}',
            label: channel.name,
            tabKey: ValueKey('discover-publication-${channel.id}'),
            selected: _draftPublication?.id == channel.id,
            onTap: () => _selectPublicationChannel(channel),
          ),
      ],
    );
  }

  Widget _buildSectionBody() {
    if (_requestedPublicationTab || _draftPublication != null) {
      if (_loadingPublications && _publications == null) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              CupertinoActivityIndicator(),
              SizedBox(width: 8),
              AppText('正在载入网站频道…', style: TextStyle(fontSize: 13)),
            ],
          ),
        );
      }
      if (_publicationError case final error?) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Expanded(child: AppText(error, style: const TextStyle(fontSize: 13))),
              const SizedBox(width: 8),
              DiscoverFilterChip(
                key: const ValueKey('discover-publication-retry'),
                label: '重新加载',
                selected: false,
                onTap: () => _loadPublications(refresh: true),
              ),
            ],
          ),
        );
      }
      if (_publications != null && _publications!.isEmpty) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: AppText('暂无频道分类', style: TextStyle(fontSize: 13)),
        );
      }
    }

    final kind = DiscoveryFilters.sectionFor(
      sort: _draftSort,
      publication: _draftPublication,
    );

    if (kind == WebsiteSectionKind.rank) {
      final activeRank = DiscoveryFilters.isRankSort(_draftSort)
          ? _draftSort!
          : NovelSort.weekVisit;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabelHeader('榜单'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (sort, label) in DiscoveryFilters.rankScenes)
                DiscoverFilterChip(
                  key: ValueKey('discover-sort-${sort.name}'),
                  label: label,
                  selected: activeRank == sort,
                  onTap: () => _selectRankScene(sort),
                ),
            ],
          ),
        ],
      );
    }

    if (kind == WebsiteSectionKind.hot) {
      final activeHot = DiscoveryFilters.isHotTabSort(_draftSort)
          ? _draftSort!
          : NovelSort.allVisit;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabelHeader('排序'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (sort, label) in DiscoveryFilters.hotScenes)
                DiscoverFilterChip(
                  key: ValueKey('discover-hot-${sort.name}'),
                  label: label,
                  selected: activeHot == sort,
                  onTap: () => _selectHotScene(sort),
                ),
            ],
          ),
        ],
      );
    }

    final schema = _schema ?? _fallbackSchemaForDraft();
    final readOptions = schema.readOptions.isEmpty
        ? FeedFilterSchema.canonicalReadOptions
        : schema.readOptions;
    final statusOptions = schema.statusOptions.isEmpty
        ? const [
            FeedFilterChoice(key: 'all', title: '全部'),
            FeedFilterChoice(key: 'completed', title: '完结'),
            FeedFilterChoice(key: 'serializing', title: '连载'),
          ]
        : schema.statusOptions;
    final categoryOptions = schema.categoryOptions.isEmpty
        ? FeedFilterSchema.canonicalCategoryOptions
        : schema.categoryOptions;
    final activeSortKey = _draftFilter.normalizedSortKey.isNotEmpty
        ? _draftFilter.normalizedSortKey
        : schema.defaultSortKey;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionLabelHeader('阅读'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in readOptions)
              DiscoverFilterChip(
                key: ValueKey('discover-read-${option.key}'),
                label: option.title,
                selected: _draftFilter.readFilter == option.key,
                onTap: () => setState(() {
                  _draftFilter = _draftFilter.copyWith(
                    readFilter: option.key,
                    readTitle: option.key == 'all' ? null : option.title,
                    clearReadTitle: option.key == 'all',
                  );
                }),
              ),
          ],
        ),
        const SizedBox(height: 14),
        _sectionLabelHeader('状态'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in statusOptions)
              DiscoverFilterChip(
                key: ValueKey('discover-status-${option.key}'),
                label: option.title,
                selected: _draftFilter.statusFilter == option.key,
                onTap: () => setState(() {
                  _draftFilter = _draftFilter.copyWith(
                    statusFilter: option.key,
                    statusTitle: option.key == 'all' ? null : option.title,
                    clearStatusTitle: option.key == 'all',
                  );
                }),
              ),
          ],
        ),
        const SizedBox(height: 14),
        _sectionLabelHeader('分类'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in categoryOptions)
              DiscoverFilterChip(
                key: ValueKey('discover-category-${option.key}'),
                label: option.title,
                selected: _draftFilter.categoryFilter == option.key,
                onTap: () => setState(() {
                  _draftFilter = _draftFilter.copyWith(
                    categoryFilter: option.key,
                    categoryTitle: option.key == 'all' ? null : option.title,
                    clearCategoryTitle: option.key == 'all',
                  );
                }),
              ),
          ],
        ),
        if (schema.supportsSort) ...[
          const SizedBox(height: 14),
          _sectionLabelHeader('排序'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in schema.sortOptions)
                DiscoverFilterChip(
                  key: ValueKey('discover-subsort-${option.key}'),
                  label: option.title,
                  selected: activeSortKey == option.key,
                  onTap: () => setState(() {
                    _draftFilter = _draftFilter.copyWith(sortKey: option.key);
                  }),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildBlockedEditor() {
    final frequency = <String, int>{
      for (final tag in [
        ...BookTagCatalog.shared.suggestions,
        ...widget.availableTags,
        ...blocked,
      ])
        tag: 0,
    };
    for (final book in widget.books) {
      for (final tag in book.tags) {
        frequency.update(tag, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final deduped = {for (final tag in frequency.keys) _tagKey(tag): tag}.values;
    final tags =
        deduped
            .where(
              (tag) =>
                  _isBlockedSelected(tag) ||
                  tag.toLowerCase().contains(query.text.trim().toLowerCase()),
            )
            .toList()
          ..sort((a, b) {
            final order = frequency[b]!.compareTo(frequency[a]!);
            return order == 0 ? a.compareTo(b) : order;
          });

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: ArchiveSection(
                  title: '屏蔽标签',
                  code: 'LIGHTNOVEL / BLOCKED',
                ),
              ),
              if (!widget.editingBlockedTags)
                GlassTextButton(
                  compact: true,
                  onPressed: () => setState(() => _editingBlocked = false),
                  child: const AppText('返回筛选'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      GlassTextButton(
                        key: const ValueKey('blocked-tags-clear'),
                        onPressed: blocked.isEmpty || _saving
                            ? null
                            : () => setState(() {
                                blocked.clear();
                                _saveError = null;
                              }),
                        child: const AppText('清空'),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GlassTextButton(
                          key: const ValueKey('blocked-tags-apply'),
                          selected: blocked.isNotEmpty,
                          onPressed: _saving
                              ? null
                              : () {
                                  FocusScope.of(context).unfocus();
                                  _applyBlocked();
                                },
                          child: AppText(
                            _saving
                                ? '保存中…'
                                : blocked.isEmpty
                                ? '解除全部屏蔽'
                                : '屏蔽 ${blocked.length} 个标签',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  AppSearchField(
                    inputKey: const ValueKey('blocked-tag-input'),
                    controller: query,
                    hint: '搜索或添加屏蔽标签',
                    onChanged: (_) => setState(() {}),
                    onSubmitted: addBlockedTags,
                    trailing: ArchiveIconButton(
                      tooltip: appText(context, '加入标签'),
                      icon: const ArchiveIcon(CupertinoIcons.plus, size: 18),
                      onPressed: query.text.trim().isEmpty
                          ? null
                          : () => addBlockedTags(query.text),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const AppText(
                    '在发现与在线搜索中隐藏含任一所选标签的书。',
                    style: TextStyle(fontSize: 13),
                  ),
                  if (_saveError case final error?) ...[
                    const SizedBox(height: 8),
                    AppText(error, style: const TextStyle(fontSize: 13)),
                  ],
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final tag in tags)
                        GlassTextButton(
                          key: ValueKey('blocked-tag-$tag'),
                          compact: true,
                          selected: _isBlockedSelected(tag),
                          onPressed: _saving
                              ? null
                              : () => setState(() {
                                  if (_isBlockedSelected(tag)) {
                                    blocked.removeWhere(
                                      (value) => _tagKey(value) == _tagKey(tag),
                                    );
                                  } else {
                                    blocked.add(tag);
                                  }
                                  _saveError = null;
                                }),
                          child: AppText(tag, style: const TextStyle(fontSize: 13)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_editingBlocked) return _buildBlockedEditor();

    final supportsSubFilters = DiscoveryFilters.supportsChannelSubFilters(
      sort: _draftSort,
      publication: _draftPublication,
    );
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ArchiveSection(
            title: '筛选',
            code: 'LIGHTNOVEL / FILTERS',
          ),
          const SizedBox(height: 10),
          _buildWebsiteTopTabs(),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 14),
              child: _buildSectionBody(),
            ),
          ),
          Container(
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: scheme.onSurface.withValues(alpha: .08),
                  width: .8,
                ),
              ),
            ),
            child: Row(
              children: [
                if (supportsSubFilters) ...[
                  SizedBox(
                    width: 96,
                    child: DiscoverSecondaryActionButton(
                      key: const ValueKey('discover-filter-reset'),
                      label: '重置',
                      onPressed: _draftFilter.isDefault
                          ? null
                          : () => setState(
                              () => _draftFilter = const FeedFilter(),
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: DiscoverPrimaryActionButton(
                    key: const ValueKey('discover-apply'),
                    label: '确定',
                    onPressed: _applySelection,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
