#!/usr/bin/env python3
"""성능 이상 수집: hang 로그, 크래시 리포트, 느린 타입 체크 경고를 모아 기호화한 보고서 JSON을 쓴다.
사용: python3 -I scripts/perf-report.py collect --since "<YYYY-MM-DD HH:MM:SS>" --device <UDID>
          --products <제품 폴더> [--build-log <경로>]... --out <경로>
바이너리 선택 규칙(find_binary): 제품 폴더 아래에서 파일 이름이 이미지 이름과 같은 일반 파일 중
  1) .xctest 번들 밖 우선, 2) 경로가 얕은 것 우선, 3) 경로 문자열 사전순."""
import argparse
import collections
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
from typing import Dict, Iterable, List, Optional

ENTRY_POINTS = {"main", "$main", "static PayLabApp.$main()", "__debug_main_executable_dylib_entry_point"}
CRASH_GLOB = "~/Library/Logs/DiagnosticReports/PayLab-*.ips"
SUBSYSTEM_PREDICATE = 'subsystem == "com.example.paylab"'

HANG_RE = re.compile(r"^hang id=(\d+) duration=(\d+)ms frames=\d+$")
HANG_FRAME_RE = re.compile(r"^hang frame id=(\d+) #\d+ (\S+) 0x([0-9a-f]+) base=0x([0-9a-f]+) (.*)$")
SLOW_RE = re.compile(r"^(.+?):(\d+):\d+: warning: (.+?) took (\d+)ms to type-check \(limit: \d+ms\)")
TIMING_RE = re.compile(r"^\s*(\S.*?) \(\d+ tasks?\) \| ([\d.]+) seconds")
TIME_FORMATS = ("%Y-%m-%d %H:%M:%S.%f %z", "%Y-%m-%d %H:%M:%S %z")


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


def run_checked(run, cmd: List[str], what: str, warnings: Optional[List[str]]):
    """실행 실패(없는 명령·비 0 종료)는 warnings에 남기고 None."""
    try:
        result = run(cmd, capture_output=True, text=True)
    except OSError as e:
        result = None
        reason = str(e)
    else:
        reason = "exit %s" % result.returncode
        if result.returncode == 0:
            return result
    if warnings is not None and what not in warnings:
        warnings.append("%s 실패 (%s)" % (what, reason))
    return None


def ensure_dwarf(binary: str, dsym_dir: str, run, warnings: Optional[List[str]] = None) -> Optional[str]:
    name = os.path.basename(binary)
    dsym = os.path.join(dsym_dir, name + ".dSYM")
    dwarf = os.path.join(dsym, "Contents", "Resources", "DWARF", name)
    if os.path.exists(dwarf):
        return dwarf
    result = run_checked(run, ["xcrun", "dsymutil", binary, "-o", dsym], "dsymutil " + name, warnings)
    return dwarf if result else None


def symbolize(frames: List[dict], products_dir: str, repo_root: str, run=subprocess.run,
              dsym_dir: Optional[str] = None, warnings: Optional[List[str]] = None) -> List[dict]:
    """frames는 스택 하나(첫 프레임 = pc). #1 이상은 복귀 주소라 address - 1을 조회한다."""
    out = [dict(f, file=repo_relative(f.get("file"), repo_root)) for f in frames]
    if dsym_dir is None:
        with tempfile.TemporaryDirectory() as tmp:
            return symbolize(frames, products_dir, repo_root, run, tmp, warnings)
    groups = collections.OrderedDict()  # (image, base) -> [프레임 위치]
    for i, f in enumerate(frames):
        if f["image"] != "?":
            groups.setdefault((f["image"], f["base"]), []).append(i)
    for (image, base), positions in groups.items():
        binary = find_binary(products_dir, image)
        dwarf = ensure_dwarf(binary, dsym_dir, run, warnings) if binary else None
        if not dwarf:
            continue
        addresses = [frames[i]["address"] - (1 if i > 0 else 0) for i in positions]
        result = run_checked(run, ["xcrun", "atos", "-fullPath", "-o", dwarf, "-l", hex(base)]
                             + [hex(a) for a in addresses], "atos " + image, warnings)
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


def git_output(run, repo_root: str, *args: str) -> str:
    result = run(["git", "-C", repo_root] + list(args), capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else "unknown"


def collect(since: str, device: str, products_dir: str, build_logs: List[str], repo_root: str,
            run=subprocess.run, crash_dir: Optional[str] = None) -> dict:
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
            return symbolize(frames, products_dir, repo_root, run, dsym_dir, warnings)

        for hang in parse_hang_log(log.stdout.splitlines()):
            frames = sym(hang["frames"])
            files = frame_files(frames)
            if not files:
                ignored += 1
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
            "branch": git_output(run, repo_root, "branch", "--show-current"),
            "problems": problems, "ignored_hangs": ignored, "timing": timing, "warnings": warnings}


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("collect", help="로그·크래시·빌드 경고를 모아 보고서 JSON을 쓴다")
    c.add_argument("--since", required=True, help='"YYYY-MM-DD HH:MM:SS" (로컬 시각)')
    c.add_argument("--device", required=True, help="시뮬레이터 UDID")
    c.add_argument("--products", required=True)
    c.add_argument("--build-log", action="append", default=[])
    c.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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
