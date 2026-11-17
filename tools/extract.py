"""extract.py PACK OUTDIR [name-regex] : extracts entries; nested .str2_pc are expanded too."""
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srvpp import Pack
def dump(data, out, rx):
    pk = Pack(data)
    for name, blob, us in pk.read_all():
        if rx and not re.search(rx, name, re.I): continue
        os.makedirs(out, exist_ok=True)
        if name.lower().endswith('.str2_pc'):
            dump(blob, os.path.join(out, name[:-8]), None)
        else:
            open(os.path.join(out, name), 'wb').write(blob)
dump(open(sys.argv[1],'rb').read(), sys.argv[2], sys.argv[3] if len(sys.argv)>3 else None)
