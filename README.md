# Materialize CLI

A **Rust CLI** that generates PBR (Physically Based Rendering) maps from diffuse textures using GPU compute shaders via [wgpu](https://wgpu.rs/). One command, six maps, plus optional Unity HDRP packed maps — from the terminal, or from a window if you prefer one.

A fork of [maikramer/Materialize-CLI](https://github.com/maikramer/Materialize-CLI), which was inspired by the original [Materialize](https://github.com/BoundingBoxSoftware/Materialize) (Unity/Windows). For a Portuguese version, see [README_PT.md](README_PT.md).

**Who is this for?** Game developers, 3D artists, and anyone who needs PBR maps from diffuse textures — in engines like Unity, Unreal, Godot, or in Blender, without the Windows-only original.

---

## Generated maps

From a single diffuse/albedo image, the tool outputs six maps:

| Map | Description |
|-----|-------------|
| **Height** | Surface elevation for parallax/displacement |
| **Normal** | Surface normals for lighting |
| **Metallic** | Metallic vs dielectric mask |
| **Smoothness** | Roughness/smoothness (base + metallic contribution) |
| **Edge** | Edge detection derived from normals |
| **AO** | Ambient occlusion (cavity-style from height) |

With `--unity`, two more channel-packed maps for Unity HDRP:

| Map | Channels |
|-----|----------|
| **Mask Map** | R Metallic, G Ambient Occlusion, B Detail Mask, A Smoothness |
| **Detail Map** | R Desaturated albedo, G Normal Y, B Smoothness, A Normal X |

---

## Features

- **Minimal** — Command-line only; easy to script and automate
- **Fast** — GPU compute shaders (wgpu); no CPU-bound image loops
- **Cross-platform** — Linux, macOS, Windows (Vulkan, Metal, DirectX 12)
- **Flexible** — Output formats: PNG, JPG, TGA, EXR; configurable quality for JPEG

---

## Quick start

### macOS app

For a double-clickable app instead of a terminal — same maps, same exports,
with a window and a drop zone:

```bash
./macos/build-app.sh              # builds dist/Materialize.app
./macos/build-app.sh --install    # ...and copies it to /Applications
```

Apple silicon, macOS 12+. The bundle carries its own copy of the CLI, so it
runs with nothing else installed. See [macos/README.md](macos/README.md).

### Install (recommended)

Requires **Python 3** (installer) and **Rust** (cargo) to build. The installer compiles and places the binary in `~/.local/bin/materialize` (ensure it’s on your `PATH`).

```bash
git clone https://github.com/maikramer/Materialize-CLI.git
cd Materialize-CLI
./install.sh
```

- **Linux/macOS:** `./install.sh` | `./install.sh uninstall` | `./install.sh reinstall`
- **Windows:** `.\install.ps1` or `install.bat`

### Run

```bash
materialize texture.png
# Writes to current directory:
#   texture_height.png, texture_normal.png, texture_metallic.png,
#   texture_smoothness.png, texture_edge.png, texture_ao.png

materialize texture.png -o ./out/ -v
materialize diffuse.png --format png --quiet
```

### Manual build (Cargo)

```bash
cargo build --release
cargo install --path .
```

---

## Usage

### Syntax

```text
materialize [OPTIONS] [INPUT] [COMMAND]
```

### Options

| Option | Short | Default | Description |
|--------|-------|---------|-------------|
| `--output` | `-o` | `./` | Output directory |
| `--format` | `-f` | `png` | Output format: `png`, `jpg`, `jpeg`, `tga`, `exr` |
| `--quality` | `-q` | `95` | JPEG quality (0–100) when using `-f jpg` |
| `--verbose` | `-v` | — | Print progress and timing |
| `--quiet` | — | — | Do not list generated files on success |
| `--unity` | — | — | Also write the HDRP mask and detail maps (needs png, tga or exr) |
| `--help` | `-h` | — | Show help |
| `--version` | `-V` | — | Show version |

### Subcommands

- **`materialize skill install`** — Installs the Materialize CLI [Cursor skill](.cursor/skills/materialize-cli/) into the current project’s `.cursor/skills/materialize-cli/`.

### Output naming

For input `texture.png`, outputs are:

- `texture_height.png`
- `texture_normal.png`
- `texture_metallic.png`
- `texture_smoothness.png`
- `texture_edge.png`
- `texture_ao.png`

(Extension follows `--format`.)

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Generic error |
| `2` | Input file not found |
| `3` | Unsupported input format |
| `4` | GPU error (no adapter) |
| `5` | I/O error (permissions, disk full, etc.) |
| `6` | Image too large for GPU |

---

## Examples

```bash
# Default: current directory, PNG
materialize brick.png

# Custom output directory and verbose
materialize brick.png -o ./materials/brick/ -v

# EXR for HDR / precision
materialize texture.png -f exr -o ./out/

# Batch (parallel with xargs)
ls *.png | xargs -P 4 -I {} materialize {} -o ./output/

# Unity HDRP: adds brick_maskmap.png and brick_detail.png
materialize brick.png -o ./out/ --unity

# Script-friendly: quiet, check exit code
materialize texture.png -o ./out/ --quiet
if [ $? -eq 0 ]; then echo "OK"; fi
```

---

## Getting help

- **Bugs & features** — [Open an issue](https://github.com/maikramer/Materialize-CLI/issues) (templates for bug reports and feature requests are available).
- **Questions** — [GitHub Discussions](https://github.com/maikramer/Materialize-CLI/discussions).
- **Contributing** — See [CONTRIBUTING.md](CONTRIBUTING.md). We follow a [Code of Conduct](CODE_OF_CONDUCT.md).

---

## Requirements

- **Rust** 1.75+
- **GPU** with Vulkan (Linux), Metal (macOS), or DirectX 12 (Windows); up-to-date drivers

---

## Documentation

- [docs/README.md](docs/README.md) — Overview, installation details, and doc index
- [docs/cli-api.md](docs/cli-api.md) — Full CLI reference, env vars, shell completion
- [docs/architecture.md](docs/architecture.md) — System structure
- [docs/features.md](docs/features.md) — Capabilities
- [docs/algorithms.md](docs/algorithms.md) — Processing algorithms
- [docs/shaders.md](docs/shaders.md) — WGSL shaders
- [docs/roadmap.md](docs/roadmap.md) — Future plans
- [macos/README.md](macos/README.md) — The macOS app bundle
- [ui/README.md](ui/README.md) — The local web UI

---

## License

[MIT](LICENSE). Forked from [maikramer/Materialize-CLI](https://github.com/maikramer/Materialize-CLI), itself based on the original Materialize by Bounding Box Software.
