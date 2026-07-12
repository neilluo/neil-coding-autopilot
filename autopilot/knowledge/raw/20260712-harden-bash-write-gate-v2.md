---
created: 2026-07-12
source: evolve/harden-bash-write-gate-v2
evidence: primary
---

# Bash 写码门扩展：覆盖 sed -i / 解释器内联写（非重定向旁路）

承接 `20260712-harden-bash-write-gate.md`（该文把 `python -c open` / `sed -i`
列为残留）。本轮把它们也纳入 `guard-bash-write.sh`，仍严格 fail-open：

## 新增探测向量（layer 3）
- (a) 重定向再补 `>|`（clobber）、`&>`（both）。
- (b) 就地编辑：`sed -i` / `sed -i.bak` / `perl -pi -e` / `ruby -i` → 抽取命令中
  源码扩展名文件 token。判据正则允许 `-i<suffix>` 形式（`-i.bak` 曾漏判，已修）。
- (c) 解释器内联写：`open('<src>', 'w'|'a'|'x')`、`writeFileSync/appendFileSync('<src>')`
  → 抽取被写源码路径。**只认写模式**：`open('x.py')`（只读）不拦。

## 误报护栏（已在 smoke 固化为 ALLOW 用例）
`grep -i`、`sed -n`（无 -i）、`python -c "open('config.py').read()"`（只读）、
`sed -i` 改 `.md`、git/verify/`>/tmp/*.log`/`>/dev/null`/`>output.txt` 全部放行。

## 验证
- `smoke-bash-guard.sh` 扩到 **25 例全过**（含新 DENY：sed -i / perl -pi /
  python open(w) / node writeFileSync / `>|`；含新 ALLOW 误报护栏）。
- 真机 qodercli：控制器被要求用 `python3 -c "open('src/App.py','w')…"` 写源码
  → **blocked**（narration：hook blocks shell-based writes）。

## 残留（更小，文档标注）
- 极端混淆写法仍可能绕过：base64 解码后管道写、`printf`拼到变量再 eval、
  非上述扩展名的源文件（如无扩展名的可执行脚本）。失败方向仍偏 fail-open。
- 跳阶段 / 分支纪律仍为 md 软约束（无运行时门）。

## Lesson
- in-place 编辑器的 `-i` 常带后缀（`-i.bak`/BSD `-i ''`）——正则必须容忍后缀，
  否则漏判；用 smoke 的 `sed -i.bak` 用例守住这个回归。
