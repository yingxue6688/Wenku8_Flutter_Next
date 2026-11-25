import 'dart:async';
import 'dart:math' as math;

import '../book_search.dart';
import '../book_tag_catalog.dart';
import '../catalog.dart';
import '../publication_catalog.dart';
import '../tag_catalogue.dart';
import 'lightnovel_client.dart';
import 'lightnovel_content.dart';
import 'lightnovel_models.dart';

class _MultiTagCursor {
  _MultiTagCursor({required this.terms});

  final List<String> terms;
  final List<Novel> matched = [];
  final Set<int> seenIds = {};
  int nextApiPage = 0;
  int scannedPages = 0;
  int? totalApiPages;
  bool done = false;
}

/// Pure-Dart repository implementing LightNovel.fun's BFF/read APIs on top of
/// [NovelRepository], [PublicationCatalog], [ProgressiveTagCatalogue],
/// [FilteredNovelRepository], and [SiteFeedFilterCatalog].
class LightNovelRepository extends NovelRepository
    implements
        PublicationCatalog,
        ProgressiveTagCatalogue,
        FilteredNovelRepository,
        SiteFeedFilterCatalog,
        CachedBookPeekCatalog {
  LightNovelRepository({
    LightNovelClient? client,
    LightNovelPost? post,
    this.pageSize = 20,
    this.tocPageSize = 50,
    this.chapterConcurrency = 8,
    this.maxMultiTagScanPages = 25,
  }) : assert(pageSize > 0),
       assert(tocPageSize > 0),
       assert(chapterConcurrency > 0),
       assert(maxMultiTagScanPages > 0) {
    if (post != null) {
      _post = post;
      _ownedClient = null;
    } else if (client != null) {
      _post = client.post;
      _ownedClient = null;
    } else {
      final owned = LightNovelClient();
      _post = owned.post;
      _ownedClient = owned;
    }
  }

  final int pageSize;
  final int tocPageSize;
  final int chapterConcurrency;
  final int maxMultiTagScanPages;

  late final LightNovelPost _post;
  late final LightNovelClient? _ownedClient;

  static const _stableChannelIds = <String, int>{
    'lightnovel': 1,
    'original': 2,
    'fanfic': 3,
    'epub': 4,
  };

  static const _defaultChannelsById = <int, String>{
    1: 'lightnovel',
    2: 'original',
    3: 'fanfic',
    4: 'epub',
  };

  final Map<(NovelSort, FeedFilter, int), NovelPage> _pages = {};
  final Map<NovelSort, int> _listVersions = {};
  final Map<(NovelSort, FeedFilter, int, int), Future<NovelPage>> _pageRequests =
      {};

  Future<LightNovelTaxonomy>? _taxonomyRequest;
  LightNovelTaxonomy? _taxonomyCache;
  int _taxonomyVersion = 0;
  final Map<int, String> _channelsByLibraryId = Map<int, String>.of(
    _defaultChannelsById,
  );
  final Map<int, int> _publicationVersions = {};
  final Map<(int, FeedFilter, int), NovelPage> _publicationPageCache = {};
  final Map<(int, FeedFilter, int, int), Future<NovelPage>>
  _publicationRequests = {};

  final Map<int, LightNovelBookCard> _bookCards = {};
  final Map<int, Novel> _meta = {};
  final Map<int, Future<Novel?>> _metaRequests = {};
  final Map<int, Future<Novel>> _detailRequests = {};

  final Map<int, List<LightNovelVolumeMeta>> _bookVolumes = {};
  final Map<int, List<NovelChapter>> _indexes = {};
  final Map<int, int> _indexVersions = {};
  final Map<(int, int), Future<List<NovelChapter>>> _indexRequests = {};
  final Map<int, LightNovelChapterMeta> _chapterMeta = {};
  final Map<int, Set<int>> _bookChapterIds = {};

  final Map<String, _MultiTagCursor> _multiTagCursors = {};
  int _tagVersion = 0;

  final Map<(NovelSort?, int?), List<LightNovelFilterOption>>
  _feedCategoryOptions = {};
  final Map<(NovelSort?, int?), FeedFilterSchema> _feedSchemas = {};

  /// Default homepage/feed category tags exposed on LightNovel.fun when
  /// offline or before the first feed filter payload arrives.
  static const List<String> defaultHomeTags = <String>[
    '异世界',
    '校园',
    '恋爱',
    '青春',
    '日常',
    '后宫',
    '冒险',
    '美少女',
    '穿越',
  ];

  /// Returns the site-curated category tags for the active discovery feed or
  /// channel (falling back to hot taxonomy tags or [defaultHomeTags]).
  List<String> discoveryCategoryTags({
    NovelSort sort = NovelSort.lastUpdate,
    PublicationLibrary? publication,
  }) {
    List<String> pickSiteTags(List<LightNovelFilterOption> options) {
      if (options.length > 12) {
        final hot = [
          for (final option in options)
            if (option.displayGroup == 'hot') option.title,
        ];
        if (hot.isNotEmpty) {
          return List<String>.unmodifiable(hot.take(12));
        }
        return List<String>.unmodifiable(
          options.take(12).map((option) => option.title),
        );
      }
      return List<String>.unmodifiable(options.map((option) => option.title));
    }

    final key = publication != null ? (null, publication.id) : (sort, null);
    final scoped = _feedCategoryOptions[key];
    if (scoped != null && scoped.isNotEmpty) {
      return pickSiteTags(scoped);
    }
    if (publication == null) {
      final fallbackFeed =
          _feedCategoryOptions[(NovelSort.lastUpdate, null)] ??
          _feedCategoryOptions[(NovelSort.allVisit, null)];
      if (fallbackFeed != null && fallbackFeed.isNotEmpty) {
        return pickSiteTags(fallbackFeed);
      }
    }
    final hotTags = [
      for (final tag in _taxonomyCache?.tags ?? const <LightNovelTagItem>[])
        if (tag.displayGroup == 'hot') tag.name,
    ];
    if (hotTags.isNotEmpty) {
      return List<String>.unmodifiable(hotTags.take(12));
    }
    return defaultHomeTags;
  }

  bool _supportsCombinedFilters({NovelSort? sort, int? publicationId}) {
    if (publicationId != null) return true;
    return switch (sort) {
      NovelSort.allVisit || NovelSort.lastUpdate || NovelSort.postDate => true,
      _ => false,
    };
  }

  String _defaultSortKeyFor({NovelSort? sort, int? publicationId}) {
    if (publicationId != null) return 'updated';
    return sort == NovelSort.allVisit ? 'hot' : 'updated';
  }

  List<FeedFilterChoice> _sortChoicesFor({
    NovelSort? sort,
    int? publicationId,
  }) => _defaultSortKeyFor(sort: sort, publicationId: publicationId) == 'hot'
      ? const [
          FeedFilterChoice(key: 'hot', title: '按热度'),
          FeedFilterChoice(key: 'updated', title: '按更新时间'),
        ]
      : const [
          FeedFilterChoice(key: 'updated', title: '按更新时间'),
          FeedFilterChoice(key: 'hot', title: '按热度'),
        ];

  void _recordFeedFilterOptions(
    Map<String, dynamic> data, {
    NovelSort? sort,
    int? publicationId,
  }) {
    final options = LightNovelFilterOption.extractCategories(data);
    if (options.isNotEmpty) {
      _feedCategoryOptions[(sort, publicationId)] = options;
    }
    if (!_supportsCombinedFilters(sort: sort, publicationId: publicationId)) {
      return;
    }
    final readRaw = LightNovelFilterOption.extractReadOptions(data);
    final statusRaw = LightNovelFilterOption.extractStatusOptions(data);
    final categoryRaw = LightNovelFilterOption.extractAllCategories(data);
    if (readRaw.isEmpty && statusRaw.isEmpty && categoryRaw.isEmpty) return;
    final defaultSort = _defaultSortKeyFor(
      sort: sort,
      publicationId: publicationId,
    );
    final isEpub =
        publicationId != null && _channelsByLibraryId[publicationId] == 'epub';
    final base =
        _feedSchemas[(sort, publicationId)] ??
        FeedFilterSchema.defaultFor(
          supportsCombinedFilters: true,
          defaultSortKey: defaultSort,
          includeEpubStatus: isEpub,
        );
    final incoming = FeedFilterSchema(
      supportsSort: true,
      defaultSortKey: defaultSort,
      sortOptions: _sortChoicesFor(sort: sort, publicationId: publicationId),
      readOptions: [
        for (final item in readRaw)
          FeedFilterChoice(
            key: item.key,
            title: item.title,
            group: item.displayGroup,
          ),
      ],
      statusOptions: [
        for (final item in statusRaw)
          FeedFilterChoice(
            key: item.key,
            title: item.title,
            group: item.displayGroup,
          ),
      ],
      categoryOptions: [
        for (final item in categoryRaw)
          FeedFilterChoice(
            key: item.key,
            title: item.title,
            group: item.displayGroup,
          ),
      ],
    );
    _feedSchemas[(sort, publicationId)] = base.mergeWith(incoming);
  }

  @override
  FeedFilterSchema? cachedFeedFilters({
    NovelSort? sort,
    PublicationLibrary? publication,
  }) {
    final pubId = publication?.id;
    final effectiveSort = pubId != null ? null : sort;
    if (!_supportsCombinedFilters(sort: effectiveSort, publicationId: pubId)) {
      return const FeedFilterSchema.unsupported();
    }
    return _feedSchemas[(effectiveSort, pubId)];
  }

  @override
  Future<FeedFilterSchema> loadFeedFilters({
    NovelSort? sort,
    PublicationLibrary? publication,
  }) async {
    final cached = cachedFeedFilters(sort: sort, publication: publication);
    if (cached != null) return cached;
    if (publication != null) {
      await browsePublicationFiltered(publication.id, page: 1);
    } else if (sort != null) {
      await browseFiltered(sort: sort, page: 1);
    }
    final resolved = cachedFeedFilters(sort: sort, publication: publication);
    if (resolved != null) return resolved;
    final pubId = publication?.id;
    final effectiveSort = pubId != null ? null : sort;
    if (!_supportsCombinedFilters(sort: effectiveSort, publicationId: pubId)) {
      return const FeedFilterSchema.unsupported();
    }
    final isEpub = pubId != null && _channelsByLibraryId[pubId] == 'epub';
    return FeedFilterSchema.defaultFor(
      supportsCombinedFilters: true,
      defaultSortKey: _defaultSortKeyFor(
        sort: effectiveSort,
        publicationId: pubId,
      ),
      includeEpubStatus: isEpub,
    );
  }

  /// Exposes cached rich [LightNovelBookCard] metadata for Wave 3 UI
  /// integration (illustrator, rating, wordCount, badges).
  LightNovelBookCard? bookMeta(int bookId) => _bookCards[bookId];

  /// Exposes cached [LightNovelChapterMeta] for Wave 3 UI integration
  /// (`locked`, `unlocked`, `accessType`, `coinPrice`, `braveRequired`).
  LightNovelChapterMeta? chapterMeta(int chapterId) => _chapterMeta[chapterId];

  /// Loads and caches the search taxonomy (channels, tags, tabs).
  Future<LightNovelTaxonomy> taxonomy({bool refresh = false}) {
    if (!refresh && _taxonomyCache != null) {
      return Future.value(_taxonomyCache!);
    }
    if (refresh) {
      _taxonomyVersion++;
      _taxonomyCache = null;
      _taxonomyRequest = null;
    }
    final version = _taxonomyVersion;
    return _taxonomyRequest ??= () async {
      try {
        final data = await _post('/api/bff/apk-search-taxonomy-v1', const {});
        final parsed = LightNovelTaxonomy.fromJson(data);
        if (parsed.tags.isNotEmpty) {
          BookTagCatalog.shared.observe(parsed.tags.map((t) => t.name));
        }
        if (_taxonomyVersion == version) {
          _taxonomyCache = parsed;
        }
        return parsed;
      } catch (_) {
        if (_taxonomyVersion == version) {
          _taxonomyRequest = null;
        }
        rethrow;
      }
    }();
  }

  @override
  Future<List<PublicationLibrary>> publicationLibraries({
    bool refresh = false,
  }) async {
    final tax = await taxonomy(refresh: refresh);
    if (tax.channels.isEmpty) {
      throw const FormatException('没有读到有效文库分类');
    }
    final libraries = <PublicationLibrary>[];
    final mapping = <int, String>{};
    var nextDynamicId = 5;
    final usedIds = <int>{};

    for (final channel in tax.channels) {
      var id = _stableChannelIds[channel.code];
      if (id == null || !usedIds.add(id)) {
        while (usedIds.contains(nextDynamicId)) {
          nextDynamicId++;
        }
        id = nextDynamicId++;
        usedIds.add(id);
      }
      mapping[id] = channel.code;
      libraries.add(PublicationLibrary(id, channel.label));
    }

    _channelsByLibraryId
      ..clear()
      ..addAll(_defaultChannelsById)
      ..addAll(mapping);
    return List<PublicationLibrary>.unmodifiable(libraries);
  }

  @override
  Future<NovelPage> browsePublication(
    int libraryId, {
    int page = 1,
    bool refresh = false,
  }) => browsePublicationFiltered(
    libraryId,
    filter: const FeedFilter(),
    page: page,
    refresh: refresh,
  );

  @override
  Future<NovelPage> browsePublicationFiltered(
    int libraryId, {
    FeedFilter filter = const FeedFilter(),
    int page = 1,
    bool refresh = false,
  }) async {
    if (libraryId <= 0 || page <= 0) {
      throw ArgumentError('Invalid publication page');
    }
    final effectiveFilter = filter.normalizedFor(
      defaultSortKey: _defaultSortKeyFor(publicationId: libraryId),
    );
    if (refresh) {
      if (page == 1) {
        _publicationVersions[libraryId] =
            (_publicationVersions[libraryId] ?? 0) + 1;
        _publicationPageCache.removeWhere((key, _) => key.$1 == libraryId);
      } else {
        _publicationPageCache.remove((libraryId, effectiveFilter, page));
      }
    }
    final cached = _publicationPageCache[(libraryId, effectiveFilter, page)];
    if (cached != null) return cached;

    final version = _publicationVersions[libraryId] ?? 0;
    final requestKey = (libraryId, effectiveFilter, page, version);
    final pending = _publicationRequests[requestKey];
    if (pending != null) return pending;

    final request = _loadPublicationPage(
      libraryId,
      page,
      version,
      effectiveFilter,
    );
    _publicationRequests[requestKey] = request;
    try {
      return await request;
    } finally {
      _publicationRequests.remove(requestKey);
    }
  }

  Future<NovelPage> _loadPublicationPage(
    int libraryId,
    int page,
    int version,
    FeedFilter filter,
  ) async {
    var channelCode = _channelsByLibraryId[libraryId];
    if (channelCode == null) {
      await publicationLibraries();
      channelCode = _channelsByLibraryId[libraryId];
    }
    if (channelCode == null) {
      throw ArgumentError.value(libraryId, 'libraryId', '未知文库分类');
    }

    final (path, zeroBased, isSearchFallback) = switch (channelCode) {
      'lightnovel' => ('/api/bff/home-lightnovel-feed-v1', true, false),
      'original' => ('/api/bff/home-original-feed-v1', false, false),
      'fanfic' => ('/api/bff/home-fanfic-feed-v1', false, false),
      'epub' => ('/api/bff/home-epub-feed-v1', false, false),
      _ => ('/api/bff/apk-search-result-v1', true, true),
    };

    final effectiveSort = filter.normalizedSortKey.isNotEmpty
        ? filter.normalizedSortKey
        : _defaultSortKeyFor(publicationId: libraryId);
    final apiPage = zeroBased ? page - 1 : page;
    final body = isSearchFallback
        ? _searchBody(page: apiPage, channelCode: channelCode)
        : <String, Object?>{
            'page': apiPage,
            'page_size': pageSize,
            'pageSize': pageSize,
            'read_filter': filter.readFilter,
            'status_filter': filter.statusFilter,
            'category_filter': filter.categoryFilter,
            'sort': effectiveSort,
          };

    final data = await _post(path, body);
    _recordFeedFilterOptions(data, publicationId: libraryId);
    final result = _parseBookListPage(data, requestedPage: page);
    if ((_publicationVersions[libraryId] ?? 0) == version) {
      _publicationPageCache[(libraryId, filter, page)] = result;
    }
    return result;
  }

  @override
  Future<List<Novel>> list() async => (await browse()).items;

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) => browseFiltered(
    sort: sort,
    filter: const FeedFilter(),
    page: page,
    refresh: refresh,
  );

  @override
  Future<NovelPage> browseFiltered({
    NovelSort sort = NovelSort.lastUpdate,
    FeedFilter filter = const FeedFilter(),
    int page = 1,
    bool refresh = false,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    final effectiveFilter = _supportsCombinedFilters(sort: sort)
        ? filter.normalizedFor(defaultSortKey: _defaultSortKeyFor(sort: sort))
        : const FeedFilter();
    if (refresh && page == 1) {
      _listVersions[sort] = (_listVersions[sort] ?? 0) + 1;
      _pages.removeWhere((key, _) => key.$1 == sort);
    } else if (refresh) {
      _pages.remove((sort, effectiveFilter, page));
    }

    final cached = _pages[(sort, effectiveFilter, page)];
    if (cached != null) return cached;

    final version = _listVersions[sort] ?? 0;
    final key = (sort, effectiveFilter, page, version);
    final pending = _pageRequests[key];
    if (pending != null) return pending;

    final request = _loadBrowsePage(sort, page, version, effectiveFilter);
    _pageRequests[key] = request;
    try {
      return await request;
    } finally {
      _pageRequests.remove(key);
    }
  }

  Future<NovelPage> _loadBrowsePage(
    NovelSort sort,
    int page,
    int version,
    FeedFilter filter,
  ) async {
    final (path, body) = _browseEndpoint(sort, page, filter: filter);
    final data = await _post(path, body);
    _recordFeedFilterOptions(data, sort: sort);
    final result = _parseBookListPage(data, requestedPage: page);
    if ((_listVersions[sort] ?? 0) == version) {
      _pages[(sort, filter, page)] = result;
    }
    return result;
  }

  (String path, Map<String, Object?> body) _browseEndpoint(
    NovelSort sort,
    int page, {
    FeedFilter filter = const FeedFilter(),
  }) {
    final requestedSort = filter.normalizedSortKey;
    Map<String, Object?> feedBody({
      required int apiPage,
      required String defaultSortKey,
      String readFilter = 'all',
      String statusFilter = 'all',
      String categoryFilter = 'all',
    }) => <String, Object?>{
      'page': apiPage,
      'page_size': pageSize,
      'pageSize': pageSize,
      'read_filter': readFilter,
      'status_filter': statusFilter,
      'category_filter': categoryFilter,
      'sort': requestedSort.isNotEmpty ? requestedSort : defaultSortKey,
    };

    Map<String, Object?> rankBody(String scene) => <String, Object?>{
      'rank_scene': scene,
      'page': page,
      'page_size': pageSize,
      'pageSize': pageSize,
    };

    return switch (sort) {
      NovelSort.lastUpdate => (
        '/api/bff/home-recent-updates-feed-v1',
        feedBody(
          apiPage: page - 1,
          defaultSortKey: 'updated',
          readFilter: filter.readFilter,
          statusFilter: filter.statusFilter,
          categoryFilter: filter.categoryFilter,
        ),
      ),
      NovelSort.postDate => (
        '/api/bff/home-new-books-feed-v1',
        feedBody(
          apiPage: page,
          defaultSortKey: 'updated',
          readFilter: filter.readFilter,
          statusFilter: filter.statusFilter,
          categoryFilter: filter.categoryFilter,
        ),
      ),
      NovelSort.allVisit => (
        '/api/bff/home-feed-v1',
        feedBody(
          apiPage: page,
          defaultSortKey: 'hot',
          readFilter: filter.readFilter,
          statusFilter: filter.statusFilter,
          categoryFilter: filter.categoryFilter,
        ),
      ),
      NovelSort.allVote => (
        '/api/bff/home-promo-v1',
        <String, Object?>{
          'page': page,
          'page_size': pageSize,
          'pageSize': pageSize,
        },
      ),
      NovelSort.weekVisit => (
        '/api/bff/book-rank-list-v1',
        rankBody('weekly_hot'),
      ),
      NovelSort.dayVisit => (
        '/api/bff/book-rank-list-v1',
        rankBody('daily_hot'),
      ),
      NovelSort.weekVote => (
        '/api/bff/book-rank-list-v1',
        rankBody('weekly_lightnovel'),
      ),
      NovelSort.dayVote => (
        '/api/bff/book-rank-list-v1',
        rankBody('daily_lightnovel'),
      ),
      NovelSort.monthVisit => (
        '/api/bff/book-rank-list-v1',
        rankBody('weekly_all'),
      ),
      NovelSort.monthVote => (
        '/api/bff/book-rank-list-v1',
        rankBody('daily_all'),
      ),
      NovelSort.goodNum => (
        '/api/bff/book-rank-list-v1',
        rankBody('daily_fresh'),
      ),
      NovelSort.size => (
        '/api/bff/apk-search-result-v1',
        _searchBody(page: page - 1, workType: 'lightnovel', sort: 'words'),
      ),
      NovelSort.fullFlag => (
        '/api/bff/home-lightnovel-feed-v1',
        feedBody(
          apiPage: page - 1,
          defaultSortKey: 'updated',
          statusFilter: 'completed',
        ),
      ),
    };
  }

  Map<String, Object?> _searchBody({
    required int page,
    String q = '',
    String scope = '',
    String source = '',
    String primaryTag = '',
    String channelCode = '',
    String workType = '',
    String sort = 'relevance',
  }) => <String, Object?>{
    'q': q,
    'scope': scope,
    'source': source,
    'primary_tag': primaryTag,
    'channel_code': channelCode,
    'work_type': workType,
    'preset': '',
    'source_type': '',
    'filters': <String, Object?>{},
    'word_count_bucket': '',
    'status_bucket': '',
    'page': page,
    'page_size': pageSize,
    'pageSize': pageSize,
    'sort': sort,
  };

  @override
  Future<Novel?> find(int id, {bool refresh = false}) async {
    if (id <= 0) return null;
    if (!refresh && _meta.containsKey(id)) return _meta[id];
    if (!refresh) {
      final pending = _metaRequests[id];
      if (pending != null) return pending;
    }

    final request = _loadMeta(id);
    _metaRequests[id] = request;
    try {
      return await request;
    } finally {
      if (identical(_metaRequests[id], request)) {
        _metaRequests.remove(id);
      }
    }
  }

  @override
  Novel? cachedDetail(int id) => _meta[id];

  @override
  List<NovelChapter>? cachedChapters(int id) => _indexes[id];

  Future<Novel?> _loadMeta(int id) async {
    try {
      final data = await _post('/api/new-content-read/get-book-detail', {
        'book_id': id,
        'with_volumes': 1,
      });
      final card = LightNovelBookCard.fromJson(data);
      if (card.bookId <= 0 || card.title.isEmpty) return null;
      final novel = _rememberCard(card);
      final rawVolumes = asList(data['volumes']);
      if (rawVolumes.isNotEmpty) {
        final volumes = <LightNovelVolumeMeta>[];
        final seenVolIds = <int>{};
        for (final item in rawVolumes) {
          final map = asMap(item);
          if (map == null) continue;
          final volume = LightNovelVolumeMeta.fromJson(map);
          if (volume.volumeId > 0 && seenVolIds.add(volume.volumeId)) {
            volumes.add(volume);
          }
        }
        final volumesLoaded = asBool01(data['volumes_loaded']);
        final expectedVolumes = card.volumeCount;
        if (volumes.isNotEmpty &&
            (volumesLoaded ||
                expectedVolumes <= 0 ||
                volumes.length >= expectedVolumes)) {
          _bookVolumes[id] = List<LightNovelVolumeMeta>.unmodifiable(volumes);
        }
      }
      return novel;
    } on LightNovelApiError catch (error) {
      if (error.isNotFound) {
        _bookCards.remove(id);
        _meta.remove(id);
        return null;
      }
      rethrow;
    }
  }

  /// Calls `find(bookId)` bypassing stale cache to obtain the freshest cover URL.
  Future<String?> resolveCoverUrl(int bookId) async {
    final novel = await find(bookId, refresh: true);
    return novel?.coverUrl ?? _bookCards[bookId]?.coverUrl;
  }

  @override
  Future<List<Novel>> search(String query) async =>
      (await searchPage(query)).items;

  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) => searchFilteredPage(
    query,
    field: BookSearchField.all,
    page: page,
    refresh: refresh,
  );

  @override
  Future<NovelPage> authorPage(
    String author, {
    int page = 1,
    bool refresh = false,
  }) => searchFilteredPage(
    author,
    field: BookSearchField.author,
    page: page,
    refresh: refresh,
  );

  @override
  Future<NovelPage> searchFilteredPage(
    String query, {
    BookSearchField field = BookSearchField.all,
    int page = 1,
    bool refresh = false,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    var term = query.trim();
    var effectiveField = field;
    if (term.startsWith('#') && effectiveField == BookSearchField.all) {
      effectiveField = BookSearchField.tags;
      term = term.substring(1).trim();
    }
    if (term.isEmpty) {
      return effectiveField != BookSearchField.all
          ? NovelPage.fromItems(const [], page, pageSize: pageSize)
          : browse(page: page, refresh: refresh);
    }
    if (effectiveField == BookSearchField.id) {
      final id = int.tryParse(term);
      final book = id == null || id <= 0
          ? null
          : await find(id, refresh: refresh);
      return NovelPage.fromItems(
        book == null ? const [] : [book],
        page,
        pageSize: pageSize,
      );
    }
    if (effectiveField == BookSearchField.tags) {
      return tagPage(term, page: page, refresh: refresh);
    }

    final body = switch (effectiveField) {
      BookSearchField.author => _searchBody(
        page: page - 1,
        q: term,
        scope: 'author',
        source: 'manual',
      ),
      BookSearchField.title || BookSearchField.all => _searchBody(
        page: page - 1,
        q: term,
        source: 'manual',
      ),
      BookSearchField.tags || BookSearchField.id => throw StateError('handled'),
    };

    final data = await _post('/api/bff/apk-search-result-v1', body);
    if (effectiveField == BookSearchField.title) {
      final pattern = BookSearch(term, field: BookSearchField.title);
      return _parseBookListPage(
        data,
        requestedPage: page,
        filter: (card) {
          final novel = card.toNovel();
          return pattern.matches(
            title: novel.title,
            author: novel.author,
            tags: novel.genre,
          );
        },
      );
    }
    return _parseBookListPage(data, requestedPage: page);
  }

  @override
  Future<NovelPage> tagPage(
    String tag, {
    int page = 1,
    bool refresh = false,
    bool Function()? current,
    TagProgressCallback? onProgress,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    final terms = tagSearchTerms(tag);
    if (terms.isEmpty) {
      return NovelPage.fromItems(const [], page, pageSize: pageSize);
    }

    if (terms.length == 1) {
      final data = await _post(
        '/api/bff/apk-search-result-v1',
        _searchBody(
          page: page - 1,
          source: 'category_tag',
          primaryTag: terms.first,
          channelCode: '',
        ),
      );
      return _parseBookListPage(data, requestedPage: page);
    }

    final cacheKey = terms.join('|');
    if (refresh && page == 1) {
      _tagVersion++;
      _multiTagCursors.remove(cacheKey);
    }
    final version = _tagVersion;
    final cursor = _multiTagCursors.putIfAbsent(
      cacheKey,
      () => _MultiTagCursor(terms: terms),
    );

    final primaryTag = terms.first;
    final remainingTerms = terms.skip(1).toList();
    final remainingPattern = BookSearch(
      remainingTerms.join(' '),
      field: BookSearchField.tags,
    );
    final needed = page * pageSize;

    while (!cursor.done &&
        cursor.matched.length < needed &&
        current?.call() != false &&
        version == _tagVersion) {
      final apiPage = cursor.nextApiPage;
      final data = await _post(
        '/api/bff/apk-search-result-v1',
        _searchBody(
          page: apiPage,
          source: 'category_tag',
          primaryTag: primaryTag,
          channelCode: '',
        ),
      );
      if (version != _tagVersion || current?.call() == false) {
        break;
      }

      final parsed = _extractCards(data);
      final pagination = LightNovelPagination.fromResponse(
        data,
        requestedPage: apiPage + 1,
        defaultPageSize: pageSize,
        itemCount: parsed.length,
      );

      cursor.nextApiPage = apiPage + 1;
      cursor.scannedPages++;
      cursor.totalApiPages = pagination.pageCount;

      final newlyMatched = <Novel>[];
      for (final card in parsed) {
        final novel = _rememberCard(card);
        if (novel.tags.isNotEmpty) {
          BookTagCatalog.shared.observe(novel.tags);
        }
        if (remainingPattern.matches(
              title: novel.title,
              author: novel.author,
              tags: novel.genre,
            ) &&
            cursor.seenIds.add(novel.id)) {
          cursor.matched.add(novel);
          newlyMatched.add(novel);
        }
      }

      onProgress?.call(
        TagSearchProgress(
          items: List<Novel>.unmodifiable(newlyMatched),
          scannedPages: cursor.scannedPages,
          totalPages: cursor.totalApiPages,
        ),
      );

      if (!pagination.hasMore ||
          parsed.isEmpty ||
          cursor.scannedPages >= maxMultiTagScanPages) {
        cursor.done = true;
      }
    }

    final pageItems = cursor.matched
        .skip((page - 1) * pageSize)
        .take(pageSize)
        .toList();
    final totalPages = cursor.done
        ? (cursor.matched.length / pageSize).ceil()
        : (cursor.matched.length >= needed ? page + 1 : page);
    return NovelPage(
      items: List<Novel>.unmodifiable(pageItems),
      page: page,
      totalPages: totalPages,
      totalItems: cursor.done ? cursor.matched.length : null,
    );
  }

  @override
  Future<Novel> detail(Novel novel) async {
    final pending = _detailRequests[novel.id];
    if (pending != null) return pending;

    final request = _loadDetail(novel);
    _detailRequests[novel.id] = request;
    try {
      return await request;
    } finally {
      if (identical(_detailRequests[novel.id], request)) {
        _detailRequests.remove(novel.id);
      }
    }
  }

  Future<Novel> _loadDetail(Novel novel) async {
    var meta = await find(novel.id, refresh: true) ?? novel;
    if (meta.tags.isEmpty && novel.tags.isNotEmpty) {
      meta = meta.withGenre(novel.genre);
      _meta[novel.id] = meta;
    }
    return meta;
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    if (id <= 0) return const [];
    if (_indexes.containsKey(id)) return _indexes[id]!;
    final version = _indexVersions[id] ?? 0;
    final key = (id, version);
    final pending = _indexRequests[key];
    if (pending != null) return pending;

    final request = _loadChapters(id, version);
    _indexRequests[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_indexRequests[key], request)) {
        _indexRequests.remove(key);
      }
    }
  }

  Future<List<NovelChapter>> _loadChapters(int bookId, int version) async {
    final volumes = await _fetchAllVolumes(bookId);
    if (volumes.isEmpty) {
      if ((_indexVersions[bookId] ?? 0) == version) {
        _indexes[bookId] = const [];
      }
      return const [];
    }

    final indexedVolumes = volumes.indexed.toList()
      ..sort((a, b) {
        final order = a.$2.sortIndex.compareTo(b.$2.sortIndex);
        return order != 0 ? order : a.$1.compareTo(b.$1);
      });
    final sortedVolumes = [for (final entry in indexedVolumes) entry.$2];

    final chaptersByVolume = List<List<LightNovelChapterMeta>>.filled(
      sortedVolumes.length,
      const [],
    );
    var cursor = 0;
    final workers = math.min(chapterConcurrency, sortedVolumes.length);

    Future<void> worker() async {
      while (cursor < sortedVolumes.length) {
        final index = cursor++;
        chaptersByVolume[index] = await _fetchVolumeChapters(
          bookId,
          sortedVolumes[index].volumeId,
        );
      }
    }

    await Future.wait(List.generate(workers, (_) => worker()));

    final flattened = <NovelChapter>[];
    final seenChapterIds = <int>{};
    final chapterIdsForBook = <int>{};

    for (var i = 0; i < sortedVolumes.length; i++) {
      final volume = sortedVolumes[i];
      for (final meta in chaptersByVolume[i]) {
        if (meta.chapterId <= 0 || !seenChapterIds.add(meta.chapterId)) {
          continue;
        }
        chapterIdsForBook.add(meta.chapterId);
        if ((_indexVersions[bookId] ?? 0) == version) {
          _chapterMeta[meta.chapterId] = meta;
        }
        flattened.add(
          NovelChapter(
            meta.title.isNotEmpty ? meta.title : '章节 ${meta.chapterId}',
            '',
            id: meta.chapterId,
            volumeId: volume.volumeId,
            volumeTitle: volume.title,
            isLocked: meta.isLocked,
            coinPrice: meta.coinPrice,
          ),
        );
      }
    }

    final result = List<NovelChapter>.unmodifiable(flattened);
    if ((_indexVersions[bookId] ?? 0) == version) {
      final previousIds = _bookChapterIds[bookId];
      if (previousIds != null) {
        for (final oldId in previousIds) {
          if (!chapterIdsForBook.contains(oldId)) {
            _chapterMeta.remove(oldId);
          }
        }
      }
      _bookChapterIds[bookId] = chapterIdsForBook;
      _indexes[bookId] = result;
    }
    return result;
  }

  Future<List<LightNovelVolumeMeta>> _fetchAllVolumes(int bookId) async {
    final preloaded = _bookVolumes[bookId];
    if (preloaded != null && preloaded.isNotEmpty) {
      return preloaded;
    }
    final volumes = <LightNovelVolumeMeta>[];
    final seenIds = <int>{};
    var page = 1;
    const maxPages = 100;

    while (page <= maxPages) {
      final data = await _post('/api/new-content-read/get-book-volumes', {
        'book_id': bookId,
        'page': page,
        'page_size': tocPageSize,
        'pageSize': tocPageSize,
      });
      final rawList = asList(data['list']);
      var added = 0;
      for (final item in rawList) {
        final map = asMap(item);
        if (map == null) continue;
        final volume = LightNovelVolumeMeta.fromJson(map);
        if (volume.volumeId > 0 && seenIds.add(volume.volumeId)) {
          volumes.add(volume);
          added++;
        }
      }
      final pagination = LightNovelPagination.fromResponse(
        data,
        requestedPage: page,
        defaultPageSize: tocPageSize,
        itemCount: rawList.length,
      );
      if (!pagination.hasMore || rawList.isEmpty || added == 0) {
        break;
      }
      page++;
    }
    return volumes;
  }

  Future<List<LightNovelChapterMeta>> _fetchVolumeChapters(
    int bookId,
    int volumeId,
  ) async {
    final chapters = <LightNovelChapterMeta>[];
    final seenIds = <int>{};
    var page = 1;
    const maxPages = 200;

    while (page <= maxPages) {
      final data = await _post('/api/new-content-read/get-volume-chapters', {
        'book_id': bookId,
        'volume_id': volumeId,
        'page': page,
        'page_size': tocPageSize,
        'pageSize': tocPageSize,
      });
      final rawList = asList(data['list']);
      var added = 0;
      for (final item in rawList) {
        final map = asMap(item);
        if (map == null) continue;
        final chapter = LightNovelChapterMeta.fromJson(map);
        if (chapter.chapterId > 0 && seenIds.add(chapter.chapterId)) {
          chapters.add(chapter);
          added++;
        }
      }
      final pagination = LightNovelPagination.fromResponse(
        data,
        requestedPage: page,
        defaultPageSize: tocPageSize,
        itemCount: rawList.length,
      );
      if (!pagination.hasMore || rawList.isEmpty || added == 0) {
        break;
      }
      page++;
    }

    final indexed = chapters.indexed.toList()
      ..sort((a, b) {
        final order = a.$2.chapterNo.compareTo(b.$2.chapterNo);
        return order != 0 ? order : a.$1.compareTo(b.$1);
      });
    return [for (final entry in indexed) entry.$2];
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    if (chapter.id <= 0) return chapter.content;
    final data = await _post('/api/new-content-read/get-chapter-detail', {
      'book_id': novelId,
      'chapter_id': chapter.id,
    });
    final detail = LightNovelChapterDetail.fromJson(data);
    _chapterMeta[chapter.id] = detail.toChapterMeta();
    (_bookChapterIds[novelId] ??= <int>{}).add(chapter.id);
    return LightNovelContentNormalizer.normalizeDetailOrThrow(detail);
  }

  /// Unlocks a coin-locked chapter and invalidates cached lock metadata for
  /// [bookId] so the next TOC/content load reflects the unlocked state.
  Future<void> unlockChapter(int bookId, int chapterId) async {
    await _post('/api/new-content-read/unlock-chapter', {
      'chapter_id': chapterId,
    });
    _invalidateBookLockMetadata(bookId, chapterId: chapterId);
  }

  /// Clears auth-dependent caches (locked chapter states, personalized feed
  /// pages) after login or logout.
  void invalidateAuthDependentCaches() {
    for (final bookId in _indexes.keys.toList()) {
      _indexVersions[bookId] = (_indexVersions[bookId] ?? 0) + 1;
    }
    _bookVolumes.clear();
    _indexes.clear();
    _chapterMeta.clear();
    _bookChapterIds.clear();

    for (final sort in _listVersions.keys.toList()) {
      _listVersions[sort] = (_listVersions[sort] ?? 0) + 1;
    }
    _pages.clear();

    for (final libId in _publicationVersions.keys.toList()) {
      _publicationVersions[libId] = (_publicationVersions[libId] ?? 0) + 1;
    }
    _publicationPageCache.clear();
    _feedCategoryOptions.clear();
    _feedSchemas.clear();
  }

  void _invalidateBookIndex(int bookId) {
    _bookVolumes.remove(bookId);
    _indexes.remove(bookId);
    _indexVersions[bookId] = (_indexVersions[bookId] ?? 0) + 1;
  }

  void _invalidateBookLockMetadata(int bookId, {int? chapterId}) {
    _invalidateBookIndex(bookId);
    if (chapterId != null) {
      _chapterMeta.remove(chapterId);
    }
    final tracked = _bookChapterIds.remove(bookId);
    if (tracked != null) {
      for (final cid in tracked) {
        _chapterMeta.remove(cid);
      }
    }
  }

  List<LightNovelBookCard> _extractCards(Map<String, dynamic> data) {
    final rawList = asList(data['list']);
    final source = rawList.isNotEmpty ? rawList : asList(data['items']);
    final cards = <LightNovelBookCard>[];
    final seen = <int>{};
    for (final item in source) {
      final map = asMap(item);
      if (map == null) continue;
      final card = LightNovelBookCard.fromJson(map);
      if (card.bookId > 0 && seen.add(card.bookId)) {
        cards.add(card);
      }
    }
    return cards;
  }

  Novel _rememberCard(LightNovelBookCard card) {
    final previous = _bookCards[card.bookId];
    if (previous != null &&
        (previous.updatedAt != card.updatedAt ||
            (card.chapterCount > 0 &&
                previous.chapterCount > 0 &&
                previous.chapterCount != card.chapterCount) ||
            (card.volumeCount > 0 &&
                previous.volumeCount > 0 &&
                previous.volumeCount != card.volumeCount))) {
      _invalidateBookIndex(card.bookId);
    }
    var novel = card.toNovel();
    if (novel.tags.isEmpty && _meta[card.bookId]?.tags.isNotEmpty == true) {
      novel = novel.withGenre(_meta[card.bookId]!.genre);
    }
    _bookCards[card.bookId] = card;
    _meta[card.bookId] = novel;
    return novel;
  }

  NovelPage _parseBookListPage(
    Map<String, dynamic> data, {
    required int requestedPage,
    bool Function(LightNovelBookCard card)? filter,
  }) {
    final cards = _extractCards(data);
    final pagination = LightNovelPagination.fromResponse(
      data,
      requestedPage: requestedPage,
      defaultPageSize: pageSize,
      itemCount: cards.length,
    );

    final novels = <Novel>[];
    for (final card in cards) {
      final novel = _rememberCard(card);
      if (novel.tags.isNotEmpty) {
        BookTagCatalog.shared.observe(novel.tags);
      }
      if (filter == null || filter(card)) {
        novels.add(novel);
      }
    }

    final int totalPages;
    if (pagination.hasMore) {
      totalPages =
          pagination.pageCount != null && pagination.pageCount! > requestedPage
          ? pagination.pageCount!
          : requestedPage + 1;
    } else {
      totalPages = requestedPage == 1 && novels.isEmpty ? 0 : requestedPage;
    }

    return NovelPage(
      items: List<Novel>.unmodifiable(novels),
      page: requestedPage,
      totalPages: totalPages,
      totalItems: filter == null ? pagination.total : null,
    );
  }

  void close({bool force = false}) {
    _ownedClient?.close(force: force);
  }
}
