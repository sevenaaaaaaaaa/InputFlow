# 英文词表来源与许可

`words.txt`：20,000 词，按词频降序。

| 来源 | 说明 | 许可 |
|---|---|---|
| [hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords) `content/2018/en/en_50k.txt` | OpenSubtitles 语料词频（取前 2 万） | MIT |
| 原 `words.txt`（本项目） | 人工校准的高频词，权重 ×30 优先 | AGPL-3.0-only |

## 重新生成

```bash
curl -sSLO https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt
python3 - <<'PY'
import re
curated = {}
with open('crates/en/data/words.txt') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'): continue
        parts = line.split('\t')
        w = parts[0].lower()
        try: weight = int(parts[1]) if len(parts) > 1 else 1
        except ValueError: weight = 1
        curated[w] = max(curated.get(w, 0), weight*30)
merged = dict(curated)
with open('en_50k.txt') as f:
    for line in f:
        parts = line.split()
        if len(parts) != 2: continue
        w, c = parts[0].lower(), int(parts[1])
        if not re.fullmatch(r"[a-z][a-z'\-]*", w): continue
        if len(w) == 1 and w not in ('a', 'i'): continue
        merged[w] = max(merged.get(w, 0), c)
ordered = sorted(merged.items(), key=lambda kv: (-kv[1], kv[0]))[:20000]
with open('crates/en/data/words.txt', 'w') as out:
    out.write("# 英文词表：hermitdave/FrequencyWords (MIT, 2018 en_50k) + InputFlow 人工校准词（×30 优先）\n")
    out.write("# 格式：词<TAB>权重（相对序即可）；由 crates/en/data/SOURCES.md 中的脚本生成\n")
    for w, c in ordered:
        out.write(f"{w}\t{c}\n")
PY
```
