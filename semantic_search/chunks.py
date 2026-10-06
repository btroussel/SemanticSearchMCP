"""Source-based hierarchy: file outlines, classes, functions, bounded blocks."""
from __future__ import annotations

import ast
from dataclasses import dataclass, replace
from collections.abc import Callable
from pathlib import Path

from .files import digest

CHUNK_VERSION = "4"
MAX_CHARS = 5000
LANGUAGES = {".js": "javascript", ".jsx": "javascript", ".ts": "typescript",
             ".tsx": "tsx", ".go": "go", ".rs": "rust", ".java": "java",
             ".c": "c", ".h": "c", ".cpp": "cpp", ".hpp": "cpp",
             ".cs": "csharp", ".rb": "ruby", ".php": "php", ".swift": "swift"}
SYMBOL_TYPES = {"function_definition", "function_declaration", "method_definition",
                "method_declaration", "class_definition", "class_declaration",
                "function_item", "struct_item", "impl_item", "interface_declaration"}


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

    # Outlines are deterministic source-derived text, not generated summaries.
    outline = "\n".join(f"{kind} {name}: {lines[first - 1].strip()}" for name, kind, first, _, _ in symbols)
    if len(text) <= MAX_CHARS:
        file_text = text
    else:
        imports = [line for line in lines[:100] if line.startswith(("import ", "from ", "use ", "package ", "#include"))]
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
            if kind != "class":
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
