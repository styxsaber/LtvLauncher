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

/// Picks a random landscape image from the top posts of one or more subreddits
/// and downloads it to a local file. Uses only the public, unauthenticated
/// `.json` listing of Reddit and `dart:io` (no extra dependencies).
class RedditWallpaperFetcher {
  static const String _userAgent = 'android:com.leanbitlab.ltvl.wallpaper:v1.0 (by /u/styxsaber)';
  static const int _maxListingBytes = 4 * 1024 * 1024;
  static const int _maxImageBytes = 25 * 1024 * 1024;
  static const int _maxDownloadAttempts = 5;
  static const int minWidth = 1280;
  static const double minAspectRatio = 1.3;
  static const Duration _timeout = Duration(seconds: 20);

  static final RegExp _subredditPattern = RegExp(r'^[A-Za-z0-9_]{2,21}$');
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

  /// Downloads a random suitable image into [target] and returns what was picked.
  /// Throws [RedditWallpaperException] if nothing usable could be fetched.
  Future<RedditImageCandidate> fetchRandomWallpaper({
    required String subreddits,
    required File target,
    bool allowNsfw = false,
    String? excludeId,
  }) async {
    final subs = parseSubreddits(subreddits);
    if (subs.isEmpty) {
      throw const RedditWallpaperException('no valid subreddit');
    }

    final candidates = await listCandidates(subs, allowNsfw: allowNsfw);
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

  Future<List<RedditImageCandidate>> listCandidates(List<String> subreddits, {bool allowNsfw = false}) async {
    final dynamic json = await _fetchListing(subreddits);
    final dynamic data = json is Map ? json['data'] : null;
    final dynamic children = data is Map ? data['children'] : null;
    if (children is! List) {
      throw const RedditWallpaperException('unexpected response from Reddit');
    }

    final candidates = <RedditImageCandidate>[];
    for (final child in children) {
      final dynamic post = child is Map ? child['data'] : null;
      if (post is! Map) continue;
      if (post['is_video'] == true || post['stickied'] == true) continue;
      if (post['over_18'] == true && !allowNsfw) continue;

      final dynamic rawUrl = post['url_overridden_by_dest'] ?? post['url'];
      if (rawUrl is! String) continue;
      final url = Uri.tryParse(rawUrl);
      if (url == null || url.scheme != 'https' || url.host.isEmpty || !_imagePath.hasMatch(url.path)) continue;

      final dynamic preview = post['preview'];
      final dynamic images = preview is Map ? preview['images'] : null;
      final dynamic first = (images is List && images.isNotEmpty) ? images.first : null;
      final dynamic source = first is Map ? first['source'] : null;
      final dynamic width = source is Map ? source['width'] : null;
      final dynamic height = source is Map ? source['height'] : null;
      if (width is! int || height is! int || height <= 0) continue;
      if (width < minWidth || width / height < minAspectRatio) continue;

      final dynamic id = post['id'];
      candidates.add(RedditImageCandidate(
        id: id is String ? id : url.toString(),
        url: url,
        width: width,
        height: height,
      ));
    }
    return candidates;
  }

  static const List<String> _hosts = ['www.reddit.com', 'old.reddit.com'];

  /// Downloads and parses the listing JSON, trying each Reddit host in turn.
  /// If nothing works, the error message says what came back (HTTP status or the
  /// start of a non-JSON answer) so problems can be diagnosed on the TV.
  Future<dynamic> _fetchListing(List<String> subreddits) async {
    final errors = <String>[];
    for (final host in _hosts) {
      final uri = Uri.https(
        host,
        '/r/${subreddits.join('+')}/top.json',
        {'t': 'month', 'limit': '100', 'raw_json': '1'},
      );
      try {
        final body = await _getString(uri);
        try {
          return jsonDecode(body);
        } on FormatException {
          final snippet = body.replaceAll(RegExp(r'\s+'), ' ').trim();
          errors.add('$host: not JSON "${snippet.length > 70 ? snippet.substring(0, 70) : snippet}"');
        }
      } on RedditWallpaperException catch (e) {
        errors.add('$host: ${e.message}');
      } on IOException catch (e) {
        errors.add('$host: $e');
      } on TimeoutException {
        errors.add('$host: timeout');
      }
    }
    throw RedditWallpaperException(errors.join(' | '));
  }

  HttpClient _newClient() {
    return HttpClient()
      ..connectionTimeout = _timeout
      ..userAgent = _userAgent;
  }

  Future<HttpClientResponse> _open(HttpClient client, Uri uri, String accept) async {
    final request = await client.getUrl(uri).timeout(_timeout);
    request.headers.set(HttpHeaders.acceptHeader, accept);
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