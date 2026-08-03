#!/bin/bash
# SeaLead Dashboard JS Syntax Validator
# Run: bash validate.sh [html_file]

HTML="${1:-index.html}"

echo "=== JS Syntax Check: $HTML ==="

# Extract <script> content
python3 -c "
import re
with open('$HTML','r') as f:
    html = f.read()
m = re.search(r'<script[^>]*>(.*?)</script>', html, re.DOTALL)
if not m:
    print('ERROR: No <script> tag found')
    exit(1)
with open('/tmp/sealead_validate_tmp.js','w') as f:
    f.write(m.group(1))
"

# Syntax check
RESULT=$(/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc /tmp/sealead_validate_tmp.js 2>&1)
if echo "$RESULT" | grep -q "SyntaxError"; then
    echo "FAIL: $RESULT"
    rm -f /tmp/sealead_validate_tmp.js
    exit 1
elif echo "$RESULT" | grep -q "ReferenceError.*document"; then
    echo "PASS: JS syntax OK (document ref expected in non-browser env)"
else
    echo "PASS: $RESULT"
fi

# ASCII quote check
echo "=== ASCII Quote Scan ==="
python3 -c "
import re
with open('$HTML','r') as f:
    content = f.read()
pattern = re.compile(r'([\u4e00-\u9fff\u3000-\u303f\uff00-\uffef])\x22([\u4e00-\u9fff\u2018-\u201c])')
matches = list(pattern.finditer(content))
if matches:
    print(f'FAIL: {len(matches)} ASCII quotes found inside CJK context:')
    for m in matches:
        line_num = content[:m.start()].count('\n') + 1
        snippet = content[max(0,m.start()-5):m.end()+5].replace('\n',' ')
        print(f'  Line {line_num}: ...{snippet}...')
    exit(1)
else:
    print('PASS: No ASCII quote issues')
"

rm -f /tmp/sealead_validate_tmp.js
echo "=== Validation Complete ==="
