"""README.md -> _metadata/description.html, the mod's description in the game's mod
browser and on mod.io.

Only the formatting the official guidelines recommend for the in-game browser is
emitted: headings 1-3, paragraphs, bold, unordered and ordered lists, horizontal lines;
and links, which the game shows as their text and mod.io as links.
The output is bare content, no <html>/<body> (the game wants it as it would sit inside
a page's body). Anything else is reduced to plain text: italics and inline code lose
their markers, an image becomes its alt text.

Markdown subset read:
  # / ## / ###        headings (deeper ones become h3)
  blank lines         separate paragraphs; lines of one paragraph are joined
  * / - / + item      unordered list items; 1. item  ordered list items
  indented items      nested lists (inside the parent <li>, as HTML has it)
  ---, ***, ___       horizontal line
  **bold**, __bold__  bold
  [text](url), <url>  links; bare http(s) urls are linked too

Usage: python tools/readme_to_description.py [README.md] [_metadata/description.html]
"""

import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

LIST_ITEM = re.compile(r"^(\s*)([*+-]|\d+[.)])\s+(.*)$")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
RULE = re.compile(r"^\s*([-*_])(\s*\1){2,}\s*$")


def emphasis(text):
    """Bold kept; italic markers dropped (italics are not supported in game)."""
    text = re.sub(r"\*\*(.+?)\*\*|__(.+?)__", lambda m: "<b>%s</b>" % (m.group(1) or m.group(2)), text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"\1", text)
    text = re.sub(r"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])", r"\1", text)
    return text


# stands in for a link while the rest of a line is converted
LINK_MARK = "\x00%d\x00"
LINK_MARK_RE = re.compile("\x00(\\d+)\x00")


def inline(text):
    """Markdown inline -> the allowed HTML (bold and links), everything else escaped."""
    # links are taken out first and put back last, so escaping and the bold and italic
    # markers leave them (and underscores in their urls) alone
    links = []

    def keep(label, url):
        links.append((label, url))
        return LINK_MARK % (len(links) - 1)

    # images: their alt text
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)
    # (a url may hold balanced brackets: Vertex_(geometry); an optional "title" after it)
    text = re.sub(r"\[([^\]]+)\]\(([^()\s]*(?:\([^()\s]*\)[^()\s]*)*)(?:\s+\"[^\"]*\")?\)",
                  lambda m: keep(m.group(1), m.group(2)), text)
    text = re.sub(r"<(https?://[^>]+)>", lambda m: keep(m.group(1), m.group(1)), text)
    # bare urls, as GitHub links them (a closing bracket or full stop after one is not its)
    text = re.sub(r"(?<![\w/])https?://[^\s<>()\x00]*[^\s<>().,;:!?\x00]", lambda m: keep(m.group(0), m.group(0)), text)
    # inline code: the text alone
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = emphasis(html.escape(text, quote=False))

    def link(m):
        label, url = links[int(m.group(1))]
        return '<a href="%s">%s</a>' % (html.escape(url, quote=True), emphasis(html.escape(label, quote=False)))

    return LINK_MARK_RE.sub(link, text).strip()


def convert(markdown):
    out = []
    paragraph = []
    # open lists: (indent, tag), innermost last; each has an open <li>
    lists = []

    def flush_paragraph():
        if paragraph:
            out.append("<p>%s</p>" % inline(" ".join(paragraph)))
            paragraph.clear()

    def close_lists(down_to_indent=-1):
        while lists and lists[-1][0] > down_to_indent:
            __, tag = lists.pop()
            out.append("%s</li>" % ("  " * (2 * len(lists) + 1)))
            out.append("%s</%s>" % ("  " * (2 * len(lists)), tag))

    for raw in markdown.splitlines():
        line = raw.rstrip()
        if not line.strip():
            flush_paragraph()
            continue
        item = LIST_ITEM.match(line)
        if item and not RULE.match(line):
            flush_paragraph()
            indent = len(item.group(1).replace("\t", "    "))
            tag = "ol" if item.group(2)[0].isdigit() else "ul"
            # close deeper lists, and a list of the other kind at this depth
            close_lists(indent)
            if lists and lists[-1][0] == indent and lists[-1][1] != tag:
                close_lists(indent - 1)
            if lists and lists[-1][0] == indent:
                out.append("%s</li>" % ("  " * (2 * len(lists) - 1)))
            else:
                out.append("%s<%s>" % ("  " * (2 * len(lists)), tag))
                lists.append((indent, tag))
            out.append("%s<li>%s" % ("  " * (2 * len(lists) - 1), inline(item.group(3))))
            continue
        if lists and raw[:1] in (" ", "\t") and not paragraph:
            # a continuation line of the current item
            out[-1] += " " + inline(line)
            continue
        close_lists()
        heading = HEADING.match(line)
        if heading:
            flush_paragraph()
            level = min(len(heading.group(1)), 3)
            out.append("<h%d>%s</h%d>" % (level, inline(heading.group(2)), level))
        elif RULE.match(line):
            flush_paragraph()
            out.append("<hr>")
        else:
            paragraph.append(line.strip())
    flush_paragraph()
    close_lists()

    # an item without a nested list closes on its own line
    merged = []
    for line in out:
        if line.strip() == "</li>" and merged and merged[-1].lstrip().startswith("<li>"):
            merged[-1] += "</li>"
        else:
            merged.append(line)
    # a blank line before each block at the top level, for reading the file
    result = []
    for line in merged:
        if result and not line.startswith(" ") and not line.startswith("</"):
            result.append("")
        result.append(line)
    return "\n".join(result) + "\n"


def main():
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "README.md"
    target = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "_metadata" / "description.html"
    target.write_text(convert(source.read_text(encoding="utf-8")), encoding="utf-8", newline="\n")
    print("%s -> %s" % (source, target))


if __name__ == "__main__":
    main()
