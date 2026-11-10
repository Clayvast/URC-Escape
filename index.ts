// supabase/functions/admin-create-player/index.ts
// Deploy with Supabase CLI. Set SUPABASE_URL, SUPABASE_ANON_KEY,
// SUPABASE_SERVICE_ROLE_KEY as Edge Function secrets. Never expose service role key.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
Deno.serve(async(req)=>{
 if(req.method!=="POST")return new Response("Method not allowed",{status:405});
 const auth=req.headers.get("Authorization");if(!auth)return Response.json({error:"Not authenticated"},{status:401});
 const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const caller=createClient(url,anon,{global:{headers:{Authorization:auth}}});
 const {data:ud,error:ue}=await caller.auth.getUser();if(ue||!ud.user)return Response.json({error:"Not authenticated"},{status:401});
 const admin=createClient(url,service);const {data:prof}=await admin.from("profiles").select("role").eq("id",ud.user.id).single();
 if(prof?.role!=="admin")return Response.json({error:"Administrator permission required"},{status:403});
 const b=await req.json(),username=String(b.username??"").trim(),password=String(b.password??"");
 if(!/^[a-zA-Z0-9_-]{3,24}$/.test(username))return Response.json({error:"Username must be 3–24 letters, numbers, underscores or hyphens."},{status:400});
 if(password.length<8)return Response.json({error:"Password must be at least 8 characters."},{status:400});
 const email=username.toLowerCase()+"@players.urcescape.invalid";
 const {data,error}=await admin.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{username,starting_room:String(b.starting_room||"Forum"),ability:String(b.ability||"")},app_metadata:{role:"player"}});
 if(error)return Response.json({error:error.message},{status:400});
 return Response.json({id:data.user.id,username,starting_room:b.starting_room});
});