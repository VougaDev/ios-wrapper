"""An app's words, never a website's: no web vocabulary in the native texts (App Review 4.2, Echo's rule).

Reads every Localizable/InfoPlist/Shell .strings file under the given folders and fails on a value that says page, site,
web, browser, click, link, URL, reload or tab, in English, French or Spanish."""
import pathlib
import re
import sys

WORDS = r"pages?|sites?|websites?|web|browsers?|click|clicks?|links?|urls?|reload|tabs?|" \
        r"navigateurs?|cliquer|cliquez|liens?|recharger|onglets?|" \
        r"páginas?|sitios?|navegador(?:es)?|clic|enlaces?|recargar|pestañas?"
BANNED = re.compile(rf"(?<![\w.])(?:{WORDS})(?![\w])", re.IGNORECASE)
VALUE = re.compile(r'^\s*"(?:[^"\\]|\\.)*"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.MULTILINE)

found = []
for root in sys.argv[1:]:
    for path in sorted(pathlib.Path(root).rglob("*.strings")):
        for value in VALUE.findall(path.read_text(encoding="utf-8")):
            for word in BANNED.findall(value):
                found.append(f"{path}: \"{word}\" in \"{value}\"")
print("\n".join(found) or "No web vocabulary in the native texts.")
sys.exit(1 if found else 0)
