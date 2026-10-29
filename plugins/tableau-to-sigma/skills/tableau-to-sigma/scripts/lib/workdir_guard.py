"""Refuse a migration workdir that lives inside the installed plugin.

Python twin of workdir_guard.rb (keep the two in step).

WHY. AGENTS.md tells an agent to cd into the skill directory before running a
script. In a real Windows run the agent then also passed that directory (or `.`)
as --workdir / --tableau-dir, so wb-readback.json, chart-provenance.json, ...
were written into -- and read back from -- the INSTALLED plugin
(~/.claude/plugins/cache/<marketplace>/tableau-to-sigma/<version>/skills/...).
A later migration then reads a previous migration's stale files from the shared
install, and the source-object census resolves evidence through the plugin cache.

WHAT IS REFUSED (after realpath -- symlinks and `.` resolve first; compared
case-insensitively on Windows/macOS): the skill directory, the plugin root, or
anything inside either; and any `.claude/plugins/{cache,marketplaces}` path. The
workdir may not exist yet; its deepest existing ancestor is resolved.

Escape hatch: SIGMA_ALLOW_WORKDIR_IN_SKILL=1 (only for developing the skill
itself -- never for a real migration).

Usage, right after parsing arguments:
    import workdir_guard
    workdir_guard.check(args.workdir, "--workdir")
check() returns its argument unchanged, or prints the reason and exits 2.
check_file() does the same for an output FILE path (guards its directory).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

ESCAPE_ENV = "SIGMA_ALLOW_WORKDIR_IN_SKILL"
EXIT_CODE = 2
# Where the skill lives: <plugin>/skills/<skill>/scripts/lib/workdir_guard.py
SKILL_DIR = Path(__file__).resolve().parent.parent.parent


def case_insensitive() -> bool:
    return sys.platform.startswith(("win", "darwin", "cygwin"))


def resolve(path) -> str:
    """Realpath that tolerates a not-yet-created tail (non-strict resolve)."""
    return str(Path(os.path.expanduser(str(path))).resolve()).replace("\\", "/")


def _expand(path) -> str:
    return os.path.abspath(os.path.expanduser(str(path))).replace("\\", "/")


def _norm(path: str) -> str:
    text = str(path).replace("\\", "/").rstrip("/")
    return text.lower() if case_insensitive() else text


def inside(path: str, root: str) -> bool:
    p, r = _norm(path), _norm(root)
    return bool(r) and (p == r or p.startswith(r + "/"))


def protected_roots() -> list[str]:
    """The skill dir, plus the plugin root when the layout is <plugin>/skills/<skill>.

    Only when this really IS a skill dir (SKILL.md present): a script copied into an
    arbitrary layout (a test tmpdir, ~/bin) must not turn its grandparent into a
    protected tree. The .claude/plugins path rule still applies.
    """
    if not (SKILL_DIR / "SKILL.md").is_file():
        return []
    roots = [SKILL_DIR]
    if SKILL_DIR.parent.name == "skills":
        roots.append(SKILL_DIR.parent.parent)
    out: list[str] = []
    for root in roots:
        for candidate in (_expand(root), resolve(root)):
            if candidate not in out:
                out.append(candidate)
    return out


def plugin_install_path(path: str) -> bool:
    """`.claude/plugins/{cache,marketplaces}/...` (also under CLAUDE_CONFIG_DIR)."""
    segs = _norm(path).split("/")
    for i, seg in enumerate(segs):
        if seg == ".claude" and i + 2 < len(segs) and segs[i + 1] == "plugins" and segs[i + 2] in ("cache", "marketplaces"):
            return True
    cfg = os.environ.get("CLAUDE_CONFIG_DIR", "")
    if not cfg:
        return False
    return any(inside(path, resolve(cfg) + "/plugins/" + d) for d in ("cache", "marketplaces"))


def violation(path) -> str | None:
    """None when `path` is acceptable, else a one-line reason."""
    if path is None or not str(path).strip():
        return None
    expanded = _expand(path)
    real = resolve(path)
    for root in protected_roots():
        if inside(real, root) or inside(expanded, root):
            return f"{str(path)!r} resolves to {real}, inside the installed skill/plugin ({root})"
    if plugin_install_path(real) or plugin_install_path(expanded):
        return f"{str(path)!r} resolves to {real}, inside a .claude/plugins cache/marketplace install"
    return None


def message(label: str, reason: str) -> str:
    fix_flag = label.split()[0] + " " if label.startswith("-") else ""
    return (
        f"REFUSED: {label} {reason}.\n"
        "  Run artifacts (wb-readback.json, chart-provenance.json, ...) must never be written into, or\n"
        "  read back from, the installed plugin: a later migration would pick up this one's stale\n"
        "  files, and the source-object census would resolve evidence through the plugin cache.\n"
        f"  Fix: use a workdir OUTSIDE the plugin, e.g. {fix_flag}~/tableau-migration/<name>\n"
        "  (cd into the skill dir to run scripts if you like, but never use it, or `.`, as the workdir).\n"
    )


def check(path, label: str = "--workdir"):
    if os.environ.get(ESCAPE_ENV) == "1":
        return path
    reason = violation(path)
    if reason is None:
        return path
    sys.stderr.write(message(label, reason))
    raise SystemExit(EXIT_CODE)


def check_file(path, label: str = "--out"):
    """An output FILE path: its directory is what must stay out of the install."""
    if path is None or not str(path).strip():
        return path
    check(os.path.dirname(_expand(path)), label)
    return path
