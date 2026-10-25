"""Emulate a launchd inetdCompatibility socket for tests.

Usage: python3 -I inetd-emulator.py <socket path> <handler>

For each connection, start <handler> with the connection on stdin and stdout,
the same way launchd does for a job with inetdCompatibility and Wait=false.
"""

import os
import socket
import subprocess
import sys


def main():
    path, handler = sys.argv[1], sys.argv[2]
    if os.path.exists(path):
        os.unlink(path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    os.chmod(path, 0o666)
    server.listen(8)
    while True:
        conn, _ = server.accept()
        subprocess.Popen(
            [handler],
            stdin=conn.fileno(),
            stdout=conn.fileno(),
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )
        conn.close()


if __name__ == "__main__":
    main()
