/*
 * FLauncher
 * Copyright (C) 2021  Étienne Fesser
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

import 'dart:io';
import 'dart:async';

import 'package:flauncher/flauncher_channel.dart';
import 'package:flauncher/gradients.dart';
import 'package:flauncher/providers/reddit_wallpaper_fetcher.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

class WallpaperService extends ChangeNotifier {
  /// Reddit images are decoded at most this wide to keep memory usage low on weak TV hardware.
  static const int _redditMaxDecodeWidth = 2560;
  static const Duration _redditCheckInterval = Duration(minutes: 5);

  final FLauncherChannel _fLauncherChannel;
  final SettingsService _settingsService;
  final RedditWallpaperFetcher _redditFetcher = RedditWallpaperFetcher();

  late File _wallpaperFile;
  late File _wallpaperDayFile;
  late File _wallpaperNightFile;
  late File _wallpaperRedditFile;
  Timer? _timer;
  Timer? _redditTimer;

  bool _initialized = false;
  ImageProvider? _wallpaper;
  int _version = 0;
  int _updateWallpaperCallCount = 0;

  ImageProvider? _redditProvider;
  bool _redditRefreshing = false;
  String? _redditLastError;
  String? _lastRedditPostId;

  ImageProvider?  get wallpaper     => _wallpaper;
  int             get version       => _version;
  bool            get redditRefreshing => _redditRefreshing;
  String?         get redditLastError  => _redditLastError;

  FLauncherGradient get gradient => FLauncherGradients.all.firstWhere(
        (gradient) => gradient.uuid == _settingsService.gradientUuid,
        orElse: () => FLauncherGradients.pitchBlack,
      );

  WallpaperService(this._fLauncherChannel, this._settingsService) :
    _wallpaper = null
  {
    _settingsService.addListener(_onSettingsChanged);
    _init();
  }

  bool _lastTimeBasedEnabled = false;
  bool _lastRedditEnabled = false;
  String _lastRedditSubreddits = "";
  bool _lastRedditAllowNsfw = false;
  bool _lastRedditNsfwOnly = false;

  void _onSettingsChanged() {
    if (!_initialized) {
      return;
    }

    final enabled = _settingsService.timeBasedWallpaperEnabled;
    if (enabled != _lastTimeBasedEnabled) {
      _lastTimeBasedEnabled = enabled;
      _updateTimerState();
      _updateWallpaper();
    }

    final redditEnabled = _settingsService.redditWallpaperEnabled;
    final redditSubreddits = _settingsService.redditWallpaperSubreddits;
    final redditAllowNsfw = _settingsService.redditWallpaperAllowNsfw;
    final redditNsfwOnly = _settingsService.redditWallpaperNsfwOnly;
    final redditToggled = redditEnabled != _lastRedditEnabled;
    final redditSourceChanged = redditSubreddits != _lastRedditSubreddits ||
        redditAllowNsfw != _lastRedditAllowNsfw ||
        redditNsfwOnly != _lastRedditNsfwOnly;
    if (redditToggled || redditSourceChanged) {
      _lastRedditEnabled = redditEnabled;
      _lastRedditSubreddits = redditSubreddits;
      _lastRedditAllowNsfw = redditAllowNsfw;
      _lastRedditNsfwOnly = redditNsfwOnly;
      _updateRedditTimerState();
      // Show the cached Reddit picture (or switch back) right away ...
      _updateWallpaper(force: true);
      // ... and fetch a new one if the source changed or nothing is cached yet.
      if (redditEnabled) {
        _refreshReddit(force: redditSourceChanged);
      }
    }
  }

  @override
  void dispose() {
    _settingsService.removeListener(_onSettingsChanged);
    _timer?.cancel();
    _redditTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final directory = await getApplicationDocumentsDirectory();
    _wallpaperFile = File("${directory.path}/wallpaper");
    _wallpaperDayFile = File("${directory.path}/wallpaper_day");
    _wallpaperNightFile = File("${directory.path}/wallpaper_night");
    _wallpaperRedditFile = File("${directory.path}/wallpaper_reddit");

    _lastTimeBasedEnabled = _settingsService.timeBasedWallpaperEnabled;
    _lastRedditEnabled = _settingsService.redditWallpaperEnabled;
    _lastRedditSubreddits = _settingsService.redditWallpaperSubreddits;
    _lastRedditAllowNsfw = _settingsService.redditWallpaperAllowNsfw;
    _lastRedditNsfwOnly = _settingsService.redditWallpaperNsfwOnly;
    _initialized = true;

    await _updateWallpaper();
    _updateTimerState();
    _updateRedditTimerState();
    if (_lastRedditEnabled) {
      unawaited(_refreshReddit());
    }
  }

  void _updateTimerState() {
    final enabled = _settingsService.timeBasedWallpaperEnabled;
    if (enabled && (_timer == null || !_timer!.isActive)) {
      _timer = Timer.periodic(const Duration(minutes: 1), (_) => _updateWallpaper());
    } else if (!enabled && _timer != null) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _updateRedditTimerState() {
    final enabled = _settingsService.redditWallpaperEnabled;
    if (enabled && (_redditTimer == null || !_redditTimer!.isActive)) {
      _redditTimer = Timer.periodic(_redditCheckInterval, (_) => _refreshReddit());
    } else if (!enabled && _redditTimer != null) {
      _redditTimer?.cancel();
      _redditTimer = null;
    }
  }

  Future<void> _updateWallpaper({bool force = false}) async {
    final callId = ++_updateWallpaperCallCount;
    final now = DateTime.now();
    final isDay = now.hour >= 6 && now.hour < 18;
    final enabled = _settingsService.timeBasedWallpaperEnabled;

    ImageProvider? newWallpaper;

    if (_settingsService.redditWallpaperEnabled && await _wallpaperRedditFile.exists()) {
      // Keep one provider instance so periodic updates don't needlessly rebuild the UI.
      newWallpaper = _redditProvider ??= ResizeImage.resizeIfNeeded(
        _redditMaxDecodeWidth,
        null,
        FileImage(_wallpaperRedditFile),
      );
    } else if (enabled) {
      if (isDay && await _wallpaperDayFile.exists()) {
        newWallpaper = FileImage(_wallpaperDayFile);
      } else if (!isDay && await _wallpaperNightFile.exists()) {
        newWallpaper = FileImage(_wallpaperNightFile);
      } else if (await _wallpaperFile.exists()) {
        newWallpaper = FileImage(_wallpaperFile); // Fallback
      }
    } else {
      if (await _wallpaperFile.exists()) {
        newWallpaper = FileImage(_wallpaperFile);
      }
    }

    if (callId == _updateWallpaperCallCount) {
      if (_wallpaper != newWallpaper || force) {
        _wallpaper = newWallpaper;
        notifyListeners();
      }
    }
  }

  /// Downloads a new random picture from the configured subreddits right now.
  /// Returns true on success; on failure [redditLastError] describes what went wrong.
  Future<bool> refreshRedditWallpaperNow() => _refreshReddit(force: true);

  Future<bool> _isRedditRefreshDue() async {
    if (!await _wallpaperRedditFile.exists()) {
      return true;
    }
    final age = DateTime.now().difference(await _wallpaperRedditFile.lastModified());
    return age >= Duration(minutes: _settingsService.redditWallpaperIntervalMinutes);
  }

  Future<bool> _refreshReddit({bool force = false}) async {
    if (!_initialized || !_settingsService.redditWallpaperEnabled || _redditRefreshing) {
      return false;
    }
    if (!force && !await _isRedditRefreshDue()) {
      return false;
    }

    _redditRefreshing = true;
    _redditLastError = null;
    notifyListeners();

    var success = false;
    try {
      final picked = await _redditFetcher.fetchRandomWallpaper(
        subreddits: _settingsService.redditWallpaperSubreddits,
        target: _wallpaperRedditFile,
        allowNsfw: _settingsService.redditWallpaperAllowNsfw,
        nsfwOnly: _settingsService.redditWallpaperNsfwOnly,
        excludeId: _lastRedditPostId,
      );
      _lastRedditPostId = picked.id;

      // Evict the previous decode from the image cache and use a fresh provider.
      await _redditProvider?.evict();
      _redditProvider = null;
      _version++;
      success = true;
    } on RedditWallpaperException catch (e) {
      _redditLastError = e.message;
    } on TimeoutException {
      _redditLastError = "timeout";
    } on IOException catch (e) {
      _redditLastError = e.toString();
    } on FormatException {
      _redditLastError = "invalid response from Reddit";
    } finally {
      _redditRefreshing = false;
    }

    await _updateWallpaper(force: true);
    return success;
  }

  Future<void> pickWallpaper() async {
    await _pickAndSave(_wallpaperFile);
  }

  Future<void> pickWallpaperDay() async {
    await _pickAndSave(_wallpaperDayFile);
  }

  Future<void> pickWallpaperNight() async {
    await _pickAndSave(_wallpaperNightFile);
  }

  Future<void> _pickAndSave(File targetFile) async {
    if (!await _fLauncherChannel.checkForGetContentAvailability()) {
      throw NoFileExplorerException();
    }

    final imagePicker = ImagePicker();
    final pickedFile = await imagePicker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      // Use stream for memory efficiency
      final readStream = pickedFile.openRead();
      final writeStream = targetFile.openWrite();
      await readStream.cast<List<int>>().pipe(writeStream);

      // Evict from cache to ensure UI updates
      await FileImage(targetFile).evict();

      // A manually picked picture replaces the Reddit wallpaper.
      await _settingsService.setRedditWallpaperEnabled(false);

      _version++;
      await _updateWallpaper(force: true);
    }
  }

  Future<void> setGradient(FLauncherGradient fLauncherGradient) async {
    if (await _wallpaperFile.exists()) {
      await _wallpaperFile.delete();
    }

    // Choosing a gradient replaces the Reddit wallpaper.
    await _settingsService.setRedditWallpaperEnabled(false);

    _settingsService.setGradientUuid(fLauncherGradient.uuid);
    notifyListeners();
  }
}

class NoFileExplorerException implements Exception {}
