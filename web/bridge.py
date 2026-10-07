"""Read agent identities and styled terminal snapshots from tmux."""
import re
import subprocess
from pathlib import Path


def tmux(*args):
    return subprocess.run(["tmux", *args], text=True, encoding="utf-8", errors="replace",
                          capture_output=True, timeout=5, check=True).stdout


def panes(session=None):
    try:
        rows = tmux("list-panes", "-a", "-F", "#{session_name}\t#{pane_id}\t#{@peon_name}\t#{@peon_code}\t#{pane_current_command}\t#{@peon_role_type}\t#{@peon_brief}\t#{pid}:#{session_id}:#{pane_pid}")
    except subprocess.CalledProcessError:
        return []
    result = []
    for row in rows.splitlines():
        parts = row.split("\t")
        if len(parts) != 8:
            continue
        team, pane, name, marked, command, role, brief, identity = parts
        if marked != "1" or not name or (session and team != session):
            continue
        if role not in ("manager", "reviewer", "worker") and brief:
            try:
                with Path(brief).open() as file:
                    match = re.search(r"Your role: [^\n]+, type (manager|reviewer|worker):", file.read(65536))
                role = match[1] if match else ""
            except (OSError, UnicodeError):
                role = ""
        try:
            project = tmux("display-message", "-p", "-t", pane, "#{?#{@peon_project_dir},#{@peon_project_dir},#{pane_current_path}}")
        except subprocess.CalledProcessError:
            continue  # The pane may close between listing it and reading metadata.
        project = project[:-1] if project.endswith("\n") else project
        result.append(dict(session=team, id=pane, identity=identity, name=name, command=command, role=role, projectDir=project))
    for team in {pane["session"] for pane in result}:
        group = sorted((pane for pane in result if pane["session"] == team), key=lambda pane: int(pane["id"][1:]))
        for index, pane in enumerate(group):
            if pane["role"] not in ("manager", "reviewer", "worker"):
                pane["role"] = ("manager", "reviewer")[index] if index < 2 else "worker"
    return sorted(result, key=lambda pane: (pane["session"], {"manager": 0, "reviewer": 1, "worker": 2}[pane["role"]], int(pane["id"][1:])))


def snapshot(pane):
    output = tmux("capture-pane", "-p", "-e", "-N", "-t", pane["id"], "-S", "-1000")
    try:
        style = tmux("display-message", "-p", "-t", pane["id"], "#{window-style}").strip()
        if tmux("display-message", "-p", "-t", pane["id"], "#{pane_active}").strip() == "1":
            active = tmux("display-message", "-p", "-t", pane["id"], "#{window-active-style}").strip()
            style += "," + active
    except subprocess.CalledProcessError:
        style = ""
    identity = tmux("display-message", "-p", "-t", pane["id"], "#{pid}:#{session_id}:#{pane_pid}").strip()
    if identity != pane["identity"]:
        return None
    pane["output"], pane["defaultStyle"] = output, style
    return pane
