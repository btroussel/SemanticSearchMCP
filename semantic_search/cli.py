"""CLI for serving, indexing, querying, and connecting a lightweight MCP bridge."""
from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path

from .settings import DEFAULT_MAX_TOKENS, validate_max_tokens


def token_limit(value: str) -> int:
    try:
        return validate_max_tokens(int(value))
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc


def main():
    parser = argparse.ArgumentParser(prog="code-search")
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("index", "serve"):
        p = commands.add_parser(command)
        p.add_argument("--repo", type=Path, required=True)
        p.add_argument("--model", type=Path, required=True)
        p.add_argument("--db", type=Path, required=True)
        p.add_argument("--device", default="auto", choices=["auto", "mlx", "cuda", "mps", "cpu"],
                       help="auto prefers MLX on Apple silicon, then CUDA, MPS and CPU (default: auto)")
        p.add_argument("--dimensions", type=int, default=768, choices=[128, 256, 512, 768])
        p.add_argument("--max-tokens", type=token_limit, default=DEFAULT_MAX_TOKENS,
                       help="Maximum input tokens, including titles/prefixes (256–8192; default: 4096)")
        p.add_argument("--exclude", action="append", default=[])
        if command == "serve":
            p.add_argument("--port", type=int, default=8765)
            p.add_argument("--interval", type=float, default=300)
            p.add_argument("--no-watch", action="store_true")
    p = commands.add_parser("mcp")
    p.add_argument("--url", default="http://127.0.0.1:8765")
    p.add_argument("--token-file", type=Path)
    p.add_argument("--general", action="store_true")
    p.add_argument("--project", type=Path,
                   help="MCP project folder; defaults to the bridge's launch directory (--general)")
    p = commands.add_parser("workspace", help="Serve the general Mac application and its authorized folders")
    p.add_argument("--model", type=Path, required=True)
    p.add_argument("--state", type=Path, default=Path.home() / "Library/Application Support/Local Search")
    p.add_argument("--port", type=int, default=8766)
    p.add_argument("--interval", type=float, default=300)
    p.add_argument("--device", default="auto", choices=["auto", "mlx", "cuda", "mps", "cpu"],
                   help="auto prefers MLX on Apple silicon, then CUDA, MPS and CPU (default: auto)")
    p.add_argument("--no-watch", action="store_true")
    p.add_argument("--text-only", action="store_true")
    p.add_argument("--max-tokens", type=token_limit, default=None,
                   help="Override the saved maximum input tokens (256–8192; initial default: 4096)")
    p = commands.add_parser("download-model", help="Download the pinned EmbeddingGemma 2 checkpoint")
    p.add_argument("--dest", type=Path, default=Path("models/embeddinggemma-2"))
    p.add_argument("--json", action="store_true", help="Report progress as JSON lines on stdout")
    p = commands.add_parser("search")
    p.add_argument("query")
    p.add_argument("--url", default="http://127.0.0.1:8765")
    p.add_argument("--mode", default="auto", choices=["auto", "hybrid", "semantic", "lexical"])
    p.add_argument("--path-filter", default="")
    p.add_argument("--limit", type=int, default=8)
    p = commands.add_parser("status")
    p.add_argument("--url", default="http://127.0.0.1:8765")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if args.command == "mcp":
        from .mcp_server import create_server
        create_server(args.url, args.token_file, args.general, args.project).run(transport="stdio")
    elif args.command == "workspace":
        if args.interval < 5:
            parser.error("--interval must be at least 5 seconds")
        from .embeddings import Embedder
        from .workspace import Workspace, create_workspace_app
        import uvicorn
        workspace = Workspace(args.state, Embedder(args.model, args.device, images=not args.text_only),
                              args.interval, not args.no_watch, max_tokens=args.max_tokens)
        uvicorn.run(create_workspace_app(workspace), host="127.0.0.1", port=args.port)
    elif args.command == "download-model":
        from .download import main as download
        download(args.dest, args.json)
    elif args.command in {"search", "status"}:
        import httpx
        with httpx.Client(base_url=args.url, timeout=120, trust_env=False) as client:
            if args.command == "status":
                response = client.get("/status")
            else:
                response = client.post("/search", json={"query": args.query, "mode": args.mode,
                                                       "path_filter": args.path_filter, "limit": args.limit})
            response.raise_for_status()
            print(json.dumps(response.json(), indent=2))
    else:
        from .embeddings import Embedder
        from .index import Index
        index = Index(args.repo, args.db, Embedder(args.model, args.device, args.dimensions,
                                               max_tokens=args.max_tokens), args.exclude)
        if args.command == "index":
            print(json.dumps(index.sync(), indent=2))
        else:
            import uvicorn
            from .service import create_app
            if args.interval < 5:
                parser.error("--interval must be at least 5 seconds")
            uvicorn.run(create_app(index, args.interval, not args.no_watch), host="127.0.0.1", port=args.port)


if __name__ == "__main__":
    main()
