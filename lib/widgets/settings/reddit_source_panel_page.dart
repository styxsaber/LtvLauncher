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

import 'package:flauncher/l10n/app_localizations.dart';
import 'package:flauncher/providers/reddit_wallpaper_fetcher.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flauncher/providers/wallpaper_service.dart';
import 'package:flauncher/widgets/rounded_switch_list_tile.dart';
import 'package:flauncher/widgets/settings/focusable_settings_tile.dart';
import 'package:flauncher/widgets/settings/subreddit_picker_dialog.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Settings of the real Reddit wallpaper source. It works next to the Wallhaven
/// source: if both are switched on, every wallpaper change picks one of them at random.
/// The change interval is shared with the Wallhaven page.
class RedditSourcePanelPage extends StatelessWidget {
  static const String routeName = "reddit_source_panel";

  /// Selectable refresh intervals in minutes: 1 h, 6 h, 24 h.
  static const List<int> _intervals = [60, 360, 1440];

  static const List<String> _presets = [
    'EarthPorn',
    'wallpapers',
    'wallpaper',
    'spaceporn',
    'CityPorn',
    'MinimalWallpaper',
    'ImaginaryLandscapes',
    'Art',
  ];

  const RedditSourcePanelPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;

    return Column(
      children: [
        Text("Reddit", style: Theme.of(context).textTheme.titleLarge),
        const Divider(),
        Consumer<SettingsService>(
          builder: (_, settings, __) => RoundedSwitchListTile(
            autofocus: true,
            title: const Text("Reddit"),
            secondary: const Icon(Icons.forum_outlined),
            value: settings.redditSourceEnabled,
            onChanged: (value) => _setEnabled(context, settings, value, localizations),
          ),
        ),
        Consumer<SettingsService>(
          builder: (_, settings, __) => FocusableSettingsTile(
            leading: const Icon(Icons.tag),
            title: Text(localizations.redditWallpaperSubreddits, style: Theme.of(context).textTheme.bodyMedium),
            trailing: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                settings.redditSourceSubreddits.replaceAll('+', ', '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            onPressed: () => _editSubreddits(context, settings, localizations),
          ),
        ),
        Consumer<SettingsService>(
          builder: (_, settings, __) => FocusableSettingsTile(
            leading: const Icon(Icons.schedule),
            title: Text(localizations.redditWallpaperInterval, style: Theme.of(context).textTheme.bodyMedium),
            trailing: Text(_intervalLabel(settings.redditWallpaperIntervalMinutes),
                style: Theme.of(context).textTheme.bodySmall),
            onPressed: () => settings.setRedditWallpaperIntervalMinutes(_nextInterval(settings.redditWallpaperIntervalMinutes)),
          ),
        ),
        Consumer2<SettingsService, WallpaperService>(
          builder: (_, settings, wallpaperService, __) => FocusableSettingsTile(
            leading: wallpaperService.redditRefreshing
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            title: Text(
              wallpaperService.redditRefreshing ? localizations.redditWallpaperLoading : localizations.redditWallpaperNext,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            onPressed: wallpaperService.redditRefreshing ? null : () => _refreshNow(context, settings, localizations),
          ),
        ),
      ],
    );
  }

  static String _intervalLabel(int minutes) {
    if (minutes % 60 == 0) {
      return "${minutes ~/ 60} h";
    }
    return "$minutes min";
  }

  static int _nextInterval(int current) {
    final index = _intervals.indexOf(current);
    return _intervals[(index + 1) % _intervals.length];
  }

  Future<void> _setEnabled(
      BuildContext context, SettingsService settings, bool value, AppLocalizations localizations) async {
    if (value && RedditWallpaperFetcher.parseSubreddits(settings.redditSourceSubreddits).isEmpty) {
      _showMessage(context, localizations.redditWallpaperNoSubreddits);
      return;
    }
    await settings.setRedditSourceEnabled(value);
  }

  Future<void> _editSubreddits(BuildContext context, SettingsService settings, AppLocalizations localizations) async {
    final de = Localizations.localeOf(context).languageCode == 'de';
    final result = await showDialog<String>(
      context: context,
      builder: (_) => SubredditPickerDialog(
        initial: settings.redditSourceSubreddits.replaceAll('+', ', '),
        title: localizations.redditWallpaperSubreddits,
        addLabel: de ? "Eigenes Subreddit hinzufügen" : "Add your own subreddit",
        presets: _presets,
      ),
    );
    if (result == null) {
      return;
    }
    final subreddits = RedditWallpaperFetcher.parseSubreddits(result);
    if (subreddits.isEmpty) {
      if (context.mounted) {
        _showMessage(context, localizations.redditWallpaperNoSubreddits);
      }
      return;
    }
    await settings.setRedditSourceSubreddits(subreddits.join('+'));
  }

  Future<void> _refreshNow(BuildContext context, SettingsService settings, AppLocalizations localizations) async {
    if (!settings.redditSourceEnabled) {
      await _setEnabled(context, settings, true, localizations);
      if (!settings.redditSourceEnabled) {
        return;
      }
    }
    final wallpaperService = context.read<WallpaperService>();
    final success = await wallpaperService.refreshRedditWallpaperNow(only: OnlineWallpaperSource.reddit);
    if (!success && context.mounted && wallpaperService.redditLastError != null) {
      _showMessage(context, "${localizations.redditWallpaperError} (${wallpaperService.redditLastError})");
    }
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.red),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}
