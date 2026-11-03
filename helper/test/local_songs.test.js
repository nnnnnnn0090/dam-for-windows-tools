// Project: DAM for Windows Tools
// File: local_songs.test.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-11-03

import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

import { extractVideoAssetId } from '../identity.js';

/** Fridaに依存しない関数だけを、最小の代役で読み込みます。 */
function loadLocalSongs(files = {}) {
  const source = fs.readFileSync(
    new URL('../agent/25_local_songs.js', import.meta.url),
    'utf8',
  );
  const logs = [];
  const factory = new Function(
    'emitLog',
    'cleanText',
    'retainedNativeCallbacks',
    'File',
    `${source}
    return { setLocalSongList, matchingLocalSongs, appendLocalSearchRows,
      rewriteLocalResponse, requestFields, utf8Bytes, cleanScoreNotes,
      buildScoringReference, fakeScoringBody, localScores };`,
  );
  const api = factory(
    (message) => logs.push(message),
    (value) => String(value == null ? '' : value).trim(),
    [],
    {
      readAllText(path) {
        if (!(path in files)) throw new Error(`no such file: ${path}`);
        return files[path];
      },
    },
  );
  return { ...api, logs };
}

const song = {
  requestNo: '9999-01',
  title: 'where the light leads us',
  artist: 'fripSide',
  titleYomi: 'ホエアザライトリーズアス',
  artistYomi: 'フリップサイド',
  playtime: 245,
};

/** 8秒歌って2秒休む旋律（1音0.45秒）を、開始・終了・音高の平らな配列で作ります。 */
function melody(phrases = 3) {
  const flat = [];
  for (let p = 0; p < phrases; p += 1) {
    for (let i = 0; i < 16; i += 1) {
      const start = 10000 + p * 10000 + i * 500;
      flat.push(start, start + 450, 60 + (i % 5));
    }
  }
  return flat;
}

test('一覧は曲番号の形を検証し、不正な行を捨てる', () => {
  const agent = loadLocalSongs();
  assert.equal(agent.setLocalSongList([song, { requestNo: '6343-03x', title: 'x' }, null]), 1);
});

test('キーワードは大文字小文字・かなの種類・空白の違いを無視して照合する', () => {
  const agent = loadLocalSongs();
  agent.setLocalSongList([song]);
  for (const keyword of ['fripside', 'FRIPSIDE light', 'ふりっぷさいど', 'ホエアザ', 'where the light']) {
    assert.equal(agent.matchingLocalSongs(keyword).length, 1, keyword);
  }
  assert.equal(agent.matchingLocalSongs('GARNET CROW').length, 0);
  assert.equal(agent.matchingLocalSongs('').length, 0);
});

test('検索結果の先頭へ追加し、件数を増やす。該当なしの応答は成功の形で作る', () => {
  const agent = loadLocalSongs();
  agent.setLocalSongList([song]);
  const request = { matches: agent.matchingLocalSongs('fripside'), keyword: 'fripside' };
  const original = JSON.stringify({
    result: { statusCode: '0000', message: '成功' },
    data: { totalCount: 10, pageNo: 1 },
    list: [{ requestNo: '1234-56', title: 'real' }],
  });
  const merged = agent.appendLocalSearchRows(original, request);
  assert.deepEqual(merged.list.map((row) => row.requestNo), ['9999-01', '1234-56']);
  assert.equal(merged.data.totalCount, 11);
  assert.equal(merged.list[0].scoreFlag, '0', '採点データのない曲は採点なし');
  assert.equal(merged.list[0].titleYomi, 'ほえあざらいとりーずあす');

  const empty = agent.appendLocalSearchRows(
    JSON.stringify({ result: { statusCode: '9001', message: '該当なし' } }),
    request,
  );
  assert.equal(empty.result.statusCode, '0000');
  assert.equal(empty.data.totalCount, 1);
  assert.equal(empty.list.length, 1);
});

test('曲情報・配信URLは作った応答へ置き換え、配信URLから曲番号を読める', () => {
  const agent = loadLocalSongs();
  agent.setLocalSongList([song]);
  const request = { song: agent.matchingLocalSongs('fripside')[0] };
  const streaming = JSON.parse(agent.rewriteLocalResponse(
    { api: 'streaming', request },
    JSON.stringify({ statusCode: '9999', status: 'NG' }),
  ));
  assert.equal(streaming.statusCode, '0000');
  assert.equal(extractVideoAssetId(streaming.list[0].highBitrateUrl), '9999-01');

  const detail = JSON.parse(agent.rewriteLocalResponse({ api: 'detailInfo', request }, ''));
  assert.equal(detail.data.requestNo, '9999-01');
  assert.equal(detail.list[0].mModelMusicInfoList[0].playtime, '245');
  assert.equal(detail.list[0].mModelMusicInfoList[0].scoreFlag, '0');
});

test('要求本文はJSONとフォームの両方から読む', () => {
  const agent = loadLocalSongs();
  const asPointer = (text) => {
    const bytes = Buffer.from(text, 'utf8');
    return { isNull: () => false, readUtf8String: () => text, length: bytes.length };
  };
  const json = asPointer('{"requestNo":"9999-01","keyword":"x"}');
  assert.equal(agent.requestFields(json, json.length).requestNo, '9999-01');
  const form = asPointer('charset=UTF-8&requestNo=9999-01&keyword=fri%20side');
  const fields = agent.requestFields(form, form.length);
  assert.equal(fields.requestNo, '9999-01');
  assert.equal(fields.keyword, 'fri side');
});

test('UTF-8へのエンコードはNodeと一致する', () => {
  const agent = loadLocalSongs();
  const text = 'fripSide「where the light leads us」🎤';
  assert.deepEqual(Buffer.from(agent.utf8Bytes(text)), Buffer.from(text, 'utf8'));
});

test('音符は不正な値を捨て、時間順で重ならない形にそろえる', () => {
  const agent = loadLocalSongs();
  const notes = agent.cleanScoreNotes([
    2000, 3000, 60, // 正常
    500, 1000, 62, // 先に並べ替わる
    2500, 3500, 64, // 前の音と重なる -> 開始を前の終わりへ
    4000, 3900, 60, // 終わりが開始より前 -> 捨てる
    5000, 6000, 10, // 音高が範囲外 -> 捨てる
  ]);
  assert.deepEqual(
    notes.map((n) => [n.start, n.end, n.pitch]),
    [[500, 1000, 62], [2000, 3000, 60], [3000, 3500, 64]],
  );
});

test('採点基準データは、調べた実データと同じ構成で作る', () => {
  const agent = loadLocalSongs();
  const notes = agent.cleanScoreNotes(melody(3));
  const bytes = agent.buildScoringReference(notes);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const ints = Array.from({ length: bytes.length / 4 }, (_, i) => view.getUint32(i * 4, true));

  const [kind, noteCount, phraseCount, segmentCount, sectionCount, lead] = ints;
  assert.equal(kind, 0);
  assert.equal(noteCount, 48);
  assert.equal(phraseCount, 3, '2秒休むたびではなく、1.5秒以上の空きで区切る');
  assert.equal(segmentCount, 24);
  assert.equal(sectionCount, 2);
  assert.equal(lead, 5200, '最初のフレーズの開始（最初の音の4.8秒前）');
  assert.equal(
    ints.length,
    6 + 4 * noteCount + 2 * phraseCount + 2 * segmentCount + 2 * sectionCount,
  );

  const at = 6;
  assert.deepEqual(ints.slice(at, at + 4), [10000, 10450, 60, 100]);
  const phrasesAt = at + 4 * noteCount;
  const phrases = [];
  for (let i = 0; i < phraseCount; i += 1) {
    phrases.push([ints[phrasesAt + 2 * i], ints[phrasesAt + 2 * i + 1]]);
  }
  assert.equal(phrases[0][0], 5200);
  for (let i = 0; i < phraseCount - 1; i += 1) {
    assert.equal(phrases[i + 1][0], phrases[i][1] + 1, 'フレーズは隙間なくつながる');
  }
  assert.equal(phrases[0][1], 17950, 'フレーズの終わりは最後の音符の終わり');
  assert.equal(phrases[2][1], 37950 + 2000, '最後は歌い終わりの2秒後');

  const segmentsAt = phrasesAt + 2 * phraseCount;
  const first = ints[segmentsAt];
  const last = ints[segmentsAt + 47];
  assert.equal(first, 10000);
  assert.equal(last, 37950, '最後の音符の終わり');
  for (let i = 0; i < 23; i += 1) {
    assert.equal(ints[segmentsAt + 2 * i + 1], ints[segmentsAt + 2 * i + 2], '区間は隣と端を共有');
  }
});

test('採点基準データは偽の暗号文に包み、目印から曲番号を読める', () => {
  const agent = loadLocalSongs();
  const plain = agent.buildScoringReference(agent.cleanScoreNotes(melody(2)));
  const body = agent.fakeScoringBody('9999-01', plain);
  assert.equal(Buffer.from(body.subarray(0, 8)).toString(), 'Salted__');
  const cipher = body.subarray(16);
  assert.equal(cipher.length % 16, 0, 'AESのブロック長の倍数');
  assert.ok(cipher.length >= plain.length + 16, '復号後の長さより十分に長い');
  assert.equal(Buffer.from(cipher.subarray(0, 16)).toString(), 'LOCALSC|9999-01|');
});

test('採点データはファイルから読み、あれば採点あり・なければ採点なしで返す', () => {
  const agent = loadLocalSongs({ 'C:\\data\\9999-01.json': JSON.stringify(melody(2)) });
  agent.setLocalSongList([
    { ...song, scorePath: 'C:\\data\\9999-01.json' },
    { ...song, requestNo: '9999-02', title: 'no data' },
    { ...song, requestNo: '9999-03', title: 'broken', scorePath: 'C:\\data\\missing.json' },
  ]);
  assert.deepEqual([...agent.localScores.keys()], ['9999-01']);
  assert.match(agent.logs.join('\n'), /9999-03 の採点データを読めません/);

  const request = { matches: [{ ...song, requestNo: '9999-01' }], keyword: 'x' };
  const merged = agent.appendLocalSearchRows('', request);
  assert.equal(merged.list[0].scoreFlag, '1');
  const rewritten = agent.rewriteLocalResponse(
    { api: 'scoring', request: { song: { ...song, requestNo: '9999-01' } } },
    '',
  );
  assert.ok(rewritten instanceof Uint8Array);
  assert.equal(Buffer.from(rewritten.subarray(0, 8)).toString(), 'Salted__');
});
