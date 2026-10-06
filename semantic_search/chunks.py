"""Source-based hierarchy: file outlines, classes, functions, bounded blocks."""
from __future__ import annotations

import ast
import re
from dataclasses import dataclass, replace
from collections.abc import Callable
from pathlib import Path

from .files import digest

CHUNK_VERSION = "5"
MAX_CHARS = 5000
LANGUAGES = {".js": "javascript", ".jsx": "javascript", ".ts": "typescript",
             ".tsx": "tsx", ".go": "go", ".rs": "rust", ".java": "java",
             ".c": "c", ".h": "c", ".cpp": "cpp", ".hpp": "cpp",
             ".cs": "csharp", ".rb": "ruby", ".php": "php", ".swift": "swift"}
SYMBOL_TYPES = {"function_definition", "function_declaration", "method_definition",
                "method_declaration", "class_definition", "class_declaration",
                "function_item", "struct_item", "impl_item", "interface_declaration"}
SECTIONED_DOCUMENTS = {".md", ".markdown", ".docx", ".rst"}
HEADING = re.compile(r" {0,3}(#{1,6})[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$")
SETEXT = re.compile(r" {0,3}(=+|-+)[ \t]*$")
NOT_PARAGRAPH = re.compile(r" {0,3}([-*+>|]|\d+[.)])(\s|$)| {4}|\t")
FENCE = re.compile(r" {0,3}(`{3,}|~{3,})")
RST_ADORNMENT = re.compile(r"([!-/:-@\[-`{-~])\1+[ \t]*$")
PAGE = re.compile(r"\[Page (\d+)\]$")


@dataclass
class Chunk:
    id: str
    path: str
    symbol: str
    kind: str
    start: int
    end: int
    parent_id: str | None
    text: str

    @property
    def document(self) -> str:
        return f"title: {self.path} :: {self.symbol} | text: {self.text}"


def chunk_id(path: str, symbol: str, kind: str, start: int) -> str:
    return digest(f"{path}:{symbol}:{kind}:{start}")[:24]


def _windows(lines: list[str], first: int, last: int):
    start = first
    while start <= last:
        end, size = start - 1, 0
        while end < last and (size < MAX_CHARS or end < start):
            end += 1
            size += len(lines[end - 1]) + 1
        yield start, end, "\n".join(lines[start - 1:end])
        start = end + 1


def _runs(numbers: list[int]):
    """Contiguous (first, last) ranges of sorted line numbers."""
    start = previous = None
    for number in numbers:
        if start is None:
            start = number
        elif number != previous + 1:
            yield start, previous
            start = number
        previous = number
    if start is not None:
        yield start, previous


def _markdown_headings(lines: list[str]):
    """(line, level, title) for ATX (#) and underlined (setext) headings outside code and front matter."""
    starts, fence, paragraph = [], None, False
    first = 0
    if lines and lines[0].strip() == "---":
        # YAML front matter is metadata, and its closing --- is not a heading underline.
        first = next((n for n, line in enumerate(lines[1:], 1) if line.strip() in {"---", "..."}), -1) + 1
    for number, line in enumerate(lines[first:], first + 1):
        # Headings inside fenced code blocks are code, not structure.
        if match := FENCE.match(line):
            marker = match.group(1)
            if fence is None:
                fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence) and not line.strip()[len(marker):]:
                fence = None
            paragraph = False
            continue
        if fence is not None:
            continue
        if match := HEADING.match(line):
            starts.append((number, len(match.group(1)), match.group(2).strip()))
            paragraph = False
        elif paragraph and (match := SETEXT.match(line)):
            starts.append((number - 1, 1 if match.group(1)[0] == "=" else 2, lines[number - 2].strip()))
            paragraph = False
        else:
            paragraph = bool(line.strip()) and not NOT_PARAGRAPH.match(line)
    return starts


def _rst_headings(lines: list[str]):
    """(line, level, title) for reStructuredText titles; levels follow each adornment's first use."""
    starts, styles = [], []
    for index in range(1, len(lines)):
        title, underline = lines[index - 1], lines[index]
        match = RST_ADORNMENT.match(underline)
        if not match or not title.strip() or title[0].isspace() or RST_ADORNMENT.match(title):
            continue
        if len(underline.rstrip()) < len(title.rstrip()):
            continue
        overline = index >= 2 and lines[index - 2].rstrip() == underline.rstrip()
        if not overline and index >= 2 and lines[index - 2].strip():
            continue  # A title starts a paragraph; text above it means this is not a heading.
        style = (match.group(1), overline)
        if style not in styles:
            styles.append(style)
        starts.append((index - 1 if overline else index, styles.index(style) + 1, title.strip()))
    return starts


def _sections(path: str, lines: list[str], suffix: str):
    """Markdown/DOCX/reStructuredText headings or PDF pages as (name, kind, first, last, parent) ranges."""
    if suffix == ".pdf":
        starts = [(n, 1, f"Page {m.group(1)}") for n, line in enumerate(lines, 1) if (m := PAGE.match(line))]
    else:
        starts = [(n, level, title[:80]) for n, level, title in
                  (_rst_headings(lines) if suffix == ".rst" else _markdown_headings(lines))]
    sections, open_ = [], []
    for index, (first, level, title) in enumerate(starts):
        # A section ends where the next heading of the same or a higher level starts.
        last = next((s - 1 for s, other, _ in starts[index + 1:] if other <= level), len(lines))
        while open_ and open_[-1][1] >= level:
            open_.pop()
        name = " > ".join([t for _, _, t, _ in open_] + [title])
        parent = open_[-1][3] if open_ else None
        kind = "page" if suffix == ".pdf" else "section"
        sections.append((name, kind, first, last, parent))
        open_.append((first, level, title, chunk_id(path, name, kind, first)))
    return sections
    return sections


def split_file(path: str, text: str, max_tokens: int | None = None,
               count_tokens: Callable[[str], int] | None = None) -> list[Chunk]:
    lines = text.splitlines() or [""]
    file_id = chunk_id(path, path, "file", 1)
    symbols: list[tuple[str, str, int, int, str | None]] = []
    suffix = Path(path).suffix
    if suffix in {".py", ".pyi"}:
        try:
            tree = ast.parse(text)

            def visit(node, parent: str | None = None, prefix: str = ""):
                for child in ast.iter_child_nodes(node):
                    if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                        name = prefix + child.name
                        first = min([child.lineno] + [d.lineno for d in child.decorator_list])
                        kind = "class" if isinstance(child, ast.ClassDef) else "function"
                        symbols.append((name, kind, first, child.end_lineno, parent))
                        visit(child, chunk_id(path, name, kind, first), name + ".")
                    else:
                        visit(child, parent, prefix)
            visit(tree)
        except SyntaxError:
            pass  # An incomplete saved file remains searchable by line windows.
    elif suffix in LANGUAGES:
        try:
            from tree_sitter_language_pack import get_parser
            root = get_parser(LANGUAGES[suffix]).parse(text.encode()).root_node

            def visit_ts(node, parent=None, prefix=""):
                if node.type in SYMBOL_TYPES:
                    name_node = node.child_by_field_name("name")
                    name = prefix + (name_node.text.decode() if name_node else node.type)
                    first, last = node.start_point.row + 1, node.end_point.row + 1
                    kind = "class" if any(k in node.type for k in ("class", "struct", "impl", "interface")) else "function"
                    symbols.append((name, kind, first, last, parent))
                    parent = chunk_id(path, name, kind, first)
                    prefix = name + "."
                for child in node.children:
                    visit_ts(child, parent, prefix)
            visit_ts(root)
        except (ImportError, LookupError, RuntimeError, ValueError):
            pass
    document = suffix.lower() in SECTIONED_DOCUMENTS | {".pdf"}
    if document:
        symbols = _sections(path, lines, suffix.lower())

    # Outlines are deterministic source-derived text, not generated summaries.
    outline = "\n".join(f"{kind} {name}: {lines[first - 1].strip()}" for name, kind, first, _, _ in symbols)
    if len(text) <= MAX_CHARS:
        file_text = text
    else:
        imports = [] if document else [
            line for line in lines[:100] if line.startswith(("import ", "from ", "use ", "package ", "#include"))]
        file_text = "File outline\n" + "\n".join(imports[:20]) + "\n" + outline[:MAX_CHARS]
        if not symbols:
            file_text = "\n".join(lines[:25])
    chunks = [Chunk(file_id, path, path, "file", 1, len(lines), None, file_text)]
    covered = set()
    for name, kind, first, last, parent in symbols:
        identifier = chunk_id(path, name, kind, first)
        source = "\n".join(lines[first - 1:last])
        parent = parent or file_id
        if len(source) <= MAX_CHARS:
            chunks.append(Chunk(identifier, path, name, kind, first, last, parent, source))
        else:
            header = "\n".join(lines[first - 1:min(first + 5, last)])
            children = "\n".join(f"{k} {n}: {lines[s - 1].strip()}"
                                 for n, k, s, _, p in symbols if p == identifier)
            chunks.append(Chunk(identifier, path, name, kind, first, last, parent,
                                header + "\n" + children[:MAX_CHARS]))
            if document:
                # Window only the section's own text; subsections have their own chunks.
                nested = {n for _, _, s, e, p in symbols if p == identifier for n in range(s, e + 1)}
                own = [n for n in range(first, last + 1) if n not in nested]
                for run_first, run_last in _runs(own):
                    for start, end, body in _windows(lines, run_first, run_last):
                        if body.strip():
                            chunks.append(Chunk(chunk_id(path, name, "block", start), path, name,
                                                "block", start, end, identifier, body))
            elif kind != "class":
                for start, end, body in _windows(lines, first, last):
                    chunks.append(Chunk(chunk_id(path, name, "block", start), path, name,
                                        "block", start, end, identifier, header + "\n" + body))
        covered.update(range(first, last + 1))
    # Module-level setup, constants, and unsupported languages still get indexed.
    start = None
    for line in range(1, len(lines) + 2):
        if line <= len(lines) and line not in covered:
            start = start or line
        elif start is not None:
            for first, last, body in _windows(lines, start, line - 1):
                if body.strip():
                    chunks.append(Chunk(chunk_id(path, path, "block", first), path, path,
                                        "block", first, last, file_id, body))
            start = None
    if max_tokens is not None and count_tokens is not None:
        return [part for chunk in chunks for part in _bound_chunk(chunk, max_tokens, count_tokens)]
    return chunks


def _bound_chunk(chunk: Chunk, max_tokens: int, count_tokens: Callable[[str], int]):
    """Keep every character, including long single lines, within the token budget."""
    if count_tokens(chunk.document) <= max_tokens:
        yield chunk
        return
    prefix = replace(chunk, text="").document
    if count_tokens(prefix) >= max_tokens:
        raise ValueError("Document title exceeds maximum input tokens; shorten its path or increase the limit")
    offset, line = 0, chunk.start
    while offset < len(chunk.text):
        # Limit the search span on pathological single-line documents.
        low, high = 0, min(len(chunk.text) - offset, max_tokens * 8)
        while low < high:
            middle = (low + high + 1) // 2
            if count_tokens(prefix + chunk.text[offset:offset + middle]) <= max_tokens:
                low = middle
            else:
                high = middle - 1
        if low == 0:
            raise ValueError("Maximum input tokens leaves no room for document text")
        # Prefer a nearby line boundary without throwing away whitespace.
        if offset + low < len(chunk.text):
            boundary = chunk.text.rfind("\n", offset + low * 4 // 5, offset + low)
            if boundary >= 0:
                candidate = boundary + 1 - offset
                if count_tokens(prefix + chunk.text[offset:offset + candidate]) <= max_tokens:
                    low = candidate
        body = chunk.text[offset:offset + low]
        last = line + body.count("\n") - int(body.endswith("\n"))
        if offset == 0:
            # Retain hierarchy IDs and the enclosing symbol's complete range.
            part = replace(chunk, text=body, end=last if chunk.kind == "block" else chunk.end)
        else:
            part = replace(chunk, id=digest(f"{chunk.id}:part:{offset}")[:24], kind="block",
                           start=line, end=last, text=body,
                           parent_id=chunk.parent_id if chunk.kind == "block" else chunk.id)
        yield part
        offset += low
        line += body.count("\n")
