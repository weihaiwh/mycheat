#!/usr/bin/env python3
import plistlib
import os

# Convert WHWB.plist to binary format
plist_path = "/var/jb/usr/lib/TweakInject/WHWB.plist"
with open(plist_path, "rb") as f:
    d = plistlib.load(f)
with open(plist_path, "wb") as f:
    plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)

# Verify
with open(plist_path, "rb") as f:
    header = f.read(8)
if header.startswith(b"bplist00"):
    with open("/var/mobile/Documents/plist_convert_result.txt", "w") as out:
        out.write("SUCCESS: Converted to binary plist\n")
        out.write("Content: " + str(d) + "\n")
else:
    with open("/var/mobile/Documents/plist_convert_result.txt", "w") as out:
        out.write("FAILED: Header is " + str(header) + "\n")

# Also get game bundle ID
game_plist = "/var/containers/Bundle/Application/55B6A508-933C-4772-8D3E-E8F84C092D02/JianYingJiangHu.app/Info.plist"
if os.path.exists(game_plist):
    with open(game_plist, "rb") as f:
        gd = plistlib.load(f)
    with open("/var/mobile/Documents/plist_convert_result.txt", "a") as out:
        out.write("Game Bundle ID: " + str(gd.get("CFBundleIdentifier", "NOT FOUND")) + "\n")
        out.write("Game Executable: " + str(gd.get("CFBundleExecutable", "NOT FOUND")) + "\n")
