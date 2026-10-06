import ctypes as C, datetime, hashlib, json, os, platform, subprocess, time
from pathlib import Path
assert platform.machine() == 'aarch64'
class Attr(C.Structure):
    _fields_=[('size',C.c_uint32),('policy',C.c_uint32),('flags',C.c_uint64),('nice',C.c_int32),('priority',C.c_uint32),('runtime',C.c_uint64),('deadline',C.c_uint64),('period',C.c_uint64),('util_min',C.c_uint32),('util_max',C.c_uint32)]
libc=C.CDLL(None,use_errno=True)
def read(p):
    try:return Path(p).read_text().strip()
    except (OSError,UnicodeError):return None
def link(p):
    try:return os.readlink(p)
    except OSError:return None
def stat(p):
    raw=read(p)
    if raw is None:return None
    a=raw.index('(');b=raw.rindex(')');f=raw[b+1:].split()
    return dict(comm=raw[a+1:b],state=f[0],ppid=int(f[1]),pgrp=int(f[2]),session=int(f[3]),utime=int(f[11]),stime=int(f[12]),nice=int(f[16]),num_threads=int(f[17]),starttime=int(f[19]),last_cpu=int(f[36]))
def status(p):
    s=read(p) or ''
    return {k:v.strip() for k,v in (l.split(':',1) for l in s.splitlines() if ':' in l) if k in ['Uid','Gid','Tgid','Pid','PPid','NSpid','Cpus_allowed_list','Mems_allowed_list','Threads']}
def task(pid,tid):
    p=Path(f'/proc/{pid}/task/{tid}');s=stat(p/'stat')
    if s is None:return None
    s.update(tid=tid,status=status(p/'status'),wchan=read(p/'wchan'),cgroup=read(p/'cgroup'),schedstat=read(p/'schedstat'),children=read(p/'children'))
    a=Attr();a.size=C.sizeof(a)
    if libc.syscall(275,tid,C.byref(a),C.sizeof(a),0)==0:s['attr']={n:getattr(a,n) for n,_ in a._fields_}
    else:s['attr_error']=C.get_errno()
    try:s['affinity']=sorted(os.sched_getaffinity(tid))
    except OSError:pass
    return s
def snapshot(pid):
    allp={}
    for p in Path('/proc').iterdir():
        if not p.name.isdigit():continue
        s=stat(p/'stat')
        if s is None:continue
        s.update(pid=int(p.name),exe=link(p/'exe'),cgroup=read(p/'cgroup'),status=status(p/'status'))
        allp[s['pid']]=s
    selected={pid};changed=True
    while changed:
        added={p for p,s in allp.items() if s['ppid'] in selected}-selected
        selected|=added;changed=bool(added)
    base=allp[pid]
    peers={p for p,s in allp.items() if p not in selected and (s['session']==base['session'] or (s['cgroup'] is not None and s['cgroup']==base['cgroup']))}
    for p in selected|peers:
        s=allp.get(p)
        if s is None:continue
        try: tids=sorted(int(t.name) for t in Path(f'/proc/{p}/task').iterdir())
        except OSError:continue
        s['threads']=[row for t in tids if (row:=task(p,t)) is not None]
        s['relation']='denial' if p==pid else 'descendant' if p in selected else 'session_or_cgroup_peer'
    return dict(time_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),denial_pid=pid,descendants=sorted(selected-{pid}),peers=sorted(peers),processes=[allp[p] for p in sorted(selected|peers) if p in allp],process_index=[{k:s[k] for k in ['pid','ppid','pgrp','session','starttime','comm','exe','cgroup','num_threads']} for s in allp.values() if s['exe']])
pid=int(subprocess.check_output(['systemctl','show','denial-moto70.service','-p','MainPID','--value']))
assert pid>0 and Path(f'/proc/{pid}/comm').read_text().strip()=='deniald'
boot=read('/proc/sys/kernel/random/boot_id')
first=snapshot(pid)
time.sleep(3)
second=snapshot(pid)
assert read('/proc/sys/kernel/random/boot_id')==boot
assert first['processes'][[p['pid'] for p in first['processes']].index(pid)]['starttime']==second['processes'][[p['pid'] for p in second['processes']].index(pid)]['starttime']
cpus={p.name:{'capacity':read(p/'cpu_capacity'),'online':read(p/'online'),'cluster_id':read(p/'topology/cluster_id'),'core_id':read(p/'topology/core_id')} for p in Path('/sys/devices/system/cpu').glob('cpu[0-9]*')}
print(json.dumps(dict(boot_id=boot,kernel=platform.release(),collector_version=1,denial_sha256=hashlib.file_digest(open(f'/proc/{pid}/exe','rb'),'sha256').hexdigest(),cpus=cpus,snapshots=[first,second]),indent=2))
