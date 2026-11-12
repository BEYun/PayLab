#!/usr/bin/env python3
"""perf-report.py 테스트. 사용: python3 -I scripts/test_perf_report.py"""
import importlib.util
import json
import os
import shutil
import tempfile
import types
import unittest

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
    def setUp(self):
        self.crash_dir = tempfile.mkdtemp()
        self.products = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.crash_dir)
        self.addCleanup(shutil.rmtree, self.products)
        shutil.copy(os.path.join(FIX, "crash.ips"), os.path.join(self.crash_dir, "PayLab-2026-11-12-100500.ips"))
        shutil.copy(os.path.join(FIX, "crash-other-device.ips"),
                    os.path.join(self.crash_dir, "PayLab-2026-11-12-100600.ips"))

    def collect(self, hang_lines="", since="2026-11-12 10:00:00", build_logs=()):
        def run(cmd, **kw):
            if "log" in cmd and "show" in cmd:
                self.log_cmd = cmd
                return ok(hang_lines)
            if cmd[:1] == ["git"]:
                return ok("abc123\n")
            return ok()
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


if __name__ == "__main__":
    unittest.main()
