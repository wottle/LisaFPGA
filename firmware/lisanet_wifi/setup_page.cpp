// The WiFi setup page served on the setup network (see wifisetup.h). Written with an AI assistant.
namespace web {
extern const char SETUP_PAGE[] = R"HTML(<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LisaNet Setup</title>
<style>
:root{--bg:#f4f1ea;--fg:#1d1b18;--mut:#6b665d;--line:#d8d2c4;--acc:#2f5d8a;--bad:#a33;--card:#fffdf8}
@media (prefers-color-scheme:dark){:root{--bg:#181715;--fg:#ece8df;--mut:#9a9488;--line:#34312c;--acc:#7fa9d6;--bad:#e07b7b;--card:#211f1c}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.45 system-ui,sans-serif}
main{max-width:520px;margin:0 auto;padding:16px}h1{font-size:21px;margin:0 0 4px}.mut{color:var(--mut);font-size:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;margin:12px 0}
label{display:block;margin:10px 0 4px;font-weight:600}input[type=text],input[type=password]{width:100%;font:inherit;padding:8px;
border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg)}
button{font:inherit;padding:8px 14px;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:6px;cursor:pointer}
button.pri{background:var(--acc);border-color:var(--acc);color:#fff}button:disabled{opacity:.5}
.net{display:flex;justify-content:space-between;align-items:center;padding:8px;border-radius:6px;cursor:pointer}
.net:hover,.net.sel{background:color-mix(in srgb,var(--acc) 14%,transparent)}.sig{color:var(--mut);font-size:13px;white-space:nowrap}
#msg{padding:10px 12px;border-radius:6px;display:none}#msg.err{display:block;background:color-mix(in srgb,var(--bad) 15%,transparent);color:var(--bad)}
#msg.ok{display:block;background:color-mix(in srgb,var(--acc) 15%,transparent)}a{color:var(--acc)}
</style></head><body><main>
<h1>LisaNet setup</h1>
<div class="mut">Connect your LisaFPGA's WiFi board to your network.</div>
<div id="msg"></div>
<form class="card" id="login" hidden onsubmit="return false">
<b>Log in</b>
<div class="mut">This LisaNet is already set up. Log in with its web page password to change its WiFi network.</div>
<label for="lpass">Web page password</label><input type="password" id="lpass" autocomplete="current-password">
<p><button class="pri" id="lbtn">Log in</button></p>
</form>
<div class="card" id="form" hidden>
<div style="display:flex;justify-content:space-between;align-items:center"><b>Network</b><button id="rescan">Scan again</button></div>
<div id="nets" class="mut">Scanning...</div>
<label for="ssid">Network name</label><input type="text" id="ssid" autocapitalize="off" autocorrect="off" spellcheck="false">
<label for="pass">Network password</label><input type="password" id="pass">
<label for="webpass" id="wplabel">Web page password</label><input type="password" id="webpass" autocomplete="new-password">
<div class="mut" id="wphelp"></div>
<p><button class="pri" id="save">Connect</button></p>
<div class="mut">When it connects, your phone may drop off LisaNet-Setup. Rejoin your own WiFi and open
<a href="http://lisanet.local/">http://lisanet.local/</a> (user name <b>lisa</b>).</div>
</div>
</main><script>
const $=id=>document.getElementById(id);
function msg(t,bad){const m=$('msg');m.innerHTML=t;m.className=t?(bad?'err':'ok'):'';}
const esc=s=>s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
let token='';                                   // from /setup/login; scan and save need it once a web password exists
async function scan(){$('nets').textContent='Scanning...';
 try{const r=await (await fetch('/setup/scan?t='+token)).json();
  $('wplabel').textContent=r.haveWebPass?'New web page password (optional)':'Web page password';
  $('wphelp').textContent=r.haveWebPass?'Leave blank to keep the current one.':'Required: it protects the SD card manager. 4 or more characters.';
  const seen=new Set();const nets=r.nets.sort((a,b)=>b.r-a.r).filter(n=>!seen.has(n.s)&&seen.add(n.s));
  $('nets').innerHTML='';if(!nets.length)$('nets').textContent='No networks found. Type the name below.';
  for(const n of nets){const d=document.createElement('div');d.className='net';
   const bars=n.r>-55?'strong':n.r>-70?'good':'weak';
   d.innerHTML='<span>'+esc(n.s)+'</span><span class="sig">'+bars+(n.l?' &#x1F512;':' (open)')+'</span>';
   d.onclick=()=>{document.querySelectorAll('.net').forEach(x=>x.classList.remove('sel'));d.classList.add('sel');$('ssid').value=n.s;$('pass').focus();};
   $('nets').append(d);}
 }catch(e){$('nets').textContent='Scan failed. Type the network name below.';}}
async function poll(){for(let i=0;i<40;i++){await new Promise(r=>setTimeout(r,1000));
 try{const s=await (await fetch('/setup/status')).json();
  if(s.state==='joined'||s.connected&&s.state!=='joining'){msg('Connected to <b>'+esc(s.ssid)+'</b>. Your LisaNet is at <a href="http://'+s.mdns+'/">http://'+s.mdns+'/</a> or <a href="http://'+s.ip+'/">http://'+s.ip+'/</a>. Rejoin your own WiFi to use it; this setup network turns itself off in a minute.');return;}
  if(s.state==='failed'){msg('Could not join <b>'+esc(s.ssid)+'</b>. Check the password and try again.',1);$('save').disabled=false;return;}
 }catch(e){}}
 msg('Lost contact. If your phone left LisaNet-Setup, rejoin your own WiFi and try <a href="http://lisanet.local/">http://lisanet.local/</a>.',1);}
$('save').onclick=async()=>{msg('');const b=new URLSearchParams({ssid:$('ssid').value.trim(),pass:$('pass').value,webpass:$('webpass').value,t:token});
 $('save').disabled=true;
 try{const r=await fetch('/setup/save',{method:'POST',body:b});if(!r.ok){let j={};try{j=await r.json()}catch(e){}throw new Error(j.error||'HTTP '+r.status);}
  msg('Joining <b>'+esc($('ssid').value.trim())+'</b>...');poll();}
 catch(e){msg(esc(e.message),1);$('save').disabled=false;}};
$('rescan').onclick=scan;
function showForm(){$('login').hidden=true;$('form').hidden=false;scan();}
$('lbtn').onclick=async()=>{msg('');$('lbtn').disabled=true;
 try{const r=await fetch('/setup/login',{method:'POST',body:new URLSearchParams({password:$('lpass').value})});
  let j={};try{j=await r.json()}catch(e){}
  if(!r.ok)throw new Error(j.error||'HTTP '+r.status);token=j.t;showForm();}
 catch(e){msg(esc(e.message),1);$('lpass').select();}
 $('lbtn').disabled=false;};
// A board that is already set up starts at the login; a fresh one goes straight to the network form
(async()=>{try{const i=await (await fetch('/setup/info')).json();
 if(i.haveWebPass){$('login').hidden=false;$('lpass').focus();}else showForm();}catch(e){showForm();}})();
</script></body></html>
)HTML";
}  // namespace web
