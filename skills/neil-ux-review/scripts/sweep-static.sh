#!/usr/bin/env bash
# sweep-static.sh — neil-ux-review P1 静态反模式扫描（引擎自适应：rg 优先，回退 grep）
#
# 用法：bash sweep-static.sh <前端源码目录，默认 src>
# 输出：可读清单 + 命中计数。命中不等于必错，是"待人工/运行时确认"的候选点。
# 对应规则：A11Y-03/11/12、DT-01、CS-01、PF-03、SF-13。
set -uo pipefail

SRC="${1:-src}"
[ -d "$SRC" ] || { echo "目录不存在: $SRC" >&2; exit 1; }

# 引擎自适应：优先 ripgrep，缺失时回退到系统 grep（BSD/GNU 均可）。
# 用 [[:space:]] 而非 \s、不用 \b，以兼容 BSD grep 的 POSIX ERE。
if command -v rg >/dev/null 2>&1; then ENGINE=rg; else ENGINE=grep; fi
INC=(--include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
     --include='*.css' --include='*.less' --include='*.scss')

search() { # <regex> <exclude-tests:0/1> <exclude-theme:0/1>
  local re="$1" excl="${2:-0}" xth="${3:-0}"
  # 数组恒含基础 flags + 末尾 -e/SRC，永不为空 —— 规避 bash 3.2 下 set -u 对空数组
  # 展开 "${a[@]}" 报 unbound（会被 2>/dev/null 吞成静默假阴性）。
  local a
  if [ "$ENGINE" = rg ]; then
    a=(-n --color=never)
    [ "$excl" = 1 ] && a+=(-g '!*.test.*')
    [ "$xth" = 1 ] && a+=(-g '!**/theme/**')
    a+=(-e "$re" "$SRC")
    rg "${a[@]}" 2>/dev/null
  else
    a=(-rEn "${INC[@]}")
    [ "$excl" = 1 ] && a+=(--exclude='*.test.*')
    [ "$xth" = 1 ] && a+=(--exclude-dir='theme')
    a+=(-e "$re" "$SRC")
    grep "${a[@]}" 2>/dev/null
  fi
}

hits=0
scan() { # <标题> <规则id> <regex> <exclude-tests:0/1> <exclude-theme:0/1>
  local title="$1" rule="$2" re="$3" excl="${4:-0}" xth="${5:-0}"
  local out; out="$(search "$re" "$excl" "$xth")"
  local c=0; [ -n "$out" ] && c="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  printf '\n== [%s] %s (%s 命中) ==\n' "$rule" "$title" "$c"
  [ -n "$out" ] && printf '%s\n' "$out"
  hits=$((hits + c))
}

echo "neil-ux-review 静态反模式扫描 @ ${SRC} （引擎：${ENGINE}）"

scan "裸 outline:none（焦点环丢失）"      "A11Y-03" 'outline:[[:space:]]*none|outline-none' 0 0
scan "div/span 带 onClick（非语义交互）"   "A11Y-12" '<(div|span)[^>]*onClick' 0 0
scan "正值 tabIndex（打乱焦点序）"          "A11Y-04" 'tabIndex=\{?[1-9]' 0 0
scan "缺数变 0 的嫌疑（?? 0 / || 0）"      "DT-01"   '\?\?[[:space:]]*0|\|\|[[:space:]]*0' 0 0
scan "硬编码色值（应走 token，已排除 theme/ 定义）" "CS-01" '#[0-9a-fA-F]{3,8}' 0 1
scan "transition: all（性能/动画反模式）"  "PF-03"   'transition:[[:space:]]*all' 0 0
scan "省略号 ...（应为 …，已排 spread）"   "SF-13"   '\.\.\.['\''"]' 1 0
scan "icon 按钮疑似无 aria-label"          "A11Y-11" 'icon=\{<[A-Z][A-Za-z]+Outlined' 0 0

echo ""
echo "---------------------------------------------"
echo "总命中 $hits 处（候选点，需 P2 运行时 / 人工确认）。"
echo "注意：命中≠必错；未命中≠合格（对比度/键盘/缺数渲染需运行时验证）。"
exit 0
