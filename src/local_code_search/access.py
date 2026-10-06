"""Per-project MCP grants, independent of the app's indexing sources."""
from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.parse import unquote, urlparse

from pydantic import BaseModel, Field


class AccessRequest(BaseModel):
    project: str
    folders: list[str] = Field(default_factory=list, max_length=100)


def folder(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute() or not path.is_dir():
        raise ValueError("Select an existing absolute project/folder path")
    return path.resolve()


def project_header(value: str) -> Path:
    uri = urlparse(value)
    if uri.scheme != "file" or uri.netloc or uri.query or uri.fragment:
        raise ValueError("Invalid MCP project URI")
    return folder(unquote(uri.path))


class ProjectAccess:
    def __init__(self, state: Path):
        self.path = state / "mcp-access.json"
        self.grants = json.loads(self.path.read_text()) if self.path.exists() else {}

    def get(self, project: str):
        root = folder(project)
        return {"project": str(root), "folders": self.grants.get(str(root), [])}

    def save(self, request: AccessRequest, sources):
        project = folder(request.project)
        folders = sorted({str(folder(p)) for p in request.folders})
        for value in folders:
            if not any(Path(value).is_relative_to(Path(s["path"])) for s in sources):
                raise ValueError("Add this folder as an indexing source in the app before granting MCP access")
        grants = {**self.grants}
        if folders:
            grants[str(project)] = folders
        else:
            grants.pop(str(project), None)
        self._write(grants)
        return self.get(str(project))

    def _write(self, grants):
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(grants, indent=2) + "\n")
        os.chmod(temporary, 0o600)
        temporary.replace(self.path)
        self.grants = grants

    def revoke_source(self, root: Path):
        grants = {project: [p for p in paths if not Path(p).is_relative_to(root)]
                  for project, paths in self.grants.items()}
        grants = {p: paths for p, paths in grants.items() if paths}
        if grants != self.grants:
            self._write(grants)

    def scopes(self, project: Path, sources, additional=True):
        folders = [(project, "project")]
        if additional:
            folders.extend((Path(p), "additional") for p in self.grants.get(str(project), []))
        scopes = {}
        for source in sources:
            root = Path(source["path"])
            for allowed, role in folders:
                # A project may be a subdirectory of a broadly indexed source,
                # or contain multiple separately indexed sources.
                if allowed.is_relative_to(root):
                    relative = allowed.relative_to(root).as_posix()
                    prefix = "" if relative == "." else relative + "/"
                elif root.is_relative_to(allowed):
                    prefix = ""
                else:
                    continue
                scopes.setdefault(source["id"], []).append({"path_prefix": prefix, "role": role})
        return scopes
