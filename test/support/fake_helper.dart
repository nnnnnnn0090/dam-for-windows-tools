// 試験用の偽接続ヘルパーです。docs/DAM_LINK_DESIGN.md のプロトコルの一部だけを返します。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

void emit(Map<String, Object?> event) => stdout.writeln(jsonEncode(event));

Map<String, Object?> searchResult(Object? id, Object? query) => {
  'type': 'remote-search-result',
  'requestId': id,
  'rows': [
    {'token': 't_$query', 'videoId': '1-1', 'artist': 'A', 'title': '$query'},
  ],
};

Future<void> main() async {
  // DAMの中で検索を処理している間です。実機と同じく、次の要求は busy で断ります。
  var searching = false;
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final command = jsonDecode(line) as Map<String, Object?>;
    final id = command['requestId'];
    switch (command['type']) {
      case 'config':
        emit({'type': 'status', 'state': 'ready', 'detail': ''});
        emit({'type': 'status', 'state': 'attached', 'detail': 'ok'});
      case 'remoteSearch':
        final query = command['query'];
        // 試験で「どの要求がヘルパーまで届いたか」を確かめるための記録です。
        emit({'type': 'log', 'message': 'received:$query'});
        if (query == 'crash') exit(3);
        if (query == 'huge') stdout.writeln('x' * (5 * 1024 * 1024));
        if (query == 'busy' || searching) {
          emit({
            'type': 'remote-search-result',
            'requestId': id,
            'error': 'another remote request is running',
          });
          break;
        }
        if (query == 'late') {
          // 呼び出し元のタイムアウトより後に結果を返します。
          searching = true;
          Timer(const Duration(milliseconds: 1000), () {
            searching = false;
            emit(searchResult(id, query));
          });
          break;
        }
        if (query == 'slow') {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        emit(searchResult(id, query));
      case 'remoteState':
        emit({
          'type': 'remote-state-result',
          'requestId': id,
          'result': {'connected': true, 'playing': true, 'key': 2},
        });
      case 'shutdown':
        exit(0);
    }
  }
}
