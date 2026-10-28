/*
 * LTvLauncher
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class RedditWallpaperException implements Exception {
  final String message;

  const RedditWallpaperException(this.message);

  @override
  String toString() => 'RedditWallpaperException: $message';
}

class RedditImageCandidate {
  final String id;
  final Uri url;
  final int width;
  final int height;

  const RedditImageCandidate({
    required this.id,
    required this.url,
    required this.width,
    required this.height,
  });
}

/// Picks a random landscape image from the monthly top list of Wallhaven
/// (public API) and downloads it to a local file. Reddit switched off its
/// unauthenticated .json access in 2026, so Wallhaven is used instead.
/// The class keeps its old name so the rest of the app does not change;
/// the "subreddits" setting now holds search terms such as "nature, space".
/// NSFW images need a free Wallhaven API key in [_apiKey]; without one only
/// SFW images are served.
class RedditWallpaperFetcher {
  static const String _userAgent = 'android:com.leanbitlab.ltvl.wallpaper:v1.0 (by /u/styxsaber)';

  /// Wallhaven API key (wallhaven.cc -> Settings -> Account). Only needed for NSFW.
  static const String _apiKey = '6LcMgQqJjkz4v3yPDiOvY8pd3wZQyRD4';
  static const int _maxListingBytes = 4 * 1024 * 1024;
  static const int _maxImageBytes = 25 * 1024 * 1024;
  static const int _maxDownloadAttempts = 5;
  static const int minWidth = 1280;
  static const double minAspectRatio = 1.3;
  static const Duration _timeout = Duration(seconds: 20);

  static final RegExp _subredditPattern = RegExp(r'^[A-Za-z0-9_]{2,21}$');
  static final RegExp _searchTermPattern = RegExp(r'^[A-Za-z0-9_:\-]{2,40}$');
  static final RegExp _imagePath = RegExp(r'\.(jpe?g|png|webp)$', caseSensitive: false);
  static final RegExp _subredditPrefix = RegExp(r'^/?r/', caseSensitive: false);

  final Random _random;

  RedditWallpaperFetcher({Random? random}) : _random = random ?? Random();

  /// Splits user input like "EarthPorn, r/wallpapers+Art" into valid subreddit names.
  static List<String> parseSubreddits(String input) {
    final result = <String>[];
    for (final raw in input.split(RegExp(r'[\s,+;]+'))) {
      final name = raw.trim().replaceFirst(_subredditPrefix, '');
      if (_subredditPattern.hasMatch(name) && !result.contains(name)) {
        result.add(name);
      }
    }
    return result;
  }

  /// Splits Wallhaven search terms like "rezero, re:zero space" into single terms.
  /// Unlike subreddit names they may also contain ":" and "-".
  static List<String> parseSearchTerms(String input) {
    final result = <String>[];
    for (final raw in input.split(RegExp(r'[\s,+;]+'))) {
      final name = raw.trim();
      if (_searchTermPattern.hasMatch(name) && !result.contains(name)) {
        result.add(name);
      }
    }
    return result;
  }

  /// Downloads a random suitable image into [target] and returns what was picked.
  /// Throws [RedditWallpaperException] if nothing usable could be fetched.
  Future<RedditImageCandidate> fetchRandomWallpaper({
    required String subreddits,
    required File target,
    bool allowNsfw = false,
    bool nsfwOnly = false,
    String? excludeId,
  }) async {
    final subs = parseSearchTerms(subreddits);
    if (subs.isEmpty) {
      throw const RedditWallpaperException('no valid search term');
    }

    final candidates = await listCandidates(subs, allowNsfw: allowNsfw, nsfwOnly: nsfwOnly);
    if (candidates.isEmpty) {
      throw const RedditWallpaperException('no suitable images found');
    }

    candidates.shuffle(_random);
    if (excludeId != null && candidates.length > 1) {
      // Avoid showing the same picture twice in a row.
      candidates.sort((a, b) => (a.id == excludeId ? 1 : 0).compareTo(b.id == excludeId ? 1 : 0));
    }

    Object? lastError;
    for (final candidate in candidates.take(_maxDownloadAttempts)) {
      try {
        await _download(candidate.url, target);
        return candidate;
      } on RedditWallpaperException catch (e) {
        lastError = e;
      } on IOException catch (e) {
        lastError = e;
      } on TimeoutException catch (e) {
        lastError = e;
      }
    }
    throw RedditWallpaperException('download failed: $lastError');
  }

  /// Lists top images of the last month for one randomly chosen search term.
  /// [allowNsfw] mixes SFW and NSFW, [nsfwOnly] returns NSFW only; both need [_apiKey].
  Future<List<RedditImageCandidate>> listCandidates(List<String> subreddits,
      {bool allowNsfw = false, bool nsfwOnly = false}) async {
    if ((allowNsfw || nsfwOnly) && _apiKey.isEmpty) {
      throw const RedditWallpaperException('NSFW needs a Wallhaven API key (see _apiKey in the fetcher)');
    }
    final term = subreddits[_random.nextInt(subreddits.length)];
    final purity = nsfwOnly ? '001' : (allowNsfw ? '101' : '100');

    // "110" = General + Anime. Several tries from strict to loose, so that
    // narrow terms (e.g. a single anime title) still find something.
    final tries = <Map<String, String>>[
      {'sorting': 'toplist', 'topRange': '1M', 'atleast': '1920x1080', 'ratios': 'landscape'},
      {'sorting': 'relevance', 'atleast': '1920x1080', 'ratios': 'landscape'},
      {'sorting': 'relevance', 'atleast': '1280x720'},
    ];

    List<dynamic> data = const [];
    for (final extra in tries) {
      final uri = Uri.https('wallhaven.cc', '/api/v1/search', {
        'q': term,
        'categories': '110',
        'purity': purity,
        ...extra,
      });
      final dynamic json = _decode(await _getString(uri));
      final dynamic found = json is Map ? json['data'] : null;
      if (found is! List) {
        throw const RedditWallpaperException('unexpected response from server');
      }
      if (found.isNotEmpty) {
        data = found;
        break;
      }
    }

    final candidates = <RedditImageCandidate>[];
    for (final item in data) {
      if (item is! Map) continue;
      final dynamic path = item['path'];
      if (path is! String) continue;
      final url = Uri.tryParse(path);
      if (url == null || url.scheme != 'https' || url.host.isEmpty || !_imagePath.hasMatch(url.path)) continue;

      final width = _toInt(item['dimension_x']);
      final height = _toInt(item['dimension_y']);
      if (width == null || height == null || height <= 0) continue;
      if (width < minWidth || width / height < minAspectRatio) continue;

      final dynamic id = item['id'];
      candidates.add(RedditImageCandidate(
        id: id is String ? id : url.toString(),
        url: url,
        width: width,
        height: height,
      ));
    }
    return candidates;
  }

  static int? _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// Parses JSON; on failure the error shows the start of what came back.
  static dynamic _decode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      final snippet = body.replaceAll(RegExp(r'\s+'), ' ').trim();
      throw RedditWallpaperException('not JSON "${snippet.length > 70 ? snippet.substring(0, 70) : snippet}"');
    }
  }

  HttpClient _newClient() {
    return HttpClient()
      ..connectionTimeout = _timeout
      ..userAgent = _userAgent;
  }

  Future<HttpClientResponse> _open(HttpClient client, Uri uri, String accept) async {
    final request = await client.getUrl(uri).timeout(_timeout);
    request.headers.set(HttpHeaders.acceptHeader, accept);
    if (_apiKey.isNotEmpty && uri.host == 'wallhaven.cc') {
      request.headers.set('X-API-Key', _apiKey);
    }
    final response = await request.close().timeout(_timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw RedditWallpaperException('HTTP ${response.statusCode}');
    }
    return response;
  }

  Future<String> _getString(Uri uri) async {
    final client = _newClient();
    try {
      final response = await _open(client, uri, 'application/json');
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(_timeout)) {
        builder.add(chunk);
        if (builder.length > _maxListingBytes) {
          throw const RedditWallpaperException('response too large');
        }
      }
      return utf8.decode(builder.takeBytes(), allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _download(Uri uri, File target) async {
    final tmp = File('${target.path}.tmp');
    final client = _newClient();
    IOSink? sink;
    try {
      final response = await _open(client, uri, 'image/*');
      final contentType = response.headers.contentType;
      if (contentType == null || contentType.primaryType != 'image') {
        await response.drain<void>();
        throw const RedditWallpaperException('not an image');
      }
      if (response.contentLength > _maxImageBytes) {
        await response.drain<void>();
        throw const RedditWallpaperException('image too large');
      }

      sink = tmp.openWrite();
      var received = 0;
      await for (final chunk in response.timeout(_timeout)) {
        received += chunk.length;
        if (received > _maxImageBytes) {
          throw const RedditWallpaperException('image too large');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (!await _looksLikeImage(tmp)) {
        throw const RedditWallpaperException('downloaded file is not a valid image');
      }
      await tmp.rename(target.path);
    } finally {
      client.close(force: true);
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      try {
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (_) {}
    }
  }

  /// Checks the magic bytes of JPEG, PNG and WebP files.
  Future<bool> _looksLikeImage(File file) async {
    final builder = BytesBuilder();
    await for (final chunk in file.openRead(0, 12)) {
      builder.add(chunk);
    }
    final Uint8List b = builder.takeBytes();
    if (b.length < 12) return false;
    final isJpeg = b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;
    final isPng = b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
    final isWebp = b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && // RIFF
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50; // WEBP
    return isJpeg || isPng || isWebp;
  }
}
