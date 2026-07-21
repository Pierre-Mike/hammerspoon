#!/usr/bin/env python3
"""Hold a background zellij client attached to a session.

Why this exists: zellij 0.44 routes `zellij action write-chars` / `write` through
an *attached client's* pane focus. If the target session has **zero** clients
(the user switched to another session / detached), those writes are silently
dropped — which is exactly what happened to every Hammerspoon "send to
Orchestrator" while the session wasn't the one on screen.

This helper attaches a permanent, headless client so a write always has a client
to land on. Two properties make it safe:

  * It attaches with a deliberately OVERSIZED pty (ROWS x COLS below). zellij
    sizes a shared session to its SMALLEST client, so an oversized keepalive
    never shrinks the user's real view — it just fills the gap when the user is
    away and the session would otherwise have no client at all.
  * It NEVER creates the session (`attach`, not `attach -c`). If the Orchestrator
    isn't running yet, zellij exits immediately, this process exits, and the
    Hammerspoon watchdog simply relaunches it later.

The parent keeps the pty master open and drains it forever; that read loop is
what keeps the client alive. EOF/OSError means zellij detached or the session
died — we exit so the watchdog can respawn a fresh client.
"""
import fcntl
import os
import pty
import struct
import sys
import termios

ZELLIJ = os.path.expanduser("~/.cargo/bin/zellij")
SESSION = sys.argv[1] if len(sys.argv) > 1 else "Orchestrator"
ROWS, COLS = 200, 500  # larger than any real terminal so we never constrain size


def main() -> None:
    pid, fd = pty.fork()
    if pid == 0:
        # Child: become the zellij client. `attach` (no -c) so we never spawn a
        # session the user didn't create — just ride an existing one.
        os.execv(ZELLIJ, [ZELLIJ, "attach", SESSION])
        os._exit(127)  # unreachable unless execv fails

    # Parent: size the pty large, then drain output forever to hold the client.
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    except OSError:
        pass
    while True:
        try:
            if not os.read(fd, 65536):
                break  # client exited: session gone or detached
        except OSError:
            break
    os._exit(0)


if __name__ == "__main__":
    main()
