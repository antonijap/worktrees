"""Builds throwaway git repos covering every worktree state the app knows, plus a fake gh.

Usage: python3 -I scripts/make-fixtures.py <empty or missing dir> [--many N]

Writes into <dir>:
  Code/        the folder to scan: repos alpha, beta, gamma, work/team/delta (three folders
               down), a repo inside node_modules (always
               skipped), one inside sandbox/ (skipped only when Settings adds "sandbox") and one
               five folders deep (found only with scan depth 5 or more)
  Projects/, Developer/, src -> Code, Documents/  onboarding's home folder stand-ins
  wt/          linked worktrees of alpha, outside the scanned folder like real agent worktrees
  remotes/     bare repos standing in for GitHub, so pushes and upstreams are real
  gh/          canned pull requests per repo, read by fake-gh
  fake-gh      a stand-in for the gh CLI; point WORKTREES_GH at it
  fixtures.json  every worktree path by key, for tests to look up

Nothing here touches the network, the user's git config or their real repos.
"""
import json, os, subprocess, sys, time

args = sys.argv[1:]
# --many N: instead of the feature fixtures, N repos with 5 worktrees each, for timing a big setup.
many = int(args[args.index("--many") + 1]) if "--many" in args else 0
out = os.path.abspath([a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] != "--many")][0])
if os.path.exists(out) and os.listdir(out):
    sys.exit(f"{out} is not empty")
os.makedirs(out, exist_ok=True)

CODE, WT, REMOTES, GH = (os.path.join(out, d) for d in ("Code", "wt", "remotes", "gh"))
for d in (CODE, WT, REMOTES, GH):
    os.makedirs(d, exist_ok=True)

DAY = 86_400
NOW = int(time.time())
# The user's ~/.gitconfig (signing, hooks, templates) must not leak into fixtures.
BASE_ENV = {
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": out,
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
    "GIT_COMMITTER_NAME": "Fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
    "GIT_TERMINAL_PROMPT": "0",
}


def git(cwd, *args, days_ago=0):
    env = dict(BASE_ENV)
    stamp = f"{NOW - days_ago * DAY} +0000"
    env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = stamp
    r = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"git {' '.join(args)} in {cwd} failed: {r.stderr}")
    return r.stdout.strip()


def commit(cwd, name, days_ago=0):
    with open(os.path.join(cwd, name), "w") as f:
        f.write(f"{name}\n")
    git(cwd, "add", name)
    git(cwd, "commit", "-q", "-m", f"Add {name}", days_ago=days_ago)


def repo(path, slug=None, days_ago=60):
    """A repo on main with one pushed commit, a local bare origin and a github.com remote."""
    os.makedirs(path, exist_ok=True)
    git(path, "init", "-q", "-b", "main")
    commit(path, "README.md", days_ago)
    name = os.path.basename(path)
    bare = os.path.join(REMOTES, f"{name}.git")
    git(REMOTES, "init", "-q", "--bare", "-b", "main", bare)
    git(path, "remote", "add", "origin", bare)
    git(path, "push", "-q", "-u", "origin", "main")
    if slug:
        # Never fetched: it only gives the repo a GitHub slug for PR lookups.
        git(path, "remote", "add", "github", f"https://github.com/{slug}.git")
    return path


paths = {}

if many:
    # Every repo: main plus 5 worktrees, all pushed; every tenth worktree holds 2,000 small files,
    # so measuring disk sizes has real work to do.
    for r in range(many):
        path = os.path.join(CODE, f"group-{r % 10}", f"repo-{r:03d}")
        os.makedirs(path)
        git(path, "init", "-q", "-b", "main")
        commit(path, "README.md", 30)
        bare = os.path.join(REMOTES, f"repo-{r:03d}.git")
        git(REMOTES, "init", "-q", "--bare", "-b", "main", bare)
        git(path, "remote", "add", "origin", bare)
        git(path, "remote", "add", "github", f"https://github.com/fixture/repo-{r:03d}.git")
        for w in range(5):
            wt = os.path.join(WT, f"repo-{r:03d}-{w}")
            git(path, "worktree", "add", "-q", "-b", f"feat/{w}", wt, "main")
            commit(wt, f"w{w}.txt", w * 10)
            if (r * 5 + w) % 10 == 0:
                bulk = os.path.join(wt, "node_cache")
                os.makedirs(bulk)
                for i in range(2000):
                    with open(os.path.join(bulk, f"f{i}.js"), "w") as f:
                        f.write("x" * 400)
        git(path, "push", "-q", "--all", "-u", "origin")
    with open(os.path.join(out, "fixtures.json"), "w") as f:
        here = os.path.dirname(os.path.abspath(__file__))
        fake = os.path.join(out, "fake-gh")
        with open(fake, "w") as g:
            g.write(f'#!/bin/sh\nexec /usr/bin/python3 -I "{os.path.join(here, "fake-gh.py")}" "{GH}" "$@"\n')
        os.chmod(fake, 0o755)
        json.dump({"root": os.path.realpath(CODE), "gh": GH, "fakeGh": fake, "paths": {}}, f, indent=1)
    print(out)
    sys.exit(0)


def worktree(key, repo_path, branch, where=None, days_ago=0, push=True, dirty=False, ahead=False):
    path = where or os.path.join(WT, key)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    git(repo_path, "worktree", "add", "-q", "-b", branch, path, "main")
    commit(path, f"{key}.txt", days_ago)
    if push:
        git(path, "push", "-q", "-u", "origin", branch)
    if ahead:
        commit(path, f"{key}-unpushed.txt", 0)
    if dirty:
        with open(os.path.join(path, "scratch.txt"), "w") as f:
            f.write("uncommitted\n")
    paths[key] = os.path.realpath(path)
    return path


alpha = repo(os.path.join(CODE, "alpha"), "fixture/alpha")
paths["alpha"] = os.path.realpath(alpha)
worktree("merged", alpha, "feat/merged", days_ago=3)
worktree("closed", alpha, "feat/closed", days_ago=4)
worktree("failing", alpha, "feat/failing", days_ago=1)
worktree("stale", alpha, "feat/stale", days_ago=45)
worktree("fresh", alpha, "feat/fresh", days_ago=10)
worktree("dirty", alpha, "feat/dirty", days_ago=2, dirty=True)
worktree("ahead", alpha, "feat/ahead", days_ago=2, ahead=True)
worktree("local", alpha, "feat/local", days_ago=50, push=False)
worktree("release", alpha, "release", days_ago=5)
worktree("claude", alpha, "claude/tidy-copy", where=os.path.join(out, "agents", ".claude", "worktrees", "tidy-copy"), days_ago=40)
worktree("codex", alpha, "codex/fix-scan", days_ago=40)

beta = repo(os.path.join(CODE, "work", "beta"), "fixture/beta")
paths["beta"] = os.path.realpath(beta)
worktree("beta-merged", beta, "feat/beta-merged", days_ago=2)

# gh fails for this repo, to check failed lookups are counted and old data kept.
gamma = repo(os.path.join(CODE, "gamma"), "fixture/gamma")
paths["gamma"] = os.path.realpath(gamma)
worktree("gamma-unknown", gamma, "feat/gamma-unknown", days_ago=1)

# Three folders down: found at scan depth 3 and up, not at 2.
paths["delta"] = os.path.realpath(repo(os.path.join(CODE, "work", "team", "delta")))

# For onboarding, <dir> stands in for the home folder: Code and Projects hold repos, Developer is
# empty, src is a symlink to Code (one folder, two names), and Documents holds a repo that must
# never be looked at, since macOS guards it with a permission prompt.
paths["omega"] = os.path.realpath(repo(os.path.join(out, "Projects", "omega")))
os.makedirs(os.path.join(out, "Developer"), exist_ok=True)
os.symlink(CODE, os.path.join(out, "src"))
paths["guarded"] = os.path.realpath(repo(os.path.join(out, "Documents", "GitHub", "guarded")))

paths["hidden"] = os.path.realpath(repo(os.path.join(CODE, "node_modules", "hidden")))
paths["sandboxed"] = os.path.realpath(repo(os.path.join(CODE, "sandbox", "sandboxed")))
paths["deep"] = os.path.realpath(repo(os.path.join(CODE, "deep", "a", "b", "c", "deeprepo")))


def pr(number, branch, state, checks=None, draft=False):
    """One pull request as the app's GraphQL query returns it."""
    contexts = []
    if checks:
        contexts = [{"__typename": "CheckRun", "name": "ci", "conclusion": checks, "status": "COMPLETED",
                     "detailsUrl": f"https://github.com/fixture/alpha/actions/runs/{number}0/job/1",
                     "checkSuite": {"workflowRun": {"workflow": {"name": "CI"}}}}]
    return {
        "number": number, "title": f"Fixture PR {number}", "state": state, "isDraft": draft,
        "url": f"https://github.com/fixture/alpha/pull/{number}", "headRefName": branch, "baseRefName": "main",
        "reviewDecision": None, "updatedAt": "2026-10-20T10:00:00Z", "mergeStateStatus": "CLEAN",
        "mergeable": "MERGEABLE", "author": {"login": "fixture-user"}, "labels": {"nodes": []},
        "latestReviews": {"nodes": []}, "reviewRequests": {"nodes": []},
        "commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {"nodes": contexts}} if contexts else None}}]},
    }


gh_data = {
    "fixture/alpha": {
        "feat/merged": [pr(1, "feat/merged", "MERGED", "SUCCESS")],
        "feat/closed": [pr(2, "feat/closed", "CLOSED")],
        "feat/failing": [pr(3, "feat/failing", "OPEN", "FAILURE")],
        "feat/dirty": [pr(4, "feat/dirty", "MERGED", "SUCCESS")],
        "feat/ahead": [pr(5, "feat/ahead", "MERGED", "SUCCESS")],
        "release": [pr(6, "release", "MERGED", "SUCCESS")],
        "claude/tidy-copy": [pr(7, "claude/tidy-copy", "MERGED", "SUCCESS")],
    },
    "fixture/beta": {"feat/beta-merged": [pr(8, "feat/beta-merged", "MERGED", "SUCCESS")]},
    "fixture/gamma": {"fail": True},
}
for slug, data in gh_data.items():
    owner, name = slug.split("/")
    os.makedirs(os.path.join(GH, owner), exist_ok=True)
    with open(os.path.join(GH, owner, f"{name}.json"), "w") as f:
        json.dump(data, f, indent=1)

here = os.path.dirname(os.path.abspath(__file__))
fake = os.path.join(out, "fake-gh")
with open(fake, "w") as f:
    f.write(f'#!/bin/sh\nexec /usr/bin/python3 -I "{os.path.join(here, "fake-gh.py")}" "{GH}" "$@"\n')
os.chmod(fake, 0o755)

with open(os.path.join(out, "fixtures.json"), "w") as f:
    json.dump({"root": os.path.realpath(CODE), "gh": GH, "fakeGh": fake, "paths": paths}, f, indent=1)
print(out)
