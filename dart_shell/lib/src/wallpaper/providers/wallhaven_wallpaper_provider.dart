import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../wallpaper.dart';
import '../wallpaper_provider.dart';

class WallhavenWallpaperProvider implements WallpaperProvider {
  WallhavenWallpaperProvider({
    required Directory downloadDirectory,
    String apiKey = '',
    HttpClient? httpClient,
  })  : _downloadDirectory = downloadDirectory,
        _apiKey = apiKey.trim(),
        _httpClient = httpClient ?? HttpClient();

  static final Uri _searchEndpoint =
      Uri.parse('https://wallhaven.cc/api/v1/search');
  static const Duration _requestTimeout = Duration(seconds: 30);
  static const Duration _downloadTimeout = Duration(seconds: 60);
  static const int _maximumSearchBytes = 2 * 1024 * 1024;
  static const int _maximumWallpaperBytes = 64 * 1024 * 1024;
  static const List<String> _queryBlacklist = <String>[
    'cosplay',
    'cosplayer',
    'cosplayers',
  ];

  final Directory _downloadDirectory;
  final String _apiKey;
  final HttpClient _httpClient;

  @override
  String get id => 'wallhaven';

  @override
  String get displayName => 'Wallhaven';

  @override
  Future<WallpaperPage> search(WallpaperQuery query) async {
    final text = query.text.trim();
    final blacklist = _queryBlacklist.map((term) => '-$term').join(' ');
    final parameters = <String, String>{
      'q': '$text $blacklist'.trim(),
      'page': '${math.max(1, query.page)}',
      'categories': '111',
      'purity': '100',
      'sorting': text.isEmpty ? 'toplist' : 'relevance',
      if (text.isEmpty) 'topRange': '1M',
      if (query.targetPixelSize.width > 0.0 &&
          query.targetPixelSize.height > 0.0)
        'atleast':
            '${query.targetPixelSize.width.round()}x${query.targetPixelSize.height.round()}',
      if (_apiKey.isNotEmpty) 'apikey': _apiKey,
    };
    final uri = _searchEndpoint.replace(queryParameters: parameters);
    final request = await _httpClient.getUrl(uri).timeout(_requestTimeout);
    request.headers
      ..set(HttpHeaders.userAgentHeader, 'denial-wallpaper-provider/1.0')
      ..set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'Wallhaven returned HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    if (response.contentLength > _maximumSearchBytes) {
      await response.drain<void>();
      throw const FormatException('Wallhaven response is too large');
    }

    final body =
        await response.transform(utf8.decoder).join().timeout(_requestTimeout);
    if (body.length > _maximumSearchBytes) {
      throw const FormatException('Wallhaven response is too large');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid Wallhaven response');
    }
    final items = parseSearchResponse(
      decoded,
      providerId: id,
      targetAspectRatio: query.targetAspectRatio,
    ).take(query.limit).toList(growable: false);
    final meta = decoded['meta'];
    final lastPage = meta is Map<String, dynamic> ? meta['last_page'] : null;
    return WallpaperPage(
      items: items,
      page: query.page,
      hasMore: lastPage is num && query.page < lastPage.toInt(),
    );
  }

  static List<WallpaperCandidate> parseSearchResponse(
    Map<String, dynamic> response, {
    required String providerId,
    required double targetAspectRatio,
  }) {
    final data = response['data'];
    if (data is! List) {
      return const <WallpaperCandidate>[];
    }
    final candidates = <WallpaperCandidate>[];
    for (final raw in data) {
      if (raw is! Map) {
        continue;
      }
      final item = raw.cast<Object?, Object?>();
      final id = item['id'];
      final path = _validWallhavenUri(item['path']);
      if (id is! String || id.isEmpty || path == null) {
        continue;
      }
      final width = _positiveInt(item['dimension_x']);
      final height = _positiveInt(item['dimension_y']);
      candidates.add(
        WallpaperCandidate(
          id: id,
          providerId: providerId,
          label: width > 0 && height > 0 ? '$width × $height' : id,
          previewUri: path,
          downloadUri: path,
          sourceUri: _validWallhavenUri(item['url']) ??
              _validWallhavenUri(item['short_url']),
          width: width,
          height: height,
        ),
      );
    }
    final safeTarget = targetAspectRatio.isFinite && targetAspectRatio > 0.0
        ? targetAspectRatio
        : 1.0;
    candidates.sort((a, b) {
      final aDistance = (math.log(a.aspectRatio / safeTarget)).abs();
      final bDistance = (math.log(b.aspectRatio / safeTarget)).abs();
      return aDistance.compareTo(bDistance);
    });
    return candidates;
  }

  @override
  Future<WallpaperResource> materialize(
    WallpaperCandidate candidate, {
    WallpaperDownloadProgress? onProgress,
  }) async {
    final existing = candidate.resource;
    if (existing != null) {
      onProgress?.call(1.0);
      return existing;
    }
    final uri = candidate.downloadUri;
    if (uri == null || !_isWallhavenUri(uri)) {
      throw StateError('Wallpaper has no valid Wallhaven download URL');
    }
    await _downloadDirectory.create(recursive: true);
    final extension = _safeExtension(uri.path);
    final safeId = candidate.id.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_');
    final output =
        File('${_downloadDirectory.path}/wallhaven-$safeId$extension');
    if (await output.exists()) {
      onProgress?.call(1.0);
      return WallpaperResource.file(output.path);
    }

    final temporary = File('${output.path}.part');
    final request = await _httpClient.getUrl(uri).timeout(_downloadTimeout);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'denial-wallpaper-provider/1.0',
    );
    final response = await request.close().timeout(_downloadTimeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'Wallpaper download returned HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    final expectedBytes = response.contentLength;
    if (expectedBytes > _maximumWallpaperBytes) {
      await response.drain<void>();
      throw const FormatException('Wallpaper is larger than 64 MiB');
    }

    IOSink? sink;
    var receivedBytes = 0;
    try {
      sink = temporary.openWrite();
      await for (final chunk in response.timeout(_downloadTimeout)) {
        receivedBytes += chunk.length;
        if (receivedBytes > _maximumWallpaperBytes) {
          throw const FormatException('Wallpaper is larger than 64 MiB');
        }
        sink.add(chunk);
        if (expectedBytes > 0) {
          onProgress?.call(
            (receivedBytes / expectedBytes).clamp(0.0, 1.0).toDouble(),
          );
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      await temporary.rename(output.path);
      onProgress?.call(1.0);
      return WallpaperResource.file(output.path);
    } finally {
      await sink?.close();
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  @override
  void dispose() {
    _httpClient.close(force: true);
  }
}

Uri? _validWallhavenUri(Object? raw) {
  if (raw is! String) {
    return null;
  }
  final uri = Uri.tryParse(raw);
  return uri != null && _isWallhavenUri(uri) ? uri : null;
}

bool _isWallhavenUri(Uri uri) {
  final host = uri.host.toLowerCase();
  return uri.scheme == 'https' &&
      (host == 'wallhaven.cc' || host.endsWith('.wallhaven.cc'));
}

int _positiveInt(Object? raw) {
  final value = raw is num ? raw.toInt() : int.tryParse('$raw');
  return value != null && value > 0 ? value : 0;
}

String _safeExtension(String path) {
  final dot = path.lastIndexOf('.');
  final extension = dot < 0 ? '' : path.substring(dot).toLowerCase();
  return const <String>{'.jpg', '.jpeg', '.png', '.webp'}.contains(extension)
      ? extension
      : '.jpg';
}
