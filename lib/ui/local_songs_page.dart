import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/states.dart';
import '../domain/local_songs.dart';
import '../domain/midi_melody.dart';
import 'theme.dart';
import 'widgets.dart';

/// DAMにない曲を、このPCのDAMだけに追加・管理するページです。
class LocalSongsPage extends StatelessWidget {
  const LocalSongsPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Panel(
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          controller.localSongs,
          controller.manualVideos,
          controller.tasks,
          controller.settings,
        ]),
        builder: (context, _) {
          final songs = controller.localSongs.value;
          final full = songs.length >= LocalSong.maximumSongs;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              PanelHeader(
                'ローカル曲 (${songs.length})',
                trailing: <Widget>[
                  FilledButton.icon(
                    key: const Key('local-song-add'),
                    onPressed: full ? null : () => unawaited(_add(context)),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('曲を追加...'),
                  ),
                ],
              ),
              const Divider(),
              _Notice(
                replaceEnabled: controller.settings.value.replaceVideoUrls,
              ),
              const Divider(),
              Expanded(
                child: songs.isEmpty
                    ? const Center(
                        child: Text(
                          'ローカル曲はありません',
                          style: TextStyle(color: AppColors.textFaint),
                        ),
                      )
                    : _table(context, songs),
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _table(BuildContext context, List<LocalSong> songs) => Column(
    children: <Widget>[
      Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: AppColors.tableHeader,
        child: const Row(
          children: <Widget>[
            Expanded(flex: 10, child: _Label('曲番号')),
            Expanded(flex: 18, child: _Label('曲名')),
            Expanded(flex: 14, child: _Label('アーティスト')),
            Expanded(flex: 6, child: _Label('長さ')),
            Expanded(flex: 12, child: _Label('動画')),
            Expanded(flex: 10, child: _Label('採点')),
            Expanded(flex: 30, child: _Label('')),
          ],
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: songs.length,
          itemExtent: 52,
          itemBuilder: (context, index) => _row(context, songs[index]),
        ),
      ),
    ],
  );

  Widget _row(BuildContext context, LocalSong song) {
    final task = controller.tasks.forVideo(song.requestNo);
    final importing = controller.tasks.isRunning(
      TaskKind.import,
      song.requestNo,
    );
    final hasVideo = controller.manualVideos.value.contains(song.requestNo);
    final style = TextButton.styleFrom(
      minimumSize: const Size(0, 30),
      padding: const EdgeInsets.symmetric(horizontal: 8),
    );
    return Container(
      key: Key('local-song-${song.requestNo}'),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.rowBorder)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(flex: 10, child: _Text(song.requestNo, monospace: true)),
          Expanded(flex: 18, child: _TwoLines(song.title, song.titleYomi)),
          Expanded(flex: 14, child: _TwoLines(song.artist, song.artistYomi)),
          Expanded(flex: 6, child: _Text(_clock(song.playtimeSeconds))),
          Expanded(
            flex: 12,
            child: task != null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        task.label,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.info,
                        ),
                      ),
                      const SizedBox(height: 3),
                      LinearProgressIndicator(
                        value: task.fraction,
                        minHeight: 3,
                      ),
                    ],
                  )
                : Text(
                    hasVideo ? '登録済み' : '未登録（再生できません）',
                    style: TextStyle(
                      fontSize: 12,
                      color: hasVideo ? AppColors.ok : AppColors.warning,
                    ),
                  ),
          ),
          Expanded(
            flex: 10,
            child: Text(
              song.hasScore ? 'あり（${song.melody.length}音）' : 'なし',
              style: TextStyle(
                fontSize: 12,
                color: song.hasScore ? AppColors.ok : AppColors.textFaint,
              ),
            ),
          ),
          Expanded(
            flex: 30,
            // 幅が足りないときははみ出さず、縮めて収めます。
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextButton(
                    style: style,
                    onPressed: () => unawaited(_edit(context, song)),
                    child: const Text('編集...'),
                  ),
                  TextButton(
                    key: Key('local-song-score-${song.requestNo}'),
                    style: style,
                    onPressed: () => unawaited(_score(context, song)),
                    child: const Text('採点...'),
                  ),
                  TextButton(
                    style: style,
                    onPressed: importing
                        ? null
                        : () => unawaited(_replaceVideo(context, song)),
                    child: const Text('動画...'),
                  ),
                  TextButton(
                    style: style,
                    onPressed: importing
                        ? null
                        : () => unawaited(_remove(context, song)),
                    child: const Text('削除'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final result = await showDialog<_SongForm>(
      context: context,
      builder: (_) => _LocalSongDialog(controller: controller),
    );
    if (result == null || result.videoPath == null || !context.mounted) return;
    await _run(
      context,
      () => controller.addLocalSong(
        title: result.title,
        artist: result.artist,
        titleYomi: result.titleYomi,
        artistYomi: result.artistYomi,
        video: File(result.videoPath!),
      ),
    );
  }

  Future<void> _edit(BuildContext context, LocalSong song) async {
    final result = await showDialog<_SongForm>(
      context: context,
      builder: (_) => _LocalSongDialog(controller: controller, song: song),
    );
    if (result == null || !context.mounted) return;
    await _run(
      context,
      () => controller.updateLocalSong(
        song.copyWith(
          title: result.title,
          artist: result.artist,
          titleYomi: result.titleYomi,
          artistYomi: result.artistYomi,
        ),
      ),
    );
  }

  Future<void> _score(BuildContext context, LocalSong song) async {
    final result = await showDialog<List<MelodyNote>>(
      context: context,
      builder: (_) => _ScoreDialog(controller: controller, song: song),
    );
    if (result == null || !context.mounted) return;
    await _run(
      context,
      () => controller.setLocalSongMelody(song.requestNo, result),
    );
  }

  Future<void> _replaceVideo(BuildContext context, LocalSong song) =>
      _run(context, () => controller.replaceLocalSongVideo(song.requestNo));

  Future<void> _remove(BuildContext context, LocalSong song) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ローカル曲を削除'),
        content: Text(
          '${song.requestNo}「${song.title}」と、その動画を削除します。'
          'DAMの予約に残っている場合は再生できなくなります。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (accepted == true && context.mounted) {
      await _run(context, () => controller.removeLocalSong(song.requestNo));
    }
  }

  Future<void> _run(
    BuildContext context,
    Future<Object?> Function() action,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } on Object catch (error) {
      controller.log.add('ローカル曲の操作に失敗しました: $error');
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  static String _clock(int seconds) => seconds <= 0
      ? '—'
      : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _Notice extends StatelessWidget {
  const _Notice({required this.replaceEnabled});

  final bool replaceEnabled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'DAMにない曲を、このPCのDAMだけに追加します。DAM本体やWebリモコンで曲名・'
          'アーティスト名をキーワード検索すると出てきて、通常の曲と同じように予約・再生できます。'
          '採点と歌詞の表示はありません。',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.textMuted,
            height: 1.5,
          ),
        ),
        if (!replaceEnabled)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              '「動画の差し替え」がOFFのため、ローカル曲は再生できません。動画タブでONにしてください。',
              style: TextStyle(fontSize: 12, color: AppColors.warning),
            ),
          ),
      ],
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
  );
}

class _Text extends StatelessWidget {
  const _Text(this.text, {this.monospace = false});

  final String text;
  final bool monospace;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: 13, fontFamily: monospace ? 'Consolas' : null),
  );
}

class _TwoLines extends StatelessWidget {
  const _TwoLines(this.main, this.sub);

  final String main;
  final String sub;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        main,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      if (sub.isNotEmpty)
        Text(
          sub,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
        ),
    ],
  );
}

/// 追加・編集の入力内容です。編集では [videoPath] は使いません。
class _SongForm {
  const _SongForm({
    required this.title,
    required this.artist,
    required this.titleYomi,
    required this.artistYomi,
    this.videoPath,
  });

  final String title;
  final String artist;
  final String titleYomi;
  final String artistYomi;
  final String? videoPath;
}

class _LocalSongDialog extends StatefulWidget {
  const _LocalSongDialog({required this.controller, this.song});

  final AppController controller;

  /// 編集する曲です。`null` なら追加です。
  final LocalSong? song;

  @override
  State<_LocalSongDialog> createState() => _LocalSongDialogState();
}

class _LocalSongDialogState extends State<_LocalSongDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.song?.title,
  );
  late final TextEditingController _artist = TextEditingController(
    text: widget.song?.artist,
  );
  late final TextEditingController _titleYomi = TextEditingController(
    text: widget.song?.titleYomi,
  );
  late final TextEditingController _artistYomi = TextEditingController(
    text: widget.song?.artistYomi,
  );
  String? _videoPath;

  bool get _adding => widget.song == null;

  bool get _valid =>
      _title.text.trim().isNotEmpty &&
      _artist.text.trim().isNotEmpty &&
      (!_adding || _videoPath != null);

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _titleYomi.dispose();
    _artistYomi.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_adding ? 'ローカル曲を追加' : '${widget.song!.requestNo} を編集'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _field(_title, '曲名', 'local-song-title'),
          _field(_titleYomi, '曲名の読み（任意・検索用）', 'local-song-title-yomi'),
          _field(_artist, 'アーティスト名', 'local-song-artist'),
          _field(_artistYomi, 'アーティスト名の読み（任意・検索用）', 'local-song-artist-yomi'),
          if (_adding) ...<Widget>[
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                OutlinedButton(
                  onPressed: () => unawaited(_pickVideo()),
                  child: const Text('動画を選択...'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _videoPath ?? '音声付きの動画ファイル（mp4・mkv など）',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: _videoPath == null
                          ? AppColors.textFaint
                          : AppColors.text,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      FilledButton(
        key: const Key('local-song-save'),
        onPressed: _valid
            ? () => Navigator.pop(
                context,
                _SongForm(
                  title: _title.text.trim(),
                  artist: _artist.text.trim(),
                  titleYomi: _titleYomi.text.trim(),
                  artistYomi: _artistYomi.text.trim(),
                  videoPath: _videoPath,
                ),
              )
            : null,
        child: Text(_adding ? '追加' : '保存'),
      ),
    ],
  );

  Widget _field(TextEditingController controller, String label, String key) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          key: Key(key),
          controller: controller,
          maxLength: 100,
          decoration: InputDecoration(labelText: label, counterText: ''),
          onChanged: (_) => setState(() {}),
        ),
      );

  Future<void> _pickVideo() async {
    final picked = await widget.controller.pickLocalSongVideo();
    if (picked != null && mounted) setState(() => _videoPath = picked);
  }
}

/// 採点の基準にする旋律を、MIDIファイルから取り込むダイアログです。
class _ScoreDialog extends StatefulWidget {
  const _ScoreDialog({required this.controller, required this.song});

  final AppController controller;
  final LocalSong song;

  @override
  State<_ScoreDialog> createState() => _ScoreDialogState();
}

class _ScoreDialogState extends State<_ScoreDialog> {
  final TextEditingController _path = TextEditingController();
  List<MidiTrack> _tracks = const <MidiTrack>[];
  int _selected = 0;
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  static const List<String> _noteNames = <String>[
    'C',
    'C#',
    'D',
    'D#',
    'E',
    'F',
    'F#',
    'G',
    'G#',
    'A',
    'A#',
    'B',
  ];

  static String _pitchName(int pitch) =>
      '${_noteNames[pitch % 12]}${pitch ~/ 12 - 1}';

  /// 歌のメロディーらしいトラックを選びます（名前に手がかりがあればそれ、なければ音数が最多）。
  static int _likelyMelody(List<MidiTrack> tracks) {
    final named = tracks.indexWhere(
      (t) => RegExp(
        r'melody|vocal|lead|voice|メロ|ボーカル|主旋律|歌',
        caseSensitive: false,
      ).hasMatch(t.name),
    );
    if (named >= 0) return named;
    var best = 0;
    for (var i = 1; i < tracks.length; i++) {
      if (tracks[i].notes.length > tracks[best].notes.length) best = i;
    }
    return best;
  }

  Future<void> _pick() async {
    final picked = await widget.controller.bridge.pickVideoFile(<String>[
      'mid',
      'midi',
    ]);
    if (picked == null || !mounted) return;
    _path.text = picked;
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tracks = await widget.controller.readMidiTracks(_path.text);
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _selected = tracks.isEmpty ? 0 : _likelyMelody(tracks);
        if (tracks.isEmpty) _error = '音符のあるトラックがありません';
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = _tracks.isEmpty ? null : _tracks[_selected];
    final tooMany =
        track != null && track.notes.length > LocalSong.maximumMelodyNotes;
    return AlertDialog(
      title: Text('${widget.song.requestNo} の採点データ'),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              widget.song.hasScore
                  ? '現在: あり（${widget.song.melody.length}音）'
                  : '現在: なし',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 6),
            const Text(
              '採点の基準にする歌のメロディーを、MIDIファイルから取り込みます。'
              '動画の時間と合ったMIDIを用意してください。',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('local-song-midi-path'),
                    controller: _path,
                    decoration: const InputDecoration(
                      labelText: 'MIDIファイルのパス',
                      isDense: true,
                    ),
                    onSubmitted: (_) => unawaited(_load()),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => unawaited(_pick()),
                  child: const Text('選択...'),
                ),
                const SizedBox(width: 4),
                OutlinedButton(
                  key: const Key('local-song-midi-load'),
                  onPressed: _loading ? null : () => unawaited(_load()),
                  child: const Text('読み込む'),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(fontSize: 12, color: AppColors.error),
                ),
              ),
            if (_tracks.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                key: const Key('local-song-midi-track'),
                initialValue: _selected,
                decoration: const InputDecoration(
                  labelText: '旋律のトラック',
                  isDense: true,
                ),
                items: <DropdownMenuItem<int>>[
                  for (final (i, t) in _tracks.indexed)
                    DropdownMenuItem<int>(
                      value: i,
                      child: Text(
                        '${t.name} — ${t.notes.length}音・'
                        '${_pitchName(t.lowestPitch)}〜${_pitchName(t.highestPitch)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _selected = value ?? 0),
              ),
              if (tooMany)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '音符が多すぎます（${LocalSong.maximumMelodyNotes}音まで）。',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.warning,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        if (widget.song.hasScore)
          TextButton(
            key: const Key('local-song-score-clear'),
            onPressed: () => Navigator.pop(context, const <MelodyNote>[]),
            child: const Text('採点なしにする'),
          ),
        FilledButton(
          key: const Key('local-song-score-save'),
          onPressed: track == null || tooMany
              ? null
              : () => Navigator.pop(context, track.notes),
          child: const Text('取り込む'),
        ),
      ],
    );
  }
}
