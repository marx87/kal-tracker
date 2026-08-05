#!/usr/bin/env python3
"""Genera il marchio di Coach360 e tutte le sue declinazioni Android.

Perché uno script e non un PNG disegnato a mano: il marchio è geometria pura
(un anello, un punto, un accento) e la geometria si rigenera, mentre un PNG si
può solo ridisegnare a occhio. Cambiando un numero qui dentro si riallineano
insieme icona di sistema, icona adattiva, icona monocromatica del tema, logo di
avvio (chiaro e scuro) e glifo delle notifiche: sei famiglie che devono restare
lo stesso segno, altrimenti l'app sembra tre app diverse.

Il segno. Un anello aperto in alto a destra, con un punto sospeso nel varco e
un accento che sale dentro l'anello: il giro dei 360 gradi che non è ancora
chiuso, il passo che manca, la direzione in cui si va. Niente lettere, niente
emoji: a 48 px sopravvivono solo le forme piene.

Colori dal tema dell'app (`lib/core/theme/app_theme.dart`): verde bosco su
crema di giorno, foglia schiarita sul fondo notturno — le stesse costanti, non
somiglianze.

Uso:
    python3 assets/icon/build_icon.py

Dipendenza: Pillow. Non è una dipendenza dell'app: gira sul Mac, a mano, e i
risultati sono versionati.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

# --- Tavolozza (identica a AppPalette) ---------------------------------------
FOREST = (0x24, 0x5B, 0x45, 0xFF)  # AppPalette.forest
CREAM = (0xFB, 0xF7, 0xED, 0xFF)  # AppPalette.cream
LEAF_LIGHT = (0x78, 0xBE, 0x95, 0xFF)  # AppPalette.leafLight (tema notte)
BLACK = (0x00, 0x00, 0x00, 0xFF)
WHITE = (0xFF, 0xFF, 0xFF, 0xFF)
TRANSPARENT = (0, 0, 0, 0)

# --- Geometria del segno -----------------------------------------------------
# Tutto in un sistema dove il riquadro del marchio è 708 unità di lato: sono i
# 2 x 354 del raggio esterno dell'anello. Le proporzioni restano quelle a
# qualunque dimensione si renderizzi.
MARK_UNITS = 708.0

RING_RADIUS = 308.0  # raggio di mezzeria
RING_STROKE = 92.0  # 13% del marchio: a 48 px sono ~4,5 px, ancora pieni
RING_OUTER = RING_RADIUS + RING_STROKE / 2  # 354

# Angoli in convenzione Pillow: 0° a ore 3, crescenti in senso orario.
GAP_CENTER = 315.0  # il varco sta in alto a destra
GAP_HALF = 34.0

DOT_DIAMETER = RING_STROKE  # il punto sospeso nel varco

# L'accento che sale: una spezzata a due segmenti dentro l'anello.
CHEVRON = ((-135.0, 64.0), (0.0, -66.0), (135.0, 64.0))
CHEVRON_STROKE = 80.0

SUPERSAMPLE = 4  # Pillow non antialiasa: si disegna in grande e si riduce

RES = Path(__file__).resolve().parents[2] / "android/app/src/main/res"
ICONS = Path(__file__).resolve().parent

# Densità Android, con il moltiplicatore rispetto a mdpi.
DENSITIES = (("mdpi", 1.0), ("hdpi", 1.5), ("xhdpi", 2.0), ("xxhdpi", 3.0), ("xxxhdpi", 4.0))


def _polar(center: float, radius: float, degrees: float) -> tuple[float, float]:
    """Punto sull'anello, nella stessa convenzione angolare di Pillow."""
    radians = math.radians(degrees)
    return (center + radius * math.cos(radians), center + radius * math.sin(radians))


def draw_mark(
    size: int,
    color: tuple[int, int, int, int],
    *,
    background: tuple[int, int, int, int] = TRANSPARENT,
    mark_fraction: float = 1.0,
    corner_fraction: float = 0.0,
    with_chevron: bool = True,
) -> Image.Image:
    """Disegna il marchio dentro un quadrato di lato `size`.

    `mark_fraction` è quanto del lato occupa il marchio: serve perché la stessa
    forma vive in riquadri con margini diversi (l'icona adattiva deve stare
    nella zona sicura, il logo di avvio no). `corner_fraction` arrotonda il
    fondo: lo usa solo l'icona di sistema pre-Android 8, che nessun launcher
    ritaglia per lei.

    `with_chevron` a False lascia il solo anello: è la versione per la barra di
    stato, dove 24 px non reggono tre elementi.
    """
    scale = size * SUPERSAMPLE
    canvas = Image.new("RGBA", (scale, scale), TRANSPARENT)
    draw = ImageDraw.Draw(canvas)

    if background[3] != 0:
        if corner_fraction > 0:
            draw.rounded_rectangle(
                (0, 0, scale - 1, scale - 1),
                radius=scale * corner_fraction,
                fill=background,
            )
        else:
            draw.rectangle((0, 0, scale, scale), fill=background)

    unit = scale * mark_fraction / MARK_UNITS
    center = scale / 2

    ring_outer = RING_OUTER * unit
    ring_stroke = RING_STROKE * unit
    ring_radius = RING_RADIUS * unit

    # L'anello: un arco che parte dopo il varco e gira fino a ritrovarlo.
    box = (
        center - ring_outer,
        center - ring_outer,
        center + ring_outer,
        center + ring_outer,
    )
    start = GAP_CENTER + GAP_HALF
    end = GAP_CENTER - GAP_HALF + 360
    draw.arc(box, start=start, end=end, fill=color, width=round(ring_stroke))

    # Pillow taglia gli archi di netto: le due estremità si arrotondano a mano,
    # altrimenti il varco ha due tagli a scure in mezzo a una forma tutta curva.
    for angle in (start, end):
        cap_x, cap_y = _polar(center, ring_radius, angle)
        cap = ring_stroke / 2
        draw.ellipse((cap_x - cap, cap_y - cap, cap_x + cap, cap_y + cap), fill=color)

    # Il punto sospeso nel varco: il passo che manca perché il giro si chiuda.
    dot_x, dot_y = _polar(center, ring_radius, GAP_CENTER)
    dot = DOT_DIAMETER * unit / 2
    draw.ellipse((dot_x - dot, dot_y - dot, dot_x + dot, dot_y + dot), fill=color)

    if with_chevron:
        stroke = CHEVRON_STROKE * unit
        points = [(center + x * unit, center + y * unit) for x, y in CHEVRON]
        draw.line(points, fill=color, width=round(stroke), joint="curve")
        # Anche qui i terminali: `joint` arrotonda il vertice, non le punte.
        for point_x, point_y in (points[0], points[-1]):
            cap = stroke / 2
            draw.ellipse(
                (point_x - cap, point_y - cap, point_x + cap, point_y + cap), fill=color
            )

    return canvas.resize((size, size), Image.LANCZOS)


def write(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "PNG", optimize=True)
    print(f"  {path.relative_to(Path(__file__).resolve().parents[2])}")


def build() -> None:
    print("Sorgenti (per flutter_launcher_icons):")
    # Icona di sistema pre-Android 8: tessera crema con gli angoli già smussati,
    # perché lì nessun launcher applica una maschera propria.
    write(
        draw_mark(1024, FOREST, background=CREAM, mark_fraction=0.68, corner_fraction=0.22),
        ICONS / "app_icon.png",
    )
    # iOS pretende un quadrato pieno, senza canale alfa: stessa tessera, senza
    # angoli tolti (li arrotonda il sistema).
    write(
        draw_mark(1024, FOREST, background=CREAM, mark_fraction=0.68),
        ICONS / "app_icon_ios.png",
    )
    # Icona adattiva: il segno sta nel 64% centrale, dentro la zona che ogni
    # maschera — anche quella circolare, che ne mostra il 66,7% — garantisce.
    write(draw_mark(1024, FOREST, mark_fraction=0.64), ICONS / "app_icon_foreground.png")
    # Livello monocromatico dei temi Android 13: conta solo l'alfa, il colore lo
    # decide il sistema.
    write(draw_mark(1024, BLACK, mark_fraction=0.64), ICONS / "app_icon_monochrome.png")

    print("Icona di sistema (mipmap):")
    for name, factor in DENSITIES:
        size = round(48 * factor)
        write(
            draw_mark(
                size, FOREST, background=CREAM, mark_fraction=0.68, corner_fraction=0.22
            ),
            RES / f"mipmap-{name}/ic_launcher.png",
        )

    print("Icona adattiva (108dp) e livello monocromatico:")
    for name, factor in DENSITIES:
        size = round(108 * factor)
        write(
            draw_mark(size, FOREST, mark_fraction=0.64),
            RES / f"drawable-{name}/ic_launcher_foreground.png",
        )
        write(
            draw_mark(size, BLACK, mark_fraction=0.64),
            RES / f"drawable-{name}/ic_launcher_monochrome.png",
        )

    print("Logo della schermata d'avvio (160dp), giorno e notte:")
    for name, factor in DENSITIES:
        size = round(160 * factor)
        write(
            draw_mark(size, FOREST, mark_fraction=0.94),
            RES / f"drawable-{name}/ic_splash_logo.png",
        )
        # Di notte il verde bosco su fondo quasi nero sparisce: si passa alla
        # foglia schiarita, esattamente come fa il tema dell'app.
        write(
            draw_mark(size, LEAF_LIGHT, mark_fraction=0.94),
            RES / f"drawable-night-{name}/ic_splash_logo.png",
        )

    print("Glifo delle notifiche (24dp, solo alfa):")
    for name, factor in DENSITIES:
        size = round(24 * factor)
        # Senza accento: a 24 px tre elementi diventano una macchia.
        write(
            draw_mark(size, WHITE, mark_fraction=0.92, with_chevron=False),
            RES / f"drawable-{name}/ic_stat_coach360.png",
        )


if __name__ == "__main__":
    build()
