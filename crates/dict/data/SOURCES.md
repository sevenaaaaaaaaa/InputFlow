# 词典数据来源与许可

## `base-large.tsv`（随包分发的主词库，20 万词条）

由以下来源合并、按全局同一尺度归一化并剪枝生成（单音节条目全量保留）：

| 来源 | 说明 | 许可 |
|---|---|---|
| [rime-ice / cn_dicts/8105.dict.yaml](https://github.com/iDvel/rime-ice) | 通用规范汉字表（单字 + 权重） | GPL-3.0-only |
| rime-ice / cn_dicts/base.dict.yaml | 常用词库 | GPL-3.0-only |
| rime-ice / cn_dicts/ext.dict.yaml | 扩展词汇 | GPL-3.0-only |
| rime-ice / cn_dicts/41448.dict.yaml | GB2312 生僻字 | GPL-3.0-only |
| rime-ice / cn_dicts/others.dict.yaml | 补充词条 | GPL-3.0-only |
| `data/base.tsv`（本项目） | 人工校准的常用词/短句频次，×100 权重优先 | AGPL-3.0-only |

rime-ice 的许可证全文见 `LICENSE-rime-ice.txt`（GPL-3.0-only）。本项目按 AGPL-3.0-only
分发，与 GPL-3.0 的兼容性见 AGPL-3.0 第 13 条；词库数据本身仍为 GPL-3.0-only。

## 重新生成

```bash
# 1. 下载 rime-ice 词库（任选镜像）
RI=https://raw.githubusercontent.com/iDvel/rime-ice/main/cn_dicts
mkdir -p /tmp/rime-ice && cd /tmp/rime-ice
for f in 8105 base ext 41448 others; do curl -sSLO "$RI/$f.dict.yaml"; done

# 2. 合并（×100 的人工校准词表保证首屏常用词优先）
cd <repo>
cargo run --release -p xtask -- dict import-rime-multi \
    -o /tmp/base-large.ifd --tsv crates/dict/data/base-large.tsv --max-entries 200000 \
    /tmp/rime-ice/8105.dict.yaml:1 \
    /tmp/rime-ice/base.dict.yaml:1 \
    /tmp/rime-ice/ext.dict.yaml:1 \
    /tmp/rime-ice/41448.dict.yaml:10000 \
    /tmp/rime-ice/others.dict.yaml:10000 \
    crates/dict/data/base.tsv:100

# 3. 校验
cargo run --release -p inputflow-pinyin --example dump -- /tmp/base-large.ifd
```

## `base.tsv`（内置兜底词库）

本项目人工维护的 367 条高频词/短语，供 `cargo test`、无外部词典的兜底场景使用，
并在大词典生成时作为高优先权重来源参与合并。
