#!/usr/bin/env python3

from pathlib import Path
from datetime import datetime
import shutil
import re

p = Path("inji-deploy.sh")
s = p.read_text()

marker = "INJI_DEDICATED_CONFIG_STAGE"

if marker in s:
    print("Already patched")
    raise SystemExit(0)

# Restrict modifications to the deploy() function.
match = re.search(
    r'(?m)^deploy\(\)\{\s*$([\s\S]*?)(?=^status\(\)\{)',
    s
)

if not match:
    raise SystemExit("ERROR: deploy() function not found")

section = match.group(0)

# Match the existing ConfigMap synchronization call,
# independently of its indentation.
anchor = re.search(
    r'(?m)^([ \t]*)sync_certify_configmaps[ \t]*$',
    section
)

if not anchor:
    raise SystemExit(
        "ERROR: sync_certify_configmaps call not found in deploy()"
    )

indent = anchor.group(1)

addition = (
    f'{indent}# INJI_DEDICATED_CONFIG_STAGE\n'
    f'{indent}log "Deploying dedicated Inji Config Server"\n'
    f'{indent}APPLY=YES NS_CERTIFY="$NS_CERTIFY" \\\n'
    f'{indent}  "$ROOT/scripts/deploy-inji-config-server.sh"\n'
    f'{indent}log "Validating mock-identity configuration"\n'
    f'{indent}NS_CERTIFY="$NS_CERTIFY" \\\n'
    f'{indent}  "$ROOT/scripts/check-inji-config.sh"\n'
)

updated_section = (
    section[:anchor.start()]
    + addition
    + section[anchor.start():]
)

updated = (
    s[:match.start()]
    + updated_section
    + s[match.end():]
)

backup = p.with_name(
    p.name + ".backup." +
    datetime.now().strftime("%Y%m%d-%H%M%S")
)

shutil.copy2(p, backup)
p.write_text(updated)

print("SUCCESS: Dedicated Config Server stage integrated")
print("Backup:", backup)
