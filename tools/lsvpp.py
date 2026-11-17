import sys, mmap
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srvpp import Pack
for p in sys.argv[1:]:
    with open(p,'rb') as f:
        d = f.read(4*1024*1024)  # index lives at the front
    pk = Pack(d)
    print("##", p, "flags", hex(pk.flags), "count", pk.count)
    for n, doff, us, cs in pk.entries():
        print(n, us)
