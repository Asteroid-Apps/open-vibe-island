#!/usr/bin/env python3
"""Bundle T3's ISC-licensed Lucide vectors as a native multipage PDF.

Build-time only: python -m pip install reportlab svglib
Reads literal icon nodes from the installed T3 bundle; executes no bundled JS.
Runtime rendering uses AppKit/PDFKit, with no browser or Python dependency.
"""
import argparse
import io
import json
import math
from pathlib import Path
import re
import struct
from xml.etree import ElementTree as ET
from reportlab.pdfgen import canvas
from reportlab.graphics import renderPDF
from svglib.svglib import svg2rlg

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--asar', type=Path, default=Path('/Applications/T3 Code (Beta).app/Contents/Resources/app.asar'))
parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / 'Sources/OpenIslandApp/Resources')
args = parser.parse_args()
with args.asar.open('rb') as archive:
    header = struct.unpack('<4I', archive.read(16))
    tree = json.loads(archive.read(header[3]))
    assets = tree['files']['apps']['files']['server']['files']['dist']['files']['client']['files']['assets']['files']
    def read_asset(name):
        entry = assets[name]
        archive.seek(8 + header[1] + int(entry['offset']))
        return archive.read(entry['size']).decode()
    sources = {name: read_asset(name) for name in assets if name.endswith('.js')}
    css = '\n'.join(read_asset(name) for name in assets if name.endswith('.css'))

nodes = {}
symbols = {}
imports = {}
exports = {}
for module, source in sources.items():
    local = {}
    for match in re.finditer(r'([\w$]+)=[\w$]+\(`([a-z0-9-]+)`,(\[\[.*?\]\])\)', source):
        literal = match[3].replace('`', '"')
        literal = re.sub(r'([,{])([A-Za-z_][\w-]*):', r'\1"\2":', literal)
        try:
            elements = json.loads(literal)
        except json.JSONDecodeError:
            continue
        if not all(len(node) == 2 and node[0] in {'path', 'line', 'polyline', 'polygon', 'rect', 'circle', 'ellipse'} for node in elements):
            continue
        nodes[match[2]] = elements
        local[match[1]] = match[2]
    symbols[module] = local
    imports[module] = {}
    for match in re.finditer(r'import\{([^}]+)\}from"\./([^"\n]+)"', source):
        for specifier in match[1].split(','):
            parts = specifier.split(' as ')
            imports[module][parts[-1]] = (match[2], parts[0])
    exports[module] = {}
    for match in re.finditer(r'export\{([^}]+)\}', source):
        for specifier in match[1].split(','):
            parts = specifier.split(' as ')
            exports[module][parts[-1]] = parts[0]


def resolve(module, symbol, seen=None):
    seen = set() if seen is None else seen
    if (module, symbol) in seen:
        return None
    seen.add((module, symbol))
    if symbol in symbols.get(module, {}):
        return symbols[module][symbol]
    if symbol in imports.get(module, {}):
        imported_module, imported_name = imports[module][symbol]
        return resolve(imported_module, exports.get(imported_module, {}).get(imported_name, imported_name), seen)
    return None

aliases = {}
for module, source in sources.items():
    if not module.startswith('lucideIconByName-'):
        continue
    # Includes the legacy names that T3's picker accepts, such as globe-2.
    for match in re.finditer(r'([A-Z][A-Za-z0-9]*):\(\)=>([\w$]+)', source):
        icon = resolve(module, match[2])
        if icon:
            name = '-'.join(re.findall(r'[A-Z][a-z]*|[0-9]+[a-z]*', match[1])).lower()
            aliases[name] = icon

assert len(nodes) > 1000 and aliases.get('folder-code') == 'folder-code', 'Unrecognized T3 Lucide bundle'
args.output.mkdir(parents=True, exist_ok=True)
pdf = canvas.Canvas(str(args.output / 't3-lucide-icons.pdf'), pagesize=(24, 24), invariant=1)
pdf.setTitle('Lucide project icons (ISC)')
pages = {}
for page, name in enumerate(sorted(nodes)):
    root = ET.Element('svg', {'xmlns': 'http://www.w3.org/2000/svg', 'width': '24', 'height': '24', 'viewBox': '0 0 24 24',
                              'fill': 'none', 'stroke': 'black', 'stroke-width': '2', 'stroke-linecap': 'round', 'stroke-linejoin': 'round'})
    for tag, attributes in nodes[name]:
        ET.SubElement(root, tag, {key: str(value).replace('currentColor', 'black') for key, value in attributes.items() if key != 'key'})
    drawing = svg2rlg(io.BytesIO(ET.tostring(root)))
    assert drawing is not None, name
    renderPDF.draw(drawing, pdf, 0, 0)
    pdf.showPage()
    pages[name] = page
pdf.save()
for alias, name in aliases.items():
    pages[alias] = pages[name]
(args.output / 't3-lucide-icons.json').write_text(json.dumps(pages, sort_keys=True, separators=(',', ':')) + '\n')

# Use T3's dark-mode Tailwind palette, converted from OKLCH to sRGB.
palette = {}
for name, lightness, chroma, hue in re.findall(r'--color-([a-z]+)-400:oklch\(([\d.]+)% ([\d.]+) ([\d.]+)\)', css):
    L, C, h = float(lightness)/100, float(chroma), math.radians(float(hue))
    a, b = C*math.cos(h), C*math.sin(h)
    l = (L + .3963377774*a + .2158037573*b)**3
    m = (L - .1055613458*a - .0638541728*b)**3
    s = (L - .0894841775*a - 1.291485548*b)**3
    linear = [4.0767416621*l - 3.3077115913*m + .2309699292*s,
              -1.2684380046*l + 2.6097574011*m - .3413193965*s,
              -.0041960863*l - .7034186147*m + 1.707614701*s]
    palette[name] = [round(max(0, min(1, 12.92*v if v <= .0031308 else 1.055*v**(1/2.4)-.055)), 6) for v in linear]
assert 'blue' in palette and 'gray' in palette
(args.output / 't3-project-colors.json').write_text(json.dumps(palette, sort_keys=True, separators=(',', ':')) + '\n')
print(f'Generated {len(nodes)} native vector pages and {len(pages)} icon names.')
