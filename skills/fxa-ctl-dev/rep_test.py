#!/usr/bin/env python3
"""Check rep.py: JSON pairs, block mode, and that a miss writes nothing. Run: python3 rep_test.py"""
import os
import subprocess
import sys
import tempfile

REP = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'rep.py')


def run(args, stdin):
    return subprocess.run([sys.executable, REP, *args], input=stdin, capture_output=True, text=True)


with tempfile.TemporaryDirectory() as d:
    a, b = os.path.join(d, 'a.py'), os.path.join(d, 'b.py')
    open(a, 'w').write('x = "one"\ny = 2\n')
    open(b, 'w').write("def f():\n    return 'q'\n")
    assert run([a], '[["y = 2", "y = 3"]]').returncode == 0 and open(a).read() == 'x = "one"\ny = 3\n'
    blocks = f'<<<< {a}\nx = "one"\n====\nx = "two"\n>>>>\n<<<< {b}\ndef f():\n    return \'q\'\n====\ndef f():\n    return "r"\n>>>>\n'
    assert run(['--blocks'], blocks).returncode == 0, 'block mode writes both files'
    assert open(a).read() == 'x = "two"\ny = 3\n' and open(b).read() == 'def f():\n    return "r"\n'
    miss = f'<<<< {a}\nx = "two"\n====\nx = "3"\n>>>>\n<<<< {b}\nnot there\n====\nz\n>>>>\n'
    r = run(['--blocks'], miss)
    assert r.returncode != 0 and open(a).read() == 'x = "two"\ny = 3\n', 'a miss in any block writes nothing'
print('rep_test: ok')
