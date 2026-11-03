// Project: DAM for Windows Tools
// File: app.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

'use strict';

const $ = (id) => document.getElementById(id);
const all = (selector) => document.querySelectorAll(selector);

const LIST_TITLES = {
  ranking: 'ランキング',
  new: '新曲',
  favorites: 'お気に入り',
  history: 'りれき',
};
const MODE_PLACEHOLDERS = {
  keyword: '曲名 / 歌手名 / キーワードでさがす',
  title: '曲名でさがす',
  artist: '歌手名でさがす',
};

let state = { connected: false, playing: false, paused: false, key: 0, damScoring: false, title: '', artist: '', videoId: '', confirmation: null };
let stateRequest = null;
let busy = false;
let toastTimer = 0;

let listKind = 'search';
let searchMode = 'keyword';
let listQuery = '';
let listSequence = 0;
let listRequest = Promise.resolve();

let selectedSong = null;
let selectedDetail = null;
let detailLoading = false;
let detailSequence = 0;
let reserveKey = 0;
let scoringRequested = false;
let playType = 'standard';

let openDrawerName = '';
let drawerTab = 'queue';
let queueRows = [];
let selectedQueueToken = '';

// ---- 共通 ----

/** 同一OriginのPOST APIを呼び、失敗応答を利用者向けの例外にします。 */
async function api(path, body = {}) {
  const response = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  let data = {};
  try { data = await response.json(); } catch (_) { /* 本文なし */ }
  if (!response.ok) throw new Error(data.error || '通信に失敗しました');
  return data;
}

/** textContent だけで文字を入れた要素を作ります。 */
function node(tag, text, className) {
  const element = document.createElement(tag);
  if (text !== undefined) element.textContent = text;
  if (className) element.className = className;
  return element;
}

/** 同梱スプライトのアイコンを作ります。 */
function icon(name) {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  const use = document.createElementNS(ns, 'use');
  svg.setAttribute('aria-hidden', 'true');
  svg.classList.add('icon');
  use.setAttribute('href', `#icon-${name}`);
  svg.append(use);
  return svg;
}

function toast(text) {
  $('toast').textContent = text;
  $('toast').classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => $('toast').classList.remove('show'), 2200);
}

/** DAMと同じ表記（標準・♯n・♭n）です。 */
function keyText(key) {
  return key > 0 ? `♯${key}` : key < 0 ? `♭${-key}` : '標準';
}

// ---- 演奏状態 ----

function renderState(next) {
  state = next;
  const playing = next.playing === true;
  $('lamp').classList.toggle('on', next.connected === true);
  $('connection').textContent = next.connected ? 'DAM接続中' : 'DAM未接続';

  $('nowTitle').textContent = playing ? (next.title || '曲名取得中') : '再生中の曲はありません';
  $('nowArtist').textContent = playing ? (next.artist || '—') : '—';
  $('nowId').textContent = playing ? (next.videoId || '') : '';
  $('nowKey').textContent = keyText(next.key || 0);
  const playPause = $('playPause');
  playPause.dataset.control = next.paused ? 'resume' : 'pause';
  $('playPauseIcon').setAttribute('href', next.paused ? '#icon-play' : '#icon-pause');
  all('[data-control]').forEach((button) => { button.disabled = !playing || busy; });
  $('keyStop').disabled = !playing || busy;

  const scoring = next.damScoring === true;
  $('keyScoring').classList.toggle('on', scoring);
  $('keyScoring').disabled = !next.connected || busy;
  $('playerScoring').classList.toggle('on', scoring);
  $('playerScoring').querySelector('b').textContent = scoring ? 'ON' : 'OFF';
  $('playerScoring').disabled = !next.connected || busy;

  renderConfirmation(next.confirmation);
  if (openDrawerName === 'queue' && drawerTab === 'queue') renderQueue();
}

/** 状態取得を1本にまとめ、応答待ちの間は要求を積み重ねません。 */
function refreshState(silent = true) {
  if (stateRequest) return stateRequest;
  stateRequest = api('api/state')
    .then(renderState)
    .catch((error) => {
      renderState({ ...state, connected: false, confirmation: null });
      if (!silent) toast(error.message);
    })
    .finally(() => { stateRequest = null; });
  return stateRequest;
}

async function pollState() {
  if (!busy) await refreshState(true);
  setTimeout(pollState, 1000);
}

/** 演奏操作を送り、結果の状態を反映します。 */
async function control(action, message) {
  if (busy) return;
  busy = true;
  renderState(state);
  try {
    renderState(await api('api/control', { action }));
    if (message) toast(message);
  } catch (error) {
    toast(error.message);
  } finally {
    busy = false;
    renderState(state);
  }
}

const CONTROL_MESSAGES = {
  pause: '一時停止しました',
  resume: '再開しました',
  restart: '最初から歌いなおします',
  stop: '演奏を中止しました',
  keyUp: 'キーを上げました',
  keyDown: 'キーを下げました',
  keyReset: 'キーを標準に戻しました',
};

function runControl(action) {
  if (action === 'stop' && !confirm('演奏を中止しますか？')) return;
  control(action, CONTROL_MESSAGES[action]);
}

function toggleScoring() {
  if (!state.connected) return;
  const wanted = state.damScoring !== true;
  control(wanted ? 'scoringOn' : 'scoringOff', `採点を${wanted ? 'ON' : 'OFF'}にしました`);
}

function renderConfirmation(confirmation) {
  const active = !!confirmation && typeof confirmation.message === 'string';
  $('damConfirmation').hidden = !active;
  if (!active) return;
  $('damConfirmationMessage').textContent = confirmation.message || 'DAM本体で選択を待っています';
  $('damConfirmationYes').classList.toggle('selected', confirmation.selected === 'yes');
  $('damConfirmationNo').classList.toggle('selected', confirmation.selected === 'no');
  $('damConfirmationYes').disabled = $('damConfirmationNo').disabled = busy;
}

function answerConfirmation(yes) {
  if (!state.confirmation) return;
  control(yes ? 'confirmYes' : 'confirmNo', `「${yes ? 'はい' : 'いいえ'}」を選択しました`);
}

// ---- 画面と分類タブ ----

function showView(name) {
  all('.view').forEach((view) => view.classList.toggle('active', view.id === `view-${name}`));
  if (name === 'home') $('hits').textContent = '';
}

function highlightTab(name) {
  all('.tab').forEach((tab) => tab.classList.toggle('active', tab.dataset.tab === name));
}

function selectTab(name) {
  if (name === 'home') {
    highlightTab('home');
    showView('home');
    return;
  }
  openList(name);
}

function setSearchMode(mode) {
  searchMode = mode;
  $('query').placeholder = MODE_PLACEHOLDERS[mode];
  all('.segment').forEach((segment) => segment.classList.toggle('active', segment.dataset.mode === mode));
}

/** 一覧を開き、検索または一覧取得を行います。古い応答は表示しません。 */
async function openList(kind, query = '') {
  listKind = kind;
  listQuery = query;
  highlightTab(kind === 'search' ? 'home' : kind);
  showView('list');
  $('segments').hidden = kind !== 'search';
  $('listTitle').textContent = kind === 'search' ? `# ${query}` : `# ${LIST_TITLES[kind]}`;
  $('hits').textContent = '';
  $('results').replaceChildren(node('div', '読み込み中…', 'empty'));
  $('view-list').scrollTop = 0;

  const sequence = ++listSequence;
  const mode = kind === 'search' ? searchMode : kind;
  const request = listRequest.catch(() => {}).then(() => {
    if (sequence !== listSequence) return null;
    return kind === 'history' ? api('api/history') : api('api/search', { query, mode });
  });
  listRequest = request;
  try {
    const data = await request;
    if (data === null || sequence !== listSequence) return;
    const songs = Array.isArray(data.songs) ? data.songs : Array.isArray(data.rows) ? data.rows : [];
    $('hits').textContent = String(songs.length);
    renderSongs($('results'), songs, kind === 'ranking');
  } catch (error) {
    if (sequence !== listSequence) return;
    $('results').replaceChildren(node('div', error.message, 'empty'));
  }
}

function songRow(song, rank) {
  const row = node('button', undefined, 'songrow');
  row.type = 'button';
  let mark;
  if (rank) {
    mark = node('span', String(rank), rank <= 3 ? 'rank' : 'rank plain');
  } else {
    mark = node('span', undefined, 'rowmark');
    mark.append(icon(song.kind === 'artist' ? 'user' : 'music'));
  }
  const text = node('span', undefined, 'rowtext');
  if (song.kind === 'artist') {
    text.append(node('span', song.artist || '歌手名不明', 'rowtitle'));
    const more = node('span', undefined, 'rowartist');
    more.append(node('span', 'この歌手の曲'));
    text.append(more);
    row.onclick = () => searchArtist(song.artist);
  } else {
    const artist = node('span', undefined, 'rowartist');
    artist.append(icon('user'), node('span', song.artist || '—'));
    text.append(node('span', song.title || '曲名不明', 'rowtitle'), artist);
    row.onclick = () => openDetail(song);
  }
  row.append(mark, text);
  return row;
}

function renderSongs(list, songs, ranked) {
  list.replaceChildren();
  if (!songs.length) {
    list.append(node('div', '該当する曲はありません', 'empty'));
    return;
  }
  songs.forEach((song, index) => list.append(songRow(song, ranked ? index + 1 : 0)));
}

function searchArtist(artist) {
  if (!artist) return;
  closeDetail();
  closeDrawers();
  setSearchMode('keyword');
  $('query').value = artist;
  openList('search', artist);
}

function submitSearch() {
  const query = $('query').value.trim();
  if (!query) {
    toast('さがす言葉を入れてください');
    $('query').focus();
    return;
  }
  $('query').blur();
  openList('search', query);
}

/** 「もどる」：開いている画面を1段だけ閉じます。 */
function goBack() {
  if (!$('detail').hidden) closeDetail();
  else if (openDrawerName) closeDrawers();
  else if ($('view-list').classList.contains('active')) selectTab('home');
}

function goTop() {
  closeDetail();
  closeDrawers();
  selectTab('home');
}

// ---- 曲の詳細 ----

function supportedPlayTypes() {
  return Array.isArray(selectedDetail?.playTypes) ? selectedDetail.playTypes : [];
}

function renderDetail() {
  const supported = supportedPlayTypes();
  const ready = !detailLoading && !!selectedDetail && !busy;
  $('featureArtist').classList.toggle('on', supported.includes('artistVideo'));
  $('featureGuide').classList.toggle('on', supported.includes('guideVocal'));

  const guide = $('optionGuide');
  guide.disabled = !ready || !supported.includes('guideVocal');
  guide.classList.toggle('on', playType === 'guideVocal');
  guide.querySelector('b').textContent = playType === 'guideVocal' ? 'ON' : 'OFF';
  const artist = $('optionArtist');
  artist.disabled = !ready || !supported.includes('artistVideo');
  artist.classList.toggle('on', playType === 'artistVideo');
  artist.querySelector('b').textContent = playType === 'artistVideo' ? 'ON' : 'OFF';
  const scoring = $('optionScoring');
  scoring.disabled = !ready;
  scoring.classList.toggle('on', scoringRequested);
  scoring.querySelector('b').textContent = scoringRequested ? 'ON' : '指定なし';

  all('.keydot').forEach((dot, index) => dot.classList.toggle('current', index - 7 === reserveKey));
  $('keyTrack').setAttribute('aria-valuenow', String(reserveKey));
  $('reserveKeyDown').disabled = !ready || reserveKey <= -7;
  $('reserveKeyUp').disabled = !ready || reserveKey >= 7;
  $('reserveKeyReset').disabled = !ready || reserveKey === 0;
  const original = selectedDetail ? Number(selectedDetail.originalKey) || 0 : null;
  const marker = $('keyOriginal');
  marker.hidden = original === null || original < -7 || original > 7;
  if (!marker.hidden) marker.style.left = `${((original + 7.5) / 15) * 100}%`;

  const canReserve = ready && supported.includes(playType);
  $('reserveNormal').disabled = $('reserveCutIn').disabled = $('reserveOriginal').disabled = !canReserve;
  const favorite = selectedSong?.favorite === true;
  $('detailFavorite').classList.toggle('on', favorite);
  $('detailFavorite').disabled = $('detailFavoriteButton').disabled = detailLoading || busy || !selectedSong?.token;
  $('detailFavoriteButton').textContent = favorite ? 'お気に入り解除' : 'お気に入り';
}

function setReserveKey(key) {
  reserveKey = Math.max(-7, Math.min(7, key));
  renderDetail();
}

function togglePlayType(type) {
  const supported = supportedPlayTypes();
  if (playType === type) {
    playType = supported.includes('standard') ? 'standard' : type;
  } else if (supported.includes(type)) {
    playType = type;
  }
  renderDetail();
}

async function openDetail(song) {
  const sequence = ++detailSequence;
  selectedSong = song;
  selectedDetail = null;
  detailLoading = true;
  reserveKey = 0;
  scoringRequested = false;
  playType = 'standard';
  $('detailTitle').textContent = song.title || '曲名不明';
  $('detailArtist').textContent = song.artist || '—';
  $('detailArtist').disabled = !song.artist;
  $('detailId').textContent = song.videoId || '';
  $('detailStartLyric').textContent = '取得中…';
  $('detailMessage').textContent = '曲情報を取得しています…';
  $('detail').hidden = false;
  renderDetail();
  try {
    const data = await api('api/detail', { token: song.token });
    if (sequence !== detailSequence) return;
    const detail = data.detail;
    if (!detail || !Array.isArray(detail.playTypes)) throw new Error('曲情報を取得できません');
    selectedDetail = detail;
    if (detail.videoId) {
      song.videoId = detail.videoId;
      $('detailId').textContent = detail.videoId;
    }
    $('detailStartLyric').textContent = detail.startLyric || '—';
    if (!detail.playTypes.includes(playType)) playType = detail.playTypes[0] || 'standard';
    $('detailMessage').textContent = detail.playTypes.length ? '' : '予約できる演奏タイプがありません';
  } catch (error) {
    if (sequence !== detailSequence) return;
    $('detailStartLyric').textContent = '取得できません';
    $('detailMessage').textContent = error.message;
  } finally {
    if (sequence === detailSequence) {
      detailLoading = false;
      renderDetail();
    }
  }
}

function closeDetail() {
  detailSequence++;
  $('detail').hidden = true;
}

/** mode: normal / cutIn / originalKey */
async function reserve(mode) {
  const song = selectedSong;
  if (!song?.token || !selectedDetail || !supportedPlayTypes().includes(playType) || busy) return;
  busy = true;
  renderDetail();
  $('detailMessage').textContent = '予約しています…';
  try {
    const data = await api('api/reserve', { token: song.token, mode, key: reserveKey, scoring: scoringRequested, playType });
    const message = data.message || (data.accepted ? '予約しました' : '予約できませんでした');
    toast(message);
    if (data.accepted) {
      closeDetail();
      if (openDrawerName === 'queue') refreshQueue(true);
    } else {
      $('detailMessage').textContent = message;
    }
  } catch (error) {
    $('detailMessage').textContent = error.message;
    toast(error.message);
  } finally {
    busy = false;
    renderDetail();
  }
}

async function toggleFavorite() {
  const song = selectedSong;
  if (!song?.token || detailLoading || busy) return;
  busy = true;
  renderDetail();
  try {
    const data = await api('api/favorite', { token: song.token, favorite: !song.favorite });
    if (data.accepted) song.favorite = data.favorite;
    toast(data.message || '更新しました');
  } catch (error) {
    toast(error.message);
  } finally {
    busy = false;
    renderDetail();
  }
}

function buildKeyDots() {
  const dots = $('keyDots');
  for (let index = 0; index < 15; index++) {
    const dot = node('span', undefined, 'keydot');
    dot.style.setProperty('--h', String(225 + (index / 14) * 105));
    dot.onclick = () => { if (!detailLoading && selectedDetail) setReserveKey(index - 7); };
    dots.append(dot);
  }
}

// ---- 左右から引き出す一覧 ----

function openDrawer(name) {
  closeDetail();
  openDrawerName = name;
  $('queueDrawer').classList.toggle('open', name === 'queue');
  $('playerDrawer').classList.toggle('open', name === 'player');
  $('queueDrawer').setAttribute('aria-hidden', String(name !== 'queue'));
  $('playerDrawer').setAttribute('aria-hidden', String(name !== 'player'));
  $('scrim').hidden = false;
  if (name === 'queue') showDrawerTab(drawerTab);
  if (name === 'player') refreshState(false);
}

function closeDrawers() {
  openDrawerName = '';
  $('queueDrawer').classList.remove('open');
  $('playerDrawer').classList.remove('open');
  $('queueDrawer').setAttribute('aria-hidden', 'true');
  $('playerDrawer').setAttribute('aria-hidden', 'true');
  $('scrim').hidden = true;
}

function showDrawerTab(name) {
  drawerTab = name;
  all('.drawertab').forEach((tab) => tab.classList.toggle('active', tab.dataset.drawerTab === name));
  $('queuePane').hidden = name !== 'queue';
  $('playedPane').hidden = name !== 'played';
  if (name === 'queue') refreshQueue();
  else refreshPlayed();
}

function queueRow(number, title, artist, className) {
  const row = node('button', undefined, `qrow${className ? ` ${className}` : ''}`);
  row.type = 'button';
  const avatar = node('span', undefined, 'qavatar');
  avatar.append(icon('user'));
  const text = node('span', undefined, 'qtext');
  text.append(node('div', title || '曲名取得中'), node('div', artist || ''));
  row.append(node('span', number, 'qno'), avatar, text);
  return row;
}

function renderQueue() {
  const list = $('queue');
  list.replaceChildren();
  if (state.playing) {
    const playing = queueRow('演', state.title, state.artist, 'playing');
    playing.disabled = true;
    list.append(playing);
  }
  if (!queueRows.some((row) => row.token === selectedQueueToken)) selectedQueueToken = '';
  for (const row of queueRows) {
    const item = queueRow(row.cutIn ? '割' : String(row.index + 1), row.title, row.artist, row.token === selectedQueueToken ? 'selected' : '');
    item.append(node('span', '≡', 'qhandle'));
    item.onclick = () => {
      selectedQueueToken = selectedQueueToken === row.token ? '' : row.token;
      renderQueue();
    };
    list.append(item);
  }
  if (!state.playing && !queueRows.length) list.append(node('div', '予約はありません', 'empty'));

  const selected = queueRows.find((row) => row.token === selectedQueueToken);
  const normalCount = queueRows.filter((row) => !row.cutIn).length;
  $('queueUp').disabled = !selected || selected.cutIn || selected.index === 0;
  $('queueDown').disabled = !selected || selected.cutIn || selected.index >= normalCount - 1;
  $('queueRemove').disabled = !selected;
}

async function refreshQueue(silent = false) {
  try {
    const data = await api('api/queue');
    queueRows = Array.isArray(data.rows) ? data.rows : [];
    renderQueue();
  } catch (error) {
    if (!silent) toast(error.message);
  }
}

async function queueAction(action) {
  if (!selectedQueueToken) return;
  if (action === 'remove' && !confirm('選んだ予約を取り消しますか？')) return;
  try {
    const data = await api('api/queue-action', { action, token: selectedQueueToken });
    queueRows = Array.isArray(data.rows) ? data.rows : [];
    if (action === 'remove') selectedQueueToken = '';
    renderQueue();
    toast(action === 'remove' ? '予約を取り消しました' : '予約順を変更しました');
  } catch (error) {
    toast(error.message);
    refreshQueue(true);
  }
}

async function refreshPlayed() {
  const list = $('played');
  try {
    const data = await api('api/history');
    const rows = Array.isArray(data.rows) ? data.rows : [];
    list.replaceChildren();
    if (!rows.length) list.append(node('div', 'りれきはありません', 'empty'));
    rows.forEach((song, index) => {
      const item = queueRow(String(index + 1), song.title, song.artist, '');
      item.onclick = () => { closeDrawers(); openDetail(song); };
      list.append(item);
    });
  } catch (error) {
    list.replaceChildren(node('div', error.message, 'empty'));
  }
}

/** 画面の端からのフリックで、左右の一覧を開閉します。 */
function installEdgeSwipe() {
  let start = null;
  const screen = $('screen');
  screen.addEventListener('touchstart', (event) => {
    const touch = event.touches[0];
    start = { x: touch.clientX, y: touch.clientY, width: screen.clientWidth };
  }, { passive: true });
  screen.addEventListener('touchend', (event) => {
    if (!start) return;
    const touch = event.changedTouches[0];
    const dx = touch.clientX - start.x;
    const dy = touch.clientY - start.y;
    const from = start;
    start = null;
    if (Math.abs(dx) < 60 || Math.abs(dy) > Math.abs(dx)) return;
    const rect = screen.getBoundingClientRect();
    const x = from.x - rect.left;
    if (openDrawerName === 'queue' && dx < 0) closeDrawers();
    else if (openDrawerName === 'player' && dx > 0) closeDrawers();
    else if (!openDrawerName && $('detail').hidden && x < 28 && dx > 0) openDrawer('queue');
    else if (!openDrawerName && $('detail').hidden && x > from.width - 28 && dx < 0) openDrawer('player');
  }, { passive: true });
}

// ---- 結び付け ----

$('search').onsubmit = (event) => { event.preventDefault(); submitSearch(); };
all('.tab, [data-tab]').forEach((button) => { button.onclick = () => selectTab(button.dataset.tab); });
all('[data-search-mode]').forEach((button) => {
  button.onclick = () => {
    setSearchMode(button.dataset.searchMode);
    if ($('query').value.trim()) submitSearch();
    else $('query').focus();
  };
});
all('.segment').forEach((segment) => {
  segment.onclick = () => {
    setSearchMode(segment.dataset.mode);
    if (listQuery) openList('search', listQuery);
  };
});

$('openQueue').onclick = () => openDrawer('queue');
$('tileQueue').onclick = () => openDrawer('queue');
$('openPlayer').onclick = () => openDrawer('player');
$('keyRemote').onclick = () => openDrawer('player');
$('scrim').onclick = closeDrawers;
all('[data-close-drawer]').forEach((button) => { button.onclick = closeDrawers; });
all('.drawertab').forEach((tab) => { tab.onclick = () => showDrawerTab(tab.dataset.drawerTab); });
$('queueUp').onclick = () => queueAction('moveUp');
$('queueDown').onclick = () => queueAction('moveDown');
$('queueRemove').onclick = () => queueAction('remove');

all('[data-control]').forEach((button) => { button.onclick = () => runControl(button.dataset.control); });
$('playerScoring').onclick = toggleScoring;
$('keyScoring').onclick = toggleScoring;
$('keyStop').onclick = () => runControl('stop');
$('keyTop').onclick = goTop;
$('keyBack').onclick = goBack;

$('detail').onclick = (event) => { if (event.target === $('detail')) closeDetail(); };
$('detailBack').onclick = closeDetail;
$('detailArtist').onclick = () => searchArtist(selectedSong?.artist || '');
$('detailFavorite').onclick = toggleFavorite;
$('detailFavoriteButton').onclick = toggleFavorite;
$('optionGuide').onclick = () => togglePlayType('guideVocal');
$('optionArtist').onclick = () => togglePlayType('artistVideo');
$('optionScoring').onclick = () => { scoringRequested = !scoringRequested; renderDetail(); };
$('reserveKeyDown').onclick = () => setReserveKey(reserveKey - 1);
$('reserveKeyUp').onclick = () => setReserveKey(reserveKey + 1);
$('reserveKeyReset').onclick = () => setReserveKey(0);
$('keyTrack').onkeydown = (event) => {
  if (event.key === 'ArrowLeft') setReserveKey(reserveKey - 1);
  if (event.key === 'ArrowRight') setReserveKey(reserveKey + 1);
};
$('reserveNormal').onclick = () => reserve('normal');
$('reserveCutIn').onclick = () => reserve('cutIn');
$('reserveOriginal').onclick = () => reserve('originalKey');

$('damConfirmationYes').onclick = () => answerConfirmation(true);
$('damConfirmationNo').onclick = () => answerConfirmation(false);
document.addEventListener('keydown', (event) => { if (event.key === 'Escape') goBack(); });

buildKeyDots();
installEdgeSwipe();
renderDetail();
refreshState(false).finally(() => setTimeout(pollState, 1000));
setInterval(() => {
  if (openDrawerName === 'queue' && drawerTab === 'queue') refreshQueue(true);
}, 5000);
