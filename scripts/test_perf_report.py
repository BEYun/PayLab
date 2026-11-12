#!/usr/bin/env python3
"""perf-report.py 테스트. 사용: python3 -I scripts/test_perf_report.py"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import tempfile
import time
import types
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures", "perf")
spec = importlib.util.spec_from_file_location("perf_report", os.path.join(HERE, "perf-report.py"))
pr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pr)

DEVICE = "11111111-2222-3333-4444-555555555555"
REPO = "/Users/tester/PayLab"


def read(name):
    with open(os.path.join(FIX, name)) as f:
        return f.read()


def frame(**kw):
    base = {"image": "X", "address": 0, "base": 0, "symbol": None, "function": None, "file": None, "line": None}
    base.update(kw)
    return base


def ok(stdout=""):
    return types.SimpleNamespace(returncode=0, stdout=stdout, stderr="")


def hang_event(msg, pid=1, category="hang"):
    return json.dumps({"processID": pid, "category": category, "eventMessage": msg,
                       "timestamp": "2026-11-12 10:00:00.000000+0900"})


class ParseTests(unittest.TestCase):
    def test_parse_hang_log_groups_frames_and_context(self):
        hangs = pr.parse_hang_log(read("hang.ndjson").splitlines())
        self.assertEqual(len(hangs), 1)
        h = hangs[0]
        self.assertEqual((h["pid"], h["id"], h["duration_ms"]), (4242, 1, 412))
        self.assertEqual(h["time"], "2026-11-12 10:00:02.000000+0900")
        self.assertEqual([f["image"] for f in h["frames"]], ["libsystem_kernel.dylib", "HomeFeature", "UIKitCore"])
        self.assertEqual(h["frames"][1]["address"], 0x100a4c2e0)
        self.assertEqual(h["frames"][1]["base"], 0x100a40000)
        self.assertEqual(h["frames"][2]["symbol"], "-[UIApplication sendEvent:]")
        self.assertEqual(h["context"], [  # 같은 pid(4242)의 직전 5줄. pid 9999 줄은 빠진다
            "request GET /accounts/a1/history",
            "response 200 GET /accounts/a1/history 3ms 420B",
            "load ok transactions=20",
            "select recipient=r1",
            "confirm amount=1000"])

    def test_parse_hang_log_without_frames(self):
        hangs = pr.parse_hang_log(["getpwuid_r did not find a match for uid 501",
                                   hang_event("hang id=2 duration=300ms frames=0")])
        self.assertEqual(len(hangs), 1)
        self.assertEqual(hangs[0]["frames"], [])

    def test_parse_hang_log_groups_by_pid_and_id(self):
        lines = [hang_event("hang id=1 duration=300ms frames=1", pid=1),
                 hang_event("hang id=1 duration=900ms frames=1", pid=2),
                 hang_event("hang frame id=1 #0 ? 0x0 base=0x0 ?", pid=2)]
        hangs = pr.parse_hang_log(lines)
        self.assertEqual([len(h["frames"]) for h in hangs], [0, 1])
        self.assertIsNone(hangs[1]["frames"][0]["symbol"])

    def test_parse_ips_faulting_thread(self):
        crash = pr.parse_ips(read("crash.ips"))
        self.assertEqual(crash["udid"], DEVICE)
        self.assertEqual(crash["pid"], 5001)
        self.assertEqual(crash["exception"], "EXC_BREAKPOINT")
        self.assertIn("Fatal error: Index out of range", crash["message"])
        self.assertEqual(crash["time"], "2026-11-12 10:05:00.1234 +0900")
        self.assertEqual([f["image"] for f in crash["frames"]], ["libdispatch.dylib", "PayLab.debug.dylib"])
        self.assertEqual(crash["frames"][0]["address"], 7000000000 + 225444)  # base + imageOffset
        self.assertEqual(crash["frames"][1]["base"], 4347117568)
        self.assertEqual(crash["frames"][1]["line"], 42)

    def test_parse_slow_functions_dedupes(self):
        slow = pr.parse_slow_functions(read("build.log"))
        self.assertEqual(len(slow), 1)
        self.assertEqual(slow[0]["name"], "instance method 'rows()'")
        self.assertEqual(slow[0]["ms"], 150)
        self.assertEqual(slow[0]["line"], 12)
        self.assertTrue(slow[0]["file"].endswith("Modules/HomeFeature/Sources/HistoryModel.swift"))

    def test_parse_timing_summary(self):
        timing = pr.parse_timing_summary("SwiftCompile (31 tasks) | 23.010 seconds")
        self.assertEqual(timing, {"SwiftCompile": 23.01})


class SymbolizeTests(unittest.TestCase):
    def setUp(self):
        self.products = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.products, "HomeFeature.framework"))
        open(os.path.join(self.products, "HomeFeature.framework", "HomeFeature"), "w").close()
        self.addCleanup(shutil.rmtree, self.products)

    def test_symbolize_maps_repo_paths(self):
        calls = []

        def run(cmd, **kw):
            calls.append(cmd)
            if "atos" in cmd:
                return ok("HistoryModel.load() (in PayLab.debug.dylib) (%s/Modules/HomeFeature/Sources/HistoryModel.swift:42)\n"
                          "SomeLib.f() (in HomeFeature) (/Elsewhere/Other.swift:7)\n" % REPO)
            return ok()

        frames = [frame(image="HomeFeature", address=0x1000, base=0x800),
                  frame(image="HomeFeature", address=0x2000, base=0x800),
                  frame(image="libsystem_kernel.dylib", address=0x3000, base=0x3000)]
        out = pr.symbolize(frames, self.products, REPO, run=run)
        self.assertEqual(out[0]["file"], "Modules/HomeFeature/Sources/HistoryModel.swift")
        self.assertEqual(out[0]["line"], 42)
        self.assertEqual(out[0]["function"], "HistoryModel.load()")
        self.assertIsNone(out[1]["file"])  # 저장소 밖
        self.assertEqual(out[1]["function"], "SomeLib.f()")
        self.assertIsNone(out[2]["file"])  # 제품 폴더에 없는 시스템 이미지
        self.assertEqual(out[0]["address"], 0x1000)  # 로그 주소는 그대로
        atos = [c for c in calls if "atos" in c]
        self.assertEqual(len(atos), 1)
        self.assertEqual(atos[0][atos[0].index("-l") + 1], hex(0x800))
        self.assertEqual(atos[0][-2:], [hex(0x1000), hex(0x2000 - 1)])  # 목록 첫 프레임만 pc
        self.assertTrue(any("dsymutil" in c for c in calls))

    def test_symbolize_looks_up_return_address_minus_one(self):
        calls = []

        def run(cmd, **kw):
            calls.append(cmd)
            return ok("a() (in HomeFeature) (/Users/tester/PayLab/x.swift:1)\nb() (in HomeFeature) (/Users/tester/PayLab/y.swift:2)\n")

        frames = [frame(image="HomeFeature", address=0x1000, base=0x800),
                  frame(image="HomeFeature", address=0x2000, base=0x800)]
        pr.symbolize(frames, self.products, REPO, run=run)
        atos = [c for c in calls if "atos" in c][0]
        self.assertEqual(atos[-2:], [hex(0x1000), hex(0x2000 - 1)])  # #0은 pc, #1부터 복귀 주소

    def test_find_binary_prefers_non_test_bundle_then_shallow_then_sorted(self):
        for rel in ["HomeFeatureTests.xctest/Frameworks/HomeFeature.framework/HomeFeature",
                    "PayLab.app/Frameworks/HomeFeature.framework/HomeFeature"]:
            path = os.path.join(self.products, rel)
            os.makedirs(os.path.dirname(path))
            open(path, "w").close()
        found = pr.find_binary(self.products, "HomeFeature")
        self.assertEqual(os.path.relpath(found, self.products), "HomeFeature.framework/HomeFeature")
        os.remove(found)
        found = pr.find_binary(self.products, "HomeFeature")
        self.assertEqual(os.path.relpath(found, self.products), "PayLab.app/Frameworks/HomeFeature.framework/HomeFeature")

    def test_entrypoint_is_not_our_frame(self):
        for fn in ["main", "$main", "static PayLabApp.$main()", "__debug_main_executable_dylib_entry_point"]:
            self.assertFalse(pr.is_our_frame(frame(file="Modules/App/Sources/PayLabApp.swift", function=fn)), fn)
        self.assertTrue(pr.is_our_frame(frame(file="Modules/A.swift", function="A.f()")))
        self.assertFalse(pr.is_our_frame(frame(file=None, function="A.f()")))


class CollectTests(unittest.TestCase):
    def set_tz(self, tz):
        os.environ["TZ"] = tz
        time.tzset()

    def setUp(self):
        old = os.environ.get("TZ")
        self.addCleanup(self.restore_tz, old)
        self.set_tz("Asia/Seoul")  # --since는 로컬 시각. 기기 시간대와 무관하게 고정
        self.crash_dir = tempfile.mkdtemp()
        self.products = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.crash_dir)
        self.addCleanup(shutil.rmtree, self.products)
        shutil.copy(os.path.join(FIX, "crash.ips"), os.path.join(self.crash_dir, "PayLab-2026-11-12-100500.ips"))
        shutil.copy(os.path.join(FIX, "crash-other-device.ips"),
                    os.path.join(self.crash_dir, "PayLab-2026-11-12-100600.ips"))

    @staticmethod
    def restore_tz(old):
        if old is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = old
        time.tzset()

    def collect(self, hang_lines="", since="2026-11-12 10:00:00", build_logs=(), tool=None):
        def run(cmd, **kw):
            if "log" in cmd and "show" in cmd:
                self.log_cmd = cmd
                return ok(hang_lines)
            if cmd[:1] == ["git"]:
                return ok("abc123\n")
            return tool(cmd) if tool else ok()
        return pr.collect(since, DEVICE, self.products, list(build_logs), REPO, run=run, crash_dir=self.crash_dir)

    def test_collect_ignores_other_device_crash(self):
        report = self.collect()
        crashes = [p for p in report["problems"] if p["kind"] == "crash"]
        self.assertEqual([c["time"][:19] for c in crashes], ["2026-11-12 10:05:00"])
        self.assertEqual(report["commit"], "abc123")

    def test_collect_ignores_crash_before_since(self):
        report = self.collect(since="2026-11-12 10:05:01")
        self.assertEqual(report["problems"], [])

    def test_hang_without_our_frames_is_ignored(self):
        lines = "\n".join([hang_event("hang id=1 duration=1300ms frames=1"),
                           hang_event("hang frame id=1 #0 UIKitCore 0x10 base=0x0 foo")])
        report = self.collect(hang_lines=lines, since="2026-11-12 11:00:00")
        self.assertEqual(report["problems"], [])
        self.assertEqual(report["ignored_hangs"], 1)
        self.assertIn(["--start", "2026-11-12 11:00:00"], [self.log_cmd[i:i + 2] for i in range(len(self.log_cmd))])

    def test_collect_reports_slow_function_with_repo_relative_file(self):
        path = os.path.join(self.products, "build.log")
        with open(path, "w") as f:
            f.write("/Users/tester/PayLab/Modules/HomeFeature/Sources/HistoryModel.swift:12:17: warning: "
                    "instance method 'rows()' took 150ms to type-check (limit: 100ms)\n"
                    "SwiftCompile (3 tasks) | 2.500 seconds\n")
        report = self.collect(since="2026-11-12 11:00:00", build_logs=[path])
        self.assertEqual(report["problems"], [{
            "kind": "slow-function", "name": "instance method 'rows()'", "ms": 150, "line": 12,
            "file": "Modules/HomeFeature/Sources/HistoryModel.swift",
            "files": ["Modules/HomeFeature/Sources/HistoryModel.swift"]}])
        self.assertEqual(report["timing"], {"SwiftCompile": 2.5})

    def add_binary(self, rel):
        path = os.path.join(self.products, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").close()

    def rewrite_crash(self, name, captured, header):
        path = os.path.join(self.crash_dir, name)
        with open(path) as f:
            text = f.read()
        text = text.replace("2026-11-12 10:05:00.1234 +0900", captured).replace("2026-11-12 10:05:00.00 +0900", header)
        with open(path, "w") as f:
            f.write(text)

    def test_collect_compares_crash_time_with_offset(self):
        # 10:05 +0900 == 2026-11-11 17:05 -0800 (같은 순간). 벽시계만 비교하면 since보다 이르다고 오판한다
        self.rewrite_crash("PayLab-2026-11-12-100500.ips", "2026-11-11 17:05:00.1234 -0800",
                           "2026-11-11 17:05:00.00 -0800")
        self.assertEqual([p["kind"] for p in self.collect(since="2026-11-12 10:00:00")["problems"]], ["crash"])
        self.assertEqual(self.collect(since="2026-11-12 10:05:01")["problems"], [])
        self.set_tz("UTC")  # since는 UTC 10:00 = 19:00 +0900. 크래시(10:05 +0900)는 그 전이다
        self.assertEqual(self.collect(since="2026-11-12 10:00:00")["problems"], [])

    def test_hang_with_repo_frame_is_a_problem_with_files_and_context(self):
        self.add_binary("HomeFeature.framework/HomeFeature")
        lines = "\n".join([hang_event("load start", pid=7, category="history"),
                           hang_event("hang id=1 duration=412ms frames=2", pid=7),
                           hang_event("hang frame id=1 #0 HomeFeature 0x1000 base=0x800 f", pid=7),
                           hang_event("hang frame id=1 #1 HomeFeature 0x2000 base=0x800 g", pid=7)])

        def tool(cmd):
            if "atos" in cmd:
                return ok("f() (in HomeFeature) (%s/Modules/HomeFeature/Sources/HistoryModel.swift:42)\n"
                          "g() (in HomeFeature) (/Elsewhere/Other.swift:3)\n" % REPO)
            return ok()
        report = self.collect(hang_lines=lines, since="2026-11-12 11:00:00", tool=tool)
        self.assertEqual(report["ignored_hangs"], 0)
        self.assertEqual(report["warnings"], [])
        problem = report["problems"][0]
        self.assertEqual((problem["kind"], problem["duration_ms"]), ("hang", 412))
        self.assertEqual(problem["files"], ["Modules/HomeFeature/Sources/HistoryModel.swift"])
        self.assertEqual(problem["context"], ["load start"])

    def test_crash_goes_through_symbolize(self):
        self.add_binary("PayLab.app/PayLab.debug.dylib")
        atos_cmds = []

        def tool(cmd):
            if "atos" in cmd:
                atos_cmds.append(cmd)
                return ok("PayLabModel.load() (in PayLab.debug.dylib) (%s/Modules/App/Sources/Model.swift:9)\n" % REPO)
            return ok()
        crash = self.collect(tool=tool)["problems"][0]
        self.assertEqual(crash["files"], ["Modules/App/Sources/Model.swift"])
        self.assertEqual(crash["frames"][1]["function"], "PayLabModel.load()")
        self.assertEqual(atos_cmds[0][-1], hex(4347117568 + 18904 - 1))  # 크래시 프레임 #1은 복귀 주소

    def test_atos_failure_becomes_warning_not_ignored_hang_silence(self):
        self.add_binary("HomeFeature.framework/HomeFeature")
        lines = "\n".join([hang_event("hang id=1 duration=412ms frames=1"),
                           hang_event("hang frame id=1 #0 HomeFeature 0x1000 base=0x800 f")])

        def tool(cmd):
            return types.SimpleNamespace(returncode=1, stdout="", stderr="boom") if "atos" in cmd else ok()
        report = self.collect(hang_lines=lines, since="2026-11-12 11:00:00", tool=tool)
        self.assertEqual(report["problems"], [])
        self.assertTrue(any("atos HomeFeature" in w for w in report["warnings"]), report["warnings"])

    def test_dsymutil_missing_becomes_warning(self):
        self.add_binary("HomeFeature.framework/HomeFeature")
        lines = "\n".join([hang_event("hang id=1 duration=412ms frames=1"),
                           hang_event("hang frame id=1 #0 HomeFeature 0x1000 base=0x800 f")])

        def tool(cmd):
            raise FileNotFoundError("xcrun")
        report = self.collect(hang_lines=lines, since="2026-11-12 11:00:00", tool=tool)
        self.assertTrue(any("dsymutil HomeFeature" in w for w in report["warnings"]), report["warnings"])

    def test_log_show_failure_raises(self):
        def run(cmd, **kw):
            return types.SimpleNamespace(returncode=1, stdout="", stderr="Unable to find device")
        with self.assertRaises(pr.CollectError):
            pr.collect("2026-11-12 10:00:00", DEVICE, self.products, [], REPO, run=run, crash_dir=self.crash_dir)

    def test_missing_products_dir_raises(self):
        with self.assertRaises(pr.CollectError):
            pr.collect("2026-11-12 10:00:00", DEVICE, os.path.join(self.products, "nope"), [], REPO,
                       run=lambda cmd, **kw: ok(), crash_dir=self.crash_dir)

    def test_main_exits_2_and_writes_nothing_on_collect_error(self):
        out = os.path.join(self.products, "report.json")

        def boom(*a, **kw):
            raise pr.CollectError("x")
        original, pr.collect = pr.collect, boom
        self.addCleanup(setattr, pr, "collect", original)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = pr.main(["collect", "--since", "2026-11-12 10:00:00", "--device", DEVICE,
                            "--products", self.products, "--out", out])
        self.assertIn("실패", err.getvalue())
        self.assertEqual(code, 2)
        self.assertFalse(os.path.exists(out))

    def test_unparsable_ips_is_skipped_with_warning(self):
        with open(os.path.join(self.crash_dir, "PayLab-broken.ips"), "w") as f:
            f.write('{"timestamp": "2026-11-12 10:07:00.00 +0900"')  # 쓰다 만 파일
        with open(os.path.join(self.crash_dir, "PayLab-nocrash.ips"), "w") as f:
            f.write('{"timestamp": "2026-11-12 10:07:00.00 +0900"}\n{"procPath": "x"}\n')  # 크래시 아님
        report = self.collect()
        self.assertEqual([p["kind"] for p in report["problems"]], ["crash"])  # 정상 리포트는 살아남는다
        self.assertEqual(len(report["warnings"]), 2)


SRC = "Modules/HomeFeature/Sources/HistoryModel.swift"


def hang_problem(files=(SRC,), line=12, ms=412, fn="HistoryModel.load()"):
    return {"kind": "hang", "duration_ms": ms, "time": "t", "files": list(files), "context": ["load start"],
            "frames": [frame(function="static PayLabApp.$main()", file="Modules/App/Sources/PayLabApp.swift"),
                       frame(function=fn, file=SRC, line=line)]}


def slow_problem(name="instance method 'x()'", line=10, ms=150, file=SRC):
    return {"kind": "slow-function", "name": name, "file": file, "line": line, "ms": ms, "files": [file]}


def crash_problem(files=(SRC,)):
    return {"kind": "crash", "exception": "EXC_BREAKPOINT", "message": "Fatal error: x", "time": "t",
            "files": list(files), "context": [],
            "frames": [frame(function="HistoryModel.load()", file=SRC, line=3)]}


def report_data(*problems, warnings=()):
    return {"version": 1, "commit": "abc1234", "branch": "feature/x", "problems": list(problems),
            "timing": {}, "ignored_hangs": 0, "warnings": list(warnings)}


def metric(seconds, ratio=None):
    return {"swift_compile_s": seconds, "system_modules_s": 10.0, "ratio": ratio}


class FakeGitHub:
    def __init__(self, issues=()):
        self.existing = list(issues)
        self.labels, self.created, self.edited, self.comments = 0, [], [], []

    def ensure_labels(self):
        self.labels += 1

    def issues(self):
        return self.existing

    def create_issue(self, title, body, labels):
        self.created.append((title, body, labels))
        return "https://example.invalid/1"

    def edit_issue_body(self, number, body):
        self.edited.append((number, body))

    def upsert_pr_comment(self, pr, body, only_if_exists=False):
        self.comments.append((pr, body, only_if_exists))
        return True


FOUND = {"where": "로컬", "branch": "feature/x", "commit": "abc1234", "run_url": "", "time": "2026-11-12 10:00:00"}


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.out, True)

    def run_report(self, data, where, changed=(), gh=None, **kw):
        gh = gh if gh is not None else FakeGitHub()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = pr.report(data, where, None if changed is None else set(changed), gh, out_dir=self.out, env={}, **kw)
        return code, buf.getvalue(), gh

    def open_issue(self, problem, number=7, state="OPEN"):
        return {"number": number, "state": state, "title": pr.issue_title(problem),
                "body": pr.issue_body(problem, FOUND)}

    def test_classify_change_when_any_frame_file_changed(self):
        p = {"files": ["a.swift", "b.swift"]}
        self.assertEqual(pr.classify(p, {"b.swift", "z.swift"}), "change")

    def test_classify_existing_when_no_overlap(self):
        self.assertEqual(pr.classify({"files": ["a.swift"]}, {"b.swift"}), "existing")
        self.assertEqual(pr.classify({"files": []}, {"b.swift"}), "existing")

    def test_signature_ignores_line_number(self):
        self.assertEqual(pr.signature(hang_problem(line=12)), pr.signature(hang_problem(line=30)))
        self.assertEqual(pr.signature(hang_problem()), "hang|HistoryModel.load()")
        self.assertEqual(pr.signature(slow_problem(line=1)), pr.signature(slow_problem(line=99)))
        self.assertEqual(pr.signature(crash_problem()), "crash|EXC_BREAKPOINT|HistoryModel.load()")
        self.assertEqual(pr.signature(dict(crash_problem(), frames=[])), "crash|EXC_BREAKPOINT|-")
        self.assertEqual(pr.signature({"kind": "build-time"}), "build-time")

    def test_titles(self):
        self.assertEqual(pr.issue_title(hang_problem()), "[hang] HistoryModel.load() 412ms")
        self.assertEqual(pr.issue_title(crash_problem()), "[crash] EXC_BREAKPOINT HistoryModel.load()")
        self.assertEqual(pr.issue_title(slow_problem()), "[slow-build] HistoryModel.swift instance method 'x()' 150ms")
        self.assertEqual(pr.issue_title({"kind": "build-time", "increase_pct": 35.2, "increase_s": 14.4}),
                         "[slow-build] 우리 코드 컴파일 시간 +35% (+14초)")

    def test_sanitize_removes_machine_info(self):
        udid = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        text = ("/Users/tester/PayLab/Modules/X.swift /Users/tester/Library/Logs /Users/other/secret.txt "
                "/Users/runner/work/PayLab/PayLab/Modules/Y.swift %s me@example.com ghp_%s sk-%s Yuns-Mac" %
                (udid, "a" * 36, "b" * 30))
        with mock.patch.dict(os.environ, {"HOME": "/Users/tester"}), \
                mock.patch.object(pr.socket, "gethostname", lambda: "Yuns-Mac"):
            out = pr.sanitize(text, "/Users/tester/PayLab")
        self.assertEqual(out, "Modules/X.swift ~/Library/Logs ~/secret.txt Modules/Y.swift <UDID> <email> "
                              "<token> <token> <host>")

    def test_local_change_blocks_without_issue(self):
        code, out, gh = self.run_report(report_data(hang_problem()), "local", changed={SRC})
        self.assertEqual(code, 1)
        self.assertEqual(gh.created, [])
        self.assertIn("[이번 변경] [hang] HistoryModel.load() 412ms %s:12" % SRC, out)

    def test_local_existing_creates_issue_with_labels(self):
        code, out, gh = self.run_report(report_data(hang_problem()), "local")
        self.assertEqual(code, 0)
        self.assertEqual(len(gh.created), 1)
        title, body, labels = gh.created[0]
        self.assertEqual(labels, ["perf-auto", "hang"])
        self.assertIn("<!-- perf-signature: hang|HistoryModel.load() -->", body)
        self.assertNotIn("/Users/", body)
        self.assertEqual(gh.labels, 1)

    def test_existing_open_issue_records_occurrence(self):
        gh = FakeGitHub([self.open_issue(hang_problem())])
        code, out, gh = self.run_report(report_data(hang_problem()), "local", gh=gh)
        self.assertEqual(gh.created, [])
        self.assertEqual(len(gh.edited), 1)
        number, body = gh.edited[0]
        self.assertEqual(number, 7)
        self.assertIn("횟수: 2", body)
        self.assertIn("[기존 → 이슈 #7]", out)

    def test_record_occurrence_without_markers_appends_block(self):
        body = pr.record_occurrence("손으로 쓴 본문", FOUND)
        self.assertTrue(body.startswith("손으로 쓴 본문"))
        self.assertIn("<!-- perf-occurrences:start -->", body)
        self.assertIn("횟수: 1", body)
        self.assertEqual(body.count("perf-occurrences:end"), 1)

    def test_record_occurrence_keeps_last_five(self):
        body = pr.issue_body(hang_problem(), FOUND)
        for i in range(6):
            body = pr.record_occurrence(body, dict(FOUND, commit="c%d" % i, time="T%d" % i))
        self.assertIn("횟수: 7", body)
        self.assertIn("마지막 발견: T5", body)
        block = body[body.index("perf-occurrences:start"):]
        self.assertEqual(block.count("\n  - "), 5)
        self.assertIn("c5", block)
        self.assertNotIn("abc1234", block)

    def test_local_closed_only_does_not_create(self):
        gh = FakeGitHub([self.open_issue(hang_problem(), state="CLOSED")])
        code, out, gh = self.run_report(report_data(hang_problem()), "local", gh=gh)
        self.assertEqual((gh.created, gh.edited), ([], []))
        self.assertIn("#7", out)

    def test_ci_closed_only_creates_with_link(self):
        gh = FakeGitHub([self.open_issue(hang_problem(), number=5, state="CLOSED")])
        code, out, gh = self.run_report(report_data(hang_problem()), "main", gh=gh)
        self.assertEqual(len(gh.created), 1)
        self.assertIn("#5", gh.created[0][1])

    def test_local_ignores_existing_slow_function(self):
        code, out, gh = self.run_report(report_data(slow_problem()), "local")
        self.assertEqual((code, gh.created), (0, []))
        self.assertIn("성능 문제 없음", out)

    def test_pr_change_upserts_comment(self):
        code, out, gh = self.run_report(report_data(hang_problem()), "pr", changed={SRC}, pr=12)
        self.assertEqual(code, 0)
        self.assertEqual(gh.created, [])
        self.assertEqual(len(gh.comments), 1)
        number, body, only = gh.comments[0]
        self.assertEqual((number, only), (12, False))
        self.assertIn("<!-- paylab-perf-report -->", body)
        self.assertIn("HistoryModel.load()", body)

    def test_pr_without_problems_only_edits_existing_comment(self):
        code, out, gh = self.run_report(report_data(), "pr", pr=12)
        self.assertEqual(len(gh.comments), 1)
        self.assertTrue(gh.comments[0][2])
        self.assertIn("문제 없음", gh.comments[0][1])
        self.assertIn("성능 문제 없음", out)

    def test_pr_existing_creates_issue(self):
        code, out, gh = self.run_report(report_data(hang_problem()), "pr", changed={"other.swift"}, pr=12)
        self.assertEqual(len(gh.created), 1)
        self.assertTrue(gh.comments[0][2])  # 변경 문제 없음 -> 기존 코멘트만 고침

    def test_main_treats_all_as_existing(self):
        code, out, gh = self.run_report(report_data(hang_problem()), "main", changed={SRC})
        self.assertEqual(len(gh.created), 1)
        self.assertEqual(gh.comments, [])
        self.assertNotIn("[이번 변경]", out)

    def test_duplicate_signatures_merge_into_one_issue(self):
        data = report_data(hang_problem(ms=300), hang_problem(ms=900, line=40))
        code, out, gh = self.run_report(data, "main")
        self.assertEqual(len(gh.created), 1)
        self.assertIn("900ms", gh.created[0][0])

    def test_warnings_are_printed(self):
        code, out, gh = self.run_report(report_data(warnings=["atos 실패"]), "local")
        self.assertIn("경고: atos 실패", out)

    def test_dry_run_never_calls_github(self):
        class Boom:
            def __getattr__(self, name):
                raise AssertionError("gh 호출: " + name)
        code, out, _ = self.run_report(report_data(hang_problem()), "main", gh=Boom(), dry_run=True)
        self.assertEqual(code, 0)
        self.assertIn("dry-run", out)
        self.assertFalse(os.path.exists(os.path.join(self.out, "pending-issues.json")))

    def test_local_gh_failure_does_not_block(self):
        def boom(*a, **kw):
            raise OSError("gh 없음")
        code, out, _ = self.run_report(report_data(hang_problem()), "local", gh=pr.GitHub(run=boom))
        self.assertEqual(code, 0)
        with open(os.path.join(self.out, "pending-issues.json")) as f:
            pending = json.load(f)
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["labels"], ["perf-auto", "hang"])
        self.assertIn("경고", out)

    def test_build_regression_in_pr_is_change(self):
        code, out, gh = self.run_report(report_data(), "pr", pr=3, baseline=[metric(100.0)] * 5, metrics=metric(135.0))
        self.assertIn("[이번 변경] [slow-build] 우리 코드 컴파일 시간 +35% (+35초)", out)
        self.assertEqual(gh.created, [])

    def test_build_regression_thresholds(self):
        base = [metric(100.0)] * 5
        self.assertIsNone(pr.build_regression(metric(150.0), base[:4]))  # 기준 4개
        self.assertIsNone(pr.build_regression(metric(129.0), base))  # +29%
        self.assertIsNone(pr.build_regression(metric(15.0), [metric(10.0)] * 5))  # +50%, +5초
        found = pr.build_regression(metric(131.0), base)  # +31%, +31초
        self.assertEqual(found["kind"], "build-time")
        self.assertEqual(found["files"], [])
        self.assertAlmostEqual(found["increase_pct"], 31.0)
        self.assertAlmostEqual(found["increase_s"], 31.0)
        self.assertIsNotNone(pr.build_regression(metric(42.0), [metric(30.0)] * 5))  # +40%, +12초

    def test_build_regression_uses_ratio_when_all_present(self):
        base = [metric(100.0, 2.0)] * 5
        self.assertIsNone(pr.build_regression(metric(160.0, 1.6), base))  # 초는 +60%지만 ratio는 -20%
        self.assertIsNotNone(pr.build_regression(metric(160.0, 3.0), base))  # ratio +50%, +60초
        self.assertIsNone(pr.build_regression(metric(112.0, None), base))  # ratio 없음 -> 초 +12%

    def test_report_missing_input_exits_zero(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = pr.main(["report", "--input", os.path.join(self.out, "none.json"), "--where", "local",
                            "--no-changes", "--dry-run"])
        self.assertEqual(code, 0)
        self.assertIn("보고서 없음", out.getvalue())

    def test_changed_files_modes(self):
        calls = []

        def fake(cmd, **kw):
            calls.append(cmd[3:])
            return ok({"merge-base": "base1\n", "diff": "a.swift\nb.swift\n", "ls-files": "new.swift\n"}[cmd[3]])
        self.assertEqual(pr.changed_files("/r", "merge-base", run=fake), {"a.swift", "b.swift", "new.swift"})
        self.assertIn(["diff", "--name-only", "base1"], calls)
        calls.clear()
        self.assertEqual(pr.changed_files("/r", "ref", ref="origin/main", run=fake), {"a.swift", "b.swift"})
        self.assertEqual(calls, [["diff", "--name-only", "origin/main", "HEAD"]])
        self.assertEqual(pr.changed_files("/r", "none", run=fake), set())

    def test_changed_files_unknown_raises(self):
        def fail(cmd, **kw):
            return types.SimpleNamespace(returncode=128, stdout="", stderr="bad")
        for mode, ref in (("merge-base", None), ("ref", "HEAD^1")):
            with self.assertRaises(pr.ChangedFilesUnknown):
                pr.changed_files("/r", mode, ref=ref, run=fail)  # origin/main 없음, 없는 ref

        def missing(cmd, **kw):
            raise OSError("git 없음")
        with self.assertRaises(pr.ChangedFilesUnknown):
            pr.changed_files("/r", "merge-base", run=missing)

    def test_unknown_changed_set_treats_all_as_change(self):
        code, out, gh = self.run_report(report_data(hang_problem(), slow_problem()), "local", changed=None)
        self.assertEqual(code, 1)
        self.assertEqual(gh.created, [])
        self.assertIn("경고: 변경 파일을 알 수 없어 모든 문제를 이번 변경으로 봅니다", out)
        self.assertEqual(out.count("[이번 변경]"), 2)

    def test_unknown_changed_set_in_pr_comments_without_issue(self):
        code, out, gh = self.run_report(report_data(hang_problem()), "pr", changed=None, pr=4)
        self.assertEqual((gh.created, len(gh.comments), code), ([], 1, 0))

    def test_unknown_changed_set_does_not_affect_main(self):
        code, out, gh = self.run_report(report_data(hang_problem()), "main", changed=None)
        self.assertEqual(len(gh.created), 1)
        self.assertNotIn("[이번 변경]", out)

    def test_pr_without_changed_from_is_usage_error(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
            pr.main(["report", "--input", "x.json", "--where", "pr", "--pr", "1"])
        self.assertEqual(cm.exception.code, 2)

    def test_record_occurrence_end_marker_deleted(self):
        body = pr.issue_body(hang_problem(), FOUND).replace(pr.OCC_END, "")
        body = pr.record_occurrence(body, dict(FOUND, time="T2"))
        self.assertEqual((body.count(pr.OCC_START), body.count(pr.OCC_END)), (1, 1))
        self.assertIn("횟수: 2", body)
        again = pr.record_occurrence(body, dict(FOUND, time="T3"))  # 다음 실행이 사이 내용을 지우지 않는다
        self.assertIn("횟수: 3", again)
        self.assertIn("## 우리 코드 스택", again)

    def test_record_occurrence_start_marker_deleted(self):
        body = pr.issue_body(hang_problem(), FOUND).replace(pr.OCC_START, "")
        body = pr.record_occurrence(body, FOUND)
        self.assertEqual((body.count(pr.OCC_START), body.count(pr.OCC_END)), (1, 1))
        self.assertIn("횟수: 2", body)
        self.assertIn("## 우리 코드 스택", body)

    def test_record_occurrence_ignores_and_keeps_human_lines(self):
        body = pr.issue_body(hang_problem(), FOUND).replace(
            pr.OCC_END, "  - 메모: 재현 안 됨\n사람이 쓴 줄\n" + pr.OCC_END)
        body = pr.record_occurrence(body, dict(FOUND, commit="c2"))
        self.assertIn("횟수: 2", body)
        block = body[body.index(pr.OCC_START):]
        self.assertEqual(block.count("\n  - 로컬"), 2)  # 사람이 쓴 "  - 메모"는 발생으로 세지 않는다
        self.assertIn("  - 메모: 재현 안 됨", block)
        self.assertIn("사람이 쓴 줄", block)

    def test_report_text_never_contains_machine_info(self):
        udid = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        secret = ["/Users/bob/Secret", udid, "me@example.com", "Yuns-Mac"]
        p = hang_problem(fn="load(/Users/bob/Secret %s me@example.com Yuns-Mac)" % udid)
        p["context"] = ["log /Users/bob/Secret %s me@example.com Yuns-Mac" % udid]
        p["message"] = "x"
        data = dict(report_data(p, crash_problem()), branch="fix/me@example.com")
        data["problems"][1]["message"] = "Yuns-Mac /Users/bob/Secret"

        def check(text):
            for item in secret:
                self.assertNotIn(item, text)
        with mock.patch.dict(os.environ, {"HOME": "/Users/bob"}), \
                mock.patch.object(pr.socket, "gethostname", lambda: "Yuns-Mac"):
            sig = pr.sanitize(pr.signature(p), REPO)
            clean_issue = {"number": 3, "state": "OPEN", "title": "t",
                           "body": pr.sanitize(pr.issue_body(p, FOUND), REPO)}
            self.assertIn(sig, clean_issue["body"])
            _, out, gh = self.run_report(data, "main")
            check(out)
            for title, body, _ in gh.created:
                check(title), check(body)
            self.assertEqual(len(gh.created), 2)
            _, out, gh = self.run_report(data, "main", gh=FakeGitHub([clean_issue]))
            self.assertEqual(len(gh.edited), 1)  # 열린 이슈 하나는 고치고, 크래시는 새로 만든다
            check(gh.edited[0][1])
            for title, body, _ in gh.created:
                check(title), check(body)
            code, out, gh = self.run_report(data, "pr", changed={SRC}, pr=9)
            check(out)
            check(gh.comments[0][1])
            self.assertIn("[이번 변경]", out)

    def test_at_sign_in_function_name_is_defused(self):
        fn = "closure #1 @Sendable () -> () in X.y()"
        p = hang_problem(fn=fn)
        self.assertNotIn("@", pr.issue_title(p))
        self.assertIn("＠Sendable", pr.issue_title(p))
        self.assertIn("`%s`" % fn, pr.issue_body(p, FOUND))
        code, out, gh = self.run_report(report_data(p, slow_problem(name="closure @MainActor")), "pr", changed={SRC}, pr=1)
        self.assertNotIn("@", gh.comments[0][1].replace("<!--", "").replace("-->", ""))
        self.assertIn("`closure @MainActor", pr.issue_body(slow_problem(name="closure @MainActor"), FOUND))

    def test_created_issue_line_has_number(self):
        code, out, gh = self.run_report(report_data(hang_problem()), "main")
        self.assertIn("[기존 → 이슈 #1] [hang] HistoryModel.load() 412ms", out)


class CiMetricsTests(unittest.TestCase):
    # 설계 §1 실측: 빌드 단계 376초, 첫 출력까지 263초
    JOBS = {"jobs": [{"id": 77, "name": "other", "steps": []},
                     {"id": 99, "name": "build-and-test", "steps": [
                         {"name": "프로젝트 생성", "started_at": "2026-11-11T06:15:51Z", "completed_at": "2026-11-11T06:16:02Z"},
                         {"name": "빌드", "started_at": "2026-11-11T06:17:24Z", "completed_at": "2026-11-11T06:23:40Z"}]}]}
    LOG = ("2026-11-11T06:00:10.1000000Z Command line invocation: tuist\n"  # 빌드 단계 전 줄은 무시
           "2026-11-11T06:17:26.7524350Z ##[group]Run set -o pipefail\n"  # 실제 로그(run 42971182297)를 줄인 것
           "2026-11-11T06:17:40.2309320Z shell: /bin/bash -e {0}\n"
           "2026-11-11T06:17:40.2312690Z ##[endgroup]\n"
           "2026-11-11T06:22:03.4665390Z Command line invocation:\n"
           "2026-11-11T06:23:30.0000000Z Command line invocation:\n")
    REPORT = {"commit": "abc1234", "timing": {"SwiftCompile": 23.0, "SwiftExplicitDependencyGeneratePcm": 6.0,
                                               "SwiftExplicitDependencyCompileModuleFromInterface": 2.0, "Ld": 1.0}}

    def fake_run(self, jobs=None, log=None):
        def fake(cmd, **kw):
            if cmd[-1].endswith("/jobs"):
                return ok(json.dumps(self.JOBS if jobs is None else jobs))
            return ok(self.LOG if log is None else log)
        return fake

    def test_ci_metrics_from_jobs_and_log(self):
        m = pr.ci_metrics(self.REPORT, "5", "o/r", run=self.fake_run())
        self.assertEqual(m["build_step_s"], 376)
        self.assertEqual(m["xcodebuild_start_s"], 263)
        self.assertEqual(m["swift_compile_s"], 23.0)
        self.assertEqual(m["system_modules_s"], 8.0)
        self.assertAlmostEqual(m["ratio"], 23.0 / 8.0)
        self.assertEqual(m["commit"], "abc1234")

    def test_ci_metrics_zero_system_modules_ratio_null(self):
        m = pr.ci_metrics({"commit": "c", "timing": {"SwiftCompile": 5.0}}, "5", "o/r", run=self.fake_run())
        self.assertEqual(m["system_modules_s"], 0.0)
        self.assertIsNone(m["ratio"])
        self.assertEqual(m["swift_compile_s"], 5.0)

    def test_ci_metrics_without_report_or_gh(self):
        def failing(cmd, **kw):
            return types.SimpleNamespace(returncode=1, stdout="", stderr="auth")
        m = pr.ci_metrics(None, "5", "o/r", run=failing)
        self.assertIsNone(m["swift_compile_s"])
        self.assertIsNone(m["build_step_s"])
        self.assertIsNone(m["xcodebuild_start_s"])

    def test_ci_metrics_cli_writes_file(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "m", "build-metrics.json")
            with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "o/r"}), \
                    mock.patch.object(pr.subprocess, "run", self.fake_run()):
                code = pr.main(["ci-metrics", "--report", os.path.join(d, "none.json"), "--run-id", "5", "--out", out])
            self.assertEqual(code, 0)
            with open(out) as f:
                data = json.load(f)
            self.assertIsNone(data["swift_compile_s"])
            self.assertEqual(data["build_step_s"], 376)

    def test_build_regression_ignores_null_compile_time(self):
        base = [metric(100.0)] * 5
        self.assertIsNone(pr.build_regression({"swift_compile_s": None, "ratio": None}, base))
        self.assertIsNone(pr.build_regression({"ratio": None}, base))
        bad = [metric(None), {"ratio": None}]
        self.assertIsNone(pr.build_regression(metric(150.0), base[:4] + bad))  # 유효한 기준 4개
        self.assertIsNotNone(pr.build_regression(metric(150.0), base + bad))  # 유효 5개, 무효는 건너뜀


class GitHubTests(unittest.TestCase):
    def test_upsert_pr_comment_edits_marked_comment(self):
        calls = []

        def fake(cmd, **kw):
            calls.append(cmd)
            if "PATCH" not in cmd:
                return ok(json.dumps([{"id": 1, "body": "other"}, {"id": 9, "body": "x <!-- paylab-perf-report -->"}]))
            return ok()
        self.assertTrue(pr.GitHub(run=fake).upsert_pr_comment(3, "new <!-- paylab-perf-report -->"))
        self.assertIn("PATCH", calls[-1])
        self.assertTrue(any("comments/9" in part for part in calls[-1]))

    def test_upsert_pr_comment_only_if_exists_skips_when_missing(self):
        calls = []

        def fake(cmd, **kw):
            calls.append(cmd)
            return ok("[]")
        self.assertFalse(pr.GitHub(run=fake).upsert_pr_comment(3, "x", only_if_exists=True))
        self.assertEqual(len(calls), 1)

    def test_nonzero_exit_raises(self):
        def fake(cmd, **kw):
            return types.SimpleNamespace(returncode=1, stdout="", stderr="auth")
        with self.assertRaises(pr.GitHubError):
            pr.GitHub(run=fake).issues()


if __name__ == "__main__":
    unittest.main()
