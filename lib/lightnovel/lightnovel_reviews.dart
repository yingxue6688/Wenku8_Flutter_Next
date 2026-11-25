import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../online_component.dart';

/// Callback matching `LightNovelClient.post` so social/account services plug
/// directly into the pure-Dart transport layer without tight coupling.
typedef LightNovelApiCall =
    Future<Map<String, dynamic>> Function(
      String path,
      Map<String, Object?> body, {
      bool commentProxy,
    });

typedef LightNovelErrorCode = int? Function(Object error);
typedef LightNovelErrorMessage = String? Function(Object error);

typedef LightNovelCommentPageReader =
    Future<LightNovelCommentPage> Function({
      required int bookId,
      required int volumeId,
      required int chapterId,
      required String view,
      required int commentId,
      required int page,
      required int pageSize,
      required String commentSort,
      required String ratingFilter,
    });

/// Defensive JSON helpers for LightNovel.fun responses.
/// PHP backends occasionally emit `[]` instead of `{}` or `null` for empty objects.
Map<String, dynamic>? lnAsMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

List<dynamic> lnAsList(Object? value) => value is List ? value : const [];

int lnAsInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  if (value is bool) return value ? 1 : 0;
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return fallback;
    final parsed = int.tryParse(trimmed);
    if (parsed != null) return parsed;
    final parsedDouble = double.tryParse(trimmed);
    if (parsedDouble != null && parsedDouble.isFinite) {
      return parsedDouble.toInt();
    }
  }
  return fallback;
}

String lnAsString(Object? value, [String fallback = '']) {
  if (value is String) return value;
  if (value is num && value.isFinite) return value.toString();
  return fallback;
}

bool lnAsBool(Object? value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final lower = value.trim().toLowerCase();
    if (lower == '1' || lower == 'true' || lower == 'yes') return true;
    if (lower == '0' || lower == 'false' || lower == 'no' || lower.isEmpty) {
      return false;
    }
  }
  return fallback;
}

String? _extractBackendMessage(Map<String, dynamic> envelope) {
  final top = envelope['message'];
  if (top is String && top.trim().isNotEmpty) return top.trim();
  final data = lnAsMap(envelope['data']);
  if (data != null) {
    final nested = data['message'];
    if (nested is String && nested.trim().isNotEmpty) return nested.trim();
    for (final value in data.values) {
      if (value is List) {
        for (final item in value) {
          if (item is String && item.trim().isNotEmpty) return item.trim();
        }
      } else if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
  }
  return null;
}

/// Unwraps either a full `{code, data, message}` LightNovel API envelope or an
/// already-unwrapped `data` map returned by `LightNovelClient.post`.
Map<String, dynamic> unwrapLightNovelResponse(Map<String, dynamic> response) {
  final rawCode = response['code'];
  final looksLikeEnvelope =
      rawCode is int &&
      (response.containsKey('data') ||
          response.containsKey('message') ||
          response.containsKey('t') ||
          rawCode != 0);
  if (!looksLikeEnvelope) return response;

  if (rawCode != 0) {
    throw LightNovelAuthError(rawCode, _extractBackendMessage(response));
  }
  final data = response['data'];
  if (data is Map) return Map<String, dynamic>.from(data);
  if (data is List) return <String, dynamic>{'list': data};
  return const <String, dynamic>{};
}

class LightNovelAuthError implements Exception {
  const LightNovelAuthError(this.code, [String? message]) : _message = message;

  final int code;
  final String? _message;

  String get message {
    final custom = _message?.trim();
    if ((code == 1000 || code == 3) && custom != null && custom.isNotEmpty) {
      return custom;
    }
    return switch (code) {
      -1 || 1 => '服务器繁忙，请稍后再试',
      2 => custom != null && custom.isNotEmpty ? custom : '用户名或密码不正确',
      3 => '提交的参数有误，请检查后重试',
      4 => '当前操作暂不支持',
      5 => '操作过于频繁，请稍后再试',
      6 => '暂无权限执行此操作',
      7 => '验证码无效或已过期',
      8 => '登录已过期，请重新登录；本地阅读记录仍保留',
      1000 => '操作未完成，请稍后重试',
      1001 => custom != null && custom.isNotEmpty ? custom : '账号不存在或密码不正确',
      1012 => '密码强度不足（需 8–16 位，至少包含大小写字母、数字、特殊字符中的 3 种）',
      5001 => '未找到对应作品',
      _ => custom != null && custom.isNotEmpty ? custom : '服务器未完成本次操作，请稍后再试',
    };
  }

  @override
  String toString() => message;
}

String describeLightNovelError(
  Object error, {
  LightNovelErrorCode? errorCode,
  LightNovelErrorMessage? errorMessage,
}) {
  if (error is LightNovelAuthError) return error.message;
  if (error is OnlineComponentUnavailable ||
      error is OnlineAuthenticationRequired) {
    return error.toString();
  }
  if (error is FormatException) return error.message.toString();
  final mappedCode = errorCode?.call(error);
  if (mappedCode != null) {
    final mappedMessage = errorMessage?.call(error)?.trim();
    return LightNovelAuthError(mappedCode, mappedMessage).message;
  }
  return '网络或本地存储暂时异常，请重试';
}

String _unescapeUrl(String url) =>
    url.replaceAll('&amp;', '&').replaceAll('&#38;', '&').trim();

List<String> _parseImageUrls(Map<String, dynamic> json) {
  final urls = <String>[];
  final seen = <String>{};

  void addUrl(Object? raw) {
    final text = _unescapeUrl(lnAsString(raw));
    if (text.isEmpty) return;
    if ((text.startsWith('https://') || text.startsWith('http://')) &&
        seen.add(text)) {
      urls.add(text);
    }
  }

  void collectFromList(Object? value) {
    for (final entry in lnAsList(value)) {
      if (entry is String) {
        addUrl(entry);
      } else if (entry is Map) {
        final map = Map<String, dynamic>.from(entry);
        final type = lnAsString(map['type'] ?? map['media_type']).toLowerCase();
        if (type.isNotEmpty &&
            type != 'image' &&
            type != 'img' &&
            type != 'pic') {
          continue;
        }
        addUrl(
          map['url'] ??
              map['src'] ??
              map['image_url'] ??
              map['imageUrl'] ??
              map['source_url'],
        );
      }
    }
  }

  collectFromList(json['imageUrls'] ?? json['image_urls']);
  collectFromList(json['images']);

  final resources = json['resources'];
  if (resources is List) {
    collectFromList(resources);
  } else if (resources is Map) {
    final resMap = Map<String, dynamic>.from(resources);
    collectFromList(resMap['images'] ?? resMap['image_urls'] ?? resMap['list']);
    if (resMap['url'] != null) addUrl(resMap['url']);
  }

  final mediaJson = json['media_json'] ?? json['mediaJson'];
  if (mediaJson is String && mediaJson.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(mediaJson);
      if (decoded is List) {
        collectFromList(decoded);
      } else if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded);
        collectFromList(map['images'] ?? map['image_urls'] ?? map['list']);
        if (map['url'] != null) addUrl(map['url']);
      }
    } catch (_) {
      // Ignore malformed optional media JSON.
    }
  } else if (mediaJson is List) {
    collectFromList(mediaJson);
  }

  return List.unmodifiable(urls);
}

class LightNovelComment {
  const LightNovelComment({
    required this.id,
    this.rootCommentId = 0,
    this.type = 'topic',
    this.userId = 0,
    this.nickname = '',
    this.avatarUrl = '',
    this.levelName = '',
    required this.content,
    this.dateText = '',
    this.likeCount = 0,
    this.replyCount = 0,
    this.liked = false,
    this.isMine = false,
    this.ratingStars = 0,
    this.replyToUser = '',
    this.imageUrls = const [],
    this.replyPreview = const [],
  });

  final int id;
  final int rootCommentId;
  final String type;
  final int userId;
  final String nickname;
  final String avatarUrl;
  final String levelName;
  final String content;
  final String dateText;
  final int likeCount;
  final int replyCount;
  final bool liked;
  final bool isMine;
  final int ratingStars;
  final String replyToUser;
  final List<String> imageUrls;
  final List<LightNovelComment> replyPreview;

  String get identity => '$id';
  bool get isReply => rootCommentId > 0 || type == 'reply';

  static LightNovelComment? tryFromJson(Map<String, dynamic> json) {
    final id = lnAsInt(json['comment_id'] ?? json['commentId'] ?? json['id']);
    if (id <= 0) return null;

    final author = lnAsMap(json['author']);
    final authorLevel = lnAsMap(author?['level']);
    final stats = lnAsMap(json['stats']);
    final interaction = lnAsMap(
      json['interaction_state'] ?? json['interactionState'],
    );
    final ratingMap = lnAsMap(json['rating']);
    final replyToMap = lnAsMap(json['reply_to'] ?? json['replyTo']);

    final rawReplyToUser = json['reply_to_user'] ?? json['replyToUser'];
    final replyToUserMap = lnAsMap(rawReplyToUser);
    final replyToUser =
        (rawReplyToUser is String && rawReplyToUser.trim().isNotEmpty)
        ? rawReplyToUser.trim()
        : lnAsString(
            replyToUserMap?['nickname'] ??
                replyToUserMap?['nick_name'] ??
                replyToUserMap?['username'] ??
                replyToMap?['nickname'] ??
                replyToMap?['nick_name'] ??
                replyToMap?['username'],
          ).trim();

    final previews = <LightNovelComment>[];
    final rawPreview = json['reply_preview'] ?? json['replyPreview'];
    for (final entry in lnAsList(rawPreview)) {
      final entryMap = lnAsMap(entry);
      if (entryMap == null) continue;
      final parsed = LightNovelComment.tryFromJson(entryMap);
      if (parsed != null) previews.add(parsed);
    }

    final rootId = lnAsInt(json['root_comment_id'] ?? json['rootCommentId']);
    final type = lnAsString(
      json['comment_type'] ?? json['commentType'] ?? json['type'],
      rootId > 0 ? 'reply' : 'topic',
    ).trim();

    final userId = lnAsInt(
      author?['uid'] ??
          author?['user_id'] ??
          json['uid'] ??
          json['user_id'] ??
          json['userId'],
    );
    final nickname = lnAsString(
      author?['nickname'] ??
          author?['nick_name'] ??
          author?['username'] ??
          json['nickname'] ??
          json['nick_name'],
    ).trim();
    final avatarUrl = _unescapeUrl(
      lnAsString(
        author?['avatar_url'] ??
            author?['avatarUrl'] ??
            author?['avatar'] ??
            json['avatarUrl'] ??
            json['avatar_url'] ??
            json['avatar'],
      ),
    );
    final levelName = lnAsString(
      authorLevel?['name'] ??
          authorLevel?['title'] ??
          author?['level_name'] ??
          author?['levelName'] ??
          json['levelName'] ??
          json['level_name'],
    ).trim();

    final likeCount = lnAsInt(
      json['likeCount'] ??
          json['like_count'] ??
          stats?['like_count'] ??
          stats?['likeCount'],
    );
    final replyCount = lnAsInt(
      json['replyCount'] ??
          json['reply_count'] ??
          stats?['reply_count'] ??
          stats?['replyCount'],
      previews.length,
    );
    final liked = lnAsBool(
      json['liked'] ??
          json['is_liked'] ??
          json['isLiked'] ??
          interaction?['liked'] ??
          interaction?['is_liked'],
    );
    final isMine = lnAsBool(json['isMine'] ?? json['is_mine']);
    final ratingStars = lnAsInt(
      ratingMap?['rating_stars'] ??
          ratingMap?['ratingStars'] ??
          json['ratingStars'] ??
          json['rating_stars'] ??
          json['stars'],
    ).clamp(0, 5);

    final dateText = lnAsString(
      json['dateText'] ??
          json['date_text'] ??
          json['publishTime'] ??
          json['publish_time'] ??
          json['created_at'] ??
          json['create_time'],
    ).trim();

    return LightNovelComment(
      id: id,
      rootCommentId: rootId,
      type: type.isEmpty ? (rootId > 0 ? 'reply' : 'topic') : type,
      userId: userId,
      nickname: nickname,
      avatarUrl: avatarUrl,
      levelName: levelName,
      content: lnAsString(json['content'] ?? json['text']),
      dateText: dateText,
      likeCount: likeCount < 0 ? 0 : likeCount,
      replyCount: replyCount < 0 ? 0 : replyCount,
      liked: liked,
      isMine: isMine,
      ratingStars: ratingStars,
      replyToUser: replyToUser,
      imageUrls: _parseImageUrls(json),
      replyPreview: List.unmodifiable(previews),
    );
  }

  LightNovelComment copyWith({
    int? id,
    int? rootCommentId,
    String? type,
    int? userId,
    String? nickname,
    String? avatarUrl,
    String? levelName,
    String? content,
    String? dateText,
    int? likeCount,
    int? replyCount,
    bool? liked,
    bool? isMine,
    int? ratingStars,
    String? replyToUser,
    List<String>? imageUrls,
    List<LightNovelComment>? replyPreview,
  }) => LightNovelComment(
    id: id ?? this.id,
    rootCommentId: rootCommentId ?? this.rootCommentId,
    type: type ?? this.type,
    userId: userId ?? this.userId,
    nickname: nickname ?? this.nickname,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    levelName: levelName ?? this.levelName,
    content: content ?? this.content,
    dateText: dateText ?? this.dateText,
    likeCount: likeCount ?? this.likeCount,
    replyCount: replyCount ?? this.replyCount,
    liked: liked ?? this.liked,
    isMine: isMine ?? this.isMine,
    ratingStars: ratingStars ?? this.ratingStars,
    replyToUser: replyToUser ?? this.replyToUser,
    imageUrls: imageUrls ?? this.imageUrls,
    replyPreview: replyPreview ?? this.replyPreview,
  );
}

class LightNovelCommentLikeResult {
  const LightNovelCommentLikeResult({
    required this.liked,
    required this.likeCount,
  });

  final bool liked;
  final int likeCount;
}

class LightNovelCommentPage {
  const LightNovelCommentPage({
    required this.items,
    required this.page,
    required this.totalCount,
    required this.hasMore,
    this.rootComment,
  });

  final List<LightNovelComment> items;
  final int page;
  final int totalCount;
  final bool hasMore;
  final LightNovelComment? rootComment;

  factory LightNovelCommentPage.parse(
    Map<String, dynamic> raw, {
    int requestedPage = 1,
    int pageSize = 20,
  }) {
    final data = unwrapLightNovelResponse(raw);
    final rawItems = lnAsList(data['list']).isNotEmpty
        ? lnAsList(data['list'])
        : lnAsList(data['items']);
    final seen = <int>{};
    final items = <LightNovelComment>[];
    for (final entry in rawItems) {
      final map = lnAsMap(entry);
      if (map == null) continue;
      final comment = LightNovelComment.tryFromJson(map);
      if (comment != null && seen.add(comment.id)) {
        items.add(comment);
      }
    }

    final rootMap = lnAsMap(data['root_comment'] ?? data['rootComment']);
    final rootComment = rootMap == null
        ? null
        : LightNovelComment.tryFromJson(rootMap);

    final pageInfo = lnAsMap(data['page_info']);
    final pagination = lnAsMap(data['pagination']);

    final page = lnAsInt(
      pageInfo?['cur'] ?? pagination?['page'],
      requestedPage,
    );
    final effectiveSize = lnAsInt(
      pageInfo?['size'] ?? pagination?['page_size'],
      pageSize,
    );
    final rawTotal = lnAsInt(
      pagination?['total'] ?? data['total'] ?? pageInfo?['count'],
    );
    final totalCount = rawTotal > 0 ? rawTotal : (rootComment?.replyCount ?? 0);

    final hasNext = pageInfo != null && pageInfo.containsKey('has_next')
        ? lnAsInt(pageInfo['has_next'])
        : (pagination != null && pagination.containsKey('page_count')
              ? (page < lnAsInt(pagination['page_count']) ? 1 : 0)
              : 0);

    // Reply threads can report `has_next: 1` when `reply_count == pageSize`
    // and then return an empty page 2. Stop immediately on any stop signal.
    final reachedTotal =
        totalCount > 0 &&
        effectiveSize > 0 &&
        page * effectiveSize >= totalCount;
    final hasMore = items.isNotEmpty && !reachedTotal && hasNext != 0;

    return LightNovelCommentPage(
      items: List.unmodifiable(items),
      page: page,
      totalCount: totalCount > 0 ? totalCount : items.length,
      hasMore: hasMore,
      rootComment: rootComment,
    );
  }
}

class LightNovelEmojiItem {
  const LightNovelEmojiItem({
    required this.id,
    required this.code,
    required this.url,
    required this.isSticker,
    this.width = 0,
    this.height = 0,
  });

  final int id;
  final String code;
  final String url;
  final bool isSticker;
  final int width;
  final int height;
}

class LightNovelEmojiPack {
  const LightNovelEmojiPack({
    required this.id,
    required this.name,
    required this.type,
    required this.icon,
    required this.items,
  });

  final int id;
  final String name;
  final int type;
  final String icon;
  final List<LightNovelEmojiItem> items;
}

class LightNovelEmojiToken {
  const LightNovelEmojiToken({this.text = '', this.code = '', this.stickerUrl});

  final String text;
  final String code;
  final String? stickerUrl;

  bool get isSticker => stickerUrl != null && stickerUrl!.isNotEmpty;
}

/// Parses `/api/bff/comment-emoji-list-v1` into sticker image URL and unicode
/// emoji lookup tables, with optional shared caching and `{:code:}` token parsing.
class LightNovelEmojiCatalog {
  LightNovelEmojiCatalog._({
    required this.packs,
    required this.stickerUrls,
    required this.unicodeMap,
    required this.itemsByCode,
  });

  static final LightNovelEmojiCatalog empty = LightNovelEmojiCatalog._(
    packs: const [],
    stickerUrls: const {},
    unicodeMap: const {},
    itemsByCode: const {},
  );

  static LightNovelEmojiCatalog? _shared;
  static Future<LightNovelEmojiCatalog>? _inFlight;

  static LightNovelEmojiCatalog? get cached => _shared;

  static void clearSharedCache() {
    _shared = null;
    _inFlight = null;
  }

  static Future<LightNovelEmojiCatalog> loadShared(
    LightNovelApiCall apiCall, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _shared != null) return _shared!;
    if (!forceRefresh && _inFlight != null) return _inFlight!;

    final request = (() async {
      final response = await apiCall(
        '/api/bff/comment-emoji-list-v1',
        const {},
      );
      final catalog = LightNovelEmojiCatalog.fromJson(response);
      _shared = catalog;
      return catalog;
    })();
    _inFlight = request;
    try {
      return await request;
    } finally {
      if (identical(_inFlight, request)) {
        _inFlight = null;
      }
    }
  }

  final List<LightNovelEmojiPack> packs;
  final Map<String, String> stickerUrls;
  final Map<String, String> unicodeMap;
  final Map<String, LightNovelEmojiItem> itemsByCode;

  static final RegExp _tokenPattern = RegExp(r'\{:([^{}\r\n]+):\}');

  factory LightNovelEmojiCatalog.fromJson(Map<String, dynamic> raw) {
    final data = unwrapLightNovelResponse(raw);
    final rawPacks = lnAsList(data['list']).isNotEmpty
        ? lnAsList(data['list'])
        : lnAsList(data['packs']);

    final packs = <LightNovelEmojiPack>[];
    final stickerUrls = <String, String>{};
    final unicodeMap = <String, String>{};
    final itemsByCode = <String, LightNovelEmojiItem>{};

    for (final rawPack in rawPacks) {
      final packMap = lnAsMap(rawPack);
      if (packMap == null) continue;
      final packType = lnAsInt(packMap['type'], 1);
      final items = <LightNovelEmojiItem>[];
      for (final rawItem in lnAsList(packMap['items'])) {
        final itemMap = lnAsMap(rawItem);
        if (itemMap == null) continue;
        final code = lnAsString(itemMap['code']).trim();
        if (code.isEmpty) continue;
        final isSticker = packType != 1;
        final rawUrl = _unescapeUrl(lnAsString(itemMap['url']));
        final resolvedUrl = rawUrl.isNotEmpty
            ? rawUrl
            : (isSticker ? '' : code);
        if (isSticker && resolvedUrl.isEmpty) continue;

        final item = LightNovelEmojiItem(
          id: lnAsInt(itemMap['id']),
          code: code,
          url: resolvedUrl,
          isSticker: isSticker,
          width: lnAsInt(itemMap['width']),
          height: lnAsInt(itemMap['height']),
        );
        items.add(item);
        itemsByCode[code] = item;
        if (isSticker) {
          stickerUrls[code] = resolvedUrl;
        } else {
          unicodeMap[code] = resolvedUrl;
        }
      }

      packs.add(
        LightNovelEmojiPack(
          id: lnAsInt(packMap['id']),
          name: lnAsString(packMap['name']).trim(),
          type: packType,
          icon: _unescapeUrl(lnAsString(packMap['icon'])),
          items: List.unmodifiable(items),
        ),
      );
    }

    return LightNovelEmojiCatalog._(
      packs: List.unmodifiable(packs),
      stickerUrls: Map.unmodifiable(stickerUrls),
      unicodeMap: Map.unmodifiable(unicodeMap),
      itemsByCode: Map.unmodifiable(itemsByCode),
    );
  }

  String? imageUrlFor(String code) {
    final direct = stickerUrls[code];
    if (direct != null) return direct;
    final match = _tokenPattern.firstMatch(code);
    if (match != null) {
      return stickerUrls[match.group(1)!];
    }
    return stickerUrls['{:$code:}'];
  }

  String? unicodeFor(String code) {
    final direct = unicodeMap[code];
    if (direct != null) return direct;
    final match = _tokenPattern.firstMatch(code);
    if (match != null) {
      return unicodeMap[match.group(1)!];
    }
    return unicodeMap['{:$code:}'];
  }

  /// Splits comment text into plain text segments (with unicode `{:code:}`
  /// tokens resolved) and sticker segments carrying their image URL.
  List<LightNovelEmojiToken> parseSegments(String content) {
    if (content.isEmpty) return const [];
    final result = <LightNovelEmojiToken>[];
    final textBuffer = StringBuffer();
    var cursor = 0;

    for (final match in _tokenPattern.allMatches(content)) {
      if (match.start > cursor) {
        textBuffer.write(content.substring(cursor, match.start));
      }
      final fullToken = match.group(0)!;
      final innerCode = match.group(1)!;
      final stickerUrl = stickerUrls[fullToken] ?? stickerUrls[innerCode];
      if (stickerUrl != null) {
        if (textBuffer.isNotEmpty) {
          result.add(LightNovelEmojiToken(text: textBuffer.toString()));
          textBuffer.clear();
        }
        result.add(
          LightNovelEmojiToken(
            text: fullToken,
            code: fullToken,
            stickerUrl: stickerUrl,
          ),
        );
      } else {
        final unicode = unicodeMap[fullToken] ?? unicodeMap[innerCode];
        textBuffer.write(unicode ?? fullToken);
      }
      cursor = match.end;
    }

    if (cursor < content.length) {
      textBuffer.write(content.substring(cursor));
    }
    if (textBuffer.isNotEmpty) {
      result.add(LightNovelEmojiToken(text: textBuffer.toString()));
    }
    return List.unmodifiable(result);
  }

  /// Resolves `{:code:}` tokens into plain text, replacing type-1 tokens with
  /// their unicode characters and stickers via [stickerReplacement].
  String formatText(
    String content, {
    String Function(String code, String url)? stickerReplacement,
  }) {
    if (content.isEmpty) return '';
    return content.replaceAllMapped(_tokenPattern, (match) {
      final fullToken = match.group(0)!;
      final innerCode = match.group(1)!;
      final stickerUrl = stickerUrls[fullToken] ?? stickerUrls[innerCode];
      if (stickerUrl != null) {
        return stickerReplacement?.call(fullToken, stickerUrl) ??
            '[$innerCode]';
      }
      return unicodeMap[fullToken] ?? unicodeMap[innerCode] ?? fullToken;
    });
  }
}

class LightNovelReviewFeed extends ChangeNotifier {
  LightNovelReviewFeed({
    required this.bookId,
    this.volumeId = 0,
    this.chapterId = 0,
    this.view = '',
    this.commentId = 0,
    this.pageSize = 20,
    String commentSort = 'hot',
    String ratingFilter = 'all',
    LightNovelApiCall? apiCall,
    this.securityKeyProvider,
    LightNovelCommentPageReader? readPage,
    this.errorCode,
    this.errorMessage,
    this.onAuthExpired,
  }) : assert(apiCall != null || readPage != null),
       _commentSort = commentSort,
       _ratingFilter = ratingFilter,
       _apiCall = apiCall,
       _readPage = readPage;

  final int bookId;
  final int volumeId;
  final int chapterId;
  final String view;
  final int commentId;
  final int pageSize;
  final LightNovelApiCall? _apiCall;
  final String? Function()? securityKeyProvider;
  final LightNovelCommentPageReader? _readPage;
  final LightNovelErrorCode? errorCode;
  final LightNovelErrorMessage? errorMessage;
  final VoidCallback? onAuthExpired;

  final _seenIds = <int>{};
  String _commentSort;
  String _ratingFilter;
  String get commentSort => _commentSort;
  String get ratingFilter => _ratingFilter;

  List<LightNovelComment> items = const [];
  LightNovelComment? rootComment;
  int page = 0;
  int totalCount = 0;
  int revision = 0;
  int firstIndex = 0;
  bool loading = false;
  bool hasMore = true;
  String? error;
  bool requiresLogin = false;

  int _generation = 0;
  bool _disposed = false;
  bool _failedRefresh = false;

  bool get isReplies => commentId > 0;

  Future<void> setSort(String sort) async {
    if (_commentSort == sort) return;
    _commentSort = sort;
    await load(refresh: true);
  }

  Future<void> setRatingFilter(String filter) async {
    if (_ratingFilter == filter) return;
    _ratingFilter = filter;
    await load(refresh: true);
  }

  bool _isExpired(Object failure) =>
      failure is OnlineAuthenticationRequired ||
      (failure is LightNovelAuthError && failure.code == 8) ||
      errorCode?.call(failure) == 8;

  Future<void> load({bool refresh = false}) async {
    refresh = refresh || _failedRefresh;
    if (_disposed || (loading && !refresh) || (!refresh && !hasMore)) return;
    final generation = ++_generation;
    final next = refresh ? 1 : page + 1;
    loading = true;
    error = null;
    requiresLogin = false;
    notifyListeners();

    final sentKey = securityKeyProvider?.call()?.trim();
    try {
      final LightNovelCommentPage result;
      if (_readPage != null) {
        result = await _readPage(
          bookId: bookId,
          volumeId: volumeId,
          chapterId: chapterId,
          view: view,
          commentId: commentId,
          page: next,
          pageSize: pageSize,
          commentSort: _commentSort,
          ratingFilter: _ratingFilter,
        );
      } else {
        final raw = await _apiCall!('/api/new-content-read/get-book-comments', {
          'book_id': bookId,
          'volume_id': volumeId,
          'chapter_id': chapterId,
          'view': view,
          'comment_id': commentId,
          'page': next,
          'pageSize': pageSize,
          'comment_sort': _commentSort,
          'rating_filter': _ratingFilter,
          'include_user_interactions': 1,
          if (sentKey != null && sentKey.isNotEmpty) 'security_key': sentKey,
        }, commentProxy: true);
        result = LightNovelCommentPage.parse(
          raw,
          requestedPage: next,
          pageSize: pageSize,
        );
      }
      if (_disposed || generation != _generation) return;

      final old = refresh ? <LightNovelComment>[] : items;
      if (refresh) _seenIds.clear();
      final newItems = result.items
          .where((item) => _seenIds.add(item.id))
          .toList();
      firstIndex = old.length;
      items = List.unmodifiable([...old, ...newItems]);
      if (result.rootComment != null) {
        rootComment = result.rootComment;
      }
      page = next;
      totalCount = result.totalCount;
      _failedRefresh = false;
      revision++;
      hasMore = result.hasMore;
    } catch (failure) {
      if (_disposed || generation != _generation) return;
      final expired = _isExpired(failure);
      if (expired && sentKey != null && sentKey.isNotEmpty) {
        onAuthExpired?.call();
      }
      error = describeLightNovelError(
        failure,
        errorCode: errorCode,
        errorMessage: errorMessage,
      );
      requiresLogin = expired;
      _failedRefresh = refresh;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void _updateCommentById(
    int id,
    LightNovelComment Function(LightNovelComment current) transform,
  ) {
    var changed = false;

    if (rootComment?.id == id) {
      rootComment = transform(rootComment!);
      changed = true;
    }

    final updatedItems = <LightNovelComment>[];
    for (final item in items) {
      var nextItem = item;
      if (item.id == id) {
        nextItem = transform(item);
        changed = true;
      } else if (item.replyPreview.any((reply) => reply.id == id)) {
        nextItem = item.copyWith(
          replyPreview: List.unmodifiable([
            for (final reply in item.replyPreview)
              reply.id == id ? transform(reply) : reply,
          ]),
        );
        changed = true;
      }
      updatedItems.add(nextItem);
    }

    if (changed) {
      items = List.unmodifiable(updatedItems);
      revision++;
      notifyListeners();
    }
  }

  LightNovelComment? _findComment(int id) {
    if (rootComment?.id == id) return rootComment;
    for (final item in items) {
      if (item.id == id) return item;
      for (final reply in item.replyPreview) {
        if (reply.id == id) return reply;
      }
    }
    return null;
  }

  /// Optimistically toggles like state on [comment], notifies listeners
  /// immediately, and if [persist] is supplied, reconciles the authoritative
  /// count or rolls back on failure.
  Future<void> toggleLike(
    LightNovelComment comment, {
    Future<LightNovelCommentLikeResult> Function(bool nextLiked)? persist,
  }) async {
    if (_disposed) return;
    final current = _findComment(comment.id) ?? comment;
    final nextLiked = !current.liked;
    final nextCount = (current.likeCount + (nextLiked ? 1 : -1)).clamp(
      0,
      1 << 30,
    );

    _updateCommentById(
      current.id,
      (item) => item.copyWith(liked: nextLiked, likeCount: nextCount),
    );

    if (persist == null) return;
    try {
      final result = await persist(nextLiked);
      if (_disposed) return;
      _updateCommentById(
        current.id,
        (item) => item.copyWith(
          liked: result.liked,
          likeCount: result.likeCount < 0 ? 0 : result.likeCount,
        ),
      );
    } catch (_) {
      if (!_disposed) {
        _updateCommentById(
          current.id,
          (item) =>
              item.copyWith(liked: current.liked, likeCount: current.likeCount),
        );
      }
      rethrow;
    }
  }

  /// Inserts or replaces a newly created comment/reply locally without waiting
  /// for a full reload.
  void insertLocalComment(LightNovelComment comment, {bool prepend = true}) {
    if (_disposed) return;

    if (commentId == 0 && comment.rootCommentId > 0) {
      final parentExists = items.any(
        (item) => item.id == comment.rootCommentId,
      );
      if (parentExists) {
        _updateCommentById(comment.rootCommentId, (parent) {
          final hasReply = parent.replyPreview.any((r) => r.id == comment.id);
          final preview = hasReply
              ? parent.replyPreview
              : (parent.replyPreview.length < 3
                    ? [...parent.replyPreview, comment]
                    : parent.replyPreview);
          return parent.copyWith(
            replyCount: parent.replyCount + (hasReply ? 0 : 1),
            replyPreview: List.unmodifiable(preview),
          );
        });
      }
      return;
    }

    final existingIndex = items.indexWhere((item) => item.id == comment.id);
    if (existingIndex >= 0) {
      final updated = [...items];
      updated[existingIndex] = comment;
      items = List.unmodifiable(updated);
      revision++;
      notifyListeners();
      return;
    }

    _seenIds.add(comment.id);
    items = List.unmodifiable(
      prepend ? [comment, ...items] : [...items, comment],
    );
    totalCount++;
    if (commentId > 0 && rootComment != null) {
      rootComment = rootComment!.copyWith(
        replyCount: rootComment!.replyCount + 1,
      );
    }
    revision++;
    notifyListeners();
  }

  /// Removes a deleted comment/reply locally from the feed (and preview list).
  void removeLocalComment(int targetCommentId) {
    if (_disposed) return;
    var changed = false;

    final nextItems = <LightNovelComment>[];
    for (final item in items) {
      if (item.id == targetCommentId) {
        _seenIds.remove(targetCommentId);
        totalCount = (totalCount - 1).clamp(0, 1 << 30);
        if (commentId > 0 && rootComment != null) {
          rootComment = rootComment!.copyWith(
            replyCount: (rootComment!.replyCount - 1).clamp(0, 1 << 30),
          );
        }
        changed = true;
        continue;
      }
      if (item.replyPreview.any((r) => r.id == targetCommentId)) {
        nextItems.add(
          item.copyWith(
            replyCount: (item.replyCount - 1).clamp(0, 1 << 30),
            replyPreview: List.unmodifiable(
              item.replyPreview.where((r) => r.id != targetCommentId),
            ),
          ),
        );
        changed = true;
      } else {
        nextItems.add(item);
      }
    }

    if (changed) {
      items = List.unmodifiable(nextItems);
      revision++;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
