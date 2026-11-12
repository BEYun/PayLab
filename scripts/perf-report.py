#!/usr/bin/env python3
"""성능 이상 수집: hang 로그, 크래시 리포트, 느린 타입 체크 경고를 모아 기호화한 보고서 JSON을 쓴다.
사용: python3 -I scripts/perf-report.py collect --since "<YYYY-MM-DD HH:MM:SS>" --device <UDID>
          --products <제품 폴더> [--build-log <경로>]... --out <경로>
     python3 -I scripts/perf-report.py report --input <json> --where local|pr|main [--changed-from <ref> | --no-changes]
          [--pr <n>] [--baseline-dir <dir>] [--metrics <json>] [--dry-run]
     python3 -I scripts/perf-report.py ci-metrics --report <json> --run-id <id> --out <json>
     python3 -I scripts/perf-report.py changed-swift
바이너리 선택 규칙(find_binary): 제품 폴더 아래에서 파일 이름이 이미지 이름과 같은 일반 파일 중
  1) .xctest 번들 밖 우선, 2) 경로가 얕은 것 우선, 3) 경로 문자열 사전순."""
import argparse
import collections
import datetime
import glob
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
from typing import Dict, Iterable, List, Optional, Set

MIRROR_FRAME = "_os_log_impl_mirror_to_stderr"  # 디버거·테스트 콘솔에서만 쓰이는 stderr 미러링. 출시 앱에는 없다
ENTRY_POINTS = {"main", "$main", "static PayLabApp.$main()", "__debug_main_executable_dylib_entry_point"}
CRASH_GLOB = "~/Library/Logs/DiagnosticReports/PayLab-*.ips"
SUBSYSTEM_PREDICATE = 'subsystem == "com.example.paylab"'

HANG_RE = re.compile(r"^hang id=(\d+) duration=(\d+)ms frames=\d+$")
HANG_FRAME_RE = re.compile(r"^hang frame id=(\d+) #\d+ (\S+) 0x([0-9a-f]+) base=0x([0-9a-f]+) (.*)$")
SLOW_RE = re.compile(r"^(.+?):(\d+):\d+: warning: (.+?) took (\d+)ms to type-check \(limit: \d+ms\)")
TIMING_RE = re.compile(r"^\s*(\S.*?) \(\d+ tasks?\) \| ([\d.]+) seconds")
TIME_FORMATS = ("%Y-%m-%d %H:%M:%S.%f %z", "%Y-%m-%d %H:%M:%S %z")
TOOL_TIMEOUT = 120  # dsymutil·atos 한 번 (초). hook 전체 예산은 600초
GH_TIMEOUT = 60  # gh 한 번 (초)


class CollectError(Exception):
    """수집을 계속할 수 없는 입력 실패. main이 stderr에 알리고 종료 코드 2로 끝낸다."""


ATOS_RE = re.compile(r"^(.*?) \(in .*?\)(?: \((.+):(\d+)\))?(?: \+ \d+)?$")


def parse_time(text: str) -> datetime.datetime:
    """오프셋이 있는 리포트 시각 -> aware datetime."""
    for fmt in TIME_FORMATS:
        try:
            return datetime.datetime.strptime(text, fmt)
        except ValueError:
            pass
    raise ValueError("시각을 읽을 수 없음: %r" % text)


def parse_since(since: str) -> datetime.datetime:
    """--since는 로컬 시각 -> aware datetime."""
    try:
        return datetime.datetime.strptime(since, "%Y-%m-%d %H:%M:%S").astimezone()
    except ValueError:
        raise CollectError('--since 형식 오류: "YYYY-MM-DD HH:MM:SS"여야 함: %r' % since)


def make_frame(image: str, address: int, base: int, symbol: Optional[str],
               file: Optional[str] = None, line: Optional[int] = None) -> dict:
    return {"image": image, "address": address, "base": base, "symbol": symbol,
            "function": None, "file": file, "line": line}


def parse_hang_log(lines: Iterable[str]) -> List[dict]:
    hangs = collections.OrderedDict()  # (pid, id) -> hang. id는 프로세스 안에서만 유일하다
    recent = collections.defaultdict(lambda: collections.deque(maxlen=5))  # pid -> 최근 다른 카테고리 메시지
    for raw in lines:
        try:
            event = json.loads(raw)
        except ValueError:
            continue  # getpwuid_r 같은 잡음
        if not isinstance(event, dict) or "eventMessage" not in event:
            continue
        pid, message = event.get("processID"), event["eventMessage"]
        if event.get("category") != "hang":
            recent[pid].append(message)
            continue
        summary = HANG_RE.match(message)
        if summary:
            hangs[(pid, int(summary.group(1)))] = {
                "pid": pid, "id": int(summary.group(1)), "duration_ms": int(summary.group(2)),
                "time": event.get("timestamp"), "frames": [], "context": list(recent[pid])}
            continue
        part = HANG_FRAME_RE.match(message)
        if part and (pid, int(part.group(1))) in hangs:
            symbol = part.group(5)
            hangs[(pid, int(part.group(1)))]["frames"].append(make_frame(
                part.group(2), int(part.group(3), 16), int(part.group(4), 16), None if symbol == "?" else symbol))
    return list(hangs.values())


def parse_ips(text: str) -> dict:
    body = json.loads(text[text.index("\n") + 1:])  # 첫 줄은 헤더 JSON
    images = body.get("usedImages", [])
    frames = []
    for f in body["threads"][body["faultingThread"]]["frames"]:
        index = f.get("imageIndex", -1)
        image = images[index] if 0 <= index < len(images) else {}
        base = image.get("base", 0)
        frames.append(make_frame(image.get("name", "?"), base + f.get("imageOffset", 0), base, f.get("symbol"),
                                 f.get("sourceFile"), f.get("sourceLine")))
    udid = re.search(r"Devices/([0-9A-Fa-f-]{36})/", body.get("procPath", ""))
    message = "\n".join(line for lines in (body.get("asi") or {}).values() for line in lines)
    return {"pid": body.get("pid"), "time": body.get("captureTime"), "udid": udid.group(1) if udid else None,
            "exception": (body.get("exception") or {}).get("type"), "message": message, "frames": frames}


def parse_slow_functions(build_log: str) -> List[dict]:
    found, seen = [], set()
    for line in build_log.splitlines():
        m = SLOW_RE.match(line)
        if not m:
            continue
        key = (m.group(1), int(m.group(2)), m.group(3))
        if key not in seen:
            seen.add(key)
            found.append({"file": key[0], "line": key[1], "name": key[2], "ms": int(m.group(4))})
    return found


def parse_timing_summary(build_log: str) -> Dict[str, float]:
    timing = {}
    for line in build_log.splitlines():
        m = TIMING_RE.match(line)
        if m:
            timing[m.group(1)] = float(m.group(2))
    return timing


def find_binary(products_dir: str, image: str) -> Optional[str]:
    matches = []
    for root, dirs, files in os.walk(products_dir):
        dirs[:] = [d for d in dirs if not d.endswith(".dSYM")]
        if image in files:
            matches.append(os.path.join(root, image))
    if not matches:
        return None
    return min(matches, key=lambda p: (".xctest" in p, p.count(os.sep), p))


def repo_relative(path: Optional[str], repo_root: str) -> Optional[str]:
    if not path or not os.path.isabs(path):
        return None
    root = os.path.normpath(repo_root)
    path = os.path.normpath(path)
    return os.path.relpath(path, root) if path.startswith(root + os.sep) else None


def run_checked(run, cmd: List[str], what: str, failures: Optional[List[str]]):
    """실행 실패(없는 명령·비 0 종료·시간 초과)는 failures에 남기고 None."""
    try:
        result = run(cmd, capture_output=True, text=True, timeout=TOOL_TIMEOUT)
    except OSError as e:
        result = None
        reason = str(e)
    except subprocess.TimeoutExpired:
        result = None
        reason = "%d초 초과" % TOOL_TIMEOUT
    else:
        reason = "exit %s" % result.returncode
        if result.returncode == 0:
            return result
    if failures is not None and what not in failures:
        failures.append("%s 실패 (%s)" % (what, reason))
    return None


def ensure_dwarf(binary: str, dsym_dir: str, run, failures: Optional[List[str]] = None) -> Optional[str]:
    name = os.path.basename(binary)
    dsym = os.path.join(dsym_dir, name + ".dSYM")
    dwarf = os.path.join(dsym, "Contents", "Resources", "DWARF", name)
    if os.path.exists(dwarf):
        return dwarf
    result = run_checked(run, ["xcrun", "dsymutil", binary, "-o", dsym], "dsymutil " + name, failures)
    return dwarf if result else None


def symbolize(frames: List[dict], products_dir: str, repo_root: str, run=subprocess.run,
              dsym_dir: Optional[str] = None, failures: Optional[List[str]] = None) -> List[dict]:
    """frames는 스택 하나(첫 프레임 = pc). #1 이상은 복귀 주소라 address - 1을 조회한다.
    dsymutil·atos가 실패한 이미지는 기호화하지 않고 failures에 남긴다(collect는 이것을 수집 실패로 본다)."""
    out = [dict(f, file=repo_relative(f.get("file"), repo_root)) for f in frames]
    if dsym_dir is None:
        with tempfile.TemporaryDirectory() as tmp:
            return symbolize(frames, products_dir, repo_root, run, tmp, failures)
    groups = collections.OrderedDict()  # (image, base) -> [프레임 위치]
    for i, f in enumerate(frames):
        if f["image"] != "?":
            groups.setdefault((f["image"], f["base"]), []).append(i)
    for (image, base), positions in groups.items():
        binary = find_binary(products_dir, image)
        dwarf = ensure_dwarf(binary, dsym_dir, run, failures) if binary else None
        if not dwarf:
            continue
        addresses = [frames[i]["address"] - (1 if i > 0 else 0) for i in positions]
        result = run_checked(run, ["xcrun", "atos", "-fullPath", "-o", dwarf, "-l", hex(base)]
                             + [hex(a) for a in addresses], "atos " + image, failures)
        if not result:
            continue
        for i, line in zip(positions, result.stdout.splitlines()):
            m = ATOS_RE.match(line.strip())
            if not m:
                continue
            out[i]["function"] = m.group(1)
            out[i]["file"] = repo_relative(m.group(2), repo_root)
            out[i]["line"] = int(m.group(3)) if m.group(3) and out[i]["file"] else None
    return out


def is_our_frame(frame: dict) -> bool:
    return bool(frame.get("file")) and frame.get("function") not in ENTRY_POINTS


def frame_files(frames: List[dict]) -> List[str]:
    files = []
    for f in frames:
        if is_our_frame(f) and f["file"] not in files:
            files.append(f["file"])
    return files


def git_output(run, repo_root: str, *args: str, default: str = "unknown") -> str:
    result = run(["git", "-C", repo_root] + list(args), capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else default


def collect(since: str, device: str, products_dir: str, build_logs: List[str], repo_root: str,
            run=subprocess.run, crash_dir: Optional[str] = None, env=None) -> dict:
    env = os.environ if env is None else env
    since_at = parse_since(since)
    if not os.path.isdir(products_dir):
        raise CollectError("--products 폴더가 없음: %s" % products_dir)
    problems, ignored, warnings = [], 0, []
    log = run(["xcrun", "simctl", "spawn", device, "log", "show", "--start", since, "--style", "ndjson",
               "--info", "--debug", "--predicate", SUBSYSTEM_PREDICATE], capture_output=True, text=True)
    if log.returncode != 0:
        raise CollectError("log show 실패 (exit %s): %s" % (log.returncode, (log.stderr or "").strip()))
    with tempfile.TemporaryDirectory() as dsym_dir:
        def sym(frames):
            failures = []
            out = symbolize(frames, products_dir, repo_root, run, dsym_dir, failures)
            if failures:  # 기호화가 안 되면 우리 코드 hang이 "무시"로, 크래시가 "앱 프레임 없음"으로 보인다
                raise CollectError("기호화 실패: %s" % "; ".join(failures))
            return out

        for hang in parse_hang_log(log.stdout.splitlines()):
            frames = sym(hang["frames"])
            files = frame_files(frames)
            if not files:
                ignored += 1
                continue
            first_app = next(i for i, f in enumerate(frames) if is_our_frame(f))
            if any(MIRROR_FRAME in (f.get("function"), f.get("symbol")) for f in frames[:first_app]):
                ignored += 1
                warnings.append("stderr 로그 미러링 중 hang %dms 무시 (%s)" % (hang["duration_ms"], frames[first_app]["function"]))
                continue
            problems.append({"kind": "hang", "duration_ms": hang["duration_ms"], "time": hang["time"],
                             "frames": frames, "files": files, "context": hang["context"]})
        pattern = os.path.join(crash_dir, "PayLab-*.ips") if crash_dir else os.path.expanduser(CRASH_GLOB)
        for path in sorted(glob.glob(pattern)):
            try:
                with open(path) as f:
                    text = f.read()
                header = json.loads(text[:text.index("\n")])  # 헤더 줄만으로 시각 필터. 본문은 큼
                if parse_time(header["timestamp"]) < since_at:
                    continue
                crash = parse_ips(text)
                if crash["udid"] != device or parse_time(crash["time"]) < since_at:
                    continue
            except (OSError, ValueError, KeyError, IndexError, TypeError) as e:
                warnings.append("크래시 리포트 건너뜀 %s: %s %s" % (os.path.basename(path), type(e).__name__, e))
                continue
            frames = sym(crash["frames"])
            problems.append({"kind": "crash", "exception": crash["exception"], "message": crash["message"],
                             "time": crash["time"], "frames": frames, "files": frame_files(frames), "context": []})
    timing, slow_seen = {}, set()
    for path in build_logs:
        with open(path, errors="replace") as f:
            text = f.read()
        for name, seconds in parse_timing_summary(text).items():
            timing[name] = round(timing.get(name, 0.0) + seconds, 3)
        for slow in parse_slow_functions(text):
            rel = repo_relative(slow["file"], repo_root)
            key = (rel, slow["line"], slow["name"])
            if rel and key not in slow_seen:
                slow_seen.add(key)
                problems.append({"kind": "slow-function", "name": slow["name"], "file": rel, "line": slow["line"],
                                 "ms": slow["ms"], "files": [rel]})
    return {"version": 1, "commit": git_output(run, repo_root, "rev-parse", "HEAD"),
            "branch": git_output(run, repo_root, "branch", "--show-current",  # CI PR은 분리된 HEAD라 비어 있다
                                 default=env.get("GITHUB_HEAD_REF") or env.get("GITHUB_REF_NAME") or "unknown"),
            "problems": problems, "ignored_hangs": ignored, "timing": timing, "warnings": warnings}


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER_ROOT = "/Users/runner/work/PayLab/PayLab/"
PR_MARKER = "<!-- paylab-perf-report -->"
OCC_START, OCC_END = "<!-- perf-occurrences:start -->", "<!-- perf-occurrences:end -->"
SIGNATURE_RE = re.compile(r"<!-- perf-signature: (.*?) -->")
LABELS = {"perf-auto": "ededed", "crash": "b60205", "hang": "d93f0b", "slow-build": "fbca04"}
KIND_LABEL = {"crash": "crash", "hang": "hang", "slow-function": "slow-build", "build-time": "slow-build"}
MAX_RECENT = 5


class GitHubError(Exception):
    """gh 호출 실패(비 0 종료)."""


class ChangedFilesUnknown(RuntimeError):
    """변경 파일 집합을 알 수 없음(origin/main 없음, git 실패, ref 없음). 호출 쪽은 모든 문제를 이번 변경으로 본다."""


def changed_files(repo_root: str, mode: str, ref: Optional[str] = None, run=subprocess.run) -> Set[str]:
    def git(*args: str) -> List[str]:
        try:
            result = run(["git", "-C", repo_root] + list(args), capture_output=True, text=True)
        except OSError as e:
            raise ChangedFilesUnknown("git 실행 실패: %s" % e)
        if result.returncode != 0:
            raise ChangedFilesUnknown("git %s 실패 (exit %s)" % (args[0], result.returncode))
        return [line for line in result.stdout.splitlines() if line]

    if mode == "none":
        return set()
    if mode == "ref":
        return set(git("diff", "--name-only", ref, "HEAD"))
    bases = git("merge-base", "origin/main", "HEAD")
    if not bases:
        raise ChangedFilesUnknown("merge-base를 찾지 못함")
    base = bases[0]
    return set(git("diff", "--name-only", base)) | set(git("ls-files", "--others", "--exclude-standard"))


def classify(problem: dict, changed: Set[str]) -> str:
    return "change" if set(problem.get("files", [])) & set(changed) else "existing"


def innermost_function(problem: dict) -> Optional[str]:
    for f in problem.get("frames", []):
        if is_our_frame(f):
            return f.get("function") or f.get("symbol") or "?"
    return None


def innermost_symbol(problem: dict) -> Optional[str]:
    """가장 안쪽 기호화된 프레임의 함수(없으면 기호). 앱 프레임이 없는 크래시끼리 서명을 가른다."""
    for f in problem.get("frames", []):
        if f.get("function") or f.get("symbol"):
            return f.get("function") or f.get("symbol")
    return None


def signature(problem: dict) -> str:
    kind = problem["kind"]
    if kind == "hang":
        return "hang|%s" % innermost_function(problem)
    if kind == "crash":
        return "crash|%s|%s" % (problem.get("exception"),
                                innermost_function(problem) or innermost_symbol(problem) or "-")
    if kind == "slow-function":
        return "slow-function|%s|%s" % (problem["file"], problem["name"])
    return "build-time"


def sanitize(text: str, repo_root: str) -> str:
    text = text.replace(os.path.normpath(repo_root) + "/", "").replace(RUNNER_ROOT, "")
    home = os.path.expanduser("~")
    if home not in ("", "/"):
        text = text.replace(home, "~")
    text = re.sub(r"/Users/[^/\s]+/", "~/", text)
    text = re.sub(r"\b[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\b", "<UDID>", text)
    text = re.sub(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+", "<email>", text)
    text = re.sub(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,})", "<token>", text)
    host = socket.gethostname()
    for name in {host, host.split(".")[0]}:
        if len(name) >= 4:
            text = text.replace(name, "<host>")
    return text


def issue_title(problem: dict) -> str:
    return plain_title(problem).replace("@", "＠")  # 제목은 코드로 감쌀 수 없어 @멘션을 막는다


def plain_title(problem: dict) -> str:
    kind = problem["kind"]
    if kind == "hang":
        return "[hang] %s %dms" % (innermost_function(problem), problem["duration_ms"])
    if kind == "crash":
        return "[crash] %s" % " ".join(x for x in (problem.get("exception"), innermost_function(problem)) if x)
    if kind == "slow-function":
        return "[slow-build] %s %s %dms" % (os.path.basename(problem["file"]), problem["name"], problem["ms"])
    return "[slow-build] 우리 코드 컴파일 시간 +%d%% (+%d초)" % (round(problem["increase_pct"]), round(problem["increase_s"]))


def location(problem: dict) -> str:
    """`파일:줄`. 위치가 없으면 빈 문자열."""
    if problem["kind"] == "slow-function":
        return "%s:%d" % (problem["file"], problem["line"])
    for f in problem.get("frames", []):
        if is_our_frame(f):
            return "%s:%s" % (f["file"], f["line"]) if f.get("line") else f["file"]
    return ""


def code_span(text: str) -> str:
    """`…`로 감싼다(코드 안에서는 @멘션이 먹지 않는다). 안의 백틱은 지운다. 빈 문자열은 그대로."""
    text = (text or "").replace("`", "")
    return "`%s`" % text if text else ""


def found_line(found: dict) -> str:
    return " · ".join(x for x in (found["where"], code_span(found["branch"]), found["commit"]) if x)


def occurrence_block(count: int, found: dict, recent: List[str], extra: Optional[List[str]] = None) -> str:
    lines = [OCC_START, "## 발생 기록", "- 횟수: %d" % count, "- 마지막 발견: %s" % found["time"], "- 최근 발견한 곳:"]
    lines += ["  - %s" % entry for entry in recent[:MAX_RECENT]]
    lines += extra or []
    lines.append(OCC_END)
    return "\n".join(lines)


def issue_body(problem: dict, found: dict, previous: Optional[int] = None) -> str:
    kind = problem["kind"]
    if kind == "hang":
        figure = "메인 스레드 %dms 응답 없음 (기준 250ms)" % problem["duration_ms"]
    elif kind == "crash":
        figure = "크래시 %s" % problem.get("exception")
    elif kind == "slow-function":
        figure = "타입 검사 %dms (기준 100ms) — `%s`" % (problem["ms"], problem["name"])
    else:
        figure = "우리 코드 컴파일 시간 +%.0f%% (+%.1f초). 현재 %.1f초, 최근 중앙값 %.1f초" % (
            problem["increase_pct"], problem["increase_s"], problem["current"], problem["median"])
    parts = ["## 종류와 수치", "- 종류: %s" % kind, "- 수치: %s" % figure,
             "## 처음 발견한 곳", "- 위치: %s" % found["where"], "- 브랜치: %s" % code_span(found["branch"]),
             "- 커밋: %s" % found["commit"]]
    if found.get("run_url"):
        parts.append("- 실행: %s" % found["run_url"])
    if previous:
        parts.append("- 이전 이슈: #%d (닫힌 뒤 다시 발생)" % previous)
    if problem.get("context"):
        parts += ["## 재현 단서 (직전 앱 로그)", "```", *problem["context"], "```"]
    stack = [f for f in problem.get("frames", []) if is_our_frame(f)]
    if stack:
        parts.append("## 우리 코드 스택")
        for f in stack:
            where = "%s:%s" % (f["file"], f["line"]) if f.get("line") else f["file"]
            parts.append("- `%s` — `%s`" % (f.get("function") or f.get("symbol") or "?", where))
    if problem.get("message"):
        parts += ["## 원문", "```", problem["message"], "```"]
    parts += ["<!-- perf-signature: %s -->" % signature(problem), occurrence_block(1, found, [found_line(found)])]
    return "\n".join(parts)


RECENT_RE = re.compile(r"^  - ((?:로컬|CI) · .*)$")
OWN_LINE_RES = [re.compile(x) for x in (r"^## 발생 기록$", r"^- 횟수: \d+$", r"^- 마지막 발견: .*$", r"^- 최근 발견한 곳:$")]


def record_occurrence(body: str, found: dict) -> str:
    """표식이 하나씩 제대로 있으면 블록을 고친다. 아니면 표식을 모두 지우고 새 블록을 끝에 붙인다.
    이때 횟수는 본문에서 읽은 가장 큰 `횟수:` 값에서 이어간다(없으면 1부터)."""
    start, end = body.find(OCC_START), body.find(OCC_END)
    valid = body.count(OCC_START) == 1 and body.count(OCC_END) == 1 and start < end
    if not valid:
        counts = [int(n) for n in re.findall(r"^- 횟수: (\d+)$", body, re.M)]
        cleaned = body.replace(OCC_START, "").replace(OCC_END, "").rstrip("\n")
        return cleaned + "\n" + occurrence_block(max(counts, default=0) + 1, found, [found_line(found)])
    inner = body[start + len(OCC_START):end].splitlines()
    m = next((re.match(r"^- 횟수: (\d+)$", line) for line in inner if re.match(r"^- 횟수: (\d+)$", line)), None)
    recent = [RECENT_RE.match(line).group(1) for line in inner if RECENT_RE.match(line)]
    extra = [line for line in inner if line.strip() and not RECENT_RE.match(line)
             and not any(r.match(line) for r in OWN_LINE_RES)]  # 사람이 블록 안에 쓴 줄은 보존
    new = occurrence_block((int(m.group(1)) if m else 0) + 1, found, [found_line(found)] + recent, extra)
    return body[:start] + new + body[end + len(OCC_END):]


def median(values: List[float]) -> float:
    ordered = sorted(values)
    mid = len(ordered) // 2
    return ordered[mid] if len(ordered) % 2 else (ordered[mid - 1] + ordered[mid]) / 2


def build_regression(current: dict, baseline: List[dict], ratio: float = 0.30,
                     min_seconds: float = 10.0) -> Optional[dict]:
    if current.get("swift_compile_s") is None:
        return None
    baseline = [m for m in baseline if m.get("swift_compile_s") is not None]
    if len(baseline) < 5:
        return None
    use_ratio = all(m.get("ratio") is not None for m in baseline + [current])
    key = "ratio" if use_ratio else "swift_compile_s"
    base_value = median([m[key] for m in baseline])
    base_seconds = median([m["swift_compile_s"] for m in baseline])
    if base_value <= 0:
        return None
    pct = (current[key] / base_value - 1) * 100
    seconds = current["swift_compile_s"] - base_seconds
    if pct < ratio * 100 or seconds < min_seconds:
        return None
    return {"kind": "build-time", "files": [], "increase_pct": pct, "increase_s": seconds,
            "current": current["swift_compile_s"], "median": base_seconds}


class GitHub:
    def __init__(self, run=subprocess.run, repo_root: str = REPO_ROOT):
        self.run = run
        self.repo_root = repo_root

    def gh(self, *args: str) -> str:
        try:  # 네트워크가 멈춰도 hook 예산(600초)을 다 쓰지 않는다
            result = self.run(["gh"] + list(args), capture_output=True, text=True, timeout=GH_TIMEOUT,
                              cwd=self.repo_root)
        except subprocess.TimeoutExpired:
            raise GitHubError("gh %s 시간 초과 (%d초)" % (args[0], GH_TIMEOUT))
        if result.returncode != 0:
            raise GitHubError("gh %s 실패 (exit %s): %s" % (args[0], result.returncode, (result.stderr or "").strip()))
        return result.stdout

    def ensure_labels(self) -> None:
        have = {label["name"] for label in json.loads(self.gh("label", "list", "--json", "name", "--limit", "200"))}
        for name, color in LABELS.items():
            if name not in have:
                self.gh("label", "create", name, "--color", color)

    def issues(self) -> List[dict]:
        return json.loads(self.gh("issue", "list", "--label", "perf-auto", "--state", "all", "--limit", "200",
                                  "--json", "number,state,stateReason,title,body"))

    def create_issue(self, title: str, body: str, labels: List[str]) -> str:
        args = ["issue", "create", "--title", title, "--body", body]
        for label in labels:
            args += ["--label", label]
        return self.gh(*args).strip()

    def edit_issue_body(self, number: int, body: str) -> None:
        self.gh("issue", "edit", str(number), "--body", body)

    def upsert_pr_comment(self, pr: int, body: str, only_if_exists: bool = False) -> bool:
        comments = json.loads(self.gh("api", "repos/{owner}/{repo}/issues/%d/comments?per_page=100" % pr))
        existing = next((c for c in comments if PR_MARKER in c.get("body", "")), None)
        if existing:
            self.gh("api", "-X", "PATCH", "repos/{owner}/{repo}/issues/comments/%d" % existing["id"], "-f", "body=" + body)
            return True
        if only_if_exists:
            return False
        self.gh("pr", "comment", str(pr), "--body", body)
        return True


def merge_duplicates(problems: List[dict]) -> List[dict]:
    """서명이 같은 문제는 하나로 합친다(위치 파일은 합집합, hang은 가장 긴 지속 시간)."""
    merged = collections.OrderedDict()
    for p in problems:
        sig = signature(p)
        if sig not in merged:
            merged[sig] = dict(p, files=list(p.get("files", [])))
            continue
        kept = merged[sig]
        kept["files"] += [f for f in p.get("files", []) if f not in kept["files"]]
        if p["kind"] == "hang" and p["duration_ms"] > kept["duration_ms"]:
            merged[sig] = dict(p, files=kept["files"])
    return list(merged.values())


def make_found(data: dict, where: str, env) -> dict:
    ci = where != "local"
    run_url = ""
    if ci and all(env.get(k) for k in ("GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID")):
        run_url = "%s/%s/actions/runs/%s" % (env["GITHUB_SERVER_URL"], env["GITHUB_REPOSITORY"], env["GITHUB_RUN_ID"])
    return {"where": "CI" if ci else "로컬", "branch": data.get("branch", "unknown"),
            "commit": data.get("commit", "unknown"), "run_url": run_url,
            "time": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}


def pr_comment_body(changes: List[dict], found: dict) -> str:
    if not changes:
        return "%s\n## 성능 리포트\n문제 없음 (%s)" % (PR_MARKER, found["commit"])
    lines = [PR_MARKER, "## 성능 리포트", "이번 변경과 엮인 문제 %d개 (%s)" % (len(changes), found["commit"])]
    for p in changes:
        lines.append(("- `%s` `%s`" % (issue_title(p), location(p))).replace(" ``", ""))
    return "\n".join(lines)


def report(data: dict, where: str, changed: Optional[Set[str]], github, pr: Optional[int] = None,
           baseline: Optional[List[dict]] = None, metrics: Optional[dict] = None, dry_run: bool = False,
           out_dir: str = ".build/perf", env=None, repo_root: str = REPO_ROOT) -> int:
    env = os.environ if env is None else env
    clean = lambda text: sanitize(text, repo_root)
    for warning in data.get("warnings", []):
        print("경고: %s" % warning)
    found = make_found(data, where, env)
    problems = merge_duplicates(data.get("problems", []))
    if metrics is not None and where != "local":
        regression = build_regression(metrics, baseline or [])
        if regression:
            problems.append(regression)
    unknown = changed is None and where != "main"
    if unknown:
        print("경고: 변경 파일을 알 수 없어 모든 문제를 이번 변경으로 봅니다")
    changes, existing = [], []
    for p in problems:
        if where == "main":
            existing.append(p)
        elif p["kind"] == "build-time":
            (changes if where == "pr" else existing).append(p)
        elif p["kind"] == "crash" and not p.get("files"):
            changes.append(p)  # 앱 프레임 없는 크래시: 파일로 판정할 수 없어 컴파일 시간처럼 다룬다(main만 기존)
        else:
            (changes if unknown or classify(p, changed) == "change" else existing).append(p)
    if where == "local":
        existing = [p for p in existing if p["kind"] != "slow-function"]  # 로컬은 느린 함수의 기존 문제를 무시
    for p in changes:
        print(clean(("[이번 변경] %s %s" % (issue_title(p), location(p))).rstrip()))
    if where == "pr" and pr is not None:
        comment = clean(pr_comment_body(changes, found))
        if dry_run:
            print("[dry-run] PR #%d 코멘트%s" % (pr, "" if changes else " (기존 코멘트가 있을 때만)"))
        else:
            try:
                github.upsert_pr_comment(pr, comment, only_if_exists=not changes)
            except Exception as e:
                print("경고: PR 코멘트 실패: %s" % clean(str(e)))
    pending = handle_existing(existing, where, found, github, dry_run, clean)
    if not changes and not existing:
        print("성능 문제 없음")
    if pending:
        os.makedirs(out_dir, exist_ok=True)
        path = os.path.join(out_dir, "pending-issues.json")
        with open(path, "w") as f:
            json.dump(pending, f, ensure_ascii=False, indent=2)
        print("경고: 이슈를 올리지 못해 %s 에 남김" % path)
    return 1 if where == "local" and changes else 0


def issue_signature(issue: dict) -> Optional[str]:
    m = SIGNATURE_RE.search(issue.get("body") or "")
    return m.group(1) if m else None


def handle_existing(existing: List[dict], where: str, found: dict, github, dry_run: bool, clean) -> List[dict]:
    """기존 문제를 이슈로 올리거나 발생 기록을 고친다. 올리지 못한 이슈 목록을 돌려준다."""
    pending, issues, labels_ready = [], None, False
    if existing and not dry_run:
        try:
            issues = github.issues()
        except Exception as e:
            print("경고: gh 이슈 목록 실패: %s" % clean(str(e)))
    for p in existing:
        title = clean(issue_title(p))
        sig = clean(signature(p))
        if dry_run:
            print("[기존 → 이슈 (dry-run: 열린 이슈 확인 안 함)] %s" % title)
            continue
        labels = ["perf-auto", KIND_LABEL[p["kind"]]]
        matches = [i for i in (issues or []) if issue_signature(i) == sig]
        opened = max((i for i in matches if i["state"].upper() == "OPEN"), key=lambda i: i["number"], default=None)
        closed = max((i for i in matches if i["state"].upper() != "OPEN"), key=lambda i: i["number"], default=None)
        try:
            if issues is None:
                raise GitHubError("이슈 목록을 읽지 못함")
            if opened:
                body = clean(record_occurrence(opened["body"], found))
                try:
                    github.edit_issue_body(opened["number"], body)
                except Exception:
                    pending.append({"number": opened["number"], "title": title, "body": body, "labels": labels})
                    raise
                print("[기존 → 이슈 #%d] %s" % (opened["number"], title))
            elif closed and (closed.get("stateReason") or "").upper() == "NOT_PLANNED":
                print("[기존 → 닫힌 이슈 #%d (계획 없음), 기록만] %s" % (closed["number"], title))  # 사람이 끈 문제
            elif closed and where == "local":
                print("[기존 → 이슈 #%d 닫힘, 새로 만들지 않음] %s" % (closed["number"], title))
            else:
                body = clean(issue_body(p, found, previous=closed["number"] if closed else None))
                pending.append({"title": title, "body": body, "labels": labels})
                if not labels_ready:
                    github.ensure_labels()
                    labels_ready = True
                url = github.create_issue(title, body, labels)
                pending.pop()
                m = re.search(r"/(\d+)\s*$", url or "")
                print("[기존 → 이슈 #%s] %s" % (m.group(1), title) if m else "[기존 → 새 이슈] %s" % title)
        except Exception as e:
            print("경고: gh 실패: %s" % clean(str(e)))
            if issues is None:
                pending.append({"title": title, "body": clean(issue_body(p, found)), "labels": labels})
    return pending


def load_baselines(directory: str) -> List[dict]:
    found = []
    for path in sorted(glob.glob(os.path.join(directory, "**", "build-metrics.json"), recursive=True)):
        try:
            with open(path) as f:
                found.append(json.load(f))
        except (OSError, ValueError) as e:
            print("경고: 기준 건너뜀 %s: %s" % (path, e), file=sys.stderr)
    return found


ISO_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?Z")
BUILD_JOB, BUILD_STEP = "build-and-test", "빌드"


def parse_iso(text: str) -> Optional[datetime.datetime]:
    m = ISO_RE.match(text or "")
    if not m:
        return None
    t = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
    return t + datetime.timedelta(seconds=float(m.group(2) or 0))


def gh_text(run, *args: str) -> str:
    try:
        result = run(["gh", "api"] + list(args), capture_output=True, text=True, timeout=GH_TIMEOUT, cwd=REPO_ROOT)
    except subprocess.TimeoutExpired:
        raise GitHubError("gh api 시간 초과")
    if result.returncode != 0:
        raise GitHubError("gh api 실패")
    return result.stdout


def ci_metrics(report: Optional[dict], run_id: str, repo: str, run=subprocess.run) -> dict:
    timing = (report or {}).get("timing") or {}
    swift = timing.get("SwiftCompile")
    system = round(sum(v for k, v in timing.items() if k.startswith("SwiftExplicitDependency")), 3)
    metrics = {"commit": (report or {}).get("commit") or os.environ.get("GITHUB_SHA", "")[:7] or None,
               "swift_compile_s": swift, "system_modules_s": system if timing else None,
               "ratio": swift / system if swift is not None and system > 0 else None,
               "xcodebuild_start_s": None, "build_step_s": None}
    try:
        jobs = json.loads(gh_text(run, "repos/%s/actions/runs/%s/jobs" % (repo, run_id)))["jobs"]
        job = next(j for j in jobs if j.get("name") == BUILD_JOB)
        step = next(s for s in job["steps"] if s.get("name") == BUILD_STEP)
        start, end = parse_iso(step.get("started_at")), parse_iso(step.get("completed_at"))
        if start and end:
            metrics["build_step_s"] = round((end - start).total_seconds())
        log = gh_text(run, "--allow-escape-sequences", "repos/%s/actions/jobs/%s/logs" % (repo, job["id"]))
        shell_start = None  # 단계 헤더 뒤 첫 ##[endgroup] = 셸 시작 (러너의 단계 준비 시간 제외)
        for line in log.splitlines():
            when = parse_iso(line)
            if not (start and when and when >= start):
                continue
            if shell_start is None:
                if "##[endgroup]" in line:
                    shell_start = when
            elif "Command line invocation" in line:
                metrics["xcodebuild_start_s"] = round((when - shell_start).total_seconds())
                break
    except (GitHubError, ValueError, KeyError, StopIteration, OSError) as e:
        print("경고: CI 단계 시간을 못 구함: %s" % type(e).__name__, file=sys.stderr)
    return metrics


def run_ci_metrics(args) -> int:
    report = None
    if os.path.exists(args.report):
        with open(args.report) as f:
            report = json.load(f)
    metrics = ci_metrics(report, args.run_id, os.environ.get("GITHUB_REPOSITORY", ""), run=subprocess.run)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(metrics, f, ensure_ascii=False, indent=2)
    print(json.dumps(metrics, ensure_ascii=False))
    return 0


def run_report(args) -> int:
    if not os.path.exists(args.input):
        print("보고서 없음")
        return 0
    with open(args.input) as f:
        data = json.load(f)
    if args.where == "main" or args.no_changes:
        mode = "none"
    else:
        mode = "ref" if args.changed_from else "merge-base"
    try:
        changed = changed_files(REPO_ROOT, mode, args.changed_from)
    except ChangedFilesUnknown as e:
        print("경고: 변경 파일 확인 실패: %s" % e)
        changed = None
    baseline = load_baselines(args.baseline_dir) if args.baseline_dir else None
    metrics = None
    if args.metrics and os.path.exists(args.metrics):
        with open(args.metrics) as f:
            metrics = json.load(f)
    return report(data, args.where, changed, GitHub(), pr=args.pr, baseline=baseline, metrics=metrics,
                  dry_run=args.dry_run, out_dir=os.path.join(REPO_ROOT, ".build", "perf"))


def run_changed_swift() -> int:
    try:
        paths = sorted(changed_files(REPO_ROOT, "merge-base"))
    except ChangedFilesUnknown as e:
        print("경고: 변경 파일을 알 수 없음: %s" % e, file=sys.stderr)
        return 0
    for path in paths:
        if path.endswith(".swift") and os.path.exists(os.path.join(REPO_ROOT, path)):
            print(path)
    return 0


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("collect", help="로그·크래시·빌드 경고를 모아 보고서 JSON을 쓴다")
    c.add_argument("--since", required=True, help='"YYYY-MM-DD HH:MM:SS" (로컬 시각)')
    c.add_argument("--device", required=True, help="시뮬레이터 UDID")
    c.add_argument("--products", required=True)
    c.add_argument("--build-log", action="append", default=[])
    c.add_argument("--out", required=True)
    r = sub.add_parser("report", help="보고서를 판정해 이슈·PR 코멘트로 올린다")
    r.add_argument("--input", required=True)
    r.add_argument("--where", required=True, choices=["local", "pr", "main"])
    r.add_argument("--changed-from", help="이 ref와 HEAD의 차이를 변경 파일로 본다 (기본: origin/main merge-base)")
    r.add_argument("--no-changes", action="store_true", help="변경 파일 없음으로 본다")
    r.add_argument("--pr", type=int)
    r.add_argument("--baseline-dir")
    r.add_argument("--metrics")
    r.add_argument("--dry-run", action="store_true", help="gh를 호출하지 않고 할 일만 출력")
    m = sub.add_parser("ci-metrics", help="CI 빌드 측정값(build-metrics.json)을 만든다")
    m.add_argument("--report", required=True)
    m.add_argument("--run-id", required=True)
    m.add_argument("--out", required=True)
    sub.add_parser("changed-swift", help="merge-base 이후 변경된 .swift 파일을 줄마다 출력")
    args = parser.parse_args(argv)
    if args.command == "report":
        if args.where == "pr" and not args.changed_from and not args.no_changes:
            parser.error("--where pr 에는 --changed-from 또는 --no-changes가 필요함")
        return run_report(args)
    if args.command == "ci-metrics":
        return run_ci_metrics(args)
    if args.command == "changed-swift":
        return run_changed_swift()
    repo_root = REPO_ROOT
    try:
        report = collect(args.since, args.device, args.products, args.build_log, repo_root)
    except CollectError as e:
        print("perf-report collect 실패: %s" % e, file=sys.stderr)
        return 2
    for warning in report["warnings"]:
        print("경고: %s" % warning, file=sys.stderr)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    print("problems=%d ignored_hangs=%d -> %s" % (len(report["problems"]), report["ignored_hangs"], args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
