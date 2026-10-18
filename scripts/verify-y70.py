#!/usr/bin/env python3
"""Static acceptance for ordinary, versioned modules. Never loads a module."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

RELEASE='6.12.58-android16-6-gb0a9599c6c01-ab14987696-4k'

def config(path):
    values={}
    for line in path.read_text().splitlines():
        if line.startswith('CONFIG_') and '=' in line:
            k,v=line.split('=',1)
            values[k]=v
        elif line.startswith('# CONFIG_') and line.endswith(' is not set'):
            values[line[2:-11]]='n'
    return values

def check_config(actual, reference):
    expected=config(reference/'kernel_aarch64_dot_config')
    got=config(actual)
    # Host utility version probes can differ without changing the kernel ABI.
    permitted={'CONFIG_PAHOLE_VERSION'}
    changes=[dict(key=k,expected=expected.get(k),actual=got.get(k)) for k in sorted(set(expected)|set(got)) if expected.get(k)!=got.get(k)]
    forbidden=[c for c in changes if c['key'] not in permitted]
    return dict(status='PASS' if not forbidden else 'FAIL',changes=changes,forbidden_changes=forbidden)

class ELF:
    def __init__(self,path):
        self.data=path.read_bytes()
        d=self.data
        assert d[:7]==b'\x7fELF\x02\x01\x01','Expected ELF64 little endian'
        h=struct.unpack_from('<16sHHIQQQIHHHHHH',d)
        assert h[1]==1 and h[2]==183,'Expected AArch64 ET_REL'
        assert h[11]==64 and h[12]>0
        self.sections=[]
        for i in range(h[12]):
            v=struct.unpack_from('<IIQQQQIIQQ',d,h[6]+i*64)
            s=dict(zip(('name_off','type','flags','address','offset','size','link','info','align','entsize'),v))
            if s['type']!=8:
                assert s['offset']+s['size']<=len(d)
            self.sections.append(s)
        names=self.bytes(self.sections[h[13]])
        for s in self.sections:
            s['name']=self.string(names,s['name_off'])
        self.byname={s['name']:s for s in self.sections}
        self.modinfo={}
        for part in self.section('.modinfo').split(b'\0'):
            if b'=' in part:
                k,v=part.decode().split('=',1)
                self.modinfo.setdefault(k,[]).append(v)
        self.imports=[]
        self.exports=[]
        for s in self.sections:
            if s['type']!=2:
                continue
            assert s['entsize']==24 and s['size']%24==0
            strings=self.bytes(self.sections[s['link']])
            for off in range(s['offset'],s['offset']+s['size'],24):
                no,info,other,ndx,value,size=struct.unpack_from('<IBBHQQ',d,off)
                name=self.string(strings,no)
                if ndx==0 and name:
                    self.imports.append(dict(name=name,binding=info>>4))
                if name.startswith('__ksymtab_'):
                    self.exports.append(name[len('__ksymtab_'):])
        self.basic={}
        raw=self.section('__versions')
        assert len(raw)%64==0
        for off in range(0,len(raw),64):
            crc,=struct.unpack_from('<Q',raw,off)
            self.basic[self.string(raw,off+8)]=crc
        self.extended={}
        names=self.section('__version_ext_names')
        crcs=self.section('__version_ext_crcs')
        assert bool(names)==bool(crcs),'Incomplete extended modversions'
        if names:
            names=names.rstrip(b'\0').split(b'\0')
            assert len(crcs)==4*len(names),'Extended version count mismatch'
            self.extended={n.decode():struct.unpack_from('<I',crcs,i*4)[0] for i,n in enumerate(names)}
        for n in set(self.basic)&set(self.extended):
            assert self.basic[n]==self.extended[n],f'Conflicting CRC formats: {n}'
        self.versions=self.extended or self.basic
    @staticmethod
    def string(raw,off):
        end=raw.find(b'\0',off)
        assert end>=off
        return raw[off:end].decode()
    def bytes(self,s):
        assert not s['flags']&0x800,'Unexpected compressed metadata'
        return self.data[s['offset']:s['offset']+s['size']]
    def section(self,name):
        return self.bytes(self.byname[name]) if name in self.byname else b''

def verify_module(path,exports,allowed):
    e=ELF(path)
    assert e.modinfo.get('vermagic')==[RELEASE+' SMP preempt mod_unload modversions aarch64'],e.modinfo.get('vermagic')
    assert e.modinfo.get('license')==['GPL']
    assert e.versions,'Module has no import CRCs'
    assert e.versions.get('module_layout')==exports['module_layout']['crc'],'module_layout CRC mismatch or missing'
    assert e.byname['.gnu.linkonce.this_module']['size']==1600,'Unexpected struct module size'
    namespaces=set(e.modinfo.get('import_ns',[]))
    comparisons=[]
    for imp in e.imports:
        name=imp['name']
        assert name in exports,f'Target does not export {name}'
        assert name in allowed,f'Unsigned module may not import {name}'
        target=exports[name]
        assert target['provider']=='vmlinux',f'Unexpected dependency provider: {name}'
        assert not target['namespace'] or target['namespace'] in namespaces,f'Missing namespace for {name}'
        assert e.versions.get(name)==target['crc'],f'Missing or mismatched CRC: {name}'
        comparisons.append(dict(symbol=name,crc=f"0x{target['crc']:08x}",status='MATCH'))
    assert all(name not in exports for name in e.exports),'Export collides with target'
    return dict(file=path.name,status='PASS',sha256=hashlib.sha256(e.data).hexdigest(),size=len(e.data),
        vermagic=e.modinfo['vermagic'][0],imports=len(e.imports),basic_versions=len(e.basic),extended_versions=len(e.extended),
        module_layout_crc=f"0x{e.versions['module_layout']:08x}",exports=e.exports,depends=e.modinfo.get('depends'),crc_comparisons=comparisons,
        signature_present=e.data.endswith(b'~Module signature appended~\n'))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--modules',type=Path)
    p.add_argument('--reference',type=Path,required=True)
    p.add_argument('--check-config',type=Path)
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    if args.check_config:
        result=check_config(args.check_config,args.reference)
    else:
        assert args.modules
        exports={}
        for line in (args.reference/'kernel_aarch64_Module.symvers').read_text().splitlines():
            fields=line.split()
            crc,name,provider,kind=fields[:4]
            exports[name]=dict(crc=int(crc,16),provider=provider,kind=kind,namespace=fields[4] if len(fields)>4 else '')
        allowed=set((args.reference/'abi_symbollist.raw').read_text().splitlines())
        assert {p.name for p in args.modules.glob('*.ko')}=={'droid_lkm.ko'},'Only the Y70 main module is permitted'
        modules=[verify_module(args.modules/name,exports,allowed) for name in ('droid_lkm.ko',)]
        test_binary=(args.modules/'droidspaces-check').read_bytes()
        h=struct.unpack_from('<16sHHIQQQIHHHHHH',test_binary)
        assert test_binary[:7]==b'\x7fELF\x02\x01\x01' and h[2]==183 and h[1] in (2,3)
        assert h[9]==56
        assert all(struct.unpack_from('<I',test_binary,h[5]+i*h[9])[0]!=3 for i in range(h[10])),'Test binary is not static'
        result=dict(status='PASS',target_release=RELEASE,build_id=14987696,modules=modules,
            userspace_test=dict(name='droidspaces-check',architecture='AArch64',static_link=True,size=len(test_binary),sha256=hashlib.sha256(test_binary).hexdigest()),
            runtime_validation='NOT PERFORMED; static verification is not a device usability guarantee')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
    return 0 if result['status']=='PASS' else 1

if __name__=='__main__':
    sys.exit(main())
