"""Exercise the real stdio bridge against a running daemon."""
import asyncio
import json
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main():
    executable = Path(__file__).resolve().parents[1] / ".venv/bin/code-search"
    params = StdioServerParameters(command=str(executable), args=["mcp"])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            assert len(tools.tools) == 5
            status = await session.call_tool("index_status", {})
            assert not status.isError and status.structuredContent["repo"].endswith("TABNext")
            result = await session.call_tool("search_code", {"query": "build_scheduler", "mode": "lexical", "limit": 3})
            assert not result.isError
            found = next(r for r in result.structuredContent["results"] if r["symbol"] == "build_scheduler")
            expanded = await session.call_tool("read_symbol", {"symbol_id": found["parent_id"]})
            assert not expanded.isError
            source = await session.call_tool("read_code_file", {"path": found["path"], "start_line": found["start_line"], "max_lines": 20})
            assert not source.isError and "def build_scheduler" in source.structuredContent["code"]
            invalid = await session.call_tool("read_code_file", {"path": "../outside.py"})
            assert invalid.isError
            print(json.dumps({"tools": [t.name for t in tools.tools], "repo": status.structuredContent["repo"],
                              "search_match": [found["path"], found["symbol"]], "parent_read": True,
                              "source_read": True, "traversal_rejected": True}, indent=2))


asyncio.run(main())
