import {createPushServer,deliverQueuedPush} from '../lib/push-core.mjs';

// Immediate comment push. Only a valid, active user may wake delivery for a
// comment authored by that same user. The scheduled sender remains the fallback.
export default async request=>{
 if(request.method!=='POST')return new Response('',{status:405});
 const token=/^Bearer\s+(.+)$/i.exec(request.headers.get('authorization')||'')?.[1];
 if(!token)return new Response('',{status:401});
 let payload;
 try{payload=await request.json()}catch(_){return new Response('',{status:400})}
 const commentId=String(payload?.commentId||'');
 if(!/^[0-9a-f]{8}-[0-9a-f-]{27,}$/i.test(commentId)||commentId.length!==36)return new Response('',{status:400});
 try{
  const db=createPushServer();
  const {data:auth,error:authError}=await db.auth.getUser(token);
  if(authError||!auth?.user?.id)return new Response('',{status:401});
  const {data:worker,error:workerError}=await db.from('jb_employees')
   .select('id').eq('auth_user_id',auth.user.id).eq('active',true).maybeSingle();
  if(workerError||!worker)return new Response('',{status:403});
  const {data:comment,error:commentError}=await db.from('jb_task_comments')
   .select('id').eq('id',commentId).eq('author_id',worker.id).maybeSingle();
  if(commentError||!comment)return new Response('',{status:403});
  const {data:jobs,error:jobsError}=await db.from('jb_push_outbox')
   .select('id,event_key,employee_id,event_type,created_at,sent_at,attempts,last_error')
   .eq('event_key','comment:'+commentId).eq('event_type','comment')
   .is('sent_at',null).lt('attempts',5)
   .gte('created_at',new Date(Date.now()-120000).toISOString())
   .limit(5);
  if(jobsError)throw jobsError;
  for(const job of jobs||[])await deliverQueuedPush(db,job);
  return new Response(null,{status:204});
 }catch(error){
  console.error('JB immediate comment dispatch:',String(error?.message||error));
  return new Response('',{status:503});
 }
};
export const config={method:'POST',rateLimit:{windowLimit:90,windowSize:60,aggregateBy:['ip','domain']}};
