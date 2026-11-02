//! Direct2D・DirectWrite・WICで技法グリッドを透明DIBへ描き、レイヤードウィンドウへ反映します。

use std::path::Path;

use windows::Win32::Foundation::{COLORREF, HWND, POINT, RECT, SIZE};
use windows::Win32::Graphics::Direct2D::Common::{
    D2D_RECT_F, D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_COLOR_F, D2D1_GRADIENT_STOP, D2D1_PIXEL_FORMAT,
};
use windows::Win32::Graphics::Direct2D::{
    D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, D2D1_DRAW_TEXT_OPTIONS_NONE, D2D1_EXTEND_MODE_CLAMP,
    D2D1_FACTORY_TYPE_SINGLE_THREADED, D2D1_FEATURE_LEVEL_DEFAULT, D2D1_GAMMA_2_2,
    D2D1_INTERPOLATION_MODE_HIGH_QUALITY_CUBIC, D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES,
    D2D1_RENDER_TARGET_PROPERTIES, D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1_RENDER_TARGET_USAGE_NONE,
    D2D1_ROUNDED_RECT, D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE, D2D1CreateFactory, ID2D1Bitmap,
    ID2D1DCRenderTarget, ID2D1DeviceContext, ID2D1Factory, ID2D1LinearGradientBrush,
    ID2D1SolidColorBrush,
};
use windows::Win32::Graphics::DirectWrite::{
    DWRITE_FACTORY_TYPE_SHARED, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL,
    DWRITE_FONT_WEIGHT_BOLD, DWRITE_MEASURING_MODE_NATURAL, DWRITE_PARAGRAPH_ALIGNMENT_CENTER,
    DWRITE_TEXT_ALIGNMENT_CENTER, DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_TRIMMING,
    DWRITE_TRIMMING_GRANULARITY_CHARACTER, DWRITE_WORD_WRAPPING_NO_WRAP, DWRITE_WORD_WRAPPING_WRAP,
    DWriteCreateFactory, IDWriteFactory, IDWriteTextFormat,
};
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::{
    AC_SRC_ALPHA, AC_SRC_OVER, BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BLENDFUNCTION,
    CreateCompatibleDC, CreateDIBSection, DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC, HBITMAP,
    HDC, HGDIOBJ, ReleaseDC, SelectObject,
};
use windows::Win32::Graphics::Imaging::{
    CLSID_WICImagingFactory, GUID_WICPixelFormat32bppPBGRA, IWICBitmap, IWICImagingFactory,
    WICBitmapCacheOnLoad, WICBitmapDitherTypeNone, WICBitmapPaletteTypeMedianCut,
    WICDecodeMetadataCacheOnLoad,
};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance};
use windows::Win32::UI::WindowsAndMessaging::{ULW_ALPHA, UpdateLayeredWindow};
use windows::core::{GUID, HSTRING, Interface, w};
use windows_numerics::Vector2;

use crate::model::{self, RectF, TECHNIQUE_COUNT, TECHNIQUES};

const NAME_FONT_CANDIDATES: [&str; 5] = [
    "Yu Gothic UI",
    "Meiryo UI",
    "Meiryo",
    "MS UI Gothic",
    "Segoe UI",
];
const NUMBER_FONT_CANDIDATES: [&str; 3] = ["Arial", "Segoe UI", "Tahoma"];

/// 描画1回分の入力です。
pub struct Frame<'a> {
    pub origin: POINT,
    pub width: i32,
    pub height: i32,
    pub counts: &'a [i32; TECHNIQUE_COUNT],
    pub show_zero: bool,
    pub highlight: Option<usize>,
}

/// 0〜255のRGBAからDirect2Dの色を作ります。
fn rgba(alpha: u8, red: u8, green: u8, blue: u8) -> D2D1_COLOR_F {
    D2D1_COLOR_F {
        r: f32::from(red) / 255.0,
        g: f32::from(green) / 255.0,
        b: f32::from(blue) / 255.0,
        a: f32::from(alpha) / 255.0,
    }
}

fn d2d_rect(rect: RectF) -> D2D_RECT_F {
    D2D_RECT_F {
        left: rect.x,
        top: rect.y,
        right: rect.right(),
        bottom: rect.bottom(),
    }
}

/// 透明DIBを選択したメモリDCです。サイズが変わるまで使い回します。
struct Surface {
    dc: HDC,
    bitmap: HBITMAP,
    previous: HGDIOBJ,
    width: i32,
    height: i32,
}

impl Surface {
    fn new(screen: HDC, width: i32, height: i32) -> Option<Self> {
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width,
                biHeight: -height,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        // SAFETY: 有効な画面DCとBITMAPINFOを渡し、生成物は失敗時にその場で解放します。
        unsafe {
            let dc = CreateCompatibleDC(Some(screen));
            if dc.is_invalid() {
                return None;
            }
            let mut bits = std::ptr::null_mut();
            let Ok(bitmap) =
                CreateDIBSection(Some(screen), &info, DIB_RGB_COLORS, &mut bits, None, 0)
            else {
                let _ = DeleteDC(dc);
                return None;
            };
            if bits.is_null() {
                let _ = DeleteObject(bitmap.into());
                let _ = DeleteDC(dc);
                return None;
            }
            let previous = SelectObject(dc, bitmap.into());
            Some(Self {
                dc,
                bitmap,
                previous,
                width,
                height,
            })
        }
    }
}

impl Drop for Surface {
    fn drop(&mut self) {
        // SAFETY: `new` で作成し、このSurfaceだけが所有するGDIオブジェクトです。
        unsafe {
            SelectObject(self.dc, self.previous);
            let _ = DeleteObject(self.bitmap.into());
            let _ = DeleteDC(self.dc);
        }
    }
}

/// 縮尺ごとに作り直すDirectWriteの書式です。
struct TextFormats {
    scale: f32,
    /// 12.5・11・10px(倍率前)の技法名用書式です。
    names: [IDWriteTextFormat; 3],
    number: IDWriteTextFormat,
}

/// 描画ターゲットに結び付くデバイス依存資源です。`D2DERR_RECREATE_TARGET` で作り直します。
struct DeviceResources {
    target: ID2D1DCRenderTarget,
    context: Option<ID2D1DeviceContext>,
    brush: ID2D1SolidColorBrush,
    /// [未検出, 検出済み] の背景グラデーションです。
    backgrounds: [ID2D1LinearGradientBrush; 2],
    icons: Vec<Option<ID2D1Bitmap>>,
}

/// 描画スレッド専用の描画器です。COM初期化済みのスレッドでのみ生成・使用します。
pub struct Renderer {
    d2d: ID2D1Factory,
    dwrite: IDWriteFactory,
    icons: Vec<Option<IWICBitmap>>,
    name_family: HSTRING,
    number_family: HSTRING,
    names: Vec<Vec<u16>>,
    device: Option<DeviceResources>,
    text: Option<TextFormats>,
    surface: Option<Surface>,
}

impl Renderer {
    /// ファクトリーを作成し、アイコンをメモリ経由で読み込みます。
    pub fn new(asset_directory: &Path) -> windows::core::Result<Self> {
        // SAFETY: 呼び出し元の描画スレッドでCOMを初期化済みです。
        let (d2d, dwrite, wic) = unsafe {
            let d2d: ID2D1Factory = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;
            let dwrite: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
            let wic: IWICImagingFactory =
                CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
            (d2d, dwrite, wic)
        };
        let icons = TECHNIQUES
            .iter()
            .map(|technique| {
                let path = asset_directory.join(format!("technique_{:02}.png", technique.id));
                load_icon(&wic, &path)
            })
            .collect();
        let name_family = HSTRING::from(pick_font(&dwrite, &NAME_FONT_CANDIDATES));
        let number_family = HSTRING::from(pick_font(&dwrite, &NUMBER_FONT_CANDIDATES));
        Ok(Self {
            d2d,
            dwrite,
            icons,
            name_family,
            number_family,
            names: TECHNIQUES
                .iter()
                .map(|t| t.name.encode_utf16().collect())
                .collect(),
            device: None,
            text: None,
            surface: None,
        })
    }

    /// 全タイルを描き、`window` のレイヤー内容と位置・サイズを更新します。
    pub fn render(&mut self, window: HWND, frame: &Frame<'_>) -> bool {
        if frame.width <= 0 || frame.height <= 0 {
            return false;
        }
        // SAFETY: 画面DCは取得したこの関数内で必ず解放します。
        let screen = unsafe { GetDC(None) };
        if screen.is_invalid() {
            return false;
        }
        let result = self.render_with_screen(window, screen, frame);
        // SAFETY: 上で取得した画面DCです。
        unsafe { ReleaseDC(None, screen) };
        result
    }

    fn render_with_screen(&mut self, window: HWND, screen: HDC, frame: &Frame<'_>) -> bool {
        let needs_surface = self
            .surface
            .as_ref()
            .is_none_or(|s| s.width != frame.width || s.height != frame.height);
        if needs_surface {
            self.surface = None;
            self.surface = Surface::new(screen, frame.width, frame.height);
        }
        let Some(surface_dc) = self.surface.as_ref().map(|s| s.dc) else {
            return false;
        };
        if self.device.is_none() {
            self.device = self.create_device().ok();
        }
        let scale = model::layout_scale(frame.width, frame.height);
        if self.text.as_ref().is_none_or(|t| t.scale != scale) {
            self.text = self.create_text_formats(scale).ok();
        }
        let (Some(device), Some(text)) = (self.device.as_ref(), self.text.as_ref()) else {
            return false;
        };
        let bounds = RECT {
            left: 0,
            top: 0,
            right: frame.width,
            bottom: frame.height,
        };
        // SAFETY: Surfaceが所有するメモリDCへバインドし、描画はBeginDraw/EndDrawの組で閉じます。
        let drawn = unsafe {
            if device.target.BindDC(surface_dc, &bounds).is_err() {
                false
            } else {
                device.target.BeginDraw();
                device.target.Clear(Some(&rgba(0, 0, 0, 0)));
                for tile in
                    model::layout_tiles(frame.width, frame.height, frame.counts, frame.show_zero)
                {
                    draw_tile(
                        device,
                        text,
                        &self.names,
                        tile.index,
                        frame.counts[tile.index],
                        tile.bounds,
                        scale,
                        frame.highlight == Some(tile.index),
                    );
                }
                device.target.EndDraw(None, None).is_ok()
            }
        };
        if !drawn {
            // 描画失敗時はデバイス資源を捨て、次回に作り直します。
            self.device = None;
            return false;
        }
        let size = SIZE {
            cx: frame.width,
            cy: frame.height,
        };
        let source = POINT { x: 0, y: 0 };
        let blend = BLENDFUNCTION {
            BlendOp: AC_SRC_OVER as u8,
            BlendFlags: 0,
            SourceConstantAlpha: 255,
            AlphaFormat: AC_SRC_ALPHA as u8,
        };
        // SAFETY: 描画済みのメモリDCと有効なウィンドウを渡します。
        unsafe {
            UpdateLayeredWindow(
                window,
                Some(screen),
                Some(&frame.origin),
                Some(&size),
                Some(surface_dc),
                Some(&source),
                COLORREF(0),
                Some(&blend),
                ULW_ALPHA,
            )
            .is_ok()
        }
    }

    fn create_device(&self) -> windows::core::Result<DeviceResources> {
        let properties = D2D1_RENDER_TARGET_PROPERTIES {
            r#type: D2D1_RENDER_TARGET_TYPE_DEFAULT,
            pixelFormat: D2D1_PIXEL_FORMAT {
                format: DXGI_FORMAT_B8G8R8A8_UNORM,
                alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            dpiX: 96.0,
            dpiY: 96.0,
            usage: D2D1_RENDER_TARGET_USAGE_NONE,
            minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
        };
        // SAFETY: 描画スレッドが所有するファクトリーと、読み込み済みWICビットマップだけを使います。
        unsafe {
            let target = self.d2d.CreateDCRenderTarget(&properties)?;
            target.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
            let brush = target.CreateSolidColorBrush(&rgba(255, 255, 255, 255), None)?;
            let gradient = |top: D2D1_COLOR_F| -> windows::core::Result<ID2D1LinearGradientBrush> {
                let stops = [
                    D2D1_GRADIENT_STOP {
                        position: 0.0,
                        color: top,
                    },
                    D2D1_GRADIENT_STOP {
                        position: 1.0,
                        color: rgba(255, 7, 10, 14),
                    },
                ];
                let collection = target.CreateGradientStopCollection(
                    &stops,
                    D2D1_GAMMA_2_2,
                    D2D1_EXTEND_MODE_CLAMP,
                )?;
                let line = D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES {
                    startPoint: Vector2 { X: 0.0, Y: 0.0 },
                    endPoint: Vector2 { X: 0.0, Y: 1.0 },
                };
                target.CreateLinearGradientBrush(&line, None, &collection)
            };
            let backgrounds = [
                gradient(rgba(255, 38, 42, 44))?,
                gradient(rgba(255, 55, 60, 61))?,
            ];
            let icons = self
                .icons
                .iter()
                .map(|icon| {
                    icon.as_ref()
                        .and_then(|icon| target.CreateBitmapFromWicBitmap(icon, None).ok())
                })
                .collect();
            let context = target.cast::<ID2D1DeviceContext>().ok();
            Ok(DeviceResources {
                target,
                context,
                brush,
                backgrounds,
                icons,
            })
        }
    }

    fn create_text_formats(&self, scale: f32) -> windows::core::Result<TextFormats> {
        // SAFETY: 描画スレッドが所有するDirectWriteファクトリーです。
        unsafe {
            let name_format = |size: f32| -> windows::core::Result<IDWriteTextFormat> {
                let format = self.dwrite.CreateTextFormat(
                    &self.name_family,
                    None,
                    DWRITE_FONT_WEIGHT_BOLD,
                    DWRITE_FONT_STYLE_NORMAL,
                    DWRITE_FONT_STRETCH_NORMAL,
                    size * scale,
                    w!("ja-jp"),
                )?;
                format.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING)?;
                format.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER)?;
                format.SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP)?;
                let sign = self.dwrite.CreateEllipsisTrimmingSign(&format)?;
                let trimming = DWRITE_TRIMMING {
                    granularity: DWRITE_TRIMMING_GRANULARITY_CHARACTER,
                    delimiter: 0,
                    delimiterCount: 0,
                };
                format.SetTrimming(&trimming, &sign)?;
                Ok(format)
            };
            let number = self.dwrite.CreateTextFormat(
                &self.number_family,
                None,
                DWRITE_FONT_WEIGHT_BOLD,
                DWRITE_FONT_STYLE_NORMAL,
                DWRITE_FONT_STRETCH_NORMAL,
                18.0 * scale,
                w!("en-us"),
            )?;
            number.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER)?;
            number.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER)?;
            number.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP)?;
            Ok(TextFormats {
                scale,
                names: [name_format(12.5)?, name_format(11.0)?, name_format(10.0)?],
                number,
            })
        }
    }
}

/// MusicStaffと同系統の暗色面・金枠・白文字・右寄せ回数を1タイルへ描きます。
#[allow(clippy::too_many_arguments)]
unsafe fn draw_tile(
    device: &DeviceResources,
    text: &TextFormats,
    names: &[Vec<u16>],
    index: usize,
    count: i32,
    bounds: RectF,
    scale: f32,
    latest: bool,
) {
    let target = &device.target;
    let brush = &device.brush;
    let detected = count > 0;
    let content_alpha: u8 = if detected { 255 } else { 112 };
    let border_alpha: u8 = if latest {
        255
    } else if detected {
        235
    } else {
        105
    };
    let tile = D2D1_ROUNDED_RECT {
        rect: d2d_rect(bounds),
        radiusX: 5.0 * scale,
        radiusY: 5.0 * scale,
    };
    // SAFETY: 呼び出し元がBeginDraw済みのターゲットと、そのターゲットで作った資源だけを渡します。
    unsafe {
        let background = &device.backgrounds[usize::from(detected)];
        background.SetStartPoint(Vector2 {
            X: bounds.x,
            Y: bounds.y,
        });
        background.SetEndPoint(Vector2 {
            X: bounds.x,
            Y: bounds.bottom(),
        });
        target.FillRoundedRectangle(&tile, background);
        if latest {
            brush.SetColor(&rgba(150, 255, 215, 92));
            target.DrawRoundedRectangle(&tile, brush, 4.0 * scale, None);
        }
        brush.SetColor(&if latest {
            rgba(border_alpha, 255, 226, 118)
        } else {
            rgba(border_alpha, 201, 174, 73)
        });
        target.DrawRoundedRectangle(&tile, brush, if latest { 2.2 } else { 1.2 } * scale, None);

        let icon_width = 38.0 * scale;
        let icon_height = 22.0 * scale;
        let icon = RectF {
            x: bounds.x + 8.0 * scale,
            y: bounds.y + (bounds.height - icon_height) * 0.5,
            width: icon_width,
            height: icon_height,
        };
        let opacity = f32::from(content_alpha) / 255.0;
        match device.icons.get(index).and_then(Option::as_ref) {
            Some(bitmap) => {
                let destination = d2d_rect(icon);
                match &device.context {
                    Some(context) => context.DrawBitmap(
                        bitmap,
                        Some(&destination),
                        opacity,
                        D2D1_INTERPOLATION_MODE_HIGH_QUALITY_CUBIC,
                        None,
                        None,
                    ),
                    None => target.DrawBitmap(
                        bitmap,
                        Some(&destination),
                        opacity,
                        D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
                        None,
                    ),
                }
            }
            None => {
                brush.SetColor(&rgba(content_alpha, 230, 190, 80));
                target.DrawLine(
                    Vector2 {
                        X: icon.x,
                        Y: icon.bottom(),
                    },
                    Vector2 {
                        X: icon.right(),
                        Y: icon.y,
                    },
                    brush,
                    2.0,
                    None,
                );
            }
        }

        let count_width = 32.0 * scale;
        let divider_x = bounds.right() - count_width;
        brush.SetColor(&rgba(border_alpha / 2, 220, 205, 156));
        target.DrawLine(
            Vector2 {
                X: divider_x,
                Y: bounds.y + 6.0 * scale,
            },
            Vector2 {
                X: divider_x,
                Y: bounds.bottom() - 6.0 * scale,
            },
            brush,
            scale,
            None,
        );

        let name = &names[index];
        let font_size = model::name_font_size(TECHNIQUES[index].name);
        let name_format = if font_size >= 12.5 {
            &text.names[0]
        } else if font_size >= 11.0 {
            &text.names[1]
        } else {
            &text.names[2]
        };
        let name_bounds = RectF {
            x: icon.right() + 6.0 * scale,
            y: bounds.y,
            width: (divider_x - icon.right() - 10.0 * scale).max(1.0),
            height: bounds.height,
        };
        let shadow_bounds = RectF {
            x: name_bounds.x + scale,
            y: name_bounds.y + scale,
            ..name_bounds
        };
        brush.SetColor(&rgba(content_alpha, 0, 0, 0));
        target.DrawText(
            name,
            name_format,
            &d2d_rect(shadow_bounds),
            brush,
            D2D1_DRAW_TEXT_OPTIONS_NONE,
            DWRITE_MEASURING_MODE_NATURAL,
        );
        brush.SetColor(&rgba(content_alpha, 244, 242, 235));
        target.DrawText(
            name,
            name_format,
            &d2d_rect(name_bounds),
            brush,
            D2D1_DRAW_TEXT_OPTIONS_NONE,
            DWRITE_MEASURING_MODE_NATURAL,
        );

        let number: Vec<u16> = count.to_string().encode_utf16().collect();
        let number_bounds = RectF {
            x: divider_x,
            y: bounds.y,
            width: count_width,
            height: bounds.height,
        };
        brush.SetColor(&rgba(content_alpha, 255, 255, 255));
        target.DrawText(
            &number,
            &text.number,
            &d2d_rect(number_bounds),
            brush,
            D2D1_DRAW_TEXT_OPTIONS_NONE,
            DWRITE_MEASURING_MODE_NATURAL,
        );
    }
}

/// 候補のうち最初に見つかったフォントファミリーを返します。どれもなければ先頭を返します。
fn pick_font(dwrite: &IDWriteFactory, candidates: &[&'static str]) -> &'static str {
    let mut collection = None;
    // SAFETY: 出力引数はローカル変数で、取得失敗時は既定候補へ戻します。
    let found = unsafe {
        if dwrite
            .GetSystemFontCollection(&mut collection, false)
            .is_err()
        {
            None
        } else {
            collection.and_then(|collection| {
                candidates.iter().copied().find(|name| {
                    let mut index = 0;
                    let mut exists = windows::core::BOOL(0);
                    collection
                        .FindFamilyName(&HSTRING::from(*name), &mut index, &mut exists)
                        .is_ok()
                        && exists.as_bool()
                })
            })
        }
    };
    found.unwrap_or(candidates[0])
}

/// PNGをメモリへ読み込んでからデコードし、ファイルハンドルを即座に解放します。
fn load_icon(wic: &IWICImagingFactory, path: &Path) -> Option<IWICBitmap> {
    let bytes = std::fs::read(path).ok()?;
    // SAFETY: `bytes` はデコード結果を `CreateBitmapFromSource` で複製し終えるまで生存します。
    unsafe {
        let stream = wic.CreateStream().ok()?;
        stream.InitializeFromMemory(&bytes).ok()?;
        let decoder = wic
            .CreateDecoderFromStream(&stream, &GUID::zeroed(), WICDecodeMetadataCacheOnLoad)
            .ok()?;
        let frame = decoder.GetFrame(0).ok()?;
        let converter = wic.CreateFormatConverter().ok()?;
        converter
            .Initialize(
                &frame,
                &GUID_WICPixelFormat32bppPBGRA,
                WICBitmapDitherTypeNone,
                None,
                0.0,
                WICBitmapPaletteTypeMedianCut,
            )
            .ok()?;
        wic.CreateBitmapFromSource(&converter, WICBitmapCacheOnLoad)
            .ok()
    }
}
