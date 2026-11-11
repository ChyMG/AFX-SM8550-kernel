#!/usr/bin/env python3
import sys
from elftools.elf.elffile import ELFFile
from elftools.elf.relocation import RelocationSection

def read_exports(path):
    with open(path, 'rb') as f:
        elf = ELFFile(f)
        secs = list(elf.iter_sections())
        idx = {s.name: i for i, s in enumerate(secs)}
        ssec = elf.get_section_by_name('__ksymtab_strings')
        sdata = ssec.data() if ssec else b''
        out = []
        for tab_name, crc_name, typ in (
            ('__ksymtab', '__kcrctab', 'EXPORT_SYMBOL'),
            ('__ksymtab_gpl', '__kcrctab_gpl', 'EXPORT_SYMBOL_GPL'),
        ):
            if tab_name not in idx or crc_name not in idx:
                continue
            tab_i, crc_i = idx[tab_name], idx[crc_name]
            names = {}
            crcs = {}
            for sec in secs:
                if not isinstance(sec, RelocationSection):
                    continue
                target = sec['sh_info']
                if target not in (tab_i, crc_i):
                    continue
                symtab = elf.get_section(sec['sh_link'])
                for rel in sec.iter_relocations():
                    off = rel['r_offset']
                    sym = symtab.get_symbol(rel['r_info_sym'])
                    if target == tab_i:
                        if off % 12 != 4:
                            continue
                        eidx = off // 12
                        stroff = rel['r_addend']
                        if 0 <= stroff < len(sdata):
                            end = sdata.find(b'\0', stroff)
                            if end > stroff:
                                names[eidx] = sdata[stroff:end].decode('utf-8', 'replace')
                    else:
                        eidx = off // 4
                        crcs[eidx] = (sym['st_value'] + rel['r_addend']) & 0xffffffff
            for eidx in sorted(set(names) & set(crcs)):
                out.append((names[eidx], crcs[eidx], typ))
        return out

if __name__ == '__main__':
    for path in sys.argv[1:]:
        exports = read_exports(path)
        print(f'# {path}: {len(exports)} exports', file=sys.stderr)
        for name, crc, typ in exports:
            print(f'0x{crc:08x}\t{name}\t{path.split("/")[-1][:-3]}\t{typ}\t')
