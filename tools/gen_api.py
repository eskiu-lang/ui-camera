#!/usr/bin/env python3
"""Writes docs/api.md for an Eskiu package from its source comments.

    python3 -I tools/gen_api.py            # write docs/api.md
    python3 -I tools/gen_api.py --check    # exit 1 if it is stale or a public item has no comment

Run from the package root (the directory holding eskiu.toml). Every top-level public
declaration of src/*.esk (a name not starting with `_`, not `extern` or `intrinsic`) is
listed under its module with the comment block right above it: functions, structs,
unions, interfaces, enums, type aliases and constants. The comment at the top of a file
describes its module. Lines of a comment indented by four or more spaces are code.
Files listed in API_SKIP (generated bindings) are left out.
"""
import os
import re
import sys

API_SKIP = {"raw.esk"}

DECL_KW = re.compile(r"^(packed\s+)?(struct|union|interface|enum)\s+([A-Za-z]\w*)")
TYPE_RE = re.compile(r"^type\s+([A-Za-z]\w*)\s*=")
CONST_RE = re.compile(r"^const\s+.*?\b([A-Za-z]\w*)\s*(\[[^\]]*\])?\s*=")
FN_RE = re.compile(r"^(?:export\s+|must_use\s+|async\s+|deprecated\s*\([^)]*\)\s*)*"
                   r"[\w<>,\*\[\]\s?]+?[\s\*]([A-Za-z]\w*)\s*(?:<[^>()]*>)?\s*\(")
OP_RE = re.compile(r"^[\w<>,\*\[\]\s]+?\boperator\s*(\S+?)\s*\(")


def package_name():
    with open("eskiu.toml") as f:
        in_pkg = False
        for line in f:
            s = line.strip()
            if s.startswith("["):
                in_pkg = s == "[package]"
            elif in_pkg and s.startswith("name"):
                return s.split("=", 1)[1].strip().strip('"')
    sys.exit("gen_api: no [package] name in eskiu.toml")


def module_name(pkg, rel):
    stem = os.path.splitext(rel)[0].replace(os.sep, "/")
    return f"<{pkg}>" if stem == pkg or stem == "lib" else f"<{pkg}/{stem}>"


def comment_text(lines):
    out = []
    code = False
    for raw in lines:
        t = raw[2:] if raw.startswith("//") else raw
        if t.startswith(" "):
            t = t[1:]
        is_code = t.startswith("    ")
        if is_code and not code:
            if out and out[-1] != "":
                out.append("")
            out.append("```eskiu")
            code = True
        elif not is_code and code and t.strip() != "":
            while out and out[-1] == "":
                out.pop()
            out.append("```")
            out.append("")
            code = False
        if code:
            out.append(t[4:] if t.strip() else "")
        else:
            out.append(quote_modules(t.rstrip()))
    if code:
        while out and out[-1] == "":
            out.pop()
        out.append("```")
    while out and out[-1] == "":
        out.pop()
    while out and out[0] == "":
        out.pop(0)
    return "\n".join(out)


def quote_modules(text):
    """`<mod>` and `<mod/sub>` outside backticks get backticks (Markdown would read a tag)."""
    parts = text.split("`")
    for k in range(0, len(parts), 2):
        parts[k] = re.sub(r"(?<![\w`])<([a-z][\w-]*(?:/[\w-]+)*)>", r"`<\1>`", parts[k])
    return "`".join(parts)


def strip_trailing_comment(line):
    in_str = False
    i = 0
    while i < len(line):
        c = line[i]
        if c == '"' and (i == 0 or line[i - 1] != "\\"):
            in_str = not in_str
        elif not in_str and line.startswith("//", i):
            return line[:i].rstrip(), line[i + 2:].strip()
        i += 1
    return line.rstrip(), ""


def body_of(lines, i):
    """The members of a struct/union/interface/enum starting at line i, and the next line."""
    members = []
    depth = 0
    j = i
    while j < len(lines):
        line = lines[j]
        code, _ = strip_trailing_comment(line)
        depth += code.count("{") - code.count("}")
        if j > i:
            members.append(line)
        if depth <= 0 and "{" in "".join(lines[i:j + 1]) and "}" in code:
            break
        j += 1
    return members, j + 1


def render_body(members):
    """Public members, without method bodies: fields, enum members, methods' headers."""
    out = []
    depth = 0
    pending = []
    for line in members:
        code, cmt = strip_trailing_comment(line)
        s = code.strip()
        if depth == 0:
            if s.startswith("//"):
                pending.append(s)
                continue
            if s == "" or s == "}" or s.startswith("#"):
                pending = []
                if s.startswith("#"):
                    continue
                if s == "":
                    continue
            m = re.search(r"([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*(?:[:=;,({]|$)", s)
            name = None
            fm = re.match(r"[\w<>,\*\[\]\s?]+?[\s\*]([A-Za-z_]\w*)\s*\(", s)
            if fm:
                name = fm.group(1)
            elif m:
                name = m.group(1)
            if s and s != "}" and not (name or "").startswith("_"):
                for p in pending:
                    out.append("    " + p)
                head = s
                if "{" in head:
                    head = head[:head.index("{")].rstrip() + ";"
                out.append("    " + head + (("   // " + cmt) if cmt else ""))
            pending = []
        depth += code.count("{") - code.count("}")
        if depth < 0:
            depth = 0
    return out


def signature(lines, i):
    """A function's header from line i up to its body or ';', and the line after it."""
    text = ""
    j = i
    while j < len(lines):
        code, _ = strip_trailing_comment(lines[j])
        text += " " + code.strip()
        if "{" in code or code.rstrip().endswith(";"):
            break
        j += 1
    head = text.strip()
    if "{" in head:
        head = head[:head.index("{")].rstrip()
    head = head.rstrip(";").rstrip()
    head = re.sub(r"\s+", " ", head).replace("( ", "(").replace(" )", ")")
    head = re.sub(r"^export\s+", "", head)
    # skip the body
    depth = 0
    k = i
    started = False
    while k < len(lines):
        code, _ = strip_trailing_comment(lines[k])
        depth += code.count("{") - code.count("}")
        if "{" in code:
            started = True
        if (started and depth <= 0) or (not started and code.rstrip().endswith(";")):
            return head, k + 1
        k += 1
    return head, k


def parse(path):
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    i = 0
    header = []
    while i < len(lines) and lines[i].startswith("//"):
        header.append(lines[i])
        i += 1
    items = []
    comment = []
    last_const_end = -2
    while i < len(lines):
        line = lines[i]
        if line.startswith("//"):
            comment.append(line)
            i += 1
            continue
        if line.strip() == "" or line.startswith("#") or line.startswith("import ") \
                or line[:1].isspace() or line.startswith("}"):
            if line.strip() == "" or line.startswith("import "):
                comment = []
            i += 1
            continue
        if line.startswith("extern ") or line.startswith("intrinsic "):
            comment = []
            _, i = signature(lines, i)
            continue
        kind = None
        name = None
        m = DECL_KW.match(line)
        if m:
            kind, name = m.group(2), m.group(3)
            head = line.split("{")[0].rstrip()
            one = strip_trailing_comment(line)[0]
            if "{" in one and one.count("{") == one.count("}"):
                nxt = i + 1
                text = one.strip()
            elif "{" in line or (i + 1 < len(lines) and lines[i + 1].strip().startswith("{")):
                members, nxt = body_of(lines, i)
                body = render_body(members)
                text = head + " {\n" + "\n".join(body) + ("\n" if body else "") + "}"
            else:
                nxt = i + 1
                text = head.rstrip(";") + ";"
            if not name.startswith("_"):
                items.append((kind, name, text, comment_text(comment), comment != []))
            comment = []
            i = nxt
            continue
        m = TYPE_RE.match(line)
        if m:
            name = m.group(1)
            if not name.startswith("_"):
                items.append(("type", name, line.split("//")[0].strip(), comment_text(comment), comment != []))
            comment = []
            i += 1
            continue
        m = CONST_RE.match(line)
        if m:
            name = m.group(1)
            text = strip_trailing_comment(line)[0].strip()
            cmt = strip_trailing_comment(line)[1]
            j = i
            while not text.rstrip().endswith(";") and j + 1 < len(lines):
                j += 1
                text += " " + strip_trailing_comment(lines[j])[0].strip()
            if not name.startswith("_"):
                c = comment_text(comment) or cmt
                if len(text) > 160:
                    text = text.split("=")[0].rstrip() + " = ...;"
                prev = items[-1] if items else None
                if not comment and prev and prev[0] == "const" and last_const_end == i - 1 \
                        and not prev[1].startswith("_"):
                    # a run of constants with no blank line shares the comment above it
                    items[-1] = ("const", prev[1] + ", " + name, prev[2] + "\n" + text,
                                 prev[3] + (("\n\n`" + name + "`: " + cmt) if cmt and prev[3] else ""),
                                 prev[4] or bool(cmt))
                else:
                    items.append(("const", name, text, c, bool(comment) or bool(cmt)))
                last_const_end = j
            comment = []
            i = j + 1
            continue
        m = OP_RE.match(line)
        if m:
            head, nxt = signature(lines, i)
            items.append(("operator", "operator " + m.group(1), head, comment_text(comment), comment != []))
            comment = []
            i = nxt
            continue
        m = FN_RE.match(line)
        if m and "=" not in line.split("(")[0]:
            name = m.group(1)
            head, nxt = signature(lines, i)
            if not name.startswith("_"):
                items.append(("fn", name, head, comment_text(comment), comment != []))
            comment = []
            i = nxt
            continue
        # a global variable or something else: skip the statement
        comment = []
        while i < len(lines) and not strip_trailing_comment(lines[i])[0].rstrip().endswith(";"):
            i += 1
        i += 1
    return comment_text(header), items


def build():
    pkg = package_name()
    files = []
    for root, dirs, names in os.walk("src"):
        dirs.sort()
        for n in names:
            if n.endswith(".esk") and n not in API_SKIP and not n.startswith("_"):
                files.append(os.path.relpath(os.path.join(root, n), "src"))
    files.sort()
    main = [f for f in files if os.path.splitext(f)[0] in (pkg, "lib")]
    files = main + [f for f in files if f not in main]
    out = [f"# {pkg} API reference", "",
           "Every public declaration of the package, by module, with its comment from the source.",
           "Generated by `tools/gen_api.py`; edit the comments in `src/`, not this file.", ""]
    toc = []
    body = []
    undocumented = []
    for f in files:
        header, items = parse(os.path.join("src", f))
        mod = module_name(pkg, f)
        seen = {}
        uniq = []
        for it in items:
            key = (it[0], it[1])
            if key in seen:
                k = seen[key]
                if not uniq[k][4] and it[4]:
                    uniq[k] = it
                continue
            seen[key] = len(uniq)
            uniq.append(it)
        if not uniq and not header:
            continue
        anchor = re.sub(r"[^a-z0-9_-]", "", mod.lower())
        toc.append(f"- [`{mod}`](#{anchor})")
        body += ["", f"## `{mod}`", ""]
        if header:
            first = header.split("\n", 1)
            h = header
            if re.match(r"^[\w.]+\.esk:\s*", first[0]):
                h = re.sub(r"^[\w.]+\.esk:\s*", "", header, count=1)
                h = h[:1].upper() + h[1:]
            body += [h, ""]
        for kind, name, text, cmt, has in uniq:
            if not has:
                undocumented.append(f"src/{f}: {kind} {name}")
            body += [f"### {name}", "", "```eskiu", text, "```", ""]
            if cmt:
                body += [cmt, ""]
    out += toc + body
    while out and out[-1] == "":
        out.pop()
    return "\n".join(out) + "\n", undocumented


def main():
    text, undocumented = build()
    path = os.path.join("docs", "api.md")
    if "--check" in sys.argv:
        old = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        bad = 0
        if old != text:
            print("docs/api.md is stale: run python3 -I tools/gen_api.py")
            bad = 1
        for u in undocumented:
            print("no comment:", u)
            bad = 1
        sys.exit(bad)
    os.makedirs("docs", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    for u in undocumented:
        print("no comment:", u)


if __name__ == "__main__":
    main()
