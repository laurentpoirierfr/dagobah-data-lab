#!/usr/bin/env python3
"""Rend le site Hugo généré consultable en file:// (sans serveur web).

Avec des URL « jolies », Hugo produit des liens vers des dossiers
(href="../installation/" ou href="./docs/installation"). Un serveur web sert alors
index.html, mais un navigateur en file:// affiche le contenu du dossier. Ce script
ajoute « index.html » aux liens internes relatifs qui pointent vers un dossier
existant du site.

    file-links.py <dossier du site>    (appelé par « make docs »)
"""
import pathlib
import re
import sys

site = pathlib.Path(sys.argv[1]).resolve()
attr = re.compile(r'(\bhref=)("?)([^"\s>]*)')
changed_files = 0
changed_links = 0


def fix(match, page_dir):
    global changed_links
    prefix, quote, url = match.groups()
    if (not url or url.startswith(("#", "/", "http:", "https:", "mailto:", "data:", "javascript:"))
            or "://" in url):
        return match.group(0)
    path, sep, frag = url.partition("#")
    path, qsep, query = path.partition("?")
    target = (page_dir / path).resolve() if path else None
    if target is None or not str(target).startswith(str(site)) or not target.is_dir():
        return match.group(0)
    if not (target / "index.html").exists():
        return match.group(0)
    new_path = path.rstrip("/") + "/index.html" if path not in (".", "./") else "index.html"
    changed_links += 1
    return f"{prefix}{quote}{new_path}{qsep}{query}{sep}{frag}"


# SRI (integrity="sha256-…") : en file://, l'origine est nulle et le navigateur ne
# peut pas vérifier l'empreinte -> il BLOQUE le CSS/JS. On retire l'attribut sur les
# ressources locales (relatives) uniquement.
integrity = re.compile(r'(<(?:link|script)\b[^>]*?(?:href|src)="?(?!https?:|//)[^"\s>]+"?[^>]*?)\s+integrity=("[^"]*"|[^\s>]+)')
sri_removed = 0


def drop_sri(text):
    global sri_removed
    new, n = integrity.subn(r"\1", text)
    while n:  # plusieurs balises par ligne minifiée
        sri_removed += n
        new, n = integrity.subn(r"\1", new)
    return new


for page in site.rglob("*.html"):
    text = page.read_text(encoding="utf-8")
    new = drop_sri(attr.sub(lambda m: fix(m, page.parent), text))
    if new != text:
        page.write_text(new, encoding="utf-8")
        changed_files += 1

print(f"file-links : {changed_links} liens complétés par index.html, "
      f"{sri_removed} attributs integrity retirés, {changed_files} pages modifiées")
