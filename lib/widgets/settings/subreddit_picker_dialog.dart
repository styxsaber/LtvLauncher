import 'package:flutter/material.dart';

/// Remote-friendly replacement for the text field (search terms).
/// No system keyboard needed: presets to tick + own keyboard
/// made of normal buttons (D-pad focus works automatically).
///
/// Result: comma separated string, e.g. "nature, space"
/// (same format as the old text field).
///
/// Usage:
///   final result = await showDialog<String>(
///     context: context,
///     builder: (_) => SubredditPickerDialog(initial: aktuellerWert),
///   );
///   if (result != null) { /* speichern */ }
const _presets = <String>[
  'nature',
  'mountains',
  'forest',
  'ocean',
  'sky',
  'space',
  'city',
  'landscape',
  'abstract',
  'minimal',
];

const _keyRows = <String>[
  '1234567890',
  'qwertzuiop',
  'asdfghjkl',
  'yxcvbnm_',
];

class SubredditPickerDialog extends StatefulWidget {
  const SubredditPickerDialog({super.key, required this.initial});

  final String initial;

  @override
  State<SubredditPickerDialog> createState() => _SubredditPickerDialogState();
}

class _SubredditPickerDialogState extends State<SubredditPickerDialog> {
  final List<String> _selected = [];
  late final List<String> _options;
  String _typing = '';

  @override
  void initState() {
    super.initState();
    for (final raw in widget.initial.split(RegExp(r'[,\s]+'))) {
      var name = raw.trim();
      if (name.toLowerCase().startsWith('r/')) name = name.substring(2);
      if (name.isNotEmpty && !_contains(_selected, name)) _selected.add(name);
    }
    _options = [..._presets];
    for (final s in _selected) {
      if (!_contains(_options, s)) _options.add(s);
    }
  }

  bool _contains(List<String> list, String v) =>
      list.any((e) => e.toLowerCase() == v.toLowerCase());

  void _toggle(String name, bool on) {
    setState(() {
      if (on) {
        if (!_contains(_selected, name)) _selected.add(name);
      } else {
        _selected.removeWhere((e) => e.toLowerCase() == name.toLowerCase());
      }
    });
  }

  void _addTyped() {
    final name = _typing.trim();
    if (name.isEmpty) return;
    setState(() {
      if (!_contains(_options, name)) _options.add(name);
      if (!_contains(_selected, name)) _selected.add(name);
      _typing = '';
    });
  }

  Widget _key(String label, VoidCallback onPressed, {double width = 44}) {
    return SizedBox(
      width: width,
      height: 40,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Suchbegriffe'),
      content: SizedBox(
        width: 900,
        height: 380,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView(
                children: [
                  for (var i = 0; i < _options.length; i++)
                    CheckboxListTile(
                      autofocus: i == 0,
                      dense: true,
                      title: Text(_options[i]),
                      value: _contains(_selected, _options[i]),
                      onChanged: (v) => _toggle(_options[i], v ?? false),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Add your own search term'),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white38),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(_typing.isEmpty ? ' ' : _typing),
                  ),
                  const SizedBox(height: 8),
                  for (final row in _keyRows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Wrap(
                        spacing: 4,
                        children: [
                          for (final c in row.split(''))
                            _key(c, () => setState(() => _typing += c)),
                        ],
                      ),
                    ),
                  Wrap(
                    spacing: 4,
                    children: [
                      _key('DEL', () {
                        if (_typing.isEmpty) return;
                        setState(() =>
                            _typing = _typing.substring(0, _typing.length - 1));
                      }),
                      _key('Add', _addTyped, width: 130),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_selected.join(', ')),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
