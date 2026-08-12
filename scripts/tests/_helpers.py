from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def source_for(path) -> str:
    return (REPO_ROOT / path).read_text(encoding="utf-8")


def function_body(source: str, signature: str) -> str:
    search_from = 0
    while True:
        start = source.index(signature, search_from)
        brace = source.index("{", start)
        declaration_end = source.find(";", start, brace)
        if declaration_end == -1:
            break
        search_from = declaration_end + 1

    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"unterminated function: {signature}")
