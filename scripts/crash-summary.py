#!/usr/bin/env python3
"""시뮬레이터 크래시 리포트(.ips) 요약: 예외, 종료 이유, 앱 메시지, 크래시 스레드 프레임.
사용: python3 scripts/crash-summary.py [리포트 경로]   # 생략하면 가장 최근 PayLab 리포트"""
import glob, json, os, sys

path = sys.argv[1] if len(sys.argv) > 1 else max(
    glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/PayLab-*.ips")), key=os.path.getmtime)
raw = open(path).read()
body = json.loads(raw[raw.index("\n") + 1:])  # 첫 줄은 헤더 JSON
images = body.get("usedImages", [])
thread = body["threads"][body["faultingThread"]]

print("report:", path)
print("time:", body.get("captureTime"))
print("exception:", body.get("exception"))
print("termination:", body.get("termination", {}).get("indicator"))
for key, lines in (body.get("asi") or {}).items():  # 앱 메시지: Swift fatal error, Main Thread Checker 등
    print(f"message[{key}]:", *lines, sep="\n  ")
print(f"faulting thread {body['faultingThread']} queue={thread.get('queue')}:")
for i, f in enumerate(thread["frames"][:25]):
    image = images[f["imageIndex"]].get("name", "?") if f.get("imageIndex", -1) < len(images) else "?"
    print(f"  {i:2} {image:28} {f.get('symbol', hex(f.get('imageOffset', 0)))}"
          + (f" + {f['symbolLocation']}" if "symbolLocation" in f else "")
          + (f"  ({os.path.basename(f['sourceFile'])}:{f.get('sourceLine')})" if "sourceFile" in f else ""))
