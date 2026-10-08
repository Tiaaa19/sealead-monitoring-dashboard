#!/bin/bash
# SeaLead Dashboard 校验器（升级版）
#
# 四个关卡：
#   1) JS 语法检查：提取页面内“全部”内联 <script> 块，逐个用 jsc 做语法检查
#      （旧版只检查第一个 script 块）
#   2) ASCII 引号扫描：CJK 上下文中误用半角引号（曾导致字符串截断）
#   3) 数据完整性静态校验：所有 *KeyEvents 事件数组的必备字段（date / title / tags）
#      与 tags 元素结构（t / l），防止脏数据再次进入页面
#   4) 整页加载冒烟校验：DOM 打桩后由 jsc 真实执行页面脚本，断言
#      「页面脚本无整页中断 + 各板块时间线渲染条数 == 数据条数 + 链接收集模块可交互」
#      —— 旧版只做“语法 + 函数级仿真”，无法发现“整页时序中断”类缺陷（本次线上事故根因）
#
# 用法: bash validate.sh [html_file]     默认 index.html
# 退出码: 0 = 全部通过；1 = 存在失败项

set -u
HTML="${1:-index.html}"
[ -f "$HTML" ] || { echo "FAIL: 找不到文件 $HTML"; exit 1; }

JSC="/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc"
[ -x "$JSC" ] || { echo "FAIL: 未找到 jsc（$JSC）"; exit 1; }

python3 - "$HTML" "$JSC" <<'PY'
import json, os, re, subprocess, sys, tempfile

HTML, JSC = sys.argv[1], sys.argv[2]
html = open(HTML, encoding="utf-8").read()
fails = []

def head(t): print("\n=== %s ===" % t)

# ---------------------------------------------------------------- 1) 语法检查
head("1. JS Syntax Check（全部内联 script 块）: %s" % HTML)
scripts = re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", html, re.DOTALL)
if not scripts:
    print("FAIL: 未找到任何内联 <script> 块")
    fails.append("syntax")
else:
    print("  发现 %d 个内联 script 块" % len(scripts))
tmpdir = tempfile.mkdtemp(prefix="sealead_validate_")
for i, s in enumerate(scripts, 1):
    p = os.path.join(tmpdir, "script_%d.js" % i)
    open(p, "w", encoding="utf-8").write(s)
    r = subprocess.run([JSC, p], capture_output=True, text=True)
    out = r.stdout + r.stderr
    if "SyntaxError" in out:
        print("FAIL: script #%d 语法错误" % i)
        print("      " + out.strip().split("\n")[0])
        fails.append("syntax#%d" % i)
    else:
        print("PASS: script #%d 语法 OK（非浏览器环境下的 document/ReferenceError 属预期）" % i)

# ------------------------------------------------------------- 2) 引号扫描
head("2. ASCII Quote Scan（CJK 上下文半角引号）")
pattern = re.compile(r'([\u4e00-\u9fff\u3000-\u303f\uff00-\uffef])\x22([\u4e00-\u9fff\u2018-\u201c])')
matches = list(pattern.finditer(html))
if matches:
    print("FAIL: 发现 %d 处 CJK 上下文中的半角引号：" % len(matches))
    for m in matches[:20]:
        ln = html[:m.start()].count("\n") + 1
        print("      Line %d: ...%s..." % (ln, html[max(0, m.start() - 5):m.end() + 5].replace("\n", " ")))
    fails.append("quotes")
else:
    print("PASS: 未发现 ASCII 引号问题")

# --------------------------------------------------- 3) KeyEvents 数据完整性
head("3. 数据完整性静态校验（*KeyEvents 必备字段）")

def split_top_items(text, start):
    """字符串感知的括号配对：返回 [start] 处的数组元素文本列表与结束索引"""
    i, depth, items, cur = start, 0, [], None
    quote, esc = None, False
    while i < len(text):
        c = text[i]
        if quote:
            if esc: esc = False
            elif c == "\\": esc = True
            elif c == quote: quote = None
            i += 1; continue
        if c in "\"'`":
            quote = c; i += 1; continue
        if c == "[": depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                if cur is not None: items.append(text[cur:i])
                return items, i
        elif c == "{":
            if depth == 1 and cur is None: cur = i
        elif c == "}":
            if depth == 1 and cur is not None:
                items.append(text[cur:i + 1]); cur = None
        i += 1
    raise ValueError("括号不配对")

arrays = {}
for m in re.finditer(r"^const (\w*[Kk]eyEvents)\s*=\s*\[", html, re.M):
    name = m.group(1)
    br = html.index("[", m.start())
    items, _ = split_top_items(html, br)
    arrays[name] = items
if not arrays:
    print("FAIL: 未找到任何 *KeyEvents 事件数组")
    fails.append("keyevents-missing")
total_bad = 0
for name, items in arrays.items():
    bad = []
    for it in items:
        miss = [f for f in ("date", "title", "tags")
                if not re.search(r'(?<![A-Za-z_])"?%s"?\s*:' % f, it)]
        d = re.search(r'(?<![A-Za-z_])"?date"?\s*:\s*"([^"]*)"', it)
        if d and not re.match(r"^\d{2}-\d{2}$", d.group(1)):
            miss.append("date格式(%s)" % d.group(1))
        for tag in re.findall(r"\{[^{}]*\}", it if "tags" in it else ""):
            if re.search(r'(?<![A-Za-z_])t\s*:', tag) and not re.search(r'(?<![A-Za-z_])l\s*:', tag):
                miss.append("tag缺l")
        if miss:
            pos = html.index(it)
            bad.append((html[:pos].count("\n") + 1, miss, it[:40].replace("\n", " ")))
    if bad:
        total_bad += len(bad)
        print("FAIL: %s 存在 %d 条字段缺失（共 %d 条）" % (name, len(bad), len(items)))
        for ln, miss, snip in bad[:10]:
            print("      L%d 缺 %s :: %s" % (ln, miss, snip))
        fails.append("data-%s" % name)
    else:
        print("PASS: %s 共 %d 条，date/title/tags 齐备" % (name, len(items)))

# --------------------------------------------------------- 4) 整页加载冒烟
head("4. 整页加载冒烟校验（DOM 打桩 + jsc）")

HARNESS = r"""
// ===== DOM 打桩（仅校验用，不改变被测页面代码）=====
var __root = (typeof globalThis !== 'undefined') ? globalThis : this;
var __els = {};
function __mkEl(id) {
  return {
    id: id || '', innerHTML: '', outerHTML: '', textContent: '', value: '', className: '', style: {},
    classList: { add: function(){}, remove: function(){}, toggle: function(){}, contains: function(){ return false; } },
    dataset: {}, children: [], options: [],
    appendChild: function(c){ return c; }, removeChild: function(c){ return c; }, insertBefore: function(a){ return a; },
    querySelector: function(){ return null; }, querySelectorAll: function(){ return []; },
    setAttribute: function(){}, getAttribute: function(){ return null; }, removeAttribute: function(){},
    addEventListener: function(){}, removeEventListener: function(){},
    focus: function(){}, select: function(){}, click: function(){}, scrollIntoView: function(){},
    remove: function(){}, cloneNode: function(){ return __mkEl(id); },
    getBoundingClientRect: function(){ return { top:0, left:0, width:0, height:0 }; }
  };
}
__root.document = {
  getElementById: function(id){ if (!__els[id]) __els[id] = __mkEl(id); return __els[id]; },
  querySelector: function(){ return null; },
  querySelectorAll: function(){ return []; },
  createElement: function(t){ return __mkEl('created'); },
  addEventListener: function(){}, removeEventListener: function(){},
  body: __mkEl('body'), documentElement: __mkEl('html'), head: __mkEl('head'),
  execCommand: function(){ return true; }
};
__root.window = __root;
__root.localStorage = (function(){ var s = {}; return {
  getItem: function(k){ return Object.prototype.hasOwnProperty.call(s, k) ? s[k] : null; },
  setItem: function(k, v){ s[k] = String(v); },
  removeItem: function(k){ delete s[k]; }, clear: function(){ s = {}; } }; })();
__root.navigator = { userAgent: 'smoke', clipboard: { writeText: function(){ return { then: function(ok){ ok(); } }; } } };
__root.addEventListener = function(){};
__root.scrollTo = function(){};
__root.setTimeout = function(){ return 0; };
__root.setInterval = function(){ return 0; };
var __pass = 0, __fail = 0;
function __count(str, needle){ var n = 0, i = 0; str = String(str || ''); while ((i = str.indexOf(needle, i)) !== -1) { n++; i += needle.length; } return n; }
function __chk(name, cond, extra) {
  if (cond) { __pass++; print('  [PASS] ' + name + (extra ? '  (' + extra + ')' : '')); }
  else { __fail++; print('  [FAIL] ' + name + (extra ? '  (' + extra + ')' : '')); }
}
// 每个 <script> 块独立执行（贴近浏览器语义：一个块的未捕获异常不应阻断其它块）
var __scriptErrors = [];
function __runScript(label, src) {
  try {
    (0, eval)(src);
    print('  [PASS] ' + label + ' 执行完毕，无未捕获异常');
  } catch (e) {
    var msg = (e && e.message) ? e.message : String(e);
    __scriptErrors.push(label + ': ' + msg);
    print('  [FAIL] ' + label + ' 抛出未捕获异常：' + msg);
  }
}
var __EXPECT = __EXPECT_PLACEHOLDER__;
print('STAGE_0_HARNESS_OK');
"""

TAIL = r"""
// ===== 断言区（页面全部脚本块执行完毕后）=====
function __rows(id){ return __count(__els[id] ? __els[id].innerHTML : '', 'class="event-row"'); }
function __chkRows(label, id, nonEmptyOnly) {
  var exp = (__EXPECT[id] === undefined) ? null : __EXPECT[id];
  var got = __rows(id);
  if (exp === null) { __chk(label, nonEmptyOnly ? got > 0 : true, '未解析到数据条数，实渲染 ' + got + ' 行'); return; }
  __chk(label, nonEmptyOnly ? (got === exp && got > 0) : got === exp, got + ' / ' + exp);
}
__chkRows('汇总页时间线行数 == keyEvents 条数', 'eventsTimeline', false);
__chkRows('SeaLead 页时间线行数 == sealeadKeyEvents 条数', 'sealeadEventsTimeline', false);
__chkRows('红海页时间线行数 == redseaKeyEvents 条数（防截断）', 'redseaEventsTimeline', false);
__chkRows('CUL Klang 页时间线行数 == culklangKeyEvents 条数 且非空', 'culklangEventsTimeline', true);
__chk('红海日卡片已渲染', __count(__els['redseaDailyGrid'].innerHTML, 'class="daily-card ') > 0, __count(__els['redseaDailyGrid'].innerHTML, 'class="daily-card ') + ' 张');
__chk('顶部指标区已渲染', String(__els['metricRed'].textContent).length > 0, '红=' + __els['metricRed'].textContent);
__chk('链接收集：分类 datalist 非空（模块已初始化）', __count(__els['linkCategoryList'].innerHTML, '<option') > 0, __count(__els['linkCategoryList'].innerHTML, '<option') + ' 项');
__chk('链接收集：分组区已渲染', String(__els['linkGroups'].innerHTML).length > 0);
document.getElementById('linkCategory').value = '冒烟测试分类';
addCustomCategory();
__chk('链接收集：新增自定义分类生效', __els['linkCategoryList'].innerHTML.indexOf('冒烟测试分类') !== -1 && String(__els['linkFormMsg'].textContent).length > 0, String(__els['linkFormMsg'].textContent));
document.getElementById('linkInput').value = 'https://example.com/smoke-test';
addCollectedLinks();
__chk('链接收集：添加链接生效（条目出现 + 输入框清空）', __els['linkGroups'].innerHTML.indexOf('example.com/smoke-test') !== -1 && __els['linkInput'].value === '', String(__els['linkFormMsg'].textContent));
__chk('链接收集：已写入本地暂存', __root.localStorage.getItem('sealead_dash_user_links_v1') !== null);
print('SMOKE_' + ((__fail === 0 && __scriptErrors.length === 0) ? 'OK' : 'FAIL') + ' pass=' + __pass + ' fail=' + __fail + ' scriptErrors=' + __scriptErrors.length);
"""

expect = {tid: len(arrays[n]) for n, tid in (
    ("keyEvents", "eventsTimeline"), ("sealeadKeyEvents", "sealeadEventsTimeline"),
    ("redseaKeyEvents", "redseaEventsTimeline"), ("culklangKeyEvents", "culklangEventsTimeline")) if n in arrays}
combined = HARNESS.replace("__EXPECT_PLACEHOLDER__", json.dumps(expect)) + "\n" + "\n".join(
    "__runScript('页面内联脚本 #%d', %s);" % (i + 1, json.dumps(s, ensure_ascii=True))
    for i, s in enumerate(scripts)
) + "\n" + TAIL

smoke_path = os.path.join(tmpdir, "smoke.js")
open(smoke_path, "w", encoding="utf-8").write(combined)
r = subprocess.run([JSC, smoke_path], capture_output=True, text=True)
out = r.stdout + r.stderr
for l in out.split("\n"):
    if l.strip().startswith(("[PASS]", "[FAIL]")) and "执行完毕" not in l and "抛出未捕获异常" not in l:
        print(l)
for l in out.split("\n"):
    if l.strip().startswith(("[PASS]", "[FAIL]")) and ("执行完毕" in l or "抛出未捕获异常" in l):
        print(l)
errs = [l for l in out.split("\n") if "抛出未捕获异常" in l]
if errs:
    print("FAIL: 存在未捕获异常（整页加载时序中断风险）：")
    for l in errs[:5]:
        print("     " + l.strip())
    fails.append("script-error")
if "STAGE_0_HARNESS_OK" not in out:
    print("FAIL: 冒烟测试环境未就绪：%s" % out.strip().split("\n")[0])
    fails.append("smoke-env")
if "SMOKE_OK" not in out:
    print("FAIL: 冒烟断言未全部通过")
    fails.append("smoke-assert")
else:
    verdict = re.search(r"SMOKE_OK pass=(\d+)", out)
    print("PASS: 整页冒烟通过（%s 项断言）" % (verdict.group(1) if verdict else "?"))

print("\n=== 校验结论 ===")
if fails:
    print("FAIL: 共 %d 项不通过 -> %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("ALL PASS: 语法 / 引号 / 数据完整性 / 整页冒烟 全部通过")
PY
