//! Win32へ依存しない、技法ID・配置・可視判定の純粋ロジックです。

/// Agentの通知が途絶えたと判断して表示を隠すまでの猶予です。
pub const HEARTBEAT_TIMEOUT_MS: u64 = 3500;
/// 最新検知タイルを強調表示する時間です。
pub const HIGHLIGHT_MS: u64 = 700;
/// 1タイルに表示する回数の上限です。
pub const MAX_COUNT: i32 = 999;

const REFERENCE_WIDTH: f32 = 1920.0;
const REFERENCE_HEIGHT: f32 = 1080.0;
const COLUMN_COUNT: usize = 7;

/// 表示上の技法IDと日本語名を1対1で保持します。
#[derive(Debug, Clone, Copy)]
pub struct Technique {
    pub id: i32,
    pub name: &'static str,
}

/// グリッドへ並べる36種類の技法です。30〜38のビブラートは30へ集約します。
pub const TECHNIQUES: [Technique; 36] = [
    Technique {
        id: 0,
        name: "しゃくり",
    },
    Technique {
        id: 1,
        name: "大しゃくり",
    },
    Technique {
        id: 2,
        name: "早いしゃくり",
    },
    Technique {
        id: 3,
        name: "早いしゃくり（強）",
    },
    Technique {
        id: 4,
        name: "L字アクセント",
    },
    Technique {
        id: 5,
        name: "L字アクセント（強）",
    },
    Technique {
        id: 6,
        name: "V字アクセント",
    },
    Technique {
        id: 7,
        name: "V字アクセント（カット）",
    },
    Technique {
        id: 8,
        name: "V字アクセント（下）",
    },
    Technique {
        id: 9,
        name: "逆V字アクセント",
    },
    Technique {
        id: 10,
        name: "先頭こぶし",
    },
    Technique {
        id: 11,
        name: "こぶし",
    },
    Technique {
        id: 12,
        name: "フライダウン",
    },
    Technique {
        id: 13,
        name: "ハンマリング・オン",
    },
    Technique {
        id: 14,
        name: "プリング・オフ",
    },
    Technique {
        id: 15,
        name: "上昇ポルタメント",
    },
    Technique {
        id: 16,
        name: "下降ポルタメント",
    },
    Technique {
        id: 17,
        name: "上昇スロープ",
    },
    Technique {
        id: 18,
        name: "フォール",
    },
    Technique {
        id: 19,
        name: "早いフォール",
    },
    Technique {
        id: 20,
        name: "ヒーカップ",
    },
    Technique {
        id: 21,
        name: "フォール付きヒーカップ",
    },
    Technique {
        id: 22,
        name: "スローダウン",
    },
    Technique {
        id: 23,
        name: "スライダー",
    },
    Technique {
        id: 24,
        name: "水平",
    },
    Technique {
        id: 25,
        name: "スタッカート",
    },
    Technique {
        id: 26,
        name: "U字",
    },
    Technique {
        id: 27,
        name: "逆U字",
    },
    Technique {
        id: 28,
        name: "への字",
    },
    Technique {
        id: 29,
        name: "アーチ",
    },
    Technique {
        id: 30,
        name: "ビブラート",
    },
    Technique {
        id: 39,
        name: "ジャストヒット",
    },
    Technique {
        id: 40,
        name: "エッジボイス",
    },
    Technique {
        id: 41,
        name: "フォールエッジ",
    },
    Technique {
        id: 42,
        name: "逆こぶし",
    },
    Technique {
        id: 43,
        name: "歌い回しなし",
    },
];

/// 技法の種類数です。
pub const TECHNIQUE_COUNT: usize = TECHNIQUES.len();

/// 44個の内部IDを、ビブラートを統合した表示用IDへ変換します。
pub fn canonical_technique_id(technique_id: i32) -> i32 {
    if (30..=38).contains(&technique_id) {
        30
    } else {
        technique_id
    }
}

/// 表示用IDに一致する固定グリッド位置を返します。
pub fn technique_index(technique_id: i32) -> Option<usize> {
    let canonical = canonical_technique_id(technique_id);
    TECHNIQUES.iter().position(|t| t.id == canonical)
}

/// 既存の回数へ増分を加え、表示上限で飽和させます。
pub fn saturating_count(current: i32, value: i32) -> i32 {
    current.saturating_add(value.max(0)).clamp(0, MAX_COUNT)
}

/// 「要求表示 && セッション中 && ハートビートが有効期限内」を描画時に判定します。
pub fn is_visible(
    requested: bool,
    session_active: bool,
    now_ms: u64,
    last_heartbeat_ms: u64,
) -> bool {
    requested && session_active && now_ms.saturating_sub(last_heartbeat_ms) <= HEARTBEAT_TIMEOUT_MS
}

/// 最新タイル番号と強調終了時刻を1語へ詰め、原子的に読み書きできるようにします。
///
/// 下位8ビットは「番号+1」(0は強調なし)、上位56ビットは終了時刻(ms)です。
pub fn pack_highlight(index: Option<usize>, until_ms: u64) -> u64 {
    match index {
        Some(index) if index < 0xFF => (until_ms << 8) | (index as u64 + 1),
        _ => 0,
    }
}

/// `pack_highlight` の逆変換です。強調なしなら `None` を返します。
pub fn unpack_highlight(packed: u64) -> Option<(usize, u64)> {
    let slot = packed & 0xFF;
    if slot == 0 {
        None
    } else {
        Some((slot as usize - 1, packed >> 8))
    }
}

/// 技法名の文字数に応じたフォントサイズ(倍率適用前)です。
pub fn name_font_size(name: &str) -> f32 {
    let length = name.encode_utf16().count();
    if length >= 11 {
        10.0
    } else if length >= 8 {
        11.0
    } else {
        12.5
    }
}

/// 浮動小数点の矩形です。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RectF {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl RectF {
    pub fn right(&self) -> f32 {
        self.x + self.width
    }

    pub fn bottom(&self) -> f32 {
        self.y + self.height
    }
}

/// 1タイル分の配置です。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TileLayout {
    /// `TECHNIQUES` 上の番号です。
    pub index: usize,
    pub bounds: RectF,
}

/// 1920x1080基準の縮尺です。小さすぎる画面でも0.5倍を下限にします。
pub fn layout_scale(width: i32, height: i32) -> f32 {
    let scale = (width as f32 / REFERENCE_WIDTH).min(height as f32 / REFERENCE_HEIGHT);
    scale.max(0.5)
}

/// 歌詞とAI感性表示を避けた位置へ、7列のグリッドを左上から詰めて配置します。
pub fn layout_tiles(
    width: i32,
    height: i32,
    counts: &[i32; TECHNIQUE_COUNT],
    show_zero: bool,
) -> Vec<TileLayout> {
    let scale = layout_scale(width, height);
    let left = 14.0 * scale;
    let top = 366.0 * scale;
    let grid_width = 1410.0 * scale;
    let gap = 6.0 * scale;
    let tile_height = 43.0 * scale;
    let tile_width = (grid_width - gap * (COLUMN_COUNT - 1) as f32) / COLUMN_COUNT as f32;
    counts
        .iter()
        .enumerate()
        .filter(|(_, count)| show_zero || **count != 0)
        .enumerate()
        .map(|(slot, (index, _))| {
            let row = (slot / COLUMN_COUNT) as f32;
            let column = (slot % COLUMN_COUNT) as f32;
            TileLayout {
                index,
                bounds: RectF {
                    x: left + column * (tile_width + gap),
                    y: top + row * (tile_height + gap),
                    width: tile_width,
                    height: tile_height,
                },
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vibrato_ids_collapse_to_30() {
        for id in 30..=38 {
            assert_eq!(canonical_technique_id(id), 30);
            assert_eq!(technique_index(id), Some(30));
        }
        assert_eq!(canonical_technique_id(29), 29);
        assert_eq!(canonical_technique_id(39), 39);
    }

    #[test]
    fn all_ids_map_to_expected_slots() {
        for id in 0..=30 {
            assert_eq!(technique_index(id), Some(id as usize));
        }
        assert_eq!(technique_index(39), Some(31));
        assert_eq!(technique_index(42), Some(34));
        assert_eq!(technique_index(43), Some(35));
        assert_eq!(TECHNIQUES[35].name, "歌い回しなし");
        assert_eq!(technique_index(-1), None);
        assert_eq!(technique_index(44), None);
        assert_eq!(technique_index(i32::MAX), None);
    }

    #[test]
    fn counts_saturate() {
        assert_eq!(saturating_count(0, 1), 1);
        assert_eq!(saturating_count(998, 5), MAX_COUNT);
        assert_eq!(saturating_count(5, i32::MAX), MAX_COUNT);
        assert_eq!(saturating_count(5, -3), 5);
    }

    #[test]
    fn visibility_requires_request_session_and_heartbeat() {
        assert!(is_visible(true, true, 10_000, 9_000));
        assert!(is_visible(
            true,
            true,
            10_000,
            10_000 - HEARTBEAT_TIMEOUT_MS
        ));
        assert!(!is_visible(
            true,
            true,
            10_000,
            10_000 - HEARTBEAT_TIMEOUT_MS - 1
        ));
        assert!(!is_visible(false, true, 10_000, 10_000));
        assert!(!is_visible(true, false, 10_000, 10_000));
        // 停止後にハートビートが戻れば再び表示されます。
        assert!(is_visible(true, true, 20_000, 19_500));
        // 時刻の逆転で表示が消えないようにします。
        assert!(is_visible(true, true, 1_000, 2_000));
    }

    #[test]
    fn highlight_roundtrip() {
        assert_eq!(unpack_highlight(0), None);
        assert_eq!(unpack_highlight(pack_highlight(None, 123)), None);
        assert_eq!(
            unpack_highlight(pack_highlight(Some(0), 5_000)),
            Some((0, 5_000))
        );
        assert_eq!(
            unpack_highlight(pack_highlight(Some(35), u64::MAX >> 8)),
            Some((35, u64::MAX >> 8))
        );
    }

    #[test]
    fn font_size_follows_name_length() {
        assert_eq!(name_font_size("しゃくり"), 12.5);
        assert_eq!(name_font_size("上昇ポルタメント"), 11.0);
        assert_eq!(name_font_size("V字アクセント（カット）"), 10.0);
    }

    #[test]
    fn layout_matches_reference_dimensions() {
        let counts = [0; TECHNIQUE_COUNT];
        let tiles = layout_tiles(1920, 1080, &counts, true);
        assert_eq!(tiles.len(), TECHNIQUE_COUNT);
        let first = tiles[0].bounds;
        assert_eq!((first.x, first.y, first.height), (14.0, 366.0, 43.0));
        let tile_width = (1410.0 - 36.0) / 7.0;
        assert!((first.width - tile_width).abs() < 1e-3);
        let eighth = tiles[7].bounds;
        assert_eq!((eighth.x, eighth.y), (14.0, 366.0 + 49.0));
        let last = tiles[35].bounds;
        assert_eq!(last.y, 366.0 + 5.0 * 49.0);
        assert!((tiles[6].bounds.right() - (14.0 + 1410.0)).abs() < 1e-3);
    }

    #[test]
    fn layout_scales_and_clamps() {
        assert_eq!(layout_scale(960, 540), 0.5);
        assert_eq!(layout_scale(3840, 1080), 1.0);
        assert_eq!(layout_scale(100, 100), 0.5);
        let counts = [0; TECHNIQUE_COUNT];
        let tiles = layout_tiles(3840, 2160, &counts, true);
        assert_eq!(tiles[0].bounds.y, 732.0);
    }

    #[test]
    fn hidden_zero_tiles_are_packed() {
        let mut counts = [0; TECHNIQUE_COUNT];
        counts[3] = 2;
        counts[35] = 1;
        let tiles = layout_tiles(1920, 1080, &counts, false);
        assert_eq!(tiles.len(), 2);
        assert_eq!(tiles[0].index, 3);
        assert_eq!(tiles[0].bounds.x, 14.0);
        assert_eq!(tiles[1].index, 35);
        assert_eq!(tiles[1].bounds.y, 366.0);
    }
}
