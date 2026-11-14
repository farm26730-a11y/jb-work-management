import webpush from 'web-push';
import { createClient } from '@supabase/supabase-js';

// A single dispatcher for both the scheduled fallback and the authenticated fast path.
// Do not put service-role keys or VAPID private keys in the HTML/client.
export const MAX_PUSH_AGE_MS=30*60*1000;
const PROCESSING_TIMEOUT_MS=90*1000;

export function createPushServer(){
 const {SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY,VAPID_PUBLIC_KEY,VAPID_PRIVATE_KEY,VAPID_SUBJECT}=process.env;
 if(String(SUPABASE_URL||'').replace(/\/+$/,'')!=='https://apkrhhdmjxbvwtdktfaq.supabase.co')throw new Error('개발 푸시 서버가 운영 Supabase를 참조할 수 없습니다');
 if(![SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY,VAPID_PUBLIC_KEY,VAPID_PRIVATE_KEY,VAPID_SUBJECT].every(Boolean)){
  throw new Error('Missing server-side Supabase/VAPID configuration');
 }
 const db=createClient(SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
 webpush.setVapidDetails(VAPID_SUBJECT,VAPID_PUBLIC_KEY,VAPID_PRIVATE_KEY);
 return db;
}

export async function deliverQueuedPush(db,job){
 if(!job||job.sent_at||!job.id||!job.employee_id)return 'skipped';
 const created=Date.parse(job.created_at);
 const age=Date.now()-created;
 if(!Number.isFinite(age)||age< -60000||age>MAX_PUSH_AGE_MS)return 'stale';
 const attempts=Number(job.attempts||0);
 if(attempts>=5)return 'max_attempts';
 const previousError=job.last_error??null;
 // The claim marker is a short-lived lock shared by the scheduled and immediate senders.
 if(typeof previousError==='string'&&previousError.startsWith('PROCESSING:')){
  const time=Number(previousError.split(':')[1]);
  if(!Number.isFinite(time)||Date.now()-time<PROCESSING_TIMEOUT_MS)return 'in_progress';
 }
 // The device must have been subscribed when the event happened. This prevents
 // five-minute-old comment alerts from arriving when a phone is first registered.
 const {data:registered,error:deviceError}=await db.from('jb_push_subscriptions')
  .select('endpoint,p256dh,auth_secret,created_at')
  .eq('employee_id',job.employee_id).lte('created_at',job.created_at);
 if(deviceError){
  console.error('JB push subscriptions lookup failed:',deviceError.message);
  return 'device_error';
 }
 const devices=[...new Map((registered||[]).filter(x=>x.endpoint&&x.p256dh&&x.auth_secret).map(x=>[x.endpoint,x])).values()];
 if(!devices.length){
  // Device registrations created after the event are deliberately ineligible.
  // Rechecking this job every minute cannot create an eligible old subscription.
  // Mark terminal without claiming a push was delivered, to avoid queue starvation.
  const {error:noDeviceError}=await db.from('jb_push_outbox')
   .update({attempts:5,last_error:'이벤트 당시 등록된 푸시 기기 없음 (전송 대상 없음)'})
   .eq('id',job.id).is('sent_at',null).eq('attempts',attempts);
  if(noDeviceError)console.error('JB push no-device terminal update:',noDeviceError.message);
  return 'no_existing_device';
 }
 const marker='PROCESSING:'+Date.now()+':'+Math.random().toString(36).slice(2,9);
 let claimQuery=db.from('jb_push_outbox')
  .update({attempts:attempts+1,last_error:marker})
  .eq('id',job.id).eq('attempts',attempts).is('sent_at',null);
 claimQuery=previousError===null?claimQuery.is('last_error',null):claimQuery.eq('last_error',previousError);
 const {data:claimed,error:claimError}=await claimQuery.select('id');
 if(claimError){console.error('JB push atomic claim failed:',claimError.message);return 'claim_error'}
 if(!claimed?.length)return 'already_claimed';
 const body=job.event_type==='task'?'새 업무 지시가 등록되었습니다.':
  job.event_type==='comment'?'담당 업무에 새 댓글이 등록되었습니다. 앱에서 내용을 확인하세요.':
  job.event_type==='leave'?'근태 신청 또는 승인 관련 확인 사항이 있습니다.':
  '새 확인 요청이 등록되었습니다.';
 const payload=JSON.stringify({title:'JB 업무관리',body,tag:'jb-'+job.id,url:'./index.html'});
 const ttl=Math.max(60,Math.min(1800,Math.floor((MAX_PUSH_AGE_MS-age)/1000)));
 const results=await Promise.all(devices.map(async device=>{
  try{
   await webpush.sendNotification({endpoint:device.endpoint,keys:{p256dh:device.p256dh,auth:device.auth_secret}},payload,{TTL:ttl});
   return {sent:true};
  }catch(err){
   const code=err?.statusCode;
   if(code===404||code===410)await db.from('jb_push_subscriptions').delete().eq('endpoint',device.endpoint);
   return {sent:false,error:String(code||'')+': '+String(err?.message||err)};
  }
 }));
 const delivered=results.filter(r=>r.sent).length;
 const errors=results.filter(r=>!r.sent).map(r=>r.error).join('; ').slice(0,400);
 const outcome=delivered
  ?{sent_at:new Date().toISOString(),last_error:errors||null}
  :{last_error:errors||'푸시 전송 실패'};
 const {error:finalError}=await db.from('jb_push_outbox')
  .update(outcome).eq('id',job.id).eq('last_error',marker);
 if(finalError)console.error('JB push result update failed:',finalError.message);
 return delivered?'sent':'failed';
}
