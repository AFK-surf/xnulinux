cd /tmp
ls -t /Library/Logs/DiagnosticReports /var/root/Library/Logs/DiagnosticReports 2>/dev/null | head -8
f=$(ls -t /Library/Logs/DiagnosticReports/${1:-}*.ips /var/root/Library/Logs/DiagnosticReports/${1:-}*.ips 2>/dev/null | head -1)
echo "REPORT $f"
python3 - "$f" <<'PY'
import json,sys
t=open(sys.argv[1]).read().split('\n',1)
h=json.loads(t[0]); b=json.loads(t[1])
print(h.get('app_name'), h.get('name'))
print('exc', b.get('exception'), 'term', b.get('termination'))
print('asi', b.get('asi'))
imgs=b.get('usedImages',[])
for th in b.get('threads',[]):
  if th.get('triggered'):
    for fr in th.get('frames',[])[:22]:
      im=imgs[fr['imageIndex']] if fr.get('imageIndex') is not None and fr['imageIndex']<len(imgs) else {}
      print(' ', im.get('name','?'), fr.get('symbol','?'), hex(fr.get('imageOffset',0)))
PY
