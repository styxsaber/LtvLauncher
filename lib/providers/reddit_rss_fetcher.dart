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

import 'package:flauncher/providers/reddit_wallpaper_fetcher.dart';

/// The real Reddit source. Picks a random landscape image from the monthly top
/// posts of one of the chosen subreddits and downloads it to a local file.
///
/// Reddit blocks plain .json requests from many devices, so three ways are tried
/// one after another: the RSS feed (as a feed reader), the RSS feed (as a
/// browser) and finally the .json listing. If all of them fail, the error
/// message lists what each one answered.
///
/// The RSS feed has no NSFW flag. Which images show up depends only on the
/// subreddits you choose. The .json fallback skips posts marked as NSFW.
class RedditRssFetcher {
  static const String _feedAgent = 'Feedly/1.0 (+http://www.feedly.com/fetcher.html; like FeedFetcher-Google)';
  static const String _browserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const int _maxListingBytes = 4 * 1024 * 1024;
  static const int _maxImageBytes = 25 * 1024 * 1024;
  static const int _maxDownloadAttempts = 5;
  static const int minWidth = 1280;
  static const double minAspectRatio = 1.3;
  static const Duration _timeout = Duration(seconds: 20);

  static final RegExp _entry = RegExp(r'<entry>(.*?)</entry>', dotAll: true);
  static final RegExp _idTag = RegExp(r'<id>(?:t3_)?(.*?)</id>');
  static final RegExp _titleTag = RegExp(r'<title>(.*?)</title>', dotAll: true);
  static final RegExp _linkTag = RegExp(r'''href=["'](https?://[^\s"'<>]+)["']>\[link\]''', caseSensitive: false);
  static final RegExp _imageUrl = RegExp(
    r'https://(?:i\.redd\.it|i\.imgur\.com)/[A-Za-z0-9._-]+\.(?:jpg|jpeg|png|webp)',
    caseSensitive: false,
  );
  static final RegExp _imageExt = RegExp(r'\.(jpe?g|png|webp)$', caseSensitive: false);
  // Many wallpaper subreddits write the size into the title, e.g. "[3840x2160]".
  static final RegExp _resolution = RegExp(r'(\d{3,5})\s*[x×]\s*(\d{3,5})');

  final Random _random;

  RedditRssFetcher({Random? random}) : _random = random ?? Random();

  /// Downloads a random suitable image into [target] and returns what was picked.
  /// Throws [RedditWallpaperException] if nothing usable could be fetched.
  Future<RedditImageCandidate> fetchRandomWallpaper({
    required String subreddits,
    required File target,
    String? excludeId,
  }) async {
    final subs = RedditWallpaperFetcher.parseSubreddits(subreddits);
    if (subs.isEmpty) {
      throw const RedditWallpaperException('no valid subreddit');
    }
    final sub = subs[_random.nextInt(subs.length)];

    final candidates = await _listCandidates(sub);
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

  Future<List<RedditImageCandidate>> _listCandidates(String sub) async {
    final rssUri = Uri.https('www.reddit.com', '/r/$sub/top.rss', {'t': 'month', 'limit': '50'});
    final jsonUri = Uri.https('www.reddit.com', '/r/$sub/top.json', {'t': 'month', 'limit': '50', 'raw_json': '1'});

    final steps = <Future<List<RedditImageCandidate>> Function()>[
      () => _fromFeed(rssUri, _feedAgent),
      () => _fromFeed(rssUri, _browserAgent),
      () => _fromJson(jsonUri),
    ];

    final errors = <String>[];
    for (final step in steps) {
      try {
        final list = await step();
        if (list.isNotEmpty) {
          return list;
        }
        errors.add('no images');
      } on RedditWallpaperException catch (e) {
        errors.add(e.message);
      } on IOException catch (e) {
        errors.add(e.toString());
      } on TimeoutException {
        errors.add('timeout');
      } on FormatException {
        errors.add('invalid data');
      }
    }
    throw RedditWallpaperException(errors.join(' | '));
  }

  Future<List<RedditImageCandidate>> _fromFeed(Uri uri, String agent) async {
    final body = await _getString(uri, agent, 'application/atom+xml,application/xml,text/xml;q=0.9,*/*;q=0.8');
    if (!body.contains('<feed')) {
      throw RedditWallpaperException('not a feed "${_snippet(body)}"');
    }
    return parseFeed(body);
  }

  Future<List<RedditImageCandidate>> _fromJson(Uri uri) async {
    final body = await _getString(uri, _browserAgent, 'application/json');
    try {
      return parseJson(body);
    } on FormatException {
      throw RedditWallpaperException('not JSON "${_snippet(body)}"');
    }
  }

  static String _snippet(String body) {
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 50 ? text.substring(0, 50) : text;
  }

  /// Reads an Atom feed of a subreddit and returns the posts that link to a picture.
  static List<RedditImageCandidate> parseFeed(String xml) {
    final result = <RedditImageCandidate>[];
    for (final match in _entry.allMatches(xml)) {
      final block = match.group(1) ?? '';
      final id = _idTag.firstMatch(block)?.group(1);
      if (id == null || id.isEmpty) continue;

      final decoded = _unescape(block);
      String? link = _linkTag.firstMatch(decoded)?.group(1);
      if (link == null || !_isDirectImage(link)) {
        link = _imageUrl.firstMatch(decoded)?.group(0);
      }
      if (link == null) continue;
      final url = Uri.tryParse(link);
      if (url == null) continue;

      var width = 0;
      var height = 0;
      final title = _unescape(_titleTag.firstMatch(block)?.group(1) ?? '');
      final size = _resolution.firstMatch(title);
      if (size != null) {
        width = int.parse(size.group(1)!);
        height = int.parse(size.group(2)!);
        if (height <= 0 || width < minWidth || width / height < minAspectRatio) continue;
      }
      result.add(RedditImageCandidate(id: id, url: url, width: width, height: height));
    }
    return result;
  }

  /// Reads a .json listing of a subreddit. Throws [FormatException] if [body] is not JSON.
  static List<RedditImageCandidate> parseJson(String body) {
    final dynamic json = jsonDecode(body);
    final dynamic data = json is Map ? json['data'] : null;
    final dynamic children = data is Map ? data['children'] : null;
    if (children is! List) return <RedditImageCandidate>[];

    final result = <RedditImageCandidate>[];
    for (final child in children) {
      final dynamic post = child is Map ? child['data'] : null;
      if (post is! Map) continue;
      if (post['over_18'] == true || post['is_video'] == true || post['stickied'] == true) continue;

      final dynamic raw = post['url_overridden_by_dest'] ?? post['url'];
      if (raw is! String || !_isDirectImage(raw)) continue;
      final url = Uri.tryParse(raw);
      if (url == null) continue;

      final dynamic preview = post['preview'];
      final dynamic images = preview is Map ? preview['images'] : null;
      final dynamic first = (images is List && images.isNotEmpty) ? images.first : null;
      final dynamic source = first is Map ? first['source'] : null;
      final dynamic w = source is Map ? source['width'] : null;
      final dynamic h = source is Map ? source['height'] : null;
      var width = 0;
      var height = 0;
      if (w is num && h is num && h > 0) {
        width = w.toInt();
        height = h.toInt();
        if (width < minWidth || width / height < minAspectRatio) continue;
      }

      final dynamic id = post['id'];
      result.add(RedditImageCandidate(
        id: id is String ? id : raw,
        url: url,
        width: width,
        height: height,
      ));
    }
    return result;
  }

  static bool _isDirectImage(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'https') return false;
    if (uri.host == 'i.redd.it' || uri.host == 'i.imgur.com') return true;
    return _imageExt.hasMatch(uri.path);
  }

  static String _unescape(String text) {
    return text
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
  }

  HttpClient _newClient(String agent) {
    return HttpClient()
      ..connectionTimeout = _timeout
      ..userAgent = agent;
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

  Future<String> _getString(Uri uri, String agent, String accept) async {
    final client = _newClient(agent);
    try {
      final response = await _open(client, uri, accept);
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
    final tmp = File('${target.path}.reddit.tmp');
    final client = _newClient(_browserAgent);
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
