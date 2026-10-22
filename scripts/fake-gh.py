"""Answers the few gh commands the app runs, from files written by make-fixtures.py.

Usage (through the fake-gh wrapper): fake-gh.py <gh data dir> <gh arguments…>

  auth token …        prints a token, unless <data>/signed-out exists
  api user --jq .login  prints fixture-user
  api repos/…/releases/latest  prints "<tag>\t<url>" from <data>/release.json, or exits 1 (404)
  api graphql -f owner=… -f name=… -f b0=<branch> …
                      prints {"data":{"repository":{"b0":{"nodes":[…]}}}} from <data>/<owner>/<name>.json,
                      or exits 1 when that file says {"fail": true}
Each graphql call is appended to <data>/calls.log, so tests can see what was asked.
"""
import json, os, sys

data, args = sys.argv[1], sys.argv[2:]

if args[:2] == ["auth", "token"]:
    if os.path.exists(os.path.join(data, "signed-out")):
        sys.stderr.write("no oauth token\n")
        sys.exit(1)
    print("gho_fixture")
elif args[:2] == ["api", "user"]:
    print("fixture-user")
elif len(args) >= 2 and args[0] == "api" and args[1].endswith("/releases/latest"):
    # <data>/release.json: {"tag_name": "v1.2.0", "html_url": "https://github.com/…"}; none means 404.
    try:
        with open(os.path.join(data, "release.json")) as f:
            rel = json.load(f)
    except FileNotFoundError:
        sys.stderr.write("HTTP 404: Not Found\n")
        sys.exit(1)
    print(f"{rel['tag_name']}\t{rel['html_url']}")
elif args[:2] == ["api", "graphql"]:
    fields = {}
    for i, a in enumerate(args):
        if a == "-f" and i + 1 < len(args) and "=" in args[i + 1]:
            k, v = args[i + 1].split("=", 1)
            if k != "query":
                fields[k] = v
    with open(os.path.join(data, "calls.log"), "a") as log:
        log.write(json.dumps(fields) + "\n")
    path = os.path.join(data, fields.get("owner", ""), fields.get("name", "") + ".json")
    try:
        with open(path) as f:
            prs = json.load(f)
    except FileNotFoundError:
        prs = {}
    if prs.get("fail"):
        sys.stderr.write("HTTP 502: Bad Gateway\n")
        sys.exit(1)
    repo = {k: {"nodes": prs.get(v, [])} for k, v in fields.items() if k.startswith("b") and k[1:].isdigit()}
    print(json.dumps({"data": {"repository": repo}}))
else:
    sys.stderr.write(f"fake-gh: unsupported {' '.join(args)}\n")
    sys.exit(2)
