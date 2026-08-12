#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def fail() -> None:
    raise SystemExit(1)


def parse_args(argv: list[str]) -> tuple[object, str]:
    source = None
    expression = None
    index = 0
    while index < len(argv):
        option = argv[index]
        if option not in {"-i", "-s", "-e"} or index + 1 >= len(argv):
            fail()
        value = argv[index + 1]
        if option == "-i":
            if source is not None:
                fail()
            try:
                source = json.loads(Path(value).read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                fail()
        elif option == "-s":
            if source is not None:
                fail()
            try:
                source = json.loads(value)
            except json.JSONDecodeError:
                fail()
        else:
            if expression is not None:
                fail()
            expression = value
        index += 2
    if source is None or expression is None:
        fail()
    return source, expression


def _format(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return str(value)


def _parse_segments(expression: str) -> list[tuple[str, object | None]]:
    """Parse @.a[0].b[*].c into [(a,0),(b,'*'),(c,None)]."""
    if not expression.startswith("@."):
        fail()
    raw = expression[2:]
    segments: list[tuple[str, object | None]] = []
    i = 0
    length = len(raw)
    while i < length:
        if raw[i] == ".":
            i += 1
            continue
        start = i
        while i < length and raw[i] not in ".[":
            i += 1
        key = raw[start:i]
        if not key:
            fail()
        index: object | None = None
        if i < length and raw[i] == "[":
            i += 1
            close = raw.find("]", i)
            if close < 0:
                fail()
            inside = raw[i:close]
            i = close + 1
            if inside == "*":
                index = "*"
            else:
                if not inside.isdigit():
                    fail()
                index = int(inside)
        segments.append((key, index))
    if not segments:
        fail()
    return segments


def resolve(source: object, expression: str) -> object:
    segments = _parse_segments(expression)
    values: list[object] = [source]
    for key, index in segments:
        next_values: list[object] = []
        for value in values:
            if not isinstance(value, dict) or key not in value:
                fail()
            child = value[key]
            if index is None:
                next_values.append(child)
            elif index == "*":
                if not isinstance(child, list):
                    fail()
                next_values.extend(child)
            else:
                if not isinstance(child, list):
                    fail()
                idx = int(index)
                if idx < 0 or idx >= len(child):
                    fail()
                next_values.append(child[idx])
        values = next_values
    if len(values) == 1:
        return _format(values[0])
    return "\n".join(_format(item) for item in values)


def main() -> None:
    source, expression = parse_args(sys.argv[1:])
    value = resolve(source, expression)
    # Always emit UTF-8 with LF only so BusyBox/ash command substitution
    # does not keep a trailing CR from Windows text-mode stdout.
    sys.stdout.buffer.write((str(value) + "\n").encode("utf-8"))
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
