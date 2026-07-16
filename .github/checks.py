#!/usr/bin/env python3
"""Repo consistency checks. Run locally or in CI: python3 .github/checks.py

Checks only what the published repo carries (the .claude/ live-install copy
is gitignored; keeping it in sync is a local concern, not a repo one).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []


def fail(msg):
    failures.append(msg)
    print(f"FAIL  {msg}")


def ok(msg):
    print(f"ok    {msg}")


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


# 1. Every skill has frontmatter whose name matches its directory and a
#    non-empty description (the description IS the load trigger).
skills_dir = os.path.join(ROOT, "skills")
skill_names = sorted(
    d for d in os.listdir(skills_dir)
    if os.path.isdir(os.path.join(skills_dir, d))
)
for name in skill_names:
    rel = f"skills/{name}/SKILL.md"
    try:
        head = read(rel)[:4000]
    except OSError as e:
        fail(f"{rel}: unreadable ({e})")
        continue
    if not head.startswith("---"):
        fail(f"{rel}: missing frontmatter")
        continue
    m_name = re.search(r"^name:\s*(\S+)\s*$", head, re.M)
    m_desc = re.search(r"^description:\s*(.+)$", head, re.M)
    if not m_name or m_name.group(1) != name:
        fail(f"{rel}: frontmatter name != directory name")
    elif not m_desc or len(m_desc.group(1).strip()) < 20:
        fail(f"{rel}: description missing or too short to be a trigger")
    else:
        ok(f"{rel} frontmatter valid")

# 2. Version strings agree across both READMEs (badge + alpha callout).
versions = []
for rel, pats in [
    ("README.md", [r"version-alpha--([\d.]+)-orange", r"Early alpha \(`alpha-([\d.]+)`\)"]),
    ("README.zh-TW.md", [r"version-alpha--([\d.]+)-orange", r"早期 alpha\(`alpha-([\d.]+)`\)"]),
]:
    body = read(rel)
    for pat in pats:
        m = re.search(pat, body)
        if not m:
            fail(f"{rel}: version pattern not found: {pat}")
        else:
            versions.append((rel, m.group(1)))
import json
for rel, path in [
    (".claude-plugin/plugin.json", ["version"]),
    (".claude-plugin/marketplace.json", ["plugins", 0, "version"]),
]:
    try:
        data = json.loads(read(rel))
        for key in path:
            data = data[key]
        versions.append((rel, data))
    except (OSError, KeyError, IndexError, ValueError) as e:
        fail(f"{rel}: version unreadable ({e})")
if versions and len({v for _, v in versions}) == 1:
    ok(f"version consistent across {len(versions)} sites ({versions[0][1]})")
elif versions:
    fail(f"version mismatch: {versions}")

# 3. Every skill directory is mentioned in both READMEs.
for rel in ("README.md", "README.zh-TW.md"):
    body = read(rel)
    missing = [n for n in skill_names if n not in body]
    if missing:
        fail(f"{rel}: skills never mentioned: {missing}")
    else:
        ok(f"{rel} mentions all {len(skill_names)} skills")

# 4. No zero-width/bidi Unicode in tracked text files (hidden-directive sweep).
BAD = re.compile("[\\u200b-\\u200f\\u202a-\\u202e\\u2066-\\u2069]")
hits = 0
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [
        d for d in dirnames
        if d not in (".git", ".claude", "evals", "internal", "skills-staging", "node_modules")
    ]
    for fn in filenames:
        if not fn.endswith((".md", ".py", ".sh", ".mjs", ".yml", ".json")):
            continue
        p = os.path.join(dirpath, fn)
        try:
            with open(p, encoding="utf-8") as f:
                if BAD.search(f.read()):
                    fail(f"zero-width/bidi char in {os.path.relpath(p, ROOT)}")
                    hits += 1
        except (OSError, UnicodeDecodeError):
            pass
if hits == 0:
    ok("no zero-width/bidi characters in tracked text files")

# 5. Relative links in both READMEs resolve to files/dirs in the repo.
for rel in ("README.md", "README.zh-TW.md"):
    body = read(rel)
    broken = []
    for target in re.findall(r"\]\((?!https?://|#|mailto:)([^)#\s]+)", body):
        if not os.path.exists(os.path.join(ROOT, target)):
            broken.append(target)
    if broken:
        fail(f"{rel}: broken relative links: {sorted(set(broken))}")
    else:
        ok(f"{rel} relative links resolve")

# 6. License and notices files exist; hooks ship with their test suites.
for rel in ("LICENSE", "THIRD-PARTY-NOTICES.md"):
    (ok if os.path.exists(os.path.join(ROOT, rel)) else fail)(f"{rel} present")
hook_pairs = [
    ("hooks/gate-before-commit.sh", "hooks/test-gate-before-commit.sh"),
    ("hooks/gate-credential-destruction.py", "hooks/test-gate-credential-destruction.sh"),
    ("hooks/verify-before-stop.py", "hooks/test-verify-before-stop.sh"),
]
for hook, test in hook_pairs:
    if not os.path.exists(os.path.join(ROOT, hook)):
        fail(f"{hook} missing")
    elif not os.path.exists(os.path.join(ROOT, test)):
        fail(f"{hook} has no test suite ({test} missing)")
    else:
        ok(f"{hook} + its test suite present")

print()
if failures:
    print(f"{len(failures)} check(s) failed")
    sys.exit(1)
print("all checks passed")
