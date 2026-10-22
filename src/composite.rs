//! Unity channel-packed maps: the HDRP Mask Map and Detail Map.
//!
//! Both are composed on the CPU from maps the GPU already produced. The work is
//! a channel pack plus a separable box blur, which is cheap next to the compute
//! passes, so it does not warrant its own shader.
//!
//! Channel layouts follow the HDRP documentation:
//! <https://docs.unity3d.com/Packages/com.unity.render-pipelines.high-definition@13.1/manual/Mask-Map-and-Detail-Map.html>

use image::{DynamicImage, ImageBuffer, Rgba};

/// Blur radius used to split the source into broad shapes and fine detail.
const DETAIL_RADIUS: u32 = 4;
/// Amplifies the high-pass result, which is low amplitude on most textures.
const DETAIL_GAIN: f32 = 2.0;
/// Matches the `scale` constant in shaders/normal.wgsl.
const NORMAL_SCALE: f32 = 2.0;

/// HDRP Mask Map: R = Metallic, G = Ambient Occlusion, B = Detail mask, A = Smoothness.
pub fn mask_to_image(
    width: u32,
    height: u32,
    metallic: &[u8],
    ao: &[u8],
    smoothness: &[u8],
) -> DynamicImage {
    let mut img = ImageBuffer::new(width, height);

    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let idx = (y * width + x) as usize;
        // Blue is the detail mask. With no authored mask to honour, 255 applies
        // the detail map across the whole surface.
        *pixel = Rgba([metallic[idx], ao[idx], 255, smoothness[idx]]);
    }

    DynamicImage::ImageRgba8(img)
}

/// HDRP Detail Map: R = Desaturated albedo, G = Normal Y, B = Smoothness, A = Normal X.
///
/// 0.5 is neutral for both albedo and smoothness, so each channel is centred on
/// 128 and carries only the high-frequency part of the source. The broad shapes
/// already live in the base albedo and normal maps; restating them here would
/// double-apply them.
pub fn detail_to_image(
    width: u32,
    height: u32,
    source: &DynamicImage,
    smoothness: &[u8],
) -> DynamicImage {
    let luma = source.to_luma8();
    let lum: Vec<f32> = luma.pixels().map(|p| p[0] as f32 / 255.0).collect();
    let lum_blur = box_blur(&lum, width, height, DETAIL_RADIUS);

    // Centred on 0.5 so the detail albedo is neutral where the source is flat.
    let detail: Vec<f32> = lum
        .iter()
        .zip(&lum_blur)
        .map(|(l, b)| ((l - b) * DETAIL_GAIN + 0.5).clamp(0.0, 1.0))
        .collect();

    let smooth: Vec<f32> = smoothness.iter().map(|&s| s as f32 / 255.0).collect();
    let smooth_blur = box_blur(&smooth, width, height, DETAIL_RADIUS);

    let mut img = ImageBuffer::new(width, height);

    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let idx = (y * width + x) as usize;

        // Derived from the high-passed luminance, so these normals carry the
        // fine grain only.
        let (nx, ny) = detail_normal(&detail, width, height, x, y);

        let albedo = to_u8(detail[idx]);
        let smooth_detail = to_u8((smooth[idx] - smooth_blur[idx]) * DETAIL_GAIN + 0.5);

        *pixel = Rgba([albedo, to_u8(ny), smooth_detail, to_u8(nx)]);
    }

    DynamicImage::ImageRgba8(img)
}

/// Sobel gradient turned into an encoded tangent-space normal, using the same
/// kernel, scale and sign convention as shaders/normal.wgsl.
fn detail_normal(data: &[f32], width: u32, height: u32, x: u32, y: u32) -> (f32, f32) {
    let w = width as i64;
    let h = height as i64;
    let at = |ix: i64, iy: i64| -> f32 {
        let cx = ix.clamp(0, w - 1) as usize;
        let cy = iy.clamp(0, h - 1) as usize;
        data[cy * width as usize + cx]
    };

    let (x, y) = (x as i64, y as i64);
    let gx = -at(x - 1, y - 1) + at(x + 1, y - 1) - 2.0 * at(x - 1, y) + 2.0 * at(x + 1, y)
        - at(x - 1, y + 1)
        + at(x + 1, y + 1);
    let gy = -at(x - 1, y - 1) - 2.0 * at(x, y - 1) - at(x + 1, y - 1)
        + at(x - 1, y + 1)
        + 2.0 * at(x, y + 1)
        + at(x + 1, y + 1);

    let (nx, ny, nz) = (-gx * NORMAL_SCALE, -gy * NORMAL_SCALE, 1.0f32);
    let len = (nx * nx + ny * ny + nz * nz).sqrt();

    // Encoded to 0-1 the same way the shader does: n * 0.5 + 0.5.
    ((nx / len) * 0.5 + 0.5, (ny / len) * 0.5 + 0.5)
}

/// Separable box blur with a sliding window, so cost does not grow with radius.
/// Edge pixels are clamped, matching how the shaders sample out of bounds.
///
/// The running sum accumulates in f64: at f32 the error compounds across a wide
/// row and shifts flat areas off the neutral 128 the detail map depends on.
fn box_blur(data: &[f32], width: u32, height: u32, radius: u32) -> Vec<f32> {
    let w = width as usize;
    let h = height as usize;
    let r = radius as i64;
    let window = (2 * r + 1) as f64;

    let mut tmp = vec![0.0f32; data.len()];
    for y in 0..h {
        let row = &data[y * w..(y + 1) * w];
        let clamp_at = |i: i64| row[i.clamp(0, w as i64 - 1) as usize] as f64;
        let mut sum: f64 = (-r..=r).map(clamp_at).sum();
        for x in 0..w {
            tmp[y * w + x] = (sum / window) as f32;
            sum += clamp_at(x as i64 + r + 1) - clamp_at(x as i64 - r);
        }
    }

    let mut out = vec![0.0f32; data.len()];
    for x in 0..w {
        let clamp_at = |i: i64| tmp[i.clamp(0, h as i64 - 1) as usize * w + x] as f64;
        let mut sum: f64 = (-r..=r).map(clamp_at).sum();
        for y in 0..h {
            out[y * w + x] = (sum / window) as f32;
            sum += clamp_at(y as i64 + r + 1) - clamp_at(y as i64 - r);
        }
    }

    out
}

fn to_u8(value: f32) -> u8 {
    (value.clamp(0.0, 1.0) * 255.0).round() as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mask_channel_order() {
        // R = metallic, G = AO, B = detail mask, A = smoothness.
        let img = mask_to_image(2, 1, &[10, 20], &[30, 40], &[50, 60]);
        let rgba = img.to_rgba8();
        assert_eq!(rgba.get_pixel(0, 0), &Rgba([10, 30, 255, 50]));
        assert_eq!(rgba.get_pixel(1, 0), &Rgba([20, 40, 255, 60]));
    }

    #[test]
    fn test_detail_is_neutral_on_flat_input() {
        // A flat source has no high-frequency content, so albedo, smoothness
        // and both normal axes should all land on the neutral 128.
        let flat = DynamicImage::ImageLuma8(image::GrayImage::from_pixel(8, 8, image::Luma([120])));
        let img = detail_to_image(8, 8, &flat, &[200; 64]);
        let rgba = img.to_rgba8();
        let px = rgba.get_pixel(4, 4);
        assert_eq!(px[0], 128, "detail albedo should be neutral");
        assert_eq!(px[1], 128, "normal Y should be flat");
        assert_eq!(px[2], 128, "detail smoothness should be neutral");
        assert_eq!(px[3], 128, "normal X should be flat");
    }

    #[test]
    fn test_box_blur_preserves_constant() {
        let data = vec![0.25f32; 64];
        let out = box_blur(&data, 8, 8, 2);
        for v in out {
            assert!((v - 0.25).abs() < 1e-6);
        }
    }

    #[test]
    fn test_detail_responds_to_an_edge() {
        // A vertical split should produce non-neutral albedo and normal X at
        // the boundary, and leave normal Y neutral.
        let mut img = image::GrayImage::new(16, 16);
        for (x, _y, p) in img.enumerate_pixels_mut() {
            *p = image::Luma([if x < 8 { 40 } else { 220 }]);
        }
        let detail = detail_to_image(16, 16, &DynamicImage::ImageLuma8(img), &[128; 256]);
        let rgba = detail.to_rgba8();
        let edge = rgba.get_pixel(8, 8);
        assert_ne!(edge[0], 128, "albedo should react to the edge");
        assert_ne!(edge[3], 128, "normal X should react to a vertical edge");
        assert_eq!(edge[1], 128, "normal Y should stay flat");
    }
}
