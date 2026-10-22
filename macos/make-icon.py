#!/usr/bin/env python3
"""Render the Materialize app icon to a PNG. Standard library only.

A lit, brick-textured sphere on the dark slate of the UI: the icon says
"PBR material preview" without any text. Shading runs in linear light and
both silhouettes (squircle, sphere) get analytic edge coverage, which is
sharper and ~4x cheaper than supersampling the whole canvas.

Usage: make-icon.py OUT.png [SIZE]
"""

import struct
import sys
import zlib
from math import asin, atan2, cos, pi, sin, sqrt

# Palette lifted from ui/index.html so the icon and the window agree.
BG_TOP = (0x1D, 0x22, 0x2A)
BG_BOT = (0x0A, 0x0C, 0x0F)
ACCENT = (0x5C, 0xC8, 0xFF)
BRICK = (0xA8, 0xAE, 0xB9)
MORTAR = (0x3C, 0x43, 0x4E)


def to_linear(c):
    """sRGB 0-255 to linear 0-1."""
    out = []
    for v in c:
        s = v / 255.0
        out.append(s / 12.92 if s <= 0.04045 else ((s + 0.055) / 1.055) ** 2.4)
    return out


def to_srgb(v):
    v = 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)
    s = v * 12.92 if v <= 0.0031308 else 1.055 * (v ** (1 / 2.4)) - 0.055
    return int(s * 255.0 + 0.5)


def smoothstep(edge0, edge1, x):
    t = (x - edge0) / (edge1 - edge0)
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    return t * t * (3.0 - 2.0 * t)


# The texture axis is yawed, then rolled within the screen plane. Rolling
# keeps both poles on the limb, where foreshortening hides them; pitching
# would swing one into view, and courses converging on a visible pole are
# what make a textured sphere read as a globe instead of a material sample.
_YAW, _ROLL = 0.42, 0.40
_CY, _SY = cos(_YAW), sin(_YAW)
_CR, _SR = cos(_ROLL), sin(_ROLL)


def brick_mask(nx, ny):
    """Brick-vs-mortar coverage at a point on the unit sphere, 1 = brick face."""
    nx = max(-1.0, min(1.0, nx))
    ny = max(-1.0, min(1.0, ny))
    nz = sqrt(max(0.0, 1.0 - nx * nx - ny * ny))
    # yaw about Y (spins the courses), then roll about Z (tilts the axis)
    rx = nx * _CY + nz * _SY
    rz = -nx * _SY + nz * _CY
    nx, ny, nz = rx * _CR - ny * _SR, rx * _SR + ny * _CR, rz
    su = atan2(nx, nz) / pi * 4.5
    sv = asin(max(-1.0, min(1.0, ny))) / (pi / 2.0) * 2.6
    if int(sv + 100.0) % 2:
        su += 0.5
    fu = su % 1.0
    fv = sv % 1.0
    mu = smoothstep(0.0, 0.085, min(fu, 1.0 - fu))
    mv = smoothstep(0.0, 0.10, min(fv, 1.0 - fv))
    return mu * mv


def render(size):
    bg_top = to_linear(BG_TOP)
    bg_bot = to_linear(BG_BOT)
    accent = to_linear(ACCENT)
    brick = to_linear(BRICK)
    mortar = to_linear(MORTAR)

    s = size / 1024.0
    # Apple's icon grid: the shape sits inside the canvas, leaving room for
    # the system's own shadow.
    half = 412.0 * s
    cx = cy = size / 2.0
    sq_n = 5.0                      # squircle exponent
    aa = 1.4 * s                     # edge softness in pixels

    sph_r = 268.0 * s
    sph_cx, sph_cy = cx, cy + 6.0 * s

    # Light from upper-left, viewer on +z.
    lx, ly, lz = -0.42, -0.58, 0.70
    ln = sqrt(lx * lx + ly * ly + lz * lz)
    lx, ly, lz = lx / ln, ly / ln, lz / ln
    hx, hy, hz = lx, ly, lz + 1.0   # half-vector with V = (0,0,1)
    hn = sqrt(hx * hx + hy * hy + hz * hz)
    hx, hy, hz = hx / hn, hy / hn, hz / hn

    rows = []
    for y in range(size):
        row = bytearray()
        row.append(0)  # PNG filter: none
        fy = y + 0.5
        v = (fy - cy) / half
        # Diagonal background gradient, evaluated per row then nudged per column.
        for x in range(size):
            fx = x + 0.5
            u = (fx - cx) / half

            # --- squircle coverage ---
            q = abs(u) ** sq_n + abs(v) ** sq_n
            # Convert the implicit value to an approximate pixel distance.
            qr = q ** (1.0 / sq_n)
            cov = 1.0 - smoothstep(1.0 - aa / half, 1.0 + aa / half, qr)
            if cov <= 0.0:
                row.extend((0, 0, 0, 0))
                continue

            t = (fx * 0.35 + fy * 0.65) / size
            r = bg_top[0] + (bg_bot[0] - bg_top[0]) * t
            g = bg_top[1] + (bg_bot[1] - bg_top[1]) * t
            b = bg_top[2] + (bg_bot[2] - bg_top[2]) * t

            # Faint vignette so the sphere sits in the plate.
            d_edge = 1.0 - qr
            vig = 0.82 + 0.18 * smoothstep(0.0, 0.35, d_edge)
            r, g, b = r * vig, g * vig, b * vig

            # --- sphere ---
            dx = fx - sph_cx
            dy = fy - sph_cy
            dist = sqrt(dx * dx + dy * dy)
            s_cov = 1.0 - smoothstep(sph_r - 1.2 * s, sph_r + 1.2 * s, dist)
            if s_cov > 0.0:
                # Clamp inside the limb so the normal stays defined on the
                # partially covered edge pixels.
                k = min(dist, sph_r - 0.001) / sph_r
                nx = (dx / dist) * k if dist > 0 else 0.0
                ny = (dy / dist) * k if dist > 0 else 0.0
                nz = sqrt(max(0.0, 1.0 - nx * nx - ny * ny))

                m = brick_mask(nx, ny)
                # Bevel the mortar: a screen-space gradient of the mask is the
                # same thing the CLI's normal pass does to a height map, and it
                # is what makes this read as a lit material and not a globe.
                e = 2.0 * s
                gx = brick_mask((dx + e) / sph_r, ny) - brick_mask((dx - e) / sph_r, ny)
                gy = brick_mask(nx, (dy + e) / sph_r) - brick_mask(nx, (dy - e) / sph_r)
                bx = nx + gx * 0.55
                by = ny + gy * 0.55
                bz = nz
                bl = sqrt(bx * bx + by * by + bz * bz) or 1.0
                bx, by, bz = bx / bl, by / bl, bz / bl

                ar = mortar[0] + (brick[0] - mortar[0]) * m
                ag = mortar[1] + (brick[1] - mortar[1]) * m
                ab = mortar[2] + (brick[2] - mortar[2]) * m

                ndl = bx * lx + by * ly + bz * lz
                diff = max(0.0, ndl) * 0.95
                # Wrapped fill, just enough to keep the shadow side readable.
                fill = 0.055 + 0.10 * max(0.0, -(nx * lx + ny * ly + nz * lz))
                # Mortar sits in shadow, as recessed grout does.
                occ = 0.45 + 0.55 * m

                ndh = max(0.0, bx * hx + by * hy + bz * hz)
                spec = (ndh ** 42.0) * (0.12 + 0.70 * m)
                rim = (1.0 - nz) ** 2.6 * 0.62 * (0.30 + 0.70 * max(0.0, -ndl))

                sr = ar * (diff + fill) * occ + spec + accent[0] * rim
                sg = ag * (diff + fill) * occ + spec + accent[1] * rim
                sb = ab * (diff + fill) * occ + spec + accent[2] * rim

                r = r + (sr - r) * s_cov
                g = g + (sg - g) * s_cov
                b = b + (sb - b) * s_cov

            # Glassy top edge, the usual macOS plate highlight.
            if v < 0.0:
                lip = smoothstep(0.90, 1.0, qr) * (1.0 - smoothstep(1.0, 1.0 + aa / half, qr))
                lip *= 0.22 * (1.0 - smoothstep(0.0, 0.9, abs(u)))
                r += lip
                g += lip
                b += lip

            a = int(cov * 255.0 + 0.5)
            row.extend((to_srgb(r), to_srgb(g), to_srgb(b), a))
        rows.append(bytes(row))
    return b"".join(rows)


def write_png(path, size, raw):
    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(png)


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = sys.argv[1]
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
    write_png(out, size, render(size))
    print(f"wrote {out} ({size}x{size})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
