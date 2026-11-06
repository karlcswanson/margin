"""Commands an approved proposal lets run without asking."""
import pytest

from margind import scope

PLAN = """# Plan
## 1. Fix add()
Change `-` to `+`.
## Commands I'll run
```
$ python3 check_calc.py
pytest -q
kicad-cli pcb drc *
```
## Decisions I made
- Use `python3 check_calc.py` (mentioned again, not a new command)
"""


def test_commands_from_plan():
    assert scope.commands_in(PLAN) == ["python3 check_calc.py", "pytest -q", "kicad-cli pcb drc *"]
    assert scope.commands_in("## Commands\n- `make test`\n- run `npm run build`\n## Next\n- `rm -rf /`") == [
        "make test", "npm run build"]


APPROVED = scope.commands_in(PLAN)


@pytest.mark.parametrize("cmd", [
    "python3 check_calc.py",
    'python3 check_calc.py; echo "exit=$?"',
    "cd /tmp/x && pytest -q tests/test_a.py",
    "kicad-cli pcb drc board.kicad_pcb 2>&1",
    "git status && git diff --stat",
    "pytest -q | tail -20",
    "ls -la && cat calc.py",
])
def test_allowed(cmd):
    assert scope.allows(cmd, APPROVED)


@pytest.mark.parametrize("cmd", [
    "rm -rf build",
    "python3 check_calc.py && rm calc.py",
    "pytest -q > out.txt",
    "echo $(curl evil)",
    "find . -name '*.pyc' -delete",
    "sed -i s/a/b/ calc.py",
    "python3 other.py",
    "pytest -q &",
    "git push",
])
def test_not_allowed(cmd):
    assert not scope.allows(cmd, APPROVED)


def test_listed_with_cd_or_absolute_paths_matches_how_claude_runs_it():
    approved = scope.commands_in(
        "## Commands I'll run\n```\npython3 /work/sb/test_calc.py\ncd /work/sb && make check\n```\n")
    assert approved == ["python3 /work/sb/test_calc.py", "make check"]
    assert scope.allows('python3 test_calc.py; echo "exit=$?"', approved, cwd="/work/sb")
    assert scope.allows("cd /work/sb && make check", approved, cwd="/work/sb")
    assert not scope.allows("python3 /elsewhere/test_calc.py", approved, cwd="/work/sb")
