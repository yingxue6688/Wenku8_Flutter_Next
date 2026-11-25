import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../book_identity.dart';
import '../library_state.dart';
import '../online_component.dart';
import 'lightnovel_reviews.dart';

export 'lightnovel_reviews.dart'
    show
        LightNovelApiCall,
        LightNovelAuthError,
        LightNovelCommentLikeResult,
        LightNovelErrorCode,
        LightNovelErrorMessage,
        describeLightNovelError,
        unwrapLightNovelResponse;

typedef SessionRead = Future<String?> Function();
typedef SessionWrite = Future<void> Function(String? payload);
typedef AvatarDownload = Future<Uint8List> Function(String url);

class LightNovelShelfPlan {
  LightNovelShelfPlan({
    required Set<int> local,
    required Set<int> remote,
    Set<int>? lastLocal,
    Set<int>? lastCloud,
  }) {
    final added = lastLocal == null ? local : local.difference(lastLocal);
    final removed = lastLocal?.difference(local) ?? <int>{};
    target = {...remote, ...added}..removeAll(removed);
    localAdded = target.difference(local);
    localRemoved = local.intersection(lastCloud?.difference(remote) ?? {})
      ..removeAll(added);
  }

  late final Set<int> target;
  late final Set<int> localAdded;
  late final Set<int> localRemoved;
}

/// Persisted session payload for LightNovel.fun (`{security_key, uid}`).
/// Never exposes `securityKey` in `toString()` or diagnostics.
class LightNovelSession {
  LightNovelSession({required String securityKey, required this.uid})
    : securityKey = securityKey.trim() {
    if (!_validKey(this.securityKey)) {
      throw const FormatException('会话凭据格式无效');
    }
    if (uid <= 0) {
      throw const FormatException('账号 UID 无效');
    }
  }

  final String securityKey;
  final int uid;

  static final RegExp _controlChars = RegExp(r'[\x00-\x1f\x7f]');

  static bool _validKey(String value) =>
      value.isNotEmpty &&
      value.length <= 4096 &&
      !_controlChars.hasMatch(value);

  Map<String, Object> toJson() => {'security_key': securityKey, 'uid': uid};

  String encode() => jsonEncode(toJson());

  factory LightNovelSession.fromJson(Map<String, dynamic> json) {
    final key = lnAsString(json['security_key'] ?? json['securityKey']).trim();
    final uid = lnAsInt(json['uid']);
    if (!_validKey(key) || uid <= 0) {
      throw const FormatException('本地会话记录已损坏');
    }
    return LightNovelSession(securityKey: key, uid: uid);
  }

  factory LightNovelSession.decode(String raw) {
    final decoded = jsonDecode(raw);
    final map = lnAsMap(decoded);
    if (map == null) throw const FormatException('本地会话记录格式有误');
    return LightNovelSession.fromJson(map);
  }

  static LightNovelSession? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return LightNovelSession.decode(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LightNovelSession &&
      other.uid == uid &&
      other.securityKey == securityKey;

  @override
  int get hashCode => Object.hash(uid, securityKey);

  @override
  String toString() => 'LightNovelSession(uid: $uid)';
}

class LightNovelProfile {
  const LightNovelProfile({
    required this.uid,
    this.username = '',
    this.nickname = '',
    this.avatarUrl = '',
    this.sign = '',
    this.level = 0,
    this.levelName = '',
    this.exp = 0,
    this.nextExp = 0,
    this.coin = 0,
    this.followers = 0,
    this.following = 0,
    this.postCount = 0,
  });

  final int uid;
  final String username;
  final String nickname;
  final String avatarUrl;
  final String sign;
  final int level;
  final String levelName;
  final int exp;
  final int nextExp;
  final int coin;
  final int followers;
  final int following;
  final int postCount;

  int get id => uid;

  String get displayName {
    if (nickname.isNotEmpty) return nickname;
    if (username.isNotEmpty) return username;
    return 'UID $uid';
  }

  factory LightNovelProfile.fromJson(
    Map<String, dynamic> json, {
    int fallbackUid = 0,
    String fallbackUsername = '',
  }) {
    final profileMap = lnAsMap(json['profile']);
    final userMap = lnAsMap(json['user']);
    final statsMap = lnAsMap(json['stats']);
    final authMap = lnAsMap(json['auth']);

    final sources = <Map<String, dynamic>>[
      ?profileMap,
      ?userMap,
      json,
      ?statsMap,
    ];

    Object? firstValue(List<String> keys) {
      for (final source in sources) {
        for (final key in keys) {
          final value = source[key];
          if (value != null && !(value is String && value.trim().isEmpty)) {
            return value;
          }
        }
      }
      return null;
    }

    int firstInt(List<String> keys, {int fallback = 0}) {
      for (final source in sources) {
        for (final key in keys) {
          if (source.containsKey(key) && source[key] != null) {
            final value = source[key];
            if (value is Map || value is List) continue;
            return lnAsInt(value, fallback);
          }
        }
      }
      return fallback;
    }

    final balanceMap =
        lnAsMap(profileMap?['balance']) ??
        lnAsMap(userMap?['balance']) ??
        lnAsMap(json['balance']) ??
        lnAsMap(statsMap?['balance']);

    final levelObj =
        lnAsMap(profileMap?['level']) ??
        lnAsMap(userMap?['level']) ??
        lnAsMap(json['level']);

    final uid = lnAsInt(
      firstValue(const ['uid', 'user_id', 'id']) ?? authMap?['uid'],
      fallbackUid,
    );
    if (uid <= 0) {
      throw const FormatException('账号信息不完整');
    }

    final username = lnAsString(
      firstValue(const ['username', 'uname', 'user_name', 'account']),
      fallbackUsername,
    ).trim();
    final nickname = lnAsString(
      firstValue(const ['nickname', 'nick_name', 'name']),
    ).trim();
    final avatarUrl = lnAsString(
      firstValue(const ['avatar_url', 'avatarUrl', 'avatar']),
    ).trim();
    final sign = lnAsString(
      firstValue(const ['signature', 'sign', 'bio', 'intro']),
    ).trim();

    final level = levelObj != null
        ? lnAsInt(levelObj['level'] ?? levelObj['lv'])
        : firstInt(const ['level', 'lv']);
    final levelName = lnAsString(
      firstValue(const ['level_name', 'levelName', 'rank', 'role_name']) ??
          levelObj?['name'] ??
          levelObj?['title'],
    ).trim();
    final exp = firstInt(const [
      'exp',
      'experience',
    ], fallback: lnAsInt(levelObj?['exp']));
    final nextExp = firstInt(const [
      'next_exp',
      'nextExp',
    ], fallback: lnAsInt(levelObj?['next_exp'] ?? levelObj?['nextExp']));

    final coin =
        balanceMap != null &&
            (balanceMap.containsKey('coin') ||
                balanceMap.containsKey('light_coin') ||
                balanceMap.containsKey('lightCoin'))
        ? lnAsInt(
            balanceMap['coin'] ??
                balanceMap['light_coin'] ??
                balanceMap['lightCoin'],
          )
        : firstInt(const ['coin', 'light_coin', 'lightCoin', 'coins']);

    final followers = firstInt(const [
      'followers',
      'fans_count',
      'fansCount',
      'follower_count',
      'fans',
    ]);
    final following = firstInt(const [
      'following',
      'following_count',
      'followingCount',
      'follow_count',
    ]);
    final postCount = firstInt(const [
      'post_count',
      'postCount',
      'publish_articles',
      'publishArticles',
      'article_count',
      'posts',
    ]);

    return LightNovelProfile(
      uid: uid,
      username: username,
      nickname: nickname,
      avatarUrl: avatarUrl,
      sign: sign,
      level: level,
      levelName: levelName,
      exp: exp,
      nextExp: nextExp,
      coin: coin,
      followers: followers,
      following: following,
      postCount: postCount,
    );
  }

  static LightNovelProfile? tryFromJson(
    Map<String, dynamic> json, {
    int fallbackUid = 0,
    String fallbackUsername = '',
  }) {
    try {
      return LightNovelProfile.fromJson(
        json,
        fallbackUid: fallbackUid,
        fallbackUsername: fallbackUsername,
      );
    } catch (_) {
      return null;
    }
  }

  LightNovelProfile copyWith({
    int? uid,
    String? username,
    String? nickname,
    String? avatarUrl,
    String? sign,
    int? level,
    String? levelName,
    int? exp,
    int? nextExp,
    int? coin,
    int? followers,
    int? following,
    int? postCount,
  }) => LightNovelProfile(
    uid: uid ?? this.uid,
    username: username ?? this.username,
    nickname: nickname ?? this.nickname,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    sign: sign ?? this.sign,
    level: level ?? this.level,
    levelName: levelName ?? this.levelName,
    exp: exp ?? this.exp,
    nextExp: nextExp ?? this.nextExp,
    coin: coin ?? this.coin,
    followers: followers ?? this.followers,
    following: following ?? this.following,
    postCount: postCount ?? this.postCount,
  );
}

class LightNovelCloudBook {
  const LightNovelCloudBook({
    required this.bookId,
    this.title = '',
    this.author = '',
    this.coverUrl = '',
    this.updatedAt = '',
    this.hasUpdate = false,
    this.lastReadChapterId = 0,
    this.unreadChapterCount = 0,
  });

  final int bookId;
  final String title;
  final String author;
  final String coverUrl;
  final String updatedAt;
  final bool hasUpdate;
  final int lastReadChapterId;
  final int unreadChapterCount;

  int get id => bookId;

  static LightNovelCloudBook? tryFromJson(Map<String, dynamic> json) {
    final bookId = lnAsInt(json['book_id'] ?? json['bookId'] ?? json['id']);
    if (bookId <= 0 || isLocalBook(bookId)) return null;
    return LightNovelCloudBook(
      bookId: bookId,
      title: lnAsString(json['title'] ?? json['name']).trim(),
      author: lnAsString(
        json['author_name'] ?? json['authorName'] ?? json['author'],
      ).trim(),
      coverUrl: lnAsString(json['cover_url'] ?? json['coverUrl']).trim(),
      updatedAt: lnAsString(
        json['updated_at'] ??
            json['updatedAt'] ??
            json['latest_chapter_published_at'] ??
            json['read_at'],
      ).trim(),
      hasUpdate: lnAsBool(json['has_update'] ?? json['hasUpdate']),
      lastReadChapterId: lnAsInt(
        json['last_read_chapter_id'] ?? json['lastReadChapterId'],
      ),
      unreadChapterCount: lnAsInt(
        json['unread_chapter_count'] ?? json['unreadChapterCount'],
      ),
    );
  }
}

class LightNovelCloudUploadResult {
  const LightNovelCloudUploadResult(this.uploaded, this.remaining, this.error);

  final List<int> uploaded;
  final List<int> remaining;
  final Object? error;
}

class LightNovelBookLibraryState {
  const LightNovelBookLibraryState({
    required this.bookId,
    required this.inShelf,
    this.lastReadChapterId = 0,
    this.volumeId = 0,
    this.chapterId = 0,
    this.lastPosition = 0,
    this.progressPercent = 0,
    this.lastReadAt = '',
    this.resumeState,
  });

  final int bookId;
  final bool inShelf;
  final int lastReadChapterId;
  final int volumeId;
  final int chapterId;
  final int lastPosition;
  final int progressPercent;
  final String lastReadAt;
  final Map<String, dynamic>? resumeState;

  factory LightNovelBookLibraryState.fromJson(
    int bookId,
    Map<String, dynamic> data,
  ) {
    final history = lnAsMap(data['history']);
    final resume = lnAsMap(data['resume_state'] ?? data['resumeState']);
    final historyChapterId = lnAsInt(history?['chapter_id']);
    final lastChapterId = lnAsInt(
      data['last_read_chapter_id'] ?? data['lastReadChapterId'],
      historyChapterId,
    );
    return LightNovelBookLibraryState(
      bookId: bookId,
      inShelf: lnAsBool(data['in_shelf'] ?? data['inShelf']),
      lastReadChapterId: lastChapterId,
      volumeId: lnAsInt(history?['volume_id'] ?? data['volume_id']),
      chapterId: historyChapterId > 0 ? historyChapterId : lastChapterId,
      lastPosition: lnAsInt(history?['last_position']),
      progressPercent: lnAsInt(history?['progress_percent']).clamp(0, 100),
      lastReadAt: lnAsString(history?['last_read_at']).trim(),
      resumeState: resume == null ? null : Map.unmodifiable(resume),
    );
  }
}

/// Session owner for LightNovel.fun authentication, profile/coin state,
/// cloud bookshelf synchronization, reading progress sync, chapter unlock,
/// and comment write operations.
class LightNovelAccount extends ChangeNotifier {
  LightNovelAccount({
    required LightNovelApiCall apiCall,
    required SessionRead readSession,
    required SessionWrite writeSession,
    AvatarDownload? downloadAvatar,
    this.errorCode,
    this.errorMessage,
    int maxCloudPages = 40,
    int cloudPageSize = 50,
  }) : _apiCall = apiCall,
       _readSession = readSession,
       _writeSession = writeSession,
       _downloadAvatar = downloadAvatar,
       _maxCloudPages = maxCloudPages.clamp(1, 200),
       _cloudPageSize = cloudPageSize.clamp(1, 100);

  final LightNovelApiCall _apiCall;
  final SessionRead _readSession;
  final SessionWrite _writeSession;
  final AvatarDownload? _downloadAvatar;
  final LightNovelErrorCode? errorCode;
  final LightNovelErrorMessage? errorMessage;
  final int _maxCloudPages;
  final int _cloudPageSize;

  Future<void>? _initialization;
  LightNovelSession? _session;
  bool _disposed = false;
  int _identity = 0;

  int get sessionRevision => _identity;
  String? get securityKey => authenticated ? _session?.securityKey : null;
  LightNovelApiCall get apiCall => _apiCall;

  Future<Map<String, dynamic>> callPublicApi(
    String path,
    Map<String, Object?> body, {
    bool commentProxy = false,
  }) => _apiCall(path, body, commentProxy: commentProxy);

  bool authenticated = false;
  bool busy = false;
  String? operation;
  String? error;
  LightNovelProfile? profile;
  Uint8List? avatar;
  List<LightNovelCloudBook>? cloudBooks;
  int? syncedAt;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String describeError(
    Object error, {
    LightNovelErrorCode? errorCode,
    LightNovelErrorMessage? errorMessage,
  }) => describeLightNovelError(
    error,
    errorCode: errorCode,
    errorMessage: errorMessage,
  );

  String formatError(Object failure) => describeLightNovelError(
    failure,
    errorCode: errorCode,
    errorMessage: errorMessage,
  );

  bool _isAuthExpiredError(Object failure) {
    if (failure is OnlineAuthenticationRequired) return true;
    if (failure is LightNovelAuthError && failure.code == 8) return true;
    return errorCode?.call(failure) == 8;
  }

  Future<void> _loadAvatar(String? url) async {
    final downloader = _downloadAvatar;
    if (downloader == null) return;
    final targetUrl = url?.trim() ?? '';
    if (targetUrl.isEmpty) {
      if (avatar != null) {
        avatar = null;
        _notify();
      }
      return;
    }
    final identity = _identity;
    try {
      final bytes = await downloader(targetUrl);
      if (!_disposed &&
          identity == _identity &&
          authenticated &&
          profile?.avatarUrl == targetUrl &&
          bytes.isNotEmpty &&
          bytes.length <= 2 * 1024 * 1024) {
        avatar = bytes;
        _notify();
      }
    } catch (_) {
      // An absent avatar never invalidates an authenticated session.
    }
  }

  Future<void> _clearSessionState({bool notify = true}) async {
    try {
      await _writeSession(null);
    } catch (_) {
      // Even if secure storage fails to clear, drop in-memory auth state.
    }
    _identity++;
    _session = null;
    authenticated = false;
    profile = null;
    avatar = null;
    cloudBooks = null;
    syncedAt = null;
    if (notify) _notify();
  }

  /// Handles an external API client observing error code `8`.
  Future<void> handleSessionExpired() async {
    if (_disposed || (!authenticated && _session == null)) return;
    error = const LightNovelAuthError(8).message;
    await _clearSessionState();
  }

  Future<T> _run<T>(String label, Future<T> Function() work) async {
    if (busy) throw StateError('An account operation is already active');
    busy = true;
    operation = label;
    error = null;
    _notify();
    try {
      return await work();
    } catch (failure) {
      error = formatError(failure);
      rethrow;
    } finally {
      busy = false;
      operation = null;
      _notify();
    }
  }

  Future<Map<String, dynamic>> _callApi(
    String path,
    Map<String, Object?> body, {
    bool commentProxy = false,
  }) async {
    final raw = await _apiCall(path, body, commentProxy: commentProxy);
    return unwrapLightNovelResponse(raw);
  }

  Future<Map<String, dynamic>> _sendAuthenticated(
    String path,
    Map<String, Object?> body, {
    bool commentProxy = false,
  }) async {
    final activeSession = _session;
    if (!authenticated || activeSession == null) {
      throw const OnlineAuthenticationRequired();
    }
    final identity = _identity;
    try {
      final data = await _callApi(path, <String, Object?>{
        ...body,
        'security_key': activeSession.securityKey,
      }, commentProxy: commentProxy);
      if (_disposed || identity != _identity) {
        throw StateError('Account changed');
      }
      return data;
    } catch (failure) {
      if (_disposed || identity != _identity) rethrow;
      if (_isAuthExpiredError(failure)) {
        await _clearSessionState(notify: !busy);
        throw const OnlineAuthenticationRequired();
      }
      rethrow;
    }
  }

  Future<LightNovelProfile> _fetchProfile({
    String fallbackUsername = '',
  }) async {
    final data = await _sendAuthenticated('/api/bff/my-profile-v1', const {});
    return LightNovelProfile.fromJson(
      data,
      fallbackUid: _session?.uid ?? profile?.uid ?? 0,
      fallbackUsername: fallbackUsername.isNotEmpty
          ? fallbackUsername
          : (profile?.username ?? ''),
    );
  }

  Future<void> initialize() => _initialization ??= _run('正在读取账号', () async {
    final identity = _identity;
    final raw = await _readSession();
    if (_disposed || identity != _identity) return;
    if (raw == null || raw.trim().isEmpty) {
      authenticated = false;
      _session = null;
      return;
    }
    final stored = LightNovelSession.tryDecode(raw);
    if (stored == null) {
      await _writeSession(null);
      authenticated = false;
      _session = null;
      return;
    }
    // Keep the session loaded even if the network check is offline.
    _session = stored;
    authenticated = true;

    final sessionData = await _sendAuthenticated(
      '/api/bff/auth-session-v1',
      const {},
    );
    if (_disposed || identity != _identity) return;

    final loggedIn = sessionData.containsKey('logged_in')
        ? lnAsBool(sessionData['logged_in'])
        : (sessionData.containsKey('loggedIn')
              ? lnAsBool(sessionData['loggedIn'])
              : true);
    if (!loggedIn) {
      await _clearSessionState(notify: false);
      return;
    }

    final authMap = lnAsMap(sessionData['auth']);
    final refreshedKey = lnAsString(authMap?['security_key']).trim();
    final refreshedUid = lnAsInt(authMap?['uid'], stored.uid);
    if (refreshedKey.isNotEmpty &&
        refreshedUid > 0 &&
        (refreshedKey != stored.securityKey || refreshedUid != stored.uid)) {
      final updated = LightNovelSession(
        securityKey: refreshedKey,
        uid: refreshedUid,
      );
      _session = updated;
      try {
        await _writeSession(updated.encode());
      } catch (_) {
        // A failed rotation write must not wipe an active session.
      }
    }

    final preliminary = LightNovelProfile.tryFromJson(
      sessionData,
      fallbackUid: _session!.uid,
    );
    if (preliminary != null) {
      profile = preliminary;
    }

    try {
      profile = await _fetchProfile(
        fallbackUsername: preliminary?.username ?? '',
      );
    } catch (failure) {
      if (_isAuthExpiredError(failure) || profile == null) rethrow;
    }
    if (!_disposed && identity == _identity && authenticated) {
      unawaited(_loadAvatar(profile?.avatarUrl));
    }
  }).catchError((Object _) {});

  Future<void> login(String username, String password) =>
      _run('正在登录', () async {
        final name = username.trim();
        if (name.isEmpty ||
            name.length > 254 ||
            password.isEmpty ||
            password.length > 256 ||
            RegExp(r'[\x00-\x1f]').hasMatch(name)) {
          throw const FormatException('请填写用户名 / 邮箱及密码');
        }

        final data = await _callApi('/api/bff/auth-password-login-v1', {
          'username': name,
          'password': password,
        });
        if (_disposed) return;

        final authMap = lnAsMap(data['auth']);
        final userMap = lnAsMap(data['user']);
        final key = lnAsString(
          authMap?['security_key'] ?? data['security_key'],
        ).trim();
        final uid = lnAsInt(authMap?['uid'] ?? userMap?['uid'] ?? data['uid']);
        if (key.isEmpty || uid <= 0) {
          throw const FormatException('登录响应缺少会话凭据');
        }
        final nextSession = LightNovelSession(securityKey: key, uid: uid);
        await _writeSession(nextSession.encode());
        if (_disposed) return;

        _identity++;
        final loginIdentity = _identity;
        _session = nextSession;
        authenticated = true;
        _initialization = Future.value();
        profile = LightNovelProfile.tryFromJson(
          data,
          fallbackUid: uid,
          fallbackUsername: name,
        );
        avatar = null;
        cloudBooks = null;
        syncedAt = null;

        try {
          profile = await _fetchProfile(fallbackUsername: name);
        } catch (failure) {
          if (_isAuthExpiredError(failure) || profile == null) rethrow;
        }
        if (!_disposed && loginIdentity == _identity && authenticated) {
          unawaited(_loadAvatar(profile?.avatarUrl));
        }
      });

  Future<void> refreshProfile() => _run('正在更新账号', () async {
    final identity = _identity;
    final nextProfile = await _fetchProfile();
    if (_disposed || identity != _identity) return;
    profile = nextProfile;
    unawaited(_loadAvatar(nextProfile.avatarUrl));
  });

  /// Client-side logout: clears persisted session & resets in-memory account
  /// state. Safe to execute offline; never modifies local shelf or progress.
  Future<void> logout() => _run('正在退出账号', () async {
    _initialization = Future.value();
    await _clearSessionState(notify: false);
  });

  Future<List<LightNovelCloudBook>> _fetchAllCloudBooks() async {
    final seen = <int>{};
    final books = <LightNovelCloudBook>[];

    for (var page = 1; page <= _maxCloudPages; page++) {
      final data = await _sendAuthenticated('/api/bff/bookshelf-v1', {
        'page': page,
        'page_size': _cloudPageSize,
        'pageSize': _cloudPageSize,
      });

      final rawItems = lnAsList(data['list']).isNotEmpty
          ? lnAsList(data['list'])
          : lnAsList(data['items']);
      if (rawItems.isEmpty) break;

      var addedOnPage = 0;
      for (final rawItem in rawItems) {
        final itemMap = lnAsMap(rawItem);
        if (itemMap == null) continue;
        final book = LightNovelCloudBook.tryFromJson(itemMap);
        if (book == null || !seen.add(book.bookId)) continue;
        books.add(book);
        addedOnPage++;
      }

      final pageInfo = lnAsMap(data['page_info']);
      final pagination = lnAsMap(data['pagination']);
      final effectiveSize = lnAsInt(
        pageInfo?['size'] ?? pagination?['page_size'],
        _cloudPageSize,
      );
      final total = lnAsInt(
        pagination?['total'] ?? data['total'] ?? pageInfo?['count'],
      );
      final pageCount = lnAsInt(pagination?['page_count']);

      if (addedOnPage == 0) break;
      if (total > 0 && effectiveSize > 0 && page * effectiveSize >= total) {
        break;
      }
      if (pageInfo != null && pageInfo.containsKey('has_next')) {
        if (lnAsInt(pageInfo['has_next']) == 0) break;
      } else if (pageCount > 0) {
        if (page >= pageCount) break;
      } else if (rawItems.length < _cloudPageSize) {
        break;
      }
    }

    return List.unmodifiable(books);
  }

  Future<List<LightNovelCloudBook>> refreshCloud() => _run('正在读取云书架', () async {
    final books = await _fetchAllCloudBooks();
    cloudBooks = books;
    syncedAt = DateTime.now().millisecondsSinceEpoch;
    return books;
  });

  Future<void> _toggleCloudBook(int bookId, String action) async {
    await _sendAuthenticated('/api/new-content-read/toggle-book-shelf', {
      'book_id': bookId,
      'action': action,
      'source': 'pc_web',
    });
  }

  Future<void> addCloud(int bookId) => _run('正在收藏到云端', () async {
    if (bookId <= 0 || isLocalBook(bookId)) {
      throw ArgumentError.value(bookId, 'bookId');
    }
    await _toggleCloudBook(bookId, 'add');
    if (cloudBooks != null &&
        !cloudBooks!.any((book) => book.bookId == bookId)) {
      cloudBooks = List.unmodifiable([
        ...cloudBooks!,
        LightNovelCloudBook(bookId: bookId),
      ]);
    }
  });

  Future<void> removeCloud(int bookId) => _run('正在移出云书架', () async {
    if (bookId <= 0 || isLocalBook(bookId)) {
      throw ArgumentError.value(bookId, 'bookId');
    }
    await _toggleCloudBook(bookId, 'remove');
    cloudBooks = cloudBooks
        ?.where((book) => book.bookId != bookId)
        .toList(growable: false);
  });

  Future<LightNovelShelfPlan> exchangeShelf({
    required Set<int> local,
    Set<int>? lastLocal,
    Set<int>? lastCloud,
  }) => _run('正在同步书架', () async {
    final onlineLocal = local.where((id) => id > 0 && !isLocalBook(id)).toSet();
    final onlineLastLocal = lastLocal
        ?.where((id) => id > 0 && !isLocalBook(id))
        .toSet();
    final onlineLastCloud = lastCloud
        ?.where((id) => id > 0 && !isLocalBook(id))
        .toSet();

    final remote = await _fetchAllCloudBooks();
    final remoteIds = remote.map((book) => book.bookId).toSet();
    final plan = LightNovelShelfPlan(
      local: onlineLocal,
      remote: remoteIds,
      lastLocal: onlineLastLocal,
      lastCloud: onlineLastCloud,
    );

    for (final id in plan.target.difference(remoteIds)) {
      await _toggleCloudBook(id, 'add');
    }
    for (final id in remoteIds.difference(plan.target)) {
      await _toggleCloudBook(id, 'remove');
    }

    cloudBooks = List.unmodifiable([
      ...remote.where((book) => plan.target.contains(book.bookId)),
      for (final id in plan.target.difference(remoteIds))
        LightNovelCloudBook(bookId: id),
    ]);
    syncedAt = DateTime.now().millisecondsSinceEpoch;
    return plan;
  });

  Future<LightNovelCloudUploadResult> uploadMissing(Set<int> localIds) => _run(
    '正在合并到云端',
    () async {
      final remote = await _fetchAllCloudBooks();
      final remoteIds = remote.map((book) => book.bookId).toSet();
      final missing = localIds
          .where((id) => id > 0 && !isLocalBook(id) && !remoteIds.contains(id))
          .toList();
      final uploaded = <int>[];
      Object? failure;
      for (final id in missing) {
        try {
          await _toggleCloudBook(id, 'add');
          uploaded.add(id);
        } catch (err) {
          failure = err;
          break;
        }
      }
      if (authenticated) {
        cloudBooks = List.unmodifiable([
          ...remote,
          for (final id in uploaded) LightNovelCloudBook(bookId: id),
        ]);
      }
      if (failure != null) {
        error = formatError(failure);
      }
      syncedAt = DateTime.now().millisecondsSinceEpoch;
      return LightNovelCloudUploadResult(
        List.unmodifiable(uploaded),
        List.unmodifiable(missing.skip(uploaded.length)),
        failure,
      );
    },
  );

  Future<int> mergeCloudToLocal(LibraryState state) =>
      _run('正在合并本机收藏', () async {
        final entries = await _fetchAllCloudBooks();
        final before = state.shelf;
        await state.addShelfIds(entries.map((book) => book.bookId));
        cloudBooks = entries;
        syncedAt = DateTime.now().millisecondsSinceEpoch;
        return entries.where((book) => !before.contains(book.bookId)).length;
      });

  /// Unlocks a coin-gated chapter and refreshes coin balance via `my-profile-v1`.
  /// Backend `code: 1000` messages (e.g. insufficient coins) surface cleanly.
  Future<void> unlockChapter(int chapterId) => _run('正在解锁章节', () async {
    if (chapterId <= 0) throw ArgumentError.value(chapterId, 'chapterId');
    await _sendAuthenticated('/api/new-content-read/unlock-chapter', {
      'chapter_id': chapterId,
    });
    try {
      profile = await _fetchProfile();
    } catch (failure) {
      if (_isAuthExpiredError(failure)) rethrow;
      // Unlock already succeeded; a transient balance refresh failure must not
      // report the unlock itself as failed.
    }
  });

  /// Publishes a root book comment or star rating review with full UTF-8 support.
  Future<LightNovelComment?> postComment({
    required int bookId,
    required String content,
    int volumeId = 0,
    int chapterId = 0,
    int ratingStars = 0,
    String view = '',
    List<int> mentionUids = const [],
    String? mediaJson,
    int readDurationSeconds = 0,
  }) async {
    if (bookId <= 0 || isLocalBook(bookId)) {
      throw ArgumentError.value(bookId, 'bookId');
    }
    if (content.trim().isEmpty) {
      throw const FormatException('请填写评论内容');
    }
    if (ratingStars < 0 || ratingStars > 5) {
      throw ArgumentError.value(ratingStars, 'ratingStars');
    }
    final effectiveView = view.isNotEmpty
        ? view
        : (ratingStars > 0 ? 'rating' : '');
    final data = await _sendAuthenticated('/api/discuss/publish-book-comment', {
      'book_id': bookId,
      'volume_id': volumeId,
      'chapter_id': chapterId,
      'view': effectiveView,
      'root_comment_id': 0,
      'reply_comment_id': 0,
      'content': content,
      if (mentionUids.isNotEmpty) 'mention_uids': mentionUids,
      if (mediaJson != null && mediaJson.isNotEmpty) 'media_json': mediaJson,
      'rating_stars': ratingStars,
      'read_duration_seconds': readDurationSeconds,
    });
    final commentMap = lnAsMap(data['comment']) ?? data;
    return LightNovelComment.tryFromJson(commentMap);
  }

  /// Publishes a reply to an existing comment thread with full UTF-8 support.
  Future<LightNovelComment?> replyComment({
    required int bookId,
    required int rootCommentId,
    int replyCommentId = 0,
    required String content,
    int volumeId = 0,
    int chapterId = 0,
    String view = '',
    List<int> mentionUids = const [],
    String? mediaJson,
  }) async {
    if (bookId <= 0 || isLocalBook(bookId)) {
      throw ArgumentError.value(bookId, 'bookId');
    }
    if (rootCommentId <= 0) {
      throw ArgumentError.value(rootCommentId, 'rootCommentId');
    }
    if (content.trim().isEmpty) {
      throw const FormatException('请填写回复内容');
    }
    final targetReplyId = replyCommentId == rootCommentId ? 0 : replyCommentId;
    final data = await _sendAuthenticated('/api/discuss/publish-book-comment', {
      'book_id': bookId,
      'volume_id': volumeId,
      'chapter_id': chapterId,
      'view': view,
      'root_comment_id': rootCommentId,
      'reply_comment_id': targetReplyId,
      'content': content,
      if (mentionUids.isNotEmpty) 'mention_uids': mentionUids,
      if (mediaJson != null && mediaJson.isNotEmpty) 'media_json': mediaJson,
      'rating_stars': 0,
      'read_duration_seconds': 0,
    });
    final commentMap = lnAsMap(data['comment']) ?? data;
    return LightNovelComment.tryFromJson(commentMap);
  }

  Future<LightNovelCommentLikeResult> likeComment({
    required int bookId,
    required int commentId,
    required bool like,
    int rootCommentId = 0,
    int volumeId = 0,
    int chapterId = 0,
    String view = '',
  }) async {
    if (bookId <= 0 || isLocalBook(bookId)) {
      throw ArgumentError.value(bookId, 'bookId');
    }
    if (commentId <= 0) {
      throw ArgumentError.value(commentId, 'commentId');
    }
    final data = await _sendAuthenticated('/api/discuss/like-book-comment', {
      'book_id': bookId,
      'volume_id': volumeId,
      'chapter_id': chapterId,
      'view': view,
      'comment_id': commentId,
      'root_comment_id': rootCommentId,
      'act': like ? 'like' : 'unlike',
    });
    final liked = data.containsKey('liked')
        ? lnAsBool(data['liked'])
        : (data.containsKey('is_liked')
              ? lnAsBool(data['is_liked'])
              : (data.containsKey('isLiked')
                    ? lnAsBool(data['isLiked'])
                    : like));
    final likeCount = lnAsInt(data['like_count'] ?? data['likeCount']);
    return LightNovelCommentLikeResult(liked: liked, likeCount: likeCount);
  }

  Future<void> deleteComment({
    required int bookId,
    required int commentId,
    int rootCommentId = 0,
    int volumeId = 0,
    int chapterId = 0,
    String view = '',
  }) async {
    if (bookId <= 0 || isLocalBook(bookId)) {
      throw ArgumentError.value(bookId, 'bookId');
    }
    if (commentId <= 0) {
      throw ArgumentError.value(commentId, 'commentId');
    }
    await _sendAuthenticated('/api/new-content-read/delete-book-comment', {
      'book_id': bookId,
      'volume_id': volumeId,
      'chapter_id': chapterId,
      'view': view,
      'comment_id': commentId,
      'root_comment_id': rootCommentId,
    });
  }

  /// Best-effort remote reading progress sync. Never uploads local books and
  /// never throws on transient network failure; still clears expired sessions.
  Future<bool> saveReadingHistory({
    required int bookId,
    int? volumeId,
    int? chapterId,
    int? progressPercent,
    int? lastPosition,
    bool finished = false,
  }) async {
    if (!authenticated ||
        _session == null ||
        bookId <= 0 ||
        isLocalBook(bookId)) {
      return false;
    }
    try {
      await _sendAuthenticated('/api/new-content-read/save-book-history', {
        'book_id': bookId,
        if (volumeId != null && volumeId > 0) 'volume_id': volumeId,
        if (chapterId != null && chapterId > 0) 'chapter_id': chapterId,
        if (progressPercent != null)
          'progress_percent': progressPercent.clamp(0, 100),
        if (lastPosition != null && lastPosition >= 0)
          'last_position': lastPosition,
        'read_finished': finished ? 1 : 0,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Best-effort fetch of single-book cloud shelf & resume progress state.
  /// Clears expired sessions on error code `8`.
  Future<LightNovelBookLibraryState?> getBookLibraryState(int bookId) async {
    if (!authenticated ||
        _session == null ||
        bookId <= 0 ||
        isLocalBook(bookId)) {
      return null;
    }
    try {
      final data = await _sendAuthenticated(
        '/api/new-content-read/get-book-library-state',
        {'book_id': bookId},
      );
      return LightNovelBookLibraryState.fromJson(bookId, data);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _identity++;
    super.dispose();
  }
}
