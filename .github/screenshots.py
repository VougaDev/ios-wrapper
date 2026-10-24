"""Names the screenshots `xcresulttool export attachments` wrote: <out>/<device>/<attachment name>.png."""
import json
import re
import shutil
import sys
from pathlib import Path

exported, out = Path(sys.argv[1]), Path(sys.argv[2])
for test in json.loads((exported / "manifest.json").read_text()):
    for item in test.get("attachments", []):
        # "01-signin_0_7C3B…-….png": the attachment's name, its index and a UUID
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(?=\.\w+$)", "", item["suggestedHumanReadableName"])
        folder = out / item.get("deviceName", "device").replace(" ", "-")
        folder.mkdir(parents=True, exist_ok=True)
        shutil.copy(exported / item["exportedFileName"], folder / name)
        print(folder / name)
