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


def resolve(source: object, expression: str) -> object:
    if not expression.startswith("@."):
        fail()
    value = source
    for key in expression[2:].split("."):
        if not key or not isinstance(value, dict) or key not in value:
            fail()
        value = value[key]
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return value


def main() -> None:
    source, expression = parse_args(sys.argv[1:])
    value = resolve(source, expression)
    # Always emit UTF-8 with LF only so BusyBox/ash command substitution
    # does not keep a trailing CR from Windows text-mode stdout.
    sys.stdout.buffer.write((str(value) + "\n").encode("utf-8"))
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
