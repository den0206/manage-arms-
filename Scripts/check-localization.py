"""Sources の日本語リテラルが Localizable.strings で引けることを検査する。

**キー集合の ja/en 一致だけでは足りない。** 「両方に無い」文言は素通りするため、
`WriteGuard.Denial` などの Core 層のエラー文は、どちらにも登録されないまま
英語 UI に日本語で出ていた。ここが見るのは「UI に届く文言が実際に翻訳されるか」。

突き合わせは、補間と書式指定子を同じ伏せ字に潰してから行う。
  Swift  : "\\(name) は保護対象です"   → "␀ は保護対象です"
  strings: "%@ は保護対象です"          → "␀ は保護対象です"

`Text("…")` のようにコンパイラが `LocalizedStringKey` として引くものも、
`String(localized:)` で明示するものも、必要なキーは同じなので同じ検査で足りる。
翻訳対象でない日本語リテラルには、その行に `// not-localized: 理由` を付ける。
"""
import glob
import re
import sys

HOLE = "␀"
JAPANESE = re.compile(r"[぀-ヿ㐀-䶿一-鿿]")
# `%@` は 1 文字で完結する。`[@a-zA-Z]+` にすると `%@@latest` の `@latest` まで飲む。
SPECIFIER = re.compile(r"%(?:\d+\$)?(?:@|[a-zA-Z]+)")   # %@ / %lld / %1$@ / %2$lld
OPT_OUT = "// not-localized:"
STRINGS = "Localization/ja.lproj/Localizable.strings"


def literals(line: str) -> list[str]:
    """1 行に現れる文字列リテラルを、補間を伏せ字にして返す。

    Swift の補間 `\\(…)` の中には**文字列リテラルが入れ子になる**
    （`joined(separator: "、")` など）。素朴な正規表現だとそこで literal が切れて
    偽陽性になるので、括弧と引用符の対応を追いながら読む。
    """
    found: list[str] = []
    # stack: ("code", paren_depth) / ("string", buffer)
    stack: list = [["code", 0]]
    index = 0
    while index < len(line):
        char = line[index]
        top = stack[-1]
        if top[0] == "string":
            if char == "\\" and line[index + 1 : index + 2] == "(":
                top[1].append(HOLE)
                stack.append(["code", 0])
                index += 2
                continue
            if char == "\\":                      # \" \\ \n などをまとめて飛ばす
                index += 2
                continue
            if char == '"':
                found.append("".join(top[1]))
                stack.pop()
                index += 1
                continue
            top[1].append(char)
            index += 1
            continue
        # code
        if char == '"':
            stack.append(["string", []])
        elif char == "(":
            top[1] += 1
        elif char == ")":
            if top[1] == 0 and len(stack) > 1:
                stack.pop()                       # 補間の終わり。文字列へ戻る
            else:
                top[1] -= 1
        elif char == "/" and line[index + 1 : index + 2] == "/" and len(stack) == 1:
            break                                 # 行コメント（文字列の外だけ）
        index += 1
    return found


def strings_keys() -> set[str]:
    text = re.sub(r"/\*.*?\*/", "", open(STRINGS, encoding="utf-8").read(), flags=re.S)
    raw = re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*=', text, re.M)
    return {SPECIFIER.sub(HOLE, key) for key in raw}


def main() -> int:
    keys = strings_keys()
    missing: list[str] = []
    for path in sorted(glob.glob("Sources/**/*.swift", recursive=True)):
        in_block = in_multiline = False
        for number, line in enumerate(open(path, encoding="utf-8"), 1):
            if in_block:
                in_block = "*/" not in line
                continue
            if line.lstrip().startswith("/*"):
                in_block = "*/" not in line
                continue
            if '"""' in line:                     # 複数行リテラル（実測ではシェル片のみ）
                in_multiline = not in_multiline
                continue
            if in_multiline or OPT_OUT in line:
                continue
            for value in literals(line):
                if JAPANESE.search(value) and value not in keys:
                    missing.append(f"  {path}:{number}: {value}")
    if missing:
        print("\n".join(missing))
        return 1
    return 0


sys.exit(main())
