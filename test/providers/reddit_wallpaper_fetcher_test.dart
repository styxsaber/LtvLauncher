import 'package:flauncher/providers/reddit_wallpaper_fetcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RedditWallpaperFetcher.parseSubreddits', () {
    test('splits on commas, plus signs and whitespace', () {
      expect(
        RedditWallpaperFetcher.parseSubreddits('EarthPorn, wallpapers+Art  spaceporn'),
        ['EarthPorn', 'wallpapers', 'Art', 'spaceporn'],
      );
    });

    test('strips r/ and /r/ prefixes', () {
      expect(RedditWallpaperFetcher.parseSubreddits('r/EarthPorn, /r/wallpapers'), ['EarthPorn', 'wallpapers']);
    });

    test('removes duplicates and invalid names', () {
      expect(
        RedditWallpaperFetcher.parseSubreddits('Art, Art, a, bad-name, ../etc, this_name_is_way_too_long_for_reddit'),
        ['Art'],
      );
    });

    test('returns an empty list for empty input', () {
      expect(RedditWallpaperFetcher.parseSubreddits('  , + '), isEmpty);
    });
  });
}
