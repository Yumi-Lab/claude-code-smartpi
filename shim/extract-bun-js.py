#!/usr/bin/env python3
"""
extract-bun-js.py — Extrait le JavaScript lisible d'un binaire Claude Code
compile par Bun (`bun build --compile`).

- Version-agnostique : ne depend d'aucun numero de version (marche sur 2.1.113
  jusqu'a la derniere, ex. 2.1.212+). Ne PAS confondre avec la 2.1.112 npm qui
  est deja du cli.js pur (rien a extraire).
- Multi-plateforme : macOS (section Mach-O __BUN,__bun), Linux (blob appendu a
  l'ELF), Windows (section PE .bun). On ne parse AUCUN format executable : on
  scanne les octets bruts, donc les 3 marchent avec le meme code.
- Zero dependance externe (stdlib seule) : tourne aussi sur armv7l.

Principe : un binaire Bun standalone termine sa graphe de modules serialisee par
le trailer magique "\\n---- Bun! ----\\n". Les sources JS y sont stockees EN CLAIR
(meme avec --bytecode : JSC exige la source a cote du bytecode). On repere le
trailer pour confirmer que c'est bien un binaire Bun, puis on carve les grands
blocs de texte imprimable = les modules JS (le bytecode/binaire est exclu de fait).

IMPORTANT (rappels, cf. skill) :
- Le JS extrait est IDENTIQUE quelle que soit la plateforme du binaire source :
  extraire depuis le binaire macOS/x64 donne le meme bundle qu'un binaire arm64.
  => extraire sur une grosse machine, utiliser le resultat partout.
- Le bundle >=2.1.113 appelle des API Bun-only sans garde (Bun.spawn, Bun.file,
  bun:ffi, bun:jsc) : il est LISIBLE/greppable mais PAS executable sous Node tel
  quel (il faudrait un polyfill Bun). Pour de l'inspection/audit, pas un drop-in.
- Extraire pour soi = ok ; redistribuer le code compile d'Anthropic = probable
  conflit avec leurs CGU. Usage a la discretion de l'utilisateur.
"""
import argparse
import json
import mmap
import os
import re
import shutil
import sys

TRAILER = b"\n---- Bun! ----\n"
# Un octet est "texte" s'il est TAB/LF/CR ou imprimable ASCII 0x20..0x7e.
PRINTABLE_RUN = re.compile(rb"[\t\n\r\x20-\x7e]{%d,}")


def find_claude_binary():
    """Auto-detecte le binaire natif Claude Code installe."""
    candidates = []

    # 1. `claude` sur le PATH -> realpath (recentes versions: bin/claude.exe EST
    #    le binaire natif hardlinke par install.cjs).
    which = shutil.which("claude")
    if which:
        candidates.append(os.path.realpath(which))

    # 2. Packages optionalDependencies natifs dans les node_modules globaux.
    for root in _npm_global_roots():
        base = os.path.join(root, "@anthropic-ai", "claude-code")
        candidates.append(os.path.join(base, "bin", "claude.exe"))
        nm = os.path.join(base, "node_modules", "@anthropic-ai")
        if os.path.isdir(nm):
            for name in os.listdir(nm):
                if name.startswith("claude-code-") and name not in (
                    "claude-code",
                ):
                    candidates.append(os.path.join(nm, name, "claude"))

    # 3. Pad armv7l : binaire emule pose par install-claude-native-armv7.sh.
    candidates.append("/opt/claude-native/claude")

    seen = set()
    for c in candidates:
        if c in seen:
            continue
        seen.add(c)
        try:
            if os.path.isfile(c) and os.path.getsize(c) > 40 * 1024 * 1024:
                return c
        except OSError:
            pass
    return None


def _npm_global_roots():
    roots = []
    # npm root -g si dispo
    npm = shutil.which("npm")
    if npm:
        try:
            import subprocess

            out = subprocess.run(
                [npm, "root", "-g"], capture_output=True, text=True, timeout=15
            )
            if out.returncode == 0 and out.stdout.strip():
                roots.append(out.stdout.strip())
        except Exception:
            pass
    # emplacements usuels (nvm, homebrew, systeme)
    home = os.path.expanduser("~")
    nvm = os.path.join(home, ".nvm", "versions", "node")
    if os.path.isdir(nvm):
        for v in os.listdir(nvm):
            roots.append(os.path.join(nvm, v, "lib", "node_modules"))
    roots += [
        "/usr/local/lib/node_modules",
        "/usr/lib/node_modules",
        "/opt/homebrew/lib/node_modules",
        os.path.join(home, ".local", "lib", "node_modules"),
    ]
    return [r for r in roots if os.path.isdir(r)]


def detect_version(binary_path, bundle):
    """Best-effort : lit la version depuis package.json voisin, sinon scanne."""
    # Remonter les parents a la recherche du package.json @anthropic-ai/claude-code
    d = os.path.dirname(os.path.abspath(binary_path))
    for _ in range(6):
        pj = os.path.join(d, "package.json")
        try:
            with open(pj, "r", encoding="utf-8", errors="ignore") as f:
                data = json.load(f)
            if data.get("name") == "@anthropic-ai/claude-code" and data.get(
                "version"
            ):
                return data["version"]
        except Exception:
            pass
        nd = os.path.dirname(d)
        if nd == d:
            break
        d = nd
    # Fallback : scanner le bundle pour un semver plausible pres de "claude-code"
    m = re.search(rb'claude-code"[^0-9]{0,40}?(\d+\.\d+\.\d+)', bundle[:2_000_000])
    if m:
        return m.group(1).decode()
    m = re.search(rb'"version"\s*:\s*"(\d+\.\d+\.\d+)"', bundle[:2_000_000])
    if m:
        return m.group(1).decode()
    return "unknown"


def carve(mm, min_run):
    """Retourne la liste des (start, end) des runs de texte imprimable >= min_run."""
    rx = re.compile(rb"[\t\n\r\x20-\x7e]{%d,}" % min_run)
    return [(m.start(), m.end()) for m in rx.finditer(mm)]


def main():
    ap = argparse.ArgumentParser(
        description="Extrait le JS lisible d'un binaire Claude Code compile par Bun."
    )
    ap.add_argument(
        "binary",
        nargs="?",
        help="Chemin du binaire (defaut : auto-detection de l'installation locale).",
    )
    ap.add_argument(
        "-o",
        "--out",
        default="claude-js-extracted",
        help="Dossier de sortie (defaut : ./claude-js-extracted).",
    )
    ap.add_argument(
        "--min-run",
        type=int,
        default=100_000,
        help="Taille min d'un bloc de texte carve (octets, defaut 100000).",
    )
    ap.add_argument("--label", help="Force l'etiquette de version dans les noms.")
    args = ap.parse_args()

    binary = args.binary or find_claude_binary()
    if not binary:
        sys.exit(
            "Aucun binaire trouve. Donne le chemin en argument, ex. :\n"
            "  extract-bun-js.py /chemin/vers/claude\n"
            "(la 2.1.112 npm est deja du cli.js pur : rien a extraire)."
        )
    if not os.path.isfile(binary):
        sys.exit("Fichier introuvable : %s" % binary)

    size = os.path.getsize(binary)
    print("Binaire      : %s (%.0f Mo)" % (binary, size / 1e6))

    with open(binary, "rb") as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            ti = mm.rfind(TRAILER)
            if ti < 0:
                sys.exit(
                    "Trailer Bun \"---- Bun! ----\" absent : ce n'est pas un binaire\n"
                    "Bun standalone. (Si c'est la 2.1.112 npm, c'est deja du cli.js.)"
                )
            print("Trailer Bun  : OK (offset %d)" % ti)

            runs = carve(mm, args.min_run)
            if not runs:
                sys.exit("Aucun bloc de texte >= %d octets trouve." % args.min_run)
            runs.sort(key=lambda r: r[1] - r[0], reverse=True)

            os.makedirs(args.out, exist_ok=True)

            # Le plus gros run = bundle applicatif principal.
            a, b = runs[0]
            bundle = mm[a:b]
            ver = args.label or detect_version(binary, bundle)
            main_path = os.path.join(args.out, "claude-%s.cli.js" % ver)
            with open(main_path, "wb") as out:
                out.write(bundle)
            print(
                "Version      : %s\nBundle princ.: %s (%.1f Mo, %d modules-blocs total)"
                % (ver, main_path, len(bundle) / 1e6, len(runs))
            )

            # Blocs vendorises secondaires.
            others = 0
            for i, (a, b) in enumerate(runs[1:], 1):
                p = os.path.join(args.out, "block_%03d.js" % i)
                with open(p, "wb") as out:
                    out.write(mm[a:b])
                others += 1
            if others:
                print("Blocs annexes: %d fichiers block_NNN.js" % others)

            # Sanity check.
            print("Verif        :", end=" ")
            for needle in (b"Claude Code", b"anthropic", b"You are Claude"):
                print("%s=%d" % (needle.decode(), bundle.count(needle)), end="  ")
            print()
        finally:
            mm.close()

    print(
        "\nRappels : JS lisible mais PAS executable sous Node tel quel (API Bun-only\n"
        "sans garde) ; identique quelle que soit la plateforme source ; usage perso."
    )


if __name__ == "__main__":
    main()
