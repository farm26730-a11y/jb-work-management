import {createPushServer,deliverQueuedPush,MAX_PUSH_AGE_MS} from '../lib/push-core.mjs';

// Scheduled fallback: Netlify cron supports minute granularity. The authenticated
// push-comment-now endpoint provides a faster path after posting a comment.
export default async () => {
 let db;
 try{db=createPushServer()}catch(error){console.error('JB push configuration:',error.message);return}
 const newestAllowed=new Date(Date.now()-MAX_PUSH_AGE_MS).toISOString();
 const {data:jobs,error}=await db.from('jb_push_outbox')
  .select('id,event_key,employee_id,event_type,created_at,sent_at,attempts,last_error')
  .is('sent_at',null).lt('attempts',5)
  .gte('created_at',newestAllowed)
  .order('created_at',{ascending:true}).limit(30);
 if(error){console.error('JB push queue read failed',error.message);return}
 for(const job of jobs||[]){
  try{await deliverQueuedPush(db,job)}catch(e){console.error('JB push dispatch failed',String(e?.message||e))}
 }
};
export const config={schedule:'* * * * *'};
