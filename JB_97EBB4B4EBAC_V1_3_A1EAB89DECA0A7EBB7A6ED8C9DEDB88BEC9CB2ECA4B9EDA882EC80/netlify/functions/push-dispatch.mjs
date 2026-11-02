import webpush from 'web-push';
import { createClient } from '@supabase/supabase-js';

// Scheduled push sender. Requires Supabase service role server-side only.
export default async () => {
  const {SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY,VAPID_PUBLIC_KEY,VAPID_PRIVATE_KEY,VAPID_SUBJECT}=process.env;
  if (![SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY,VAPID_PUBLIC_KEY,VAPID_PRIVATE_KEY,VAPID_SUBJECT].every(Boolean)) {
    console.error('JB push: required environment variables are missing');return;
  }
  const db=createClient(SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
  webpush.setVapidDetails(VAPID_SUBJECT,VAPID_PUBLIC_KEY,VAPID_PRIVATE_KEY);
  const {data:jobs,error}=await db.from('jb_push_outbox').select('id,employee_id,event_type,created_at,attempts').is('sent_at',null).lt('attempts',5).order('created_at',{ascending:true}).limit(30);
  if(error){console.error('JB push outbox read failed',error.message);return;}
  for(const job of jobs||[]){
    // Verify recipient registration before consuming a retry attempt.
    const {data:devices,error:devErr}=await db.from('jb_push_subscriptions').select('endpoint,p256dh,auth_secret').eq('employee_id',job.employee_id);
    if(devErr){await db.from('jb_push_outbox').update({last_error:devErr.message}).eq('id',job.id);continue;}
    if(!devices?.length){
      await db.from('jb_push_outbox').update({last_error:'등록된 푸시 기기 없음'}).eq('id',job.id);
      continue;
    }
    const {data:claim,error:claimError}=await db.from('jb_push_outbox').update({attempts:(job.attempts||0)+1,last_error:null}).eq('id',job.id).is('sent_at',null).eq('attempts',job.attempts||0).select('id');
    if(claimError||!claim?.length){if(claimError)console.error('JB push claim failed',claimError.message);continue;}
    let delivered=0,errors=[];
    const body=job.event_type==='task'?'새 업무 지시가 등록되었습니다.':job.event_type==='leave'?'근태 신청 또는 승인 관련 확인 사항이 있습니다.':'새 확인 요청이 등록되었습니다.';
    for(const d of devices){try{
      await webpush.sendNotification({endpoint:d.endpoint,keys:{p256dh:d.p256dh,auth:d.auth_secret}},JSON.stringify({title:'JB 업무관리',body,tag:'jb-'+job.id,url:'./index.html'}),{TTL:3600});delivered++;
    }catch(e){errors.push(String(e.statusCode||'')+': '+String(e.message||e));
      if(e.statusCode===404||e.statusCode===410) await db.from('jb_push_subscriptions').delete().eq('endpoint',d.endpoint);
    }}
    await db.from('jb_push_outbox').update(delivered?{sent_at:new Date().toISOString(),last_error:errors.length?errors.join('; ').slice(0,400):null}:{last_error:errors.join('; ').slice(0,400)||'전송 실패'}).eq('id',job.id);
  }
};
export const config={schedule:'* * * * *'}; // Netlify scheduled functions use UTC; every minute
