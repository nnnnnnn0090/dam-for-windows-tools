// Project: DAM for Windows Tools
// File: agent/25_local_songs.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-11-03

// ローカル曲（DAMの配信にない曲）を、DAMが受け取るWinHTTPの応答へ付け足します。
//
// - キーワード検索の応答: 一致するローカル曲を先頭へ追加します。
// - 曲情報・配信URLの応答: ローカル曲の番号なら、作った応答へ置き換えます。
//   配信URLのファイル名に曲番号を入れ、既存の動画差し替え（prepare）でローカル動画へ向けます。
//
// DAMはこれらのAPIを同期のWinHttpReadDataで読むため、対象の要求だけ元の応答を読み切り、
// 書き換えた本文をWinHttpQueryDataAvailable・WinHttpReadDataから返します。

let localSongs = [];
// 曲番号 -> 採点用の音符の数と、DAMが読む形式の基準データです（要求のたびにファイルから作り直します）。
const localScores = new Map();
const localHttpRequests = new Map();
const LOCAL_SONG_APIS = [
  ['search', /\/SearchVariousByKeywordApi$/],
  ['detailInfo', /\/GetMusicDetailInfoApi$/],
  ['detail', /\/GetMusicDetail\.api$/],
  ['streaming', /\/GetMusicStreamingURL\.api$/],
  ['scoring', /\/GetEncryptedScoringReferenceData\.api$/],
];
const LOCAL_STREAMING_ORIGIN = 'https://local-song.invalid/';
// 採点基準データの偽の暗号文の先頭に入れる目印です（`LOCALSC|9999-01|` の16バイト）。
const LOCAL_SCORE_MARKER = /^LOCALSC\|(9999-[0-9]{2})\|$/;
const MAXIMUM_SCORE_NOTES = 3000;

/** アプリから届いた一覧を検証して保持します。 */
function setLocalSongList(list) {
  const songs = [];
  for (const raw of Array.isArray(list) ? list : []) {
    if (!raw || typeof raw !== 'object') continue;
    const requestNo = String(raw.requestNo || '');
    if (!/^[0-9]{4}-[0-9]{2}$/.test(requestNo)) continue;
    songs.push({
      requestNo,
      title: cleanText(raw.title),
      artist: cleanText(raw.artist),
      titleYomi: cleanText(raw.titleYomi),
      artistYomi: cleanText(raw.artistYomi),
      playtime: Math.max(0, Math.min(3600, Math.floor(Number(raw.playtime) || 0))),
      scorePath: typeof raw.scorePath === 'string' ? raw.scorePath : '',
    });
  }
  localSongs = songs;
  refreshLocalScores();
  emitLog(`ローカル曲: ${songs.length}曲（採点データあり ${localScores.size}曲）を登録しました`);
  return songs.length;
}

/** 各曲の採点用の音符のファイルを読み、基準データを作り直します。 */
function refreshLocalScores() {
  localScores.clear();
  for (const song of localSongs) {
    if (!song.scorePath) continue;
    try {
      const notes = JSON.parse(File.readAllText(song.scorePath));
      const cleaned = cleanScoreNotes(notes);
      const plain = buildScoringReference(cleaned);
      if (plain) {
        const view = new DataView(plain.buffer);
        localScores.set(song.requestNo, { notes: cleaned.length, plain });
        emitLog(
          `ローカル曲: ${song.requestNo} 採点データ ${cleaned.length}音・` +
            `${view.getUint32(8, true)}フレーズ・${plain.length}バイト`,
        );
      }
    } catch (error) {
      emitLog(`ローカル曲: ${song.requestNo} の採点データを読めません: ${error}`);
    }
  }
}

/** 音符の列（開始ms・終了ms・音高）を検証し、時間順で重ならない形にそろえます。 */
function cleanScoreNotes(flat) {
  const notes = [];
  const list = Array.isArray(flat) ? flat : [];
  for (let i = 0; i + 2 < list.length && notes.length < MAXIMUM_SCORE_NOTES; i += 3) {
    const start = Math.floor(Number(list[i]));
    const end = Math.floor(Number(list[i + 1]));
    const pitch = Math.floor(Number(list[i + 2]));
    if (!(start >= 0 && end > start && end < 3600000 && pitch >= 20 && pitch <= 100)) continue;
    notes.push({ start, end, pitch });
  }
  notes.sort((a, b) => a.start - b.start);
  let previousEnd = -1;
  const result = [];
  for (const note of notes) {
    const start = Math.max(note.start, previousEnd);
    if (note.end <= start) continue;
    result.push({ start, end: note.end, pitch: note.pitch });
    previousEnd = note.end;
  }
  return result;
}

/**
 * DAMが採点基準データを復号した後に読む形式を作ります（調べた実データの構成）。
 * 見出し6個 -> 音符(開始,終了,音高,100) -> フレーズ(開始,終了) -> 24区間(開始,終了) -> 区間(開始,終了)。
 * いずれも32ビット整数（リトルエンディアン）で、時間はミリ秒です。
 */
function buildScoringReference(notes) {
  if (!notes.length) return null;
  const first = notes[0].start;
  const last = notes[notes.length - 1].end;
  // 歌詞1行ぶんのまとまり。音符どうしが1.5秒以上空くか、12秒を超えたら区切ります。
  // 各フレーズの最後の音符の番号を集めます。
  const lastOfPhrase = [];
  let begin = 0;
  for (let i = 0; i + 1 < notes.length; i += 1) {
    const gap = notes[i + 1].start - notes[i].end;
    const tooLong = notes[i + 1].end - notes[begin].start > 12000;
    if (gap >= 1500 || tooLong) {
      lastOfPhrase.push(i);
      begin = i + 1;
    }
  }
  lastOfPhrase.push(notes.length - 1);
  const ranges = [];
  for (let i = 0; i < lastOfPhrase.length; i += 1) {
    const isLast = i === lastOfPhrase.length - 1;
    const end = isLast ? last + 2000 : notes[lastOfPhrase[i]].end;
    const start = i === 0 ? Math.max(0, first - 4800) : ranges[i - 1][1] + 1;
    ranges.push([start, end]);
  }
  // 歌の区間を24等分します（実データと同じく、隣の区間と端を共有します）。
  const step = Math.floor((last - first) / 24);
  const segments = [];
  for (let i = 0; i < 24; i += 1) {
    segments.push([first + i * step, i === 23 ? last : first + (i + 1) * step]);
  }
  // 歌の前半と後半から、フレーズの区切りに合わせた2つの区間を選びます。
  const sectionAt = (fraction) => {
    const target = first + (last - first) * fraction;
    let best = ranges[0][1];
    for (const range of ranges) {
      if (Math.abs(range[1] - target) < Math.abs(best - target)) best = range[1];
    }
    return best;
  };
  const sections = [
    [sectionAt(0.3), Math.max(sectionAt(0.45), sectionAt(0.3) + 1)],
    [sectionAt(0.65), Math.max(sectionAt(0.8), sectionAt(0.65) + 1)],
  ];
  const values = [0, notes.length, ranges.length, 24, sections.length, Math.min(6500, ranges[0][0])];
  for (const note of notes) values.push(note.start, note.end, note.pitch, 100);
  for (const range of ranges) values.push(range[0], range[1]);
  for (const segment of segments) values.push(segment[0], segment[1]);
  for (const section of sections) values.push(section[0], section[1]);
  const bytes = new Uint8Array(values.length * 4);
  const view = new DataView(bytes.buffer);
  values.forEach((value, index) => view.setUint32(index * 4, value >>> 0, true));
  return bytes;
}

/** DAMが `Salted__` 形式の暗号文として受け取る、目印入りの偽の応答本文を作ります。 */
function fakeScoringBody(requestNo, plain) {
  const cipherLength = Math.ceil((plain.length + 1) / 16) * 16 + 16;
  const body = new Uint8Array(16 + cipherLength);
  body.set(utf8Bytes('Salted__LOCALSCR'), 0);
  body.set(utf8Bytes(`LOCALSC|${requestNo}|`), 16);
  return body;
}

function localSongByNumber(requestNo) {
  return localSongs.find((song) => song.requestNo === requestNo) || null;
}

/** 検索用に、大文字小文字・全角半角・カタカナひらがな・空白の違いをなくします。 */
function searchKey(text) {
  return String(text || '')
    .normalize('NFKC')
    .toLowerCase()
    .replace(/[ァ-ヶ]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0x60))
    .replace(/[\s・･'’"”!！?？,，.。、~〜\-ー_]/g, '');
}

function matchingLocalSongs(keyword) {
  const words = String(keyword || '').split(/[\s　]+/).map(searchKey).filter(Boolean);
  if (!words.length) return [];
  return localSongs.filter((song) => {
    const haystack = searchKey(
      [song.title, song.artist, song.titleYomi, song.artistYomi].join(' '),
    );
    return words.every((word) => haystack.includes(word));
  });
}

function toHiragana(text) {
  return String(text || '').replace(
    /[ァ-ヶ]/g,
    (c) => String.fromCharCode(c.charCodeAt(0) - 0x60),
  );
}

function toKatakana(text) {
  return String(text || '').replace(
    /[ぁ-ゖ]/g,
    (c) => String.fromCharCode(c.charCodeAt(0) + 0x60),
  );
}

/** 曲番号から、DAMの曲と重ならないコンテンツIDを作ります。 */
function localContentsId(song, offset) {
  return String(900000000 + Number(song.requestNo.replace('-', '')) * 10 + offset);
}

function localSearchRow(song) {
  const scored = localScores.has(song.requestNo);
  return {
    requestNo: song.requestNo,
    title: song.title,
    titleYomi: toHiragana(song.titleYomi),
    artistCode: 0,
    artist: song.artist,
    artistYomi: toHiragana(song.artistYomi),
    releaseDate: '',
    newReleaseFlag: '0',
    futureReleaseFlag: '0',
    newArrivalsFlag: '0',
    honninFlag: '0',
    animeFlag: '0',
    liveFlag: '0',
    kidsFlag: '0',
    guideVocalFlag: '0',
    damTomoMovieFlag: '0',
    damTomoPublicVocalFlag: '0',
    damTomoPublicMovieFlag: '0',
    damTomoPublicRecordingFlag: '0',
    scoreFlag: scored ? '1' : '0',
    myListFlag: '0',
    shift: '0',
    playbackTime: song.playtime,
  };
}

/** 検索結果の先頭へローカル曲を足します。DAMが該当なしを返したときは成功の形で作ります。 */
function appendLocalSearchRows(text, request) {
  const rows = request.matches.map(localSearchRow);
  let json = null;
  try {
    json = JSON.parse(text);
  } catch (_) {
    json = null;
  }
  const ok = json && json.result && json.result.statusCode === '0000' && Array.isArray(json.list);
  if (!ok) {
    return {
      result: { statusCode: '0000', message: '成功' },
      data: {
        pageCount: 1,
        hasPreview: '0',
        overFlag: '0',
        pageNo: 1,
        hasNext: '0',
        keyword: request.keyword,
        totalCount: rows.length,
      },
      list: rows,
    };
  }
  json.list = rows.concat(json.list);
  if (json.data && typeof json.data === 'object') {
    json.data.totalCount = (Number(json.data.totalCount) || 0) + rows.length;
  }
  return json;
}

function localDetailInfo(song) {
  return {
    result: { statusCode: '0000', message: '成功' },
    data: {
      artistCode: 0,
      artist: song.artist,
      requestNo: song.requestNo,
      title: song.title,
      titleYomi_Kana: toKatakana(song.titleYomi),
      firstLine: '',
    },
    list: [{
      mModelMusicInfoList: [{
        highlightTieUp: 'ローカル曲',
        shift: '0',
        thumbnailType: '',
        thumbnailPath: '',
        guideVocal: '0',
        playtime: String(song.playtime),
        contentTypeId: '2',
        contentTypeName: '差し込み映像',
        scoreLevel: localScores.has(song.requestNo) ? 3 : 0,
        technicalLevel: localScores.has(song.requestNo) ? 300 : 0,
        scoreFlag: localScores.has(song.requestNo) ? '1' : '0',
        lyricsImageFlag: '0',
        myListFlag: '0',
        damTomoPublicVocalFlag: '0',
        damTomoPublicMovieFlag: '0',
        damTomoPublicRecordingFlag: '0',
      }],
    }],
  };
}

function localDetail(song) {
  return {
    data: {
      artistCode: '0',
      artistName: song.artist,
      contentsId: localContentsId(song, 1),
      contentsYomi: toKatakana(song.titleYomi),
      firstLine: '',
      guideVocalList: [{
        contentsId: localContentsId(song, 2),
        duet: '0',
        playtime: String(song.playtime),
      }],
      musicTypeList: [{ musicTypeCode: '2', musicTypeId: '2', musicTypeName: '差込映像' }],
      mylist: '0',
      requestNo: song.requestNo,
      songDifficulty: localScores.has(song.requestNo) ? '3' : '0',
      songTechDifficulty: localScores.has(song.requestNo) ? '300' : '0',
      thumbnailPathList: [{ thumbnailPath: '', thumbnailType: '' }],
      value: song.title,
    },
    message: '',
    status: 'OK',
    statusCode: '0000',
    type: '2.0',
  };
}

function localStreaming(song) {
  // ファイル名の曲番号を既存の動画差し替えが読み取り、ローカル動画のURLへ置き換えます。
  const url = `${LOCAL_STREAMING_ORIGIN}${song.requestNo}sk_1.mp4.m3u8`;
  return {
    data: { karaokeContentsId: localContentsId(song, 1) },
    list: [{
      contentsId: localContentsId(song, 2),
      duet: 'normal',
      highBitrateUrl: url,
      lowBitrateUrl: url,
    }],
    message: '',
    status: 'OK',
    statusCode: '0000',
    type: '2.2',
  };
}

/** 送信本文（JSONまたはフォーム）から、要求の項目を読みます。 */
function requestFields(pointer, length) {
  if (pointer.isNull() || length <= 0 || length > 64 * 1024) return {};
  const text = pointer.readUtf8String(length) || '';
  if (text.startsWith('{')) {
    try {
      const json = JSON.parse(text);
      return json && typeof json === 'object' ? json : {};
    } catch (_) {
      return {};
    }
  }
  const fields = {};
  for (const pair of text.split('&')) {
    const index = pair.indexOf('=');
    if (index <= 0) continue;
    try {
      fields[decodeURIComponent(pair.slice(0, index))] =
        decodeURIComponent(pair.slice(index + 1).replace(/\+/g, ' '));
    } catch (_) {
      // 解釈できない項目は使いません。
    }
  }
  return fields;
}

/** 要求の送信時に、書き換える対象かを決めます。 */
function classifyLocalRequest(state, fields) {
  if (!localSongs.length) return null;
  if (state.api === 'search') {
    const page = Number(fields.pageNo || 1);
    if (page !== 1) return null;
    const matches = matchingLocalSongs(fields.keyword);
    return matches.length ? { matches, keyword: String(fields.keyword || '') } : null;
  }
  const song = localSongByNumber(String(fields.requestNo || ''));
  if (!song) return null;
  // 採点データを持たない曲は、DAMの応答（採点なし）をそのまま渡します。
  if (state.api === 'scoring' && !localScores.has(song.requestNo)) return null;
  return { song };
}

/** 元の応答本文を受け取り、DAMへ渡す本文を作ります。 */
function rewriteLocalResponse(state, original) {
  const request = state.request;
  if (state.api === 'search') {
    emitLog(`ローカル曲: 検索「${request.keyword}」に${request.matches.length}曲を追加しました`);
    return JSON.stringify(appendLocalSearchRows(original, request));
  }
  const song = request.song;
  let originalStatus = '';
  let originalTitle = '';
  try {
    const json = JSON.parse(original);
    originalStatus = String(
      (json && json.result && json.result.statusCode) || (json && json.statusCode) || '',
    );
    const data = json && json.data;
    originalTitle = String((data && (data.title || data.value)) || '');
  } catch (_) {
    originalStatus = original ? '(JSON以外)' : '(空)';
  }
  // DAMが成功を返しても中身が空なら、存在しない番号です。曲名が入っているときだけ知らせます。
  if (originalTitle) {
    emitLog(`ローカル曲: ${song.requestNo} はDAMの曲「${originalTitle}」と重なっています`);
  }
  let body = null;
  if (state.api === 'scoring') {
    const score = localScores.get(song.requestNo);
    emitLog(`ローカル曲: ${song.requestNo} の採点基準データを差し替えました（${score.notes}音）`);
    return fakeScoringBody(song.requestNo, score.plain);
  }
  if (state.api === 'detailInfo') body = localDetailInfo(song);
  else if (state.api === 'detail') body = localDetail(song);
  else if (state.api === 'streaming') body = localStreaming(song);
  emitLog(
    `ローカル曲: ${song.requestNo} の${state.api}応答を` +
      `${body ? '差し替えました' : 'そのまま渡します'}（DAMの応答 ${originalStatus || '-'}）`,
  );
  return body ? JSON.stringify(body) : null;
}

/** 偽の暗号文を復号する呼び出しだけ、結果を作った基準データに差し替えます。 */
function installLocalScoreDecryptHook() {
  const decrypt = Process.getModuleByName('bcrypt.dll').getExportByName('BCryptDecrypt');
  Interceptor.attach(decrypt, {
    onEnter(args) {
      this.score = null;
      const length = args[2].toUInt32();
      if (length < 32 || args[1].isNull()) return;
      let marker = '';
      try {
        marker = args[1].readUtf8String(16) || '';
      } catch (_) {
        return;
      }
      const match = LOCAL_SCORE_MARKER.exec(marker);
      if (!match) return;
      this.score = localScores.get(match[1]) || null;
      this.output = args[6];
      this.capacity = args[7].toUInt32();
      this.resultSize = args[8];
    },
    onLeave(result) {
      const score = this.score;
      if (!score) return;
      const plain = score.plain;
      if (this.output.isNull() || this.capacity < plain.length || this.resultSize.isNull()) {
        emitLog(`ローカル曲: 採点基準データの出力先が足りません（${this.capacity}<${plain.length}）`);
        return;
      }
      this.output.writeByteArray(plain.buffer);
      this.resultSize.writeU32(plain.length);
      result.replace(ptr(0));
      emitLog(`ローカル曲: 採点基準データの復号結果を差し替えました（${plain.length}バイト）`);
    },
  });
}

function utf8Bytes(text) {
  const bytes = [];
  for (const char of text) {
    let code = char.codePointAt(0);
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      bytes.push(
        0xf0 | (code >> 18),
        0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f),
      );
    }
  }
  return new Uint8Array(bytes);
}

/** WinHTTPの要求を見張り、ローカル曲に関わる応答だけ書き換えます。 */
function installLocalSongHooks() {
  installLocalScoreDecryptHook();
  const winhttp = Process.getModuleByName('winhttp.dll');
  const exportOf = (name) => winhttp.getExportByName(name);
  const readDataAddress = exportOf('WinHttpReadData');
  const availableAddress = exportOf('WinHttpQueryDataAvailable');
  const originalRead = new NativeFunction(
    readDataAddress,
    'int',
    ['pointer', 'pointer', 'uint32', 'pointer'],
  );
  const originalAvailable = new NativeFunction(availableAddress, 'int', ['pointer', 'pointer']);

  Interceptor.attach(exportOf('WinHttpOpenRequest'), {
    onEnter(args) {
      this.path = args[2].isNull() ? '' : (args[2].readUtf16String() || '');
    },
    onLeave(handle) {
      if (handle.isNull()) return;
      const path = this.path.split('?', 1)[0];
      const api = LOCAL_SONG_APIS.find(([, pattern]) => pattern.test(path));
      if (api) localHttpRequests.set(handle.toString(), { api: api[0], request: null });
    },
  });
  Interceptor.attach(exportOf('WinHttpSendRequest'), {
    onEnter(args) {
      const state = localHttpRequests.get(args[0].toString());
      if (!state) return;
      state.request = null;
      state.body = null;
      try {
        state.request = classifyLocalRequest(state, requestFields(args[3], args[4].toUInt32()));
      } catch (error) {
        emitLog(`ローカル曲: 要求を読み取れません: ${error}`);
      }
    },
  });
  Interceptor.attach(exportOf('WinHttpCloseHandle'), {
    onEnter(args) {
      localHttpRequests.delete(args[0].toString());
    },
  });
  // 置き換えた応答は、DAMのサーバーが別の状態コードを返しても成功として読ませます。
  Interceptor.attach(exportOf('WinHttpQueryHeaders'), {
    onEnter(args) {
      this.state = localHttpRequests.get(args[0].toString());
      this.level = args[1].toUInt32();
      this.buffer = args[3];
      this.length = args[4];
    },
    onLeave(result) {
      const state = this.state;
      if (!state || !state.request || state.api === 'search') return;
      if (result.toInt32() === 0 || this.buffer.isNull() || (this.level & 0xffff) !== 19) return;
      if (this.level & 0x20000000) {
        this.buffer.writeU32(200);
      } else if (!this.length.isNull() && this.length.readU32() >= 8) {
        this.buffer.writeUtf16String('200');
        this.length.writeU32(6);
      }
    },
  });

  /** 元の応答を最後まで読み、書き換えた本文を用意します。失敗したら書き換えません。 */
  const prepareBody = (handle, state) => {
    if (state.body) return state.body;
    state.draining = true;
    const chunks = [];
    let total = 0;
    try {
      const available = Memory.alloc(4);
      const read = Memory.alloc(4);
      for (;;) {
        if (!originalAvailable(handle, available)) break;
        const size = available.readU32();
        if (size === 0) break;
        const buffer = Memory.alloc(size);
        if (!originalRead(handle, buffer, size, read)) break;
        const count = read.readU32();
        if (count === 0) break;
        chunks.push(buffer.readByteArray(count));
        total += count;
      }
    } finally {
      state.draining = false;
    }
    const joined = Memory.alloc(Math.max(total, 1));
    let offset = 0;
    for (const chunk of chunks) {
      joined.add(offset).writeByteArray(chunk);
      offset += chunk.byteLength;
    }
    const original = total > 0 ? (joined.readUtf8String(total) || '') : '';
    let text = null;
    try {
      text = rewriteLocalResponse(state, original);
    } catch (error) {
      emitLog(`ローカル曲: 応答を書き換えられません: ${error}`);
    }
    if (text === null) state.body = new Uint8Array(joined.readByteArray(total) || []);
    else if (typeof text === 'string') state.body = utf8Bytes(text);
    else state.body = text;
    state.offset = 0;
    return state.body;
  };

  const activeState = (handle) => {
    const state = localHttpRequests.get(handle.toString());
    return state && state.request && !state.draining ? state : null;
  };

  const availableReplacement = new NativeCallback((handle, available) => {
    const state = activeState(handle);
    if (!state || available.isNull()) return originalAvailable(handle, available);
    try {
      const body = prepareBody(handle, state);
      available.writeU32(body.length - state.offset);
      return 1;
    } catch (error) {
      emitLog(`ローカル曲: 応答の準備に失敗しました: ${error}`);
      state.request = null;
      return originalAvailable(handle, available);
    }
  }, 'int', ['pointer', 'pointer']);
  Interceptor.replace(availableAddress, availableReplacement);
  retainedNativeCallbacks.push(availableReplacement);

  const readReplacement = new NativeCallback((handle, buffer, size, read) => {
    const state = activeState(handle);
    // 非同期の読み取り（read が NULL）は書き換えず、そのまま渡します。
    if (!state || read.isNull()) return originalRead(handle, buffer, size, read);
    try {
      const body = prepareBody(handle, state);
      const count = Math.min(size, body.length - state.offset);
      if (count > 0) {
        buffer.writeByteArray(body.slice(state.offset, state.offset + count).buffer);
      }
      state.offset += count;
      read.writeU32(count);
      return 1;
    } catch (error) {
      emitLog(`ローカル曲: 応答を渡せません: ${error}`);
      state.request = null;
      return originalRead(handle, buffer, size, read);
    }
  }, 'int', ['pointer', 'pointer', 'uint32', 'pointer']);
  Interceptor.replace(readDataAddress, readReplacement);
  retainedNativeCallbacks.push(readReplacement);
}
