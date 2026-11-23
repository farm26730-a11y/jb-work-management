export default function taskClockTime(request) {
 if(request.method!=='GET')return new Response(null,{status:405,headers:{allow:'GET'}});
 return Response.json({now:Date.now()},{headers:{'cache-control':'no-store'}});
}
