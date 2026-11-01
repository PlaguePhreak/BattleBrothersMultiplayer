# Squirrel reserved words used as names make a whole .nut file fail to load (v0.28-v0.35: "local base" in mirror.nut).
# Usage: python3 tests/nut_keyword_check.py $(find mod -name "*.nut")
import re,sys,glob
KW=set("base break case catch class clone continue const default delete else enum extends for foreach function if in local null resume return switch this throw try typeof while yield constructor instanceof true false static rawcall".split())
bad=0
for p in sys.argv[1:]:
    s=open(p,encoding='utf-8').read()
    # strip comments and strings
    out=[];i=0;n=len(s)
    while i<n:
        c=s[i]
        if s.startswith('//',i): j=s.find('\n',i); i=n if j<0 else j; continue
        if s.startswith('/*',i): i=s.find('*/',i)+2; continue
        if c=='"':
            out.append('""'); i+=1
            while s[i]!='"': i+= 2 if s[i]=='\\' else 1
            i+=1; continue
        if c=="'": j=s.find("'",i+1+(s[i+1]=='\\'))+1; out.append("'x'"); i=j; continue
        out.append(c); i+=1
    t=''.join(out)
    pats=[(r'\blocal\s+([A-Za-z_]\w*)',None),(r'\.\s*([A-Za-z_]\w*)',None),(r'[{,]\s*([A-Za-z_]\w*)\s*(?:<-|=(?!=))',None),(r'\bfunction\s+([A-Za-z_]\w*)',None)]
    for pat,_ in pats:
        for m in re.finditer(pat,t):
            w=m.group(1)
            if w in KW and w!='constructor':
                line=t[:m.start()].count('\n')+1
                print(f"{p}:{line}: reserved word '{w}' used as a name"); bad+=1
    # params
    for m in re.finditer(r'function\s*\w*\s*\(([^)]*)\)',t):
        for a in m.group(1).split(','):
            a=a.split('=')[0].strip()
            if a in KW: print(f"{p}: param {a}"); bad+=1
print("keyword check:", "FAIL" if bad else "ok")
