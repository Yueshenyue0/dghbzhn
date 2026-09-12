#!/usr/bin/env python3
"""提交前校验：Dart 括号平衡（剥离注释/字符串）+ YAML 合法性 + SO 语法"""
import glob
import subprocess
import sys

import yaml


def strip_code(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                i += 1
            i += 2
            continue
        if c in '\'"':
            q = c
            triple = src[i:i + 3] == q * 3
            ln = 3 if triple else 1
            i += ln
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                hit = (src[i:i + 3] == q * 3) if triple else (src[i] == q)
                if hit:
                    i += ln
                    break
                i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)


bad = 0
for f in sorted(glob.glob('lib/**/*.dart', recursive=True)):
    code = strip_code(open(f, encoding='utf-8').read())
    delta = (
        code.count('{') - code.count('}'),
        code.count('(') - code.count(')'),
        code.count('[') - code.count(']'),
    )
    if any(delta):
        print('BAD', f, delta)
        bad += 1
    else:
        print('ok  ', f)
if bad:
    print('!! Dart 括号不平衡')
    sys.exit(1)
print('Dart balance OK')

for y in ['pubspec.yaml', '.github/workflows/build.yml']:
    yaml.safe_load(open(y, encoding='utf-8'))
print('YAML OK')

r = subprocess.run(
    ['g++', '-std=c++11', '-fsyntax-only', 'lib/native/verify.cpp'],
    capture_output=True, text=True)
if r.returncode != 0:
    print('!! C++ 语法错误')
    print(r.stderr[:1200])
    sys.exit(1)
print('C++ OK')

# 确认更新 URL 指向新仓库
nb = open('lib/native_bridge.dart', encoding='utf-8').read()
assert 'dghbzhn/releases/tags/Can' in nb, 'api url 未更新'
assert 'dghbzhn/releases/tag/Can' in nb, 'page url 未更新'
assert 'tempmail/releases' not in nb, 'dart 侧仍有旧仓库名'
cpp = open('lib/native/verify.cpp', encoding='utf-8').read()
assert 'dghb' in cpp and 'zhn/' in cpp, 'SO 侧仓库名未更新'
assert 'temp' not in cpp.split('update_api_url')[1][:600], 'SO update_api_url 仍含旧名'
print('URL 指向 dghbzhn OK')

# 确认包名未被误改（JNI 符号用下划线形式）
assert 'Java_com_eri_tempmail_MainActivity' in cpp, '包名/签名 JNI 符号丢失'
print('包名 com.eri.tempmail 保留 OK')
print('\nALL CHECKS PASSED')
