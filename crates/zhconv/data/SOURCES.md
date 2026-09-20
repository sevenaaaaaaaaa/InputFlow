# 简繁词表来源

| 文件 | 来源 | 许可 |
|---|---|---|
| `STCharacters.txt` | [OpenCC](https://github.com/BYVoid/OpenCC) `data/dictionary/STCharacters.txt` | Apache-2.0（`LICENSE-opencc.txt`） |
| `STPhrases.txt` | [OpenCC](https://github.com/BYVoid/OpenCC) `data/dictionary/STPhrases.txt` | Apache-2.0（`LICENSE-opencc.txt`） |

## 口径

- 只内置**简 → 繁**方向（`s2t`）。输入法的候选天然是简体，「繁」开关只需要单向转换。
- 一个简体字对应多个繁体字时，取词表里的**第一个**值；靠词组表做最长匹配消歧
  （`头发` → `頭髮` 而不是 `頭發`）。
- OpenCC 词表含恒等映射（供其分词用），解析时丢弃；超过 8 个字的条目（谚语、整句）
  也丢弃：对输入法候选没有意义，还会拖慢匹配。
- 未做地区词转换（`s2tw` / `s2hk` 的「鼠标 → 滑鼠」一类）。那是用词习惯而非字形，
  需要用户显式选地区，留给后续版本。

## 更新流程

```bash
curl -L -o STCharacters.txt https://raw.githubusercontent.com/BYVoid/OpenCC/master/data/dictionary/STCharacters.txt
curl -L -o STPhrases.txt   https://raw.githubusercontent.com/BYVoid/OpenCC/master/data/dictionary/STPhrases.txt
cargo test -p inputflow-zhconv
```
