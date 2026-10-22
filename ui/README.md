# Materialize UI

A local web front-end for the `materialize` CLI. Drop in a diffuse texture,
run the real binary, preview the eight PBR maps in 2D and on a lit 3D material,
and export a Unity-ready folder.

```bash
python3 ui/serve.py
```

Opens <http://127.0.0.1:8765>. Standard library only — no pip installs.

On macOS the same UI ships as a double-clickable app, which starts this
server itself and shows it in a native window: see
[macos/README.md](../macos/README.md).

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | `8765` | Port to listen on |
| `--binary` | auto | Path to `materialize`; otherwise PATH, then `~/.local/bin`, then `target/release` |
| `--no-open` | — | Don't open a browser on start |

## Packed maps

The two channel-packed maps follow the HDRP layouts. Click either card to open
it and step through R/G/B/A, since a packed map is unreadable as a colour image.

| Mask Map | Detail Map |
|----------|------------|
| R Metallic | R Desaturated albedo |
| G Ambient Occlusion | G Normal Y |
| B Detail Mask | B Smoothness |
| A Smoothness | A Normal X |

## Export for Unity

Builds `<name>_Unity.zip`, laid out for dropping into `Assets/`:

```
<name>_Unity/
  <name>_Albedo.png     <name>_MaskMap.png    <name>_Height.png
  <name>_Normal.png     <name>_Detail.png
  README.md             import settings and material slots
  Editor/MaterializeImportSettings.cs
```

The editor script adds **Tools > Materialize > Apply Import Settings**, which
sets sRGB off on the data maps, the normal map's texture type, and high-quality
compression on the packed maps for a selected folder.

## Notes

- Binds to `127.0.0.1` only. Uploads land in a temp dir that is deleted on exit.
- The 3D preview pulls three.js from unpkg.com, so it needs network access.
  The Maps tab works offline.
- Smoothness is inverted to roughness before being handed to the 3D material,
  since they are complements.
- TGA and EXR can't render in a browser, so a parallel PNG pass is generated
  purely for the preview; the saved files still use the format you picked.
- EXR is written as 32-bit float RGB. The maps are generated at 8-bit, so the
  values are exact but carry no extra precision over PNG.
