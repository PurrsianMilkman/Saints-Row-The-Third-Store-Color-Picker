"""Fill the character colour pool up to 255 entries with hsl_NN records.

    python tools/gen_palette.py <installed character_color_pool.xtbl> <out xtbl> <out report>

WHY 255: the save stores each owned clothing item's colours as u8 pool indices with
0xFF meaning "none" (owned-item records in the save), so the pool must stay <= 255 entries (0..254).
Existing entries are kept byte-for-byte and in order, so no item default and no saved index moves; the
rest are appended (129 on the vanilla 126-colour pool, 60 on a 195-colour pool from another colour mod).
With SR3StoreColorPicker.asi these records become the true-RGB slots; without it the picker snaps to
them, so they are placed to fill the pool's gaps:

WHERE THEY GO: farthest-point sampling. Every candidate on a dense HSL grid is scored by its distance
to the nearest colour already in the pool, and the worst-covered one is added, until 255. Distances
are measured in OKLab on what the cloth actually shows: the player cloth shader maps a table value
v to Reinhard(5 * v/255) (Tint_color = 5, read from the cloth pixel shader constant c37), so 255 -> 0.833
linear and 102 -> 0.667. The picker's Lua uses the same appearance mapping.
"""
import re, sys, math

KEEP = 255          # u8 index ceiling (0xFF = none)
TINT = 5.0
TOP = TINT / (1 + TINT)          # appearance of v = 255


def appearance(v):               # table value 0..255 -> displayed linear 0..1 (1 = brightest possible)
    x = TINT * v / 255.0
    return x / (1 + x) / TOP


def inv_appearance(a):           # displayed linear 0..1 -> table value 0..255
    l = min(max(a, 0.0), 1.0) * TOP
    return 255.0 * l / (TINT * (1 - l)) if l < TOP else 255.0


def srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def oklab(r, g, b):              # linear rgb -> OKLab
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (max(v, 0) ** (1 / 3) for v in (l, m, s))
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def hsl_to_srgb(h, s, l):
    c = (1 - abs(2 * l - 1)) * s
    hp = (h % 360) / 60.0
    x = c * (1 - abs(hp % 2 - 1))
    r, g, b = [(c, x, 0), (x, c, 0), (0, c, x), (0, x, c), (x, 0, c), (c, 0, x)][int(hp) % 6]
    m = l - c / 2
    return r + m, g + m, b + m


def lab_of_table(rgb):
    return oklab(*(appearance(v) for v in rgb))


def dist(a, b):
    return math.sqrt(sum((p - q) ** 2 for p, q in zip(a, b)))


def main(src, dst, report):
    text = open(src, encoding='utf-8', newline='').read()
    eol = '\r\n' if '\r\n' in text else '\n'
    entries = re.findall(r'<Color_Entry>.*?</Color_Entry>', text, re.S)
    rgbs = [tuple(int(re.search(rf'<{c}>(\d+)</{c}>', e).group(1)) for c in 'RGB') for e in entries]
    names = [re.search(r'<Name>([^<]*)</Name>', e).group(1) for e in entries]
    n_old = len(entries)
    assert n_old < KEEP, f'pool already has {n_old} entries'
    assert not any(nm.startswith('hsl_') for nm in names), 'pool already contains hsl_ entries (run on the ORIGINAL pool)'
    room = KEEP - n_old

    have = [lab_of_table(c) for c in rgbs]
    cands = []
    for h in range(0, 360, 6):
        for s in (0.25, 0.45, 0.65, 0.85, 1.0):
            for l in (0.08, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 0.93):
                sr = hsl_to_srgb(h, s, l)
                lin = [srgb_to_lin(c) for c in sr]
                tab = tuple(int(round(inv_appearance(c))) for c in lin)
                cands.append(((h, s, l), tab, lab_of_table(tab)))
    best = [min(dist(c[2], p) for p in have) for c in cands]
    picked = []
    for _ in range(room):
        i = max(range(len(cands)), key=best.__getitem__)
        picked.append((cands[i], best[i]))
        lab = cands[i][2]
        best = [min(b, dist(c[2], lab)) for b, c in zip(best, cands)]

    blocks = []
    lines = [f'pool: {n_old} kept + {len(picked)} added = {n_old + len(picked)} (max {KEEP})',
             'idx  name       table RGB        from HSL         gap(OKLab)']
    for k, ((hsl, tab, lab), gap) in enumerate(picked):
        idx = n_old + k
        nm = f'hsl_{k + 1:02d}'
        blocks.append('\t<Color_Entry>\n'
                      f'\t\t<Name>{nm}</Name>\n'
                      f'\t\t<DisplayName>{nm.upper()}</DisplayName>\n'
                      '\t\t<Color>\n'
                      f'\t\t\t<R>{tab[0]}</R>\n\t\t\t<G>{tab[1]}</G>\n\t\t\t<B>{tab[2]}</B>\n'
                      '\t\t</Color>\n'
                      '\t\t<_Editor><Category>Entries</Category></_Editor>\n'
                      '\t</Color_Entry>\n')
        lines.append(f'{idx:3d}  {nm}  {tab!s:16} h{hsl[0]:3d} s{hsl[1]:.2f} l{hsl[2]:.2f}  {gap:.4f}')
    after = max(best)
    lines.append(f'worst remaining gap after adding: {after:.4f} (largest gap before: {picked[0][1]:.4f})')

    last = text.rindex('</Color_Entry>') + len('</Color_Entry>')
    nl = text.index('\n', last) + 1
    out = text[:nl] + ''.join(blocks).replace('\n', eol) + text[nl:]
    open(dst, 'w', encoding='utf-8', newline='').write(out)
    open(report, 'w').write('\n'.join(lines) + '\n')
    print('\n'.join(lines[:2] + lines[-1:]))


if __name__ == '__main__':
    main(*sys.argv[1:4])
