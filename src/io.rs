use anyhow::{Context, Result};
use image::{DynamicImage, ImageFormat};
use std::path::Path;

/// Paths for the six PBR map outputs.
#[derive(Debug, Clone)]
pub struct OutputPaths {
    pub height_path: String,
    pub normal_path: String,
    pub metallic_path: String,
    pub smoothness_path: String,
    pub edge_path: String,
    pub ao_path: String,
    pub mask_path: String,
    pub detail_path: String,
}

pub fn load_image(path: &str) -> Result<DynamicImage> {
    let path = Path::new(path);

    if !path.exists() {
        anyhow::bail!("Input file '{}' not found", path.display());
    }

    let img = image::open(path)
        .with_context(|| format!("Failed to load image: {}", path.display()))?;

    Ok(img)
}

pub fn save_image(
    image: &DynamicImage,
    path: &str,
    format: ImageFormat,
    quality: u8,
) -> Result<()> {
    let path = Path::new(path);

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create directory: {}", parent.display()))?;
    }

    match format {
        ImageFormat::Jpeg => {
            let rgb = image.to_rgb8();
            let file = std::fs::File::create(path)
                .with_context(|| format!("Failed to create file: {}", path.display()))?;
            let mut writer = std::io::BufWriter::new(file);
            // Quality 0 is invalid for JPEG; encoder expects 1-100
            let q = quality.clamp(1, 100);
            let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut writer, q);
            encoder
                .encode_image(&rgb)
                .with_context(|| format!("Failed to save JPEG: {}", path.display()))?;
        }
        ImageFormat::OpenExr => {
            // The OpenEXR encoder only accepts 32-bit float buffers, but every
            // map we produce is 8-bit (Luma8, Rgb8 or Rgba8), so convert first.
            // Grayscale maps widen to RGB because EXR has no 1-channel path here,
            // and the packed maps keep their alpha, which carries real data.
            let float_img = if image.color().has_alpha() {
                DynamicImage::ImageRgba32F(image.to_rgba32f())
            } else {
                DynamicImage::ImageRgb32F(image.to_rgb32f())
            };
            float_img
                .save_with_format(path, format)
                .with_context(|| format!("Failed to save image: {}", path.display()))?;
        }
        _ => {
            image
                .save_with_format(path, format)
                .with_context(|| format!("Failed to save image: {}", path.display()))?;
        }
    }

    Ok(())
}

pub fn get_output_paths(
    input_path: &str,
    output_dir: &str,
    format: &str,
) -> OutputPaths {
    let input_name = Path::new(input_path)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("output");

    let ext = match format {
        "jpg" | "jpeg" => "jpg",
        _ => format,
    };

    OutputPaths {
        height_path: format!("{}/{}_height.{}", output_dir, input_name, ext),
        normal_path: format!("{}/{}_normal.{}", output_dir, input_name, ext),
        metallic_path: format!("{}/{}_metallic.{}", output_dir, input_name, ext),
        smoothness_path: format!("{}/{}_smoothness.{}", output_dir, input_name, ext),
        edge_path: format!("{}/{}_edge.{}", output_dir, input_name, ext),
        ao_path: format!("{}/{}_ao.{}", output_dir, input_name, ext),
        mask_path: format!("{}/{}_maskmap.{}", output_dir, input_name, ext),
        detail_path: format!("{}/{}_detail.{}", output_dir, input_name, ext),
    }
}

/// Convert height map (f32) to grayscale image
pub fn height_to_image(width: u32, height: u32, data: &[f32]) -> DynamicImage {
    use image::{ImageBuffer, Luma};

    let mut img = ImageBuffer::new(width, height);

    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let idx = (y * width + x) as usize;
        let value = (data[idx] * 255.0).clamp(0.0, 255.0) as u8;
        *pixel = Luma([value]);
    }

    DynamicImage::ImageLuma8(img)
}

/// Convert normal map (RGBA8) to RGB image
pub fn normal_to_image(width: u32, height: u32, data: &[u8]) -> DynamicImage {
    use image::{ImageBuffer, Rgb};

    let mut img = ImageBuffer::new(width, height);

    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let idx = ((y * width + x) * 4) as usize;
        let r = data[idx];
        let g = data[idx + 1];
        let b = data[idx + 2];
        *pixel = Rgb([r, g, b]);
    }

    DynamicImage::ImageRgb8(img)
}

/// Convert metallic map (R8) to grayscale image
pub fn metallic_to_image(width: u32, height: u32, data: &[u8]) -> DynamicImage {
    use image::{ImageBuffer, Luma};

    let mut img = ImageBuffer::new(width, height);

    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let idx = (y * width + x) as usize;
        *pixel = Luma([data[idx]]);
    }

    DynamicImage::ImageLuma8(img)
}

/// Convert smoothness map (R8) to grayscale image
pub fn smoothness_to_image(width: u32, height: u32, data: &[u8]) -> DynamicImage {
    use image::{ImageBuffer, Luma};

    let mut img = ImageBuffer::new(width, height);
    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let idx = (y * width + x) as usize;
        *pixel = Luma([data[idx]]);
    }
    DynamicImage::ImageLuma8(img)
}

/// Convert edge map (R8) to grayscale image
pub fn edge_to_image(width: u32, height: u32, data: &[u8]) -> DynamicImage {
    use image::{ImageBuffer, Luma};

    let mut img = ImageBuffer::new(width, height);
    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let idx = (y * width + x) as usize;
        *pixel = Luma([data[idx]]);
    }
    DynamicImage::ImageLuma8(img)
}

/// Convert AO map (R8) to grayscale image
pub fn ao_to_image(width: u32, height: u32, data: &[u8]) -> DynamicImage {
    use image::{ImageBuffer, Luma};

    let mut img = ImageBuffer::new(width, height);
    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let idx = (y * width + x) as usize;
        *pixel = Luma([data[idx]]);
    }
    DynamicImage::ImageLuma8(img)
}

/// Map OutputFormat to ImageFormat
pub fn output_format_to_image_format(format: &super::cli::OutputFormat) -> ImageFormat {
    match format {
        super::cli::OutputFormat::Png => ImageFormat::Png,
        super::cli::OutputFormat::Jpg => ImageFormat::Jpeg,
        super::cli::OutputFormat::Tga => ImageFormat::Tga,
        super::cli::OutputFormat::Exr => ImageFormat::OpenExr,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_load_image_not_found() {
        let result = load_image("nonexistent.png");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("not found"));
    }

    #[test]
    fn test_get_output_paths() {
        let p = get_output_paths("textures/brick.png", "./output", "png");
        assert_eq!(p.height_path, "./output/brick_height.png");
        assert_eq!(p.normal_path, "./output/brick_normal.png");
        assert_eq!(p.metallic_path, "./output/brick_metallic.png");
        assert_eq!(p.smoothness_path, "./output/brick_smoothness.png");
        assert_eq!(p.edge_path, "./output/brick_edge.png");
        assert_eq!(p.ao_path, "./output/brick_ao.png");
    }

    #[test]
    fn test_get_output_paths_jpg() {
        let p = get_output_paths("textures/brick.png", "./output", "jpg");
        assert_eq!(p.height_path, "./output/brick_height.jpg");
        assert_eq!(p.normal_path, "./output/brick_normal.jpg");
        assert_eq!(p.metallic_path, "./output/brick_metallic.jpg");
        assert_eq!(p.smoothness_path, "./output/brick_smoothness.jpg");
        assert_eq!(p.edge_path, "./output/brick_edge.jpg");
        assert_eq!(p.ao_path, "./output/brick_ao.jpg");
    }

    #[test]
    fn test_save_exr_roundtrip() {
        // Grayscale maps are Luma8; the OpenEXR encoder rejects that directly.
        let dir = std::env::temp_dir().join("materialize_exr_test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("height.exr");

        let img = height_to_image(2, 2, &[0.0f32, 0.5, 1.0, 0.25]);
        save_image(&img, path.to_str().unwrap(), ImageFormat::OpenExr, 95)
            .expect("EXR save should succeed for a grayscale map");

        let reloaded = image::open(&path).expect("saved EXR should be readable");
        assert_eq!(reloaded.width(), 2);
        assert_eq!(reloaded.height(), 2);

        // Luma8 widens to RGB, and 0.5 quantised to 127 on the way in.
        let px = reloaded.to_rgb32f();
        assert!((px.get_pixel(0, 0)[0] - 0.0).abs() < 1e-5);
        assert!((px.get_pixel(1, 0)[0] - 127.0 / 255.0).abs() < 1e-5);
        assert!((px.get_pixel(0, 1)[0] - 1.0).abs() < 1e-5);

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_save_exr_normal_map() {
        let dir = std::env::temp_dir().join("materialize_exr_test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("normal.exr");

        let data = vec![128u8, 128, 255, 255, 0, 255, 0, 255,
                        255, 0, 0, 255, 64, 64, 200, 255];
        let img = normal_to_image(2, 2, &data);
        save_image(&img, path.to_str().unwrap(), ImageFormat::OpenExr, 95)
            .expect("EXR save should succeed for an RGB map");

        let reloaded = image::open(&path).expect("saved EXR should be readable");
        let px = reloaded.to_rgb32f();
        assert!((px.get_pixel(0, 0)[2] - 1.0).abs() < 1e-5);

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_height_to_image() {
        let data = vec![0.0f32, 0.5, 1.0, 0.25];
        let img = height_to_image(2, 2, &data);
        assert_eq!(img.width(), 2);
        assert_eq!(img.height(), 2);

        // Check pixel values (scaled to 0-255, truncation)
        let luma = img.to_luma8();
        assert_eq!(luma.get_pixel(0, 0)[0], 0);
        assert_eq!(luma.get_pixel(1, 0)[0], 127); // 0.5 * 255 truncated
        assert_eq!(luma.get_pixel(0, 1)[0], 255);
    }
}
