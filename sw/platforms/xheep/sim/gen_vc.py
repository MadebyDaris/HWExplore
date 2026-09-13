#!/usr/bin/env python3
import sys, os

vc_file = sys.argv[1]
out_file = sys.argv[2]
base_dir = os.path.dirname(vc_file)
exclude_files = ['testharness.sv', 'testharness_pkg.sv', 'tb_top.cpp', 'ext_bus.sv']

with open(vc_file, 'r') as f_in, open(out_file, 'w') as f_out:
    for line in f_in:
        line = line.strip()
        if line.startswith('--top-module') or line.startswith('--exe') or line.startswith('--Mdir') or line.startswith('--cc') or line.startswith('-G'):
            continue
        if any(ex in line for ex in exclude_files):
            continue
        
        if line.startswith('+incdir+'):
            path = line.replace('+incdir+', '')
            f_out.write(f"+incdir+{os.path.abspath(os.path.join(base_dir, path))}\n")
        elif line.startswith('-CFLAGS '):
            parts = line.split(' ', 1)
            if parts[1].startswith('-I'):
                path = parts[1][2:]
                f_out.write(f"-CFLAGS -I{os.path.abspath(os.path.join(base_dir, path))}\n")
            else:
                f_out.write(line + "\n")
        elif line.startswith('-'):
            f_out.write(line + "\n")
        else:
            # it's a file path
            f_out.write(f"{os.path.abspath(os.path.join(base_dir, line))}\n")
