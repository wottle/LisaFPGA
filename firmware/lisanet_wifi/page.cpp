// The SD card manager page served by web.cpp. Written with an AI assistant.
namespace web {
extern const char PAGE[] = R"HTML(<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LisaNet</title>
<style>
:root{--bg:#f4f1ea;--fg:#1d1b18;--mut:#6b665d;--line:#d8d2c4;--acc:#2f5d8a;--bad:#a33;--card:#fffdf8}
@media (prefers-color-scheme:dark){:root{--bg:#181715;--fg:#ece8df;--mut:#9a9488;--line:#34312c;--acc:#7fa9d6;--bad:#e07b7b;--card:#211f1c}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 system-ui,sans-serif}
main{max-width:900px;margin:0 auto;padding:16px}h1{font-size:20px;margin:0 0 4px}
.mut{color:var(--mut);font-size:13px}.bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:12px 0}
button,.btn{font:inherit;padding:5px 10px;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:6px;cursor:pointer;text-decoration:none}
button:hover,.btn:hover{border-color:var(--acc)}button.danger{color:var(--bad)}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:8px;overflow:hidden}
td,th{padding:7px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:middle}th{font-size:12px;color:var(--mut);font-weight:600}
td.s{text-align:right;white-space:nowrap;color:var(--mut)}td.a{white-space:nowrap;text-align:right}td.a button,td.a .btn{padding:2px 7px;font-size:13px}
a.dir{color:var(--acc);text-decoration:none;font-weight:600}.crumb a{color:var(--acc);text-decoration:none}
#msg{padding:8px 12px;border-radius:6px;margin:10px 0;display:none}#msg.err{display:block;background:color-mix(in srgb,var(--bad) 15%,transparent);color:var(--bad)}
#msg.ok{display:block;background:color-mix(in srgb,var(--acc) 15%,transparent)}
progress{width:200px}.mn{font-size:11px;color:var(--acc);border:1px solid var(--acc);border-radius:4px;padding:0 4px;margin-left:6px}
@media (max-width:600px){td.s{display:none}td.a button,td.a .btn{padding:2px 5px}}
</style></head><body><main>
<h1>LisaNet</h1><div class="mut" id="info">ESFloppy SD card</div>
<div id="msg"></div>
<div class="bar"><span class="crumb" id="crumb"></span></div>
<div class="bar">
<label class="btn">Upload<input type="file" id="file" multiple hidden></label>
<button id="mkdir">New folder</button><button id="refresh">Refresh</button><button id="infob">Card space</button>
<progress id="prog" max="1" value="0" hidden></progress><span class="mut" id="progt"></span>
</div>
<div class="mut" id="mnext"></div>
<table><thead><tr><th>Name</th><th class="s">Size</th><th></th></tr></thead><tbody id="list"></tbody></table>
<p class="mut">Disk images (.dc42, .image, .img) must be stored contiguously; uploads here always are. "Mount next" makes
ESFloppy insert that image in drive 1 every time it starts in FLOPPY mode, until cleared.</p>
</main><script>
let cwd='/',mountNext='';
const $=id=>document.getElementById(id);
const join=(d,n)=>(d.endsWith('/')?d:d+'/')+n;
const isImg=n=>/\.(dc42|image|img)$/i.test(n);
function msg(t,bad){const m=$('msg');m.textContent=t;m.className=t?(bad?'err':'ok'):'';}
async function api(url,opt){const r=await fetch(url,opt);let j={};try{j=await r.json()}catch(e){}
 if(!r.ok)throw new Error(r.status==503?'ESFloppy is not reachable: set ESP32 MODE to WIFI in the LisaFPGA menu.':(j.error||('HTTP '+r.status)));return j;}
function size(b){if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';return (b/1048576).toFixed(1)+' MB';}
function crumbs(){const c=$('crumb');c.innerHTML='';const parts=cwd.split('/').filter(Boolean);
 const add=(t,p)=>{const a=document.createElement('a');a.href='#';a.textContent=t;a.onclick=e=>{e.preventDefault();go(p)};c.append(a)};
 add('SD card','/');let p='';for(const x of parts){p+='/'+x;c.append(' / ');add(x,p);}}
async function load(){msg('');crumbs();const tb=$('list');tb.innerHTML='<tr><td colspan=3 class=mut>Loading...</td></tr>';
 try{const [l,m]=await Promise.all([api('/api/ls?path='+encodeURIComponent(cwd)),api('/api/mountnext')]);mountNext=m.path||'';
  $('mnext').textContent=mountNext?'Mount next: '+mountNext:'';
  const es=l.entries.filter(e=>!e.n.startsWith('._')).sort((a,b)=>(b.d-a.d)||a.n.localeCompare(b.n));tb.innerHTML='';
  if(cwd!=='/')es.unshift({n:'..',d:1,up:1});
  for(const e of es){const tr=document.createElement('tr'),p=e.up?cwd.replace(/\/[^/]*$/,'')||'/':join(cwd,e.n);
   const td=document.createElement('td');
   if(e.d){const a=document.createElement('a');a.href='#';a.className='dir';a.textContent=e.n+(e.up?'':'/');a.onclick=ev=>{ev.preventDefault();go(p)};td.append(a)}
   else{td.textContent=e.n;if(p===mountNext){const s=document.createElement('span');s.className='mn';s.textContent='mount next';td.append(s)}}
   const ts=document.createElement('td');ts.className='s';ts.textContent=e.d?'':size(e.s);
   const ta=document.createElement('td');ta.className='a';
   if(!e.up){
    if(!e.d){const d=document.createElement('a');d.className='btn';d.textContent='Download';d.href='/api/get?path='+encodeURIComponent(p);ta.append(d,' ');}
    if(!e.d&&isImg(e.n)){const b=document.createElement('button');b.textContent=p===mountNext?'Clear mount':'Mount next';
     b.onclick=()=>act('/api/mountnext?path='+encodeURIComponent(p===mountNext?'':p));ta.append(b,' ');}
    const r=document.createElement('button');r.textContent='Rename';r.onclick=()=>{const n=prompt('New name',e.n);if(n&&n!==e.n)act('/api/mv?from='+encodeURIComponent(p)+'&to='+encodeURIComponent(join(cwd,n)))};
    const x=document.createElement('button');x.textContent='Delete';x.className='danger';x.onclick=()=>{if(confirm('Delete '+e.n+'?'))act('/api/rm?path='+encodeURIComponent(p))};
    ta.append(r,' ',x);}
   tr.append(td,ts,ta);tb.append(tr);}
  if(!es.length)tb.innerHTML='<tr><td colspan=3 class=mut>Empty folder</td></tr>';
 }catch(e){tb.innerHTML='';msg(e.message,1);}}
function go(p){cwd=p;load();}
async function act(url){try{await api(url,{method:'POST'});load();}catch(e){msg(e.message,1);}}
function upload(f){return new Promise((res,rej)=>{const x=new XMLHttpRequest();x.open('POST','/api/put');
 x.setRequestHeader('X-Path',encodeURIComponent(join(cwd,f.name)));x.setRequestHeader('Content-Type','application/octet-stream');
 x.upload.onprogress=e=>{$('prog').max=e.total;$('prog').value=e.loaded;$('progt').textContent=f.name+' '+size(e.loaded)+' / '+size(e.total)};
 x.onload=()=>{let j={};try{j=JSON.parse(x.responseText)}catch(e){}
  x.status==200?res():rej(new Error(x.status==503?'ESFloppy is not reachable: set ESP32 MODE to WIFI.':x.status==507?'No contiguous space on the card for '+f.name:(j.error||'HTTP '+x.status)))};
 x.onerror=()=>rej(new Error('Upload failed'));x.send(f);});}
$('file').onchange=async e=>{const fs=[...e.target.files];e.target.value='';$('prog').hidden=false;
 try{for(const f of fs)await upload(f);msg('Uploaded '+fs.length+' file(s)');}catch(err){msg(err.message,1);}
 $('prog').hidden=true;$('progt').textContent='';load();};
$('mkdir').onclick=()=>{const n=prompt('Folder name');if(n)act('/api/mkdir?path='+encodeURIComponent(join(cwd,n)))};
$('refresh').onclick=load;
$('infob').onclick=async()=>{$('info').textContent='Reading card (up to 10 s)...';
 try{const i=await api('/api/info');$('info').textContent=i.fw+' - '+size(i.free)+' free of '+size(i.card);}catch(e){$('info').textContent='';msg(e.message,1);}};
load();
</script></body></html>
)HTML";
}  // namespace web
