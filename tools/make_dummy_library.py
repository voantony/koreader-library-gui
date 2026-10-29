#!/usr/bin/env python3
"""Generate a dummy library of public-domain EPUBs with covers, for testing.

Creates, under OUT (default ./dummy):

  OUT/metadata.calibre                    calibre-style index (lpath relative to OUT)
  OUT/documents/<Author>/<Title>.epub     EPUB 2 files with a JPEG cover
  OUT/documents/<Author>/<Title>.sdr/     a few KOReader sidecars (reading/finished)
  OUT/koreader/history.lua                reading history for those books
  OUT/koreader/settings/collection.lua    two collections

All titles and authors are public domain; nothing here comes from a real device.
Requires Pillow.  Usage: make_dummy_library.py [--out DIR] [--count 200]
"""
import argparse
import json
import os
import random
import zipfile
from io import BytesIO
from xml.sax.saxutils import escape

from PIL import Image, ImageDraw, ImageFont

WORKS = [
    ("Jane Austen", ["Pride and Prejudice", "Sense and Sensibility", "Emma", "Persuasion", "Mansfield Park", "Northanger Abbey"]),
    ("Charles Dickens", ["Great Expectations", "Oliver Twist", "David Copperfield", "Bleak House", "Hard Times", "A Tale of Two Cities", "Little Dorrit", "Our Mutual Friend"]),
    ("Arthur Conan Doyle", ["A Study in Scarlet", "The Sign of the Four", "The Adventures of Sherlock Holmes", "The Memoirs of Sherlock Holmes", "The Hound of the Baskervilles", "The Valley of Fear", "The Return of Sherlock Holmes", "His Last Bow"]),
    ("H. G. Wells", ["The Time Machine", "The War of the Worlds", "The Invisible Man", "The Island of Doctor Moreau", "The First Men in the Moon", "The Food of the Gods"]),
    ("Jules Verne", ["Twenty Thousand Leagues Under the Seas", "Around the World in Eighty Days", "Journey to the Center of the Earth", "From the Earth to the Moon", "The Mysterious Island", "Five Weeks in a Balloon"]),
    ("Mark Twain", ["The Adventures of Tom Sawyer", "Adventures of Huckleberry Finn", "The Prince and the Pauper", "A Connecticut Yankee in King Arthur's Court", "Life on the Mississippi", "The Innocents Abroad"]),
    ("L. Frank Baum", ["The Wonderful Wizard of Oz", "The Marvelous Land of Oz", "Ozma of Oz", "Dorothy and the Wizard in Oz", "The Road to Oz", "The Emerald City of Oz"]),
    ("Edgar Rice Burroughs", ["A Princess of Mars", "The Gods of Mars", "The Warlord of Mars", "Thuvia, Maid of Mars", "Tarzan of the Apes", "The Return of Tarzan"]),
    ("Anthony Trollope", ["The Warden", "Barchester Towers", "Doctor Thorne", "Framley Parsonage", "The Small House at Allington", "The Last Chronicle of Barset"]),
    ("Leo Tolstoy", ["War and Peace", "Anna Karenina", "The Death of Ivan Ilyich", "Resurrection"]),
    ("Fyodor Dostoevsky", ["Crime and Punishment", "The Brothers Karamazov", "The Idiot", "Notes from Underground", "Demons"]),
    ("Herman Melville", ["Moby-Dick", "Typee", "Omoo", "Bartleby, the Scrivener", "Billy Budd"]),
    ("Charlotte Brontë", ["Jane Eyre", "Villette", "Shirley", "The Professor"]),
    ("Emily Brontë", ["Wuthering Heights"]),
    ("Anne Brontë", ["Agnes Grey", "The Tenant of Wildfell Hall"]),
    ("Mary Shelley", ["Frankenstein", "The Last Man", "Mathilda"]),
    ("Bram Stoker", ["Dracula", "The Jewel of Seven Stars", "The Lair of the White Worm"]),
    ("Robert Louis Stevenson", ["Treasure Island", "Kidnapped", "Catriona", "Strange Case of Dr Jekyll and Mr Hyde", "The Black Arrow", "The Master of Ballantrae"]),
    ("Joseph Conrad", ["Heart of Darkness", "Lord Jim", "Nostromo", "The Secret Agent", "Typhoon"]),
    ("Thomas Hardy", ["Tess of the d'Urbervilles", "Far from the Madding Crowd", "Jude the Obscure", "The Mayor of Casterbridge", "The Return of the Native"]),
    ("George Eliot", ["Middlemarch", "Silas Marner", "The Mill on the Floss", "Adam Bede", "Daniel Deronda"]),
    ("Oscar Wilde", ["The Picture of Dorian Gray", "The Importance of Being Earnest", "The Happy Prince and Other Tales"]),
    ("Alexandre Dumas", ["The Three Musketeers", "Twenty Years After", "The Vicomte of Bragelonne", "The Count of Monte Cristo"]),
    ("Victor Hugo", ["Les Misérables", "The Hunchback of Notre-Dame", "Toilers of the Sea"]),
    ("Lewis Carroll", ["Alice's Adventures in Wonderland", "Through the Looking-Glass", "The Hunting of the Snark"]),
    ("Jack London", ["The Call of the Wild", "White Fang", "The Sea-Wolf", "Martin Eden", "The Iron Heel"]),
    ("Edith Wharton", ["The Age of Innocence", "The House of Mirth", "Ethan Frome", "The Custom of the Country"]),
    ("Henry James", ["The Turn of the Screw", "The Portrait of a Lady", "Washington Square", "The Ambassadors", "Daisy Miller"]),
    ("Nathaniel Hawthorne", ["The Scarlet Letter", "The House of the Seven Gables", "The Blithedale Romance"]),
    ("Louisa May Alcott", ["Little Women", "Good Wives", "Little Men", "Jo's Boys"]),
    ("Lucy Maud Montgomery", ["Anne of Green Gables", "Anne of Avonlea", "Anne of the Island", "Anne's House of Dreams"]),
    ("Rudyard Kipling", ["The Jungle Book", "The Second Jungle Book", "Kim", "Just So Stories", "Captains Courageous"]),
    ("Walter Scott", ["Ivanhoe", "Waverley", "Rob Roy", "The Heart of Midlothian", "Kenilworth"]),
    ("Daniel Defoe", ["Robinson Crusoe", "Moll Flanders", "A Journal of the Plague Year"]),
    ("Jonathan Swift", ["Gulliver's Travels", "A Modest Proposal"]),
    ("Homer", ["The Iliad", "The Odyssey"]),
    ("Edgar Allan Poe", ["The Fall of the House of Usher", "The Narrative of Arthur Gordon Pym", "Tales of the Grotesque and Arabesque"]),
    ("E. Nesbit", ["The Railway Children", "Five Children and It", "The Phoenix and the Carpet", "The Story of the Amulet"]),
    ("G. K. Chesterton", ["The Innocence of Father Brown", "The Wisdom of Father Brown", "The Man Who Was Thursday", "The Napoleon of Notting Hill"]),
    ("John Buchan", ["The Thirty-Nine Steps", "Greenmantle", "Mr Standfast", "Huntingtower"]),
    ("Kenneth Grahame", ["The Wind in the Willows"]),
    ("Frances Hodgson Burnett", ["The Secret Garden", "A Little Princess", "Little Lord Fauntleroy"]),
    ("Anna Sewell", ["Black Beauty"]),
    ("Miguel de Cervantes", ["Don Quixote"]),
    ("Gustave Flaubert", ["Madame Bovary", "Salammbô", "Sentimental Education"]),
    ("Ivan Turgenev", ["Fathers and Sons", "A Sportsman's Sketches", "Smoke"]),
    ("Elizabeth Gaskell", ["North and South", "Cranford", "Wives and Daughters", "Mary Barton"]),
    ("Wilkie Collins", ["The Woman in White", "The Moonstone", "Armadale", "No Name"]),
]

SERIES = {
    "Arthur Conan Doyle": "Sherlock Holmes",
    "L. Frank Baum": "Oz",
    "Anthony Trollope": "Chronicles of Barsetshire",
    "Lucy Maud Montgomery": "Anne of Green Gables",
    "John Buchan": "Richard Hannay",
    "E. Nesbit": "Psammead",
    "Alexandre Dumas": "The d'Artagnan Romances",
}
BURROUGHS_SERIES = {"A Princess of Mars": ("Barsoom", 1), "The Gods of Mars": ("Barsoom", 2),
                    "The Warlord of Mars": ("Barsoom", 3), "Thuvia, Maid of Mars": ("Barsoom", 4),
                    "Tarzan of the Apes": ("Tarzan", 1), "The Return of Tarzan": ("Tarzan", 2)}

FONT_DIRS = ["/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/truetype/liberation"]


def font(size, bold=False):
    names = ["DejaVuSerif-Bold.ttf" if bold else "DejaVuSerif.ttf",
             "LiberationSerif-Bold.ttf" if bold else "LiberationSerif-Regular.ttf"]
    for d in FONT_DIRS:
        for n in names:
            p = os.path.join(d, n)
            if os.path.exists(p):
                return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def wrap(draw, text, fnt, width):
    lines, line = [], ""
    for word in text.split():
        trial = (line + " " + word).strip()
        if draw.textlength(trial, font=fnt) <= width:
            line = trial
        else:
            if line:
                lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def make_cover(title, author, seed):
    rnd = random.Random(seed)
    w, h = 600, 900
    base = tuple(rnd.randint(30, 200) for _ in range(3))
    img = Image.new("RGB", (w, h), base)
    d = ImageDraw.Draw(img)
    for y in range(h):  # simple vertical gradient
        k = y / h
        d.line([(0, y), (w, y)], fill=tuple(int(c * (1 - 0.5 * k)) for c in base))
    d.rectangle([30, 30, w - 30, h - 30], outline=(255, 255, 255), width=4)
    tf, af = font(54, True), font(34)
    y = 170
    for line in wrap(d, title, tf, w - 120):
        tw = d.textlength(line, font=tf)
        d.text(((w - tw) / 2, y), line, font=tf, fill=(255, 255, 255))
        y += 66
    tw = d.textlength(author, font=af)
    d.text(((w - tw) / 2, h - 170), author, font=af, fill=(240, 240, 240))
    buf = BytesIO()
    img.save(buf, "JPEG", quality=80)
    return buf.getvalue()


def make_epub(path, title, author, series, series_index, uid, cover):
    series_meta = ""
    if series:
        series_meta = (f'<meta name="calibre:series" content="{escape(series)}"/>'
                       f'<meta name="calibre:series_index" content="{series_index}"/>')
    opf = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="2.0">
 <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
  <dc:title>{escape(title)}</dc:title>
  <dc:creator opf:role="aut">{escape(author)}</dc:creator>
  <dc:language>en</dc:language>
  <dc:identifier id="uid">urn:uuid:{uid}</dc:identifier>
  <meta name="cover" content="cover-image"/>{series_meta}
 </metadata>
 <manifest>
  <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  <item id="cover-image" href="cover.jpg" media-type="image/jpeg"/>
  <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
 </manifest>
 <spine toc="ncx"><itemref idref="ch1"/></spine>
</package>"""
    ncx = f"""<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
 <head><meta name="dtb:uid" content="urn:uuid:{uid}"/></head>
 <docTitle><text>{escape(title)}</text></docTitle>
 <navMap><navPoint id="n1" playOrder="1"><navLabel><text>Chapter 1</text></navLabel><content src="ch1.xhtml"/></navPoint></navMap>
</ncx>"""
    para = ("This is a placeholder text for testing. " * 40).strip()
    body = "".join(f"<p>{para}</p>" for _ in range(30))
    ch1 = f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{escape(title)}</title></head>
<body><h1>{escape(title)}</h1><h2>{escape(author)}</h2>{body}</body></html>"""
    container = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
 <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("toc.ncx", ncx, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("ch1.xhtml", ch1, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("cover.jpg", cover, compress_type=zipfile.ZIP_STORED)


def safe(name):
    return "".join(c for c in name if c not in '/\\:*?"<>|').strip()


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="dummy")
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    rnd = random.Random(args.seed)
    out = os.path.abspath(args.out)
    docs = os.path.join(out, "documents")
    os.makedirs(docs, exist_ok=True)

    books = []
    for author, titles in WORKS:
        for i, title in enumerate(titles, 1):
            series, idx = SERIES.get(author), i
            if title in BURROUGHS_SERIES:
                series, idx = BURROUGHS_SERIES[title]
            books.append((author, title, series if series else None, idx if series else None))
    vol = 1
    while len(books) < args.count:  # pad with numbered anthologies
        author, titles = WORKS[vol % len(WORKS)]
        books.append((author, f"Collected Works, Volume {vol}", "Collected Works", vol))
        vol += 1
    books = books[:args.count]

    calibre, entries = [], []
    base_time = 1_780_000_000
    for n, (author, title, series, idx) in enumerate(books):
        rel_dir = os.path.join("documents", safe(author))
        os.makedirs(os.path.join(out, rel_dir), exist_ok=True)
        rel = os.path.join(rel_dir, safe(title) + ".epub")
        path = os.path.join(out, rel)
        uid = f"00000000-0000-4000-8000-{n:012d}"
        make_epub(path, title, author, series, idx, uid, make_cover(title, author, n))
        mtime = base_time - n * 3600
        os.utime(path, (mtime, mtime))
        calibre.append({
            "uuid": uid, "lpath": rel, "title": title, "authors": [author],
            "author_sort": author, "series": series, "series_index": idx,
            "tags": ["Public domain"], "size": os.path.getsize(path),
            "last_modified": "2026-01-01T00:00:00+00:00",
        })
        entries.append(path)
    with open(os.path.join(out, "metadata.calibre"), "w", encoding="utf-8") as f:
        json.dump(calibre, f, ensure_ascii=False, indent=1)

    # Reading state for a handful of books: sidecars + history.
    kodir = os.path.join(out, "koreader")
    os.makedirs(os.path.join(kodir, "settings"), exist_ok=True)
    picks = rnd.sample(entries, 36)
    history = []
    for k, path in enumerate(picks):
        status, pct = ("complete", 1.0) if k % 3 == 0 else ("reading", round(rnd.uniform(0.05, 0.95), 3))
        if k == 5:
            status = "abandoned"
        sdr = path[:-5] + ".sdr"
        os.makedirs(sdr, exist_ok=True)
        with open(os.path.join(sdr, "metadata.epub.lua"), "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write(f'    ["percent_finished"] = {pct},\n')
            f.write(f'    ["summary"] = {{ ["status"] = "{status}" }},\n')
            f.write(f'    ["doc_path"] = {lua_str(path)},\n')
            f.write("}\n")
        history.append((base_time + 86400 - k * 600, path))
    with open(os.path.join(kodir, "history.lua"), "w", encoding="utf-8") as f:
        f.write("return {\n")
        for t, p in history:
            f.write(f"    {{ time = {t}, file = {lua_str(p)} }},\n")
        f.write("}\n")
    sea = [p for p in entries if any(s in p for s in ("Moby", "Typee", "Omoo", "Twenty Thousand", "Robinson", "Sea-Wolf", "Treasure", "Typhoon", "Billy Budd"))]
    fav = picks[:6]
    with open(os.path.join(kodir, "settings", "collection.lua"), "w", encoding="utf-8") as f:
        f.write("return {\n")
        for name, files, order in (("favorites", fav, 1), ("Sea stories", sea, 2), ("Mysteries", [p for p in entries if "Sherlock" in p or "Moonstone" in p or "Woman in White" in p or "Father Brown" in p], 3)):
            f.write(f"    [{lua_str(name)}] = {{\n")
            for i, p in enumerate(files, 1):
                f.write(f"        {{ file = {lua_str(p)}, order = {i} }},\n")
            f.write(f"        settings = {{ order = {order} }},\n    }},\n")
        f.write("}\n")
    print(f"{len(entries)} books in {docs}; {len(picks)} with reading state")


if __name__ == "__main__":
    main()
