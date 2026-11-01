self.addEventListener('push',event=>{
 let data={};try{data=event.data?.json()||{}}catch(_){data={body:event.data?.text()||'새 업무 알림이 있습니다.'}}
 const title=String(data.title||'JB 업무관리');
 const opts={body:String(data.body||'새 알림이 있습니다.'),tag:String(data.tag||'jb-general'),renotify:false,icon:'./jb-icon-192.png',badge:'./jb-icon-192.png',data:{url:String(data.url||'./index.html')}};
 event.waitUntil(self.registration.showNotification(title,opts));
});
self.addEventListener('notificationclick',event=>{
 event.notification.close();
 const target=new URL(event.notification.data?.url||'./index.html',self.registration.scope);
 if(target.origin!==self.location.origin)return;
 event.waitUntil((async()=>{const wins=await clients.matchAll({type:'window',includeUncontrolled:true});for(const c of wins){if(new URL(c.url).origin===target.origin){await c.focus();c.navigate(target.href);return}}await clients.openWindow(target.href)})());
});
