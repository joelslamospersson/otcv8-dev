#!/usr/bin/env python3
"""Generate premium RPG-style tooltip assets for OTCV8."""

from PIL import Image, ImageDraw
import os

OUT_DIR = os.path.join(os.path.dirname(__file__), 'images')
os.makedirs(OUT_DIR, exist_ok=True)

# ─── Colour palette: aged bronze, subtle ───
BRONZE      = (165, 125, 35)
BRONZE_LIGHT= (185, 150, 50)
BRONZE_DIM  = (100, 75, 20)

# ─── 1. 9-slice border texture (64x64, 8px slice) ───
# Thin subtle aged-gold frame – elegant not flashy
SZ = 64
B = 8

img = Image.new('RGBA', (SZ, SZ), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Edge lines – single thin gold line with subtle dim neighbor
for x in range(B, SZ - B):
    draw.point((x, B - 2), BRONZE)
    draw.point((x, B - 3), BRONZE_DIM)
    draw.point((x, SZ - B + 1), BRONZE)
    draw.point((x, SZ - B + 2), BRONZE_DIM)
for y in range(B, SZ - B):
    draw.point((B - 2, y), BRONZE)
    draw.point((B - 3, y), BRONZE_DIM)
    draw.point((SZ - B + 1, y), BRONZE)
    draw.point((SZ - B + 2, y), BRONZE_DIM)

# ─── Subtle corner accents ───
# Small L-bracket at each corner, 3px each leg
for dx, dy in [(B - 2, B - 2), (SZ - B + 1, B - 2),
               (B - 2, SZ - B + 1), (SZ - B + 1, SZ - B + 1)]:
    for i in range(3):
        draw.point((dx + i, dy), BRONZE_LIGHT)
        draw.point((dx, dy + i), BRONZE_LIGHT)
    draw.point((dx + 1, dy + 1), BRONZE)

img.save(os.path.join(OUT_DIR, 'border.png'))
print(f"Generated: border.png ({SZ}x{SZ})")

# ─── 2. Flourish ornament (divider centre) 24x8 ───
# Engraved fantasy ornament – single centered diamond with thin wings
FW, FH = 24, 8
flourish = Image.new('RGBA', (FW, FH), (0, 0, 0, 0))
fdraw = ImageDraw.Draw(flourish)

cx, cy = FW // 2, FH // 2
# Center diamond
for dy in range(-2, 3):
    for dx in range(-2, 3):
        if abs(dx) + abs(dy) <= 2:
            shade = abs(dx) + abs(dy)
            c = BRONZE_LIGHT if shade == 0 else (BRONZE if shade <= 1 else BRONZE_DIM)
            fdraw.point((cx + dx, cy + dy), c)
# Wing dots
for side in [-7, 7]:
    fdraw.point((cx + side, cy), BRONZE)
    fdraw.point((cx + side, cy - 1), BRONZE_DIM)
    fdraw.point((cx + side, cy + 1), BRONZE_DIM)

flourish.save(os.path.join(OUT_DIR, 'flourish.png'))
print(f"Generated: flourish.png ({FW}x{FH})")

# ─── 3. Diamond bullet 8x8 ───
DS = 8
diamond = Image.new('RGBA', (DS, DS), (0, 0, 0, 0))
ddraw = ImageDraw.Draw(diamond)

c = DS // 2
for dy in range(-2, 3):
    w = 3 - abs(dy)
    for dx in range(-w + 1, w):
        dist = abs(dx) + abs(dy)
        col = BRONZE_LIGHT if dist == 0 else (BRONZE if dist <= 1 else BRONZE_DIM)
        ddraw.point((c + dx, c + dy), col)

diamond.save(os.path.join(OUT_DIR, 'diamond.png'))
print(f"Generated: diamond.png ({DS}x{DS})")

print("\nAll assets generated successfully.")
