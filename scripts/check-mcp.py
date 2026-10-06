"""Exercise the real stdio bridge against a running daemon."""
import argparse
import asyncio
import json
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main(symbol):
    executable = Path(__file__).resolve().parents[1] / ".venv/bin/code-search"
    params = StdioServerParameters(command=str(executable), args=["mcp"])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            assert len(tools.tools) == 5
            status = await session.call_tool("index_status", {})
            assert not status.isError and status.structuredContent["repo"]
            result = await session.call_tool("search_code", {"query": symbol, "mode": "lexical", "limit": 3})
            assert not result.isError
            found = next(r for r in result.structuredContent["results"] if r["symbol"] == symbol)
            expanded = await session.call_tool("read_symbol", {"symbol_id": found["parent_id"]})
            assert not expanded.isError
            source = await session.call_tool("read_code_file", {"path": found["path"], "start_line": found["start_line"], "max_lines": 20})
            assert not source.isError and symbol in source.structuredContent["code"]
            invalid = await session.call_tool("read_code_file", {"path": "../outside.py"})
            assert invalid.isError
            print(json.dumps({"tools": [t.name for t in tools.tools], "repo": status.structuredContent["repo"],
                              "search_match": [found["path"], found["symbol"]], "parent_read": True,
                              "source_read": True, "traversal_rejected": True}, indent=2))


parser = argparse.ArgumentParser()
parser.add_argument("--symbol", required=True, help="A function or class defined in the indexed repository")
asyncio.run(main(parser.parse_args().symbol))
