// JB 업무관리 V1.3 — 동일 이벤트 푸시 중복 표시 방지
// The server sends a stable tag (jb-<outbox UUID>) for each event.
const jbPushInFlight=new Set();
const JB_SEEN_CACHE='jb-push-seen-v1';
const JB_SEEN_MS=6*60*60*1000;
async function jbShowPushOnce(data){
 const title=String(data.title||'JB 업무관리');
 const tag=String(data.tag||'jb-general');
 const options={
  body:String(data.body||'새 알림이 있습니다.'),tag,renotify:false,
  icon:'./jb-work-icon.svg',badge:'./jb-notification-96.png',
  data:{url:String(data.url||'./index.html')}
 };
 // Generic untagged messages are not deduplicated against unrelated alerts.
 if(!tag.startsWith('jb-')||tag==='jb-general'){
  await self.registration.showNotification(title,options);
  return;
 }
 if(jbPushInFlight.has(tag))return;
 jbPushInFlight.add(tag);
 try{
  let cache=null,marker=null;
  try{
   cache=await caches.open(JB_SEEN_CACHE);
   marker=new Request(new URL('./.jb-push-seen/'+encodeURIComponent(tag),self.registration.scope).href);
   const record=await cache.match(marker);
   if(record){
    const lastSeen=Number(await record.text());
    if(Number.isFinite(lastSeen)&&Date.now()-lastSeen<JB_SEEN_MS)return;
   }
  }catch(_){cache=null;marker=null}
  try{
   const existing=await self.registration.getNotifications({tag});
   if(existing?.length)return;
  }catch(_){}
  await self.registration.showNotification(title,options);
  if(cache&&marker){
   try{
    await cache.put(marker,new Response(String(Date.now()),{headers:{'content-type':'text/plain'}}));
    // Bound the device-side cache; old event tags must not grow indefinitely.
    const stored=await cache.keys();
    if(stored.length>200){
     for(const entry of stored.slice(0,stored.length-160))await cache.delete(entry);
    }
   }catch(_){}
  }
 }finally{jbPushInFlight.delete(tag)}
}
self.addEventListener('push',event=>{
 let data={};
 try{data=event.data?.json()||{}}
 catch(_){data={body:event.data?.text()||'새 업무 알림이 있습니다.'}}
 event.waitUntil(jbShowPushOnce(data));
});
self.addEventListener('notificationclick',event=>{
 event.notification.close();
 const target=new URL(event.notification.data?.url||'./index.html',self.registration.scope);
 if(target.origin!==self.location.origin)return;
 event.waitUntil((async()=>{
  const wins=await clients.matchAll({type:'window',includeUncontrolled:true});
  for(const c of wins){
   if(new URL(c.url).origin===target.origin){
    await c.focus();c.navigate(target.href);return;
   }
  }
  await clients.openWindow(target.href);
 })());
});
