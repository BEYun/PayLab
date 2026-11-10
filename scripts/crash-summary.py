#!/usr/bin/env python3
"""시뮬레이터 크래시 리포트(.ips) 요약: 예외, 종료 이유, 앱 메시지, 크래시 스레드 프레임.
사용: python3 scripts/crash-summary.py [--device <시뮬레이터 UDID>] [리포트 경로]
      경로를 생략하면 가장 최근 PayLab 리포트. --device를 주면 그 시뮬레이터의 리포트만 고른다
      (병렬 세션의 다른 시뮬레이터 PayLab 리포트도 같은 폴더에 쌓인다)."""
import glob, json, os, re, sys


def load(path):
    raw = open(path).read()
    return json.loads(raw[raw.index("\n") + 1:])  # 첫 줄은 헤더 JSON


args = sys.argv[1:]
device = None
if "--device" in args:
    i = args.index("--device")
    device = args[i + 1]
    del args[i:i + 2]

if args:
    path = args[0]
else:
    candidates = sorted(glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/PayLab-*.ips")),
                        key=os.path.getmtime, reverse=True)
    path = next((p for p in candidates if device is None or device in load(p).get("procPath", "")), None)
    if path is None:
        sys.exit("PayLab 크래시 리포트 없음" + (f" (device {device})" if device else ""))

body = load(path)
images = body.get("usedImages", [])
thread = body["threads"][body["faultingThread"]]
udid = re.search(r"Devices/([0-9A-F-]{36})/", body.get("procPath", ""))

print("report:", path)
print("device:", udid.group(1) if udid else "?")
print("time:", body.get("captureTime"), " pid:", body.get("pid"))
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
