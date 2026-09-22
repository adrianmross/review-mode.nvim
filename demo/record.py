#!/usr/bin/env python3
"""Record a .tape without VHS, by driving tmux and recording with asciinema.

VHS renders through a headless browser, which is not available everywhere (a
sandbox, a server, a locked-down laptop). The tape is still the script: this
reads the same file, replays it into a tmux pane, and turns the cast into a GIF
with agg. One source of truth, two renderers.

    demo/record.py demo/suggestion.tape          record to a GIF
    demo/record.py demo/suggestion.tape --live   replay on your screen

--live sets the session up, waits for you to attach a real terminal, and then
replays the keystrokes there. Nothing is captured: it is for the takes someone
else records (Cap, OBS, QuickTime), so the polish is theirs and the timing is
still the tape's.

Supported: Set FontSize/Width/Height/TypingSpeed, Type, Enter, Escape, Tab,
Space, Up/Down/Left/Right, Backspace[@Nms] [count], Ctrl+X, Sleep, Hide/Show
(everything before the first Show is setup and is not recorded; a trailing Hide
ends the take). Output "x.gif" names the file.
"""
from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

SESSION = "review-mode-demo"


def run(*args: str, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, **kw)


def tmux(*args: str) -> subprocess.CompletedProcess:
    return run(os.environ.get("TMUX_BIN", "tmux"), *args)


def duration(text: str) -> float:
    match = re.fullmatch(r"(\d+(?:\.\d+)?)(ms|s)?", text.strip())
    if not match:
        return 0.0
    value = float(match.group(1))
    return value / 1000 if match.group(2) == "ms" else value


class Tape:
    """The parts of a tape this renderer understands."""

    def __init__(self, path: Path):
        self.gif = path.with_suffix(".gif")
        self.width, self.height, self.font_size = 1400, 800, 18
        self.typing = 0.055
        self.setup: list[tuple] = []
        self.take: list[tuple] = []
        self._parse(path)

    def _parse(self, path: Path) -> None:
        target, showing = self.setup, False
        for raw in path.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line == "Show":
                target, showing = self.take, True
                continue
            if line == "Hide":
                if showing:  # the trailing Hide is teardown, not part of the take
                    break
                target = self.setup
                continue
            target.append(("cmd", line))

    def render_ops(self, ops: list[tuple]) -> None:
        """Replay parsed lines into the pane.

        A tape line can carry several commands -- `Type "cd x" Enter`, or
        `Type "a" Sleep 500ms Enter` -- so each line is tokenised and walked
        rather than matched on its first word.
        """
        keys = {
            "Enter": "Enter",
            "Escape": "Escape",
            "Tab": "Tab",
            "Space": "Space",
            "Up": "Up",
            "Down": "Down",
            "Left": "Left",
            "Right": "Right",
        }
        for _, line in ops:
            tokens = shlex.split(line, posix=True)
            index = 0
            while index < len(tokens):
                token = tokens[index]
                index += 1
                if token == "Set":
                    key, value = tokens[index], tokens[index + 1] if index + 1 < len(tokens) else ""
                    index += 2
                    if key == "TypingSpeed":
                        self.typing = duration(value)
                    elif key == "FontSize":
                        self.font_size = int(value)
                    elif key == "Width":
                        self.width = int(value)
                    elif key == "Height":
                        self.height = int(value)
                    continue
                if token in ("Output", "Require"):
                    index += 1
                    continue
                if token == "Sleep":
                    time.sleep(duration(tokens[index]))
                    index += 1
                    continue
                if token == "Type":
                    for char in tokens[index]:
                        tmux("send-keys", "-t", SESSION, "-l", char)
                        time.sleep(self.typing)
                    index += 1
                    continue
                if token.startswith("Backspace"):
                    gap, count = self.typing, 1
                    if "@" in token:
                        gap = duration(token.split("@", 1)[1])
                    if index < len(tokens) and tokens[index].isdigit():
                        count = int(tokens[index])
                        index += 1
                    for _ in range(count):
                        tmux("send-keys", "-t", SESSION, "BSpace")
                        time.sleep(gap)
                    continue
                if token.startswith("Ctrl+"):
                    tmux("send-keys", "-t", SESSION, f"C-{token.split('+', 1)[1].lower()}")
                    time.sleep(0.12)
                    continue
                if token in keys:
                    tmux("send-keys", "-t", SESSION, keys[token])
                    time.sleep(0.12)
                    continue


def live(tape: Tape, cols: int, rows: int) -> int:
    """Replay into a session a human attaches, for an external recorder."""
    attach = f"{os.environ.get('TMUX_BIN', 'tmux')} attach -t {SESSION}"
    print(f"session ready at {cols}x{rows}\n")
    print("  1. size the window, start your recorder (Cap: Studio mode)")
    print(f"  2. run:  {attach}")
    print("  3. press Enter here when the pane is on screen\n")
    try:
        input()
    except (EOFError, KeyboardInterrupt):
        return 130
    print("replaying — do not type in that window")
    tape.render_ops(tape.take)
    print("done; stop your recorder, then detach with C-b d")
    return 0


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    sys.argv = [sys.argv[0], args[0]]
    for tool in ("asciinema", "agg"):
        if not run("command", "-v", tool).returncode == 0 and not any(
            (Path(p) / tool).exists() for p in os.environ.get("PATH", "").split(":")
        ):
            print(f"{tool} is not on PATH (brew install asciinema agg)", file=sys.stderr)
            return 1

    tape = Tape(Path(sys.argv[1]))
    cols, rows = max(80, tape.width // 10), max(24, tape.height // 21)

    tmux("kill-session", "-t", SESSION)
    # The tape refers to ${REVIEW_MODE_*} with shell defaults, and the shell in
    # the pane is the one that expands them -- so they have to reach it. A tmux
    # server started earlier does not carry this process's environment.
    passthrough: list[str] = []
    for name, value in os.environ.items():
        if name.startswith("REVIEW_MODE_"):
            passthrough += ["-e", f"{name}={value}"]

    started = tmux(
        "new-session",
        "-d",
        "-s",
        SESSION,
        "-x",
        str(cols),
        "-y",
        str(rows),
        *passthrough,
        # An rc-free shell: a project's direnv/devenv hooks otherwise print a
        # wall of activation output straight into the take.
        "zsh -f",
    )
    if started.returncode != 0:
        print(started.stderr.strip(), file=sys.stderr)
        return 1
    tmux("set-option", "-t", SESSION, "status", "off")

    if "--live" in flags:
        try:
            tape.render_ops(tape.setup)
            return live(tape, cols, rows)
        finally:
            pass  # the session stays up: the recorder may still be on it

    try:
        tape.render_ops(tape.setup)
        cast = tape.gif.with_suffix(".cast")
        cast.unlink(missing_ok=True)
        # TERM matters: tmux refuses to attach to a terminal it cannot clear,
        # and asciinema falls back to 80x24 unless the size is given.
        recorder = subprocess.Popen(
            [
                "asciinema",
                "rec",
                "--quiet",
                "--window-size",
                f"{cols}x{rows}",
                "--command",
                f"tmux attach -t {SESSION}",
                str(cast),
            ],
            stdin=subprocess.DEVNULL,
            env={**os.environ, "TERM": os.environ.get("DEMO_TERM", "xterm-256color")},
        )
        time.sleep(2)  # let the attach paint the first frame
        tape.render_ops(tape.take)
        time.sleep(1)
        tmux("detach-client", "-s", SESSION)
        recorder.wait(timeout=30)
    finally:
        tmux("kill-session", "-t", SESSION)

    if not cast.exists():
        print("no cast was recorded", file=sys.stderr)
        return 1
    made = run("agg", "--font-size", str(tape.font_size), "--theme", "dracula", str(cast), str(tape.gif))
    if made.returncode != 0:
        print(made.stderr.strip(), file=sys.stderr)
        return 1
    print(f"{tape.gif} ({tape.gif.stat().st_size // 1024} KiB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
