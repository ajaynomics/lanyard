"""Deliberately unsafe baseline; never imported by the wrapper."""
import json

from forge19 import READ_SECONDS


class Service:
    read_seconds = READ_SECONDS

    def __init__(self, *_args, **_kwargs):
        pass

    def handle(self, conn):
        with conn:
            with conn.makefile('rb') as reader:
                try:
                    op = json.loads(reader.readline())['operation']
                    conn.sendall(json.dumps(dict(status='ok', reason=None, verb=op['verb'], repo=op['repo'])).encode() + b'\n')
                except (ValueError, OSError, KeyError):
                    pass


def read_token(path):
    return path.read_bytes()
