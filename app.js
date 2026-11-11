import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const ready=window.URC_SUPABASE_URL&&!window.URC_SUPABASE_URL.startsWith("YOUR_")&&window.URC_SUPABASE_ANON_KEY&&!window.URC_SUPABASE_ANON_KEY.startsWith("YOUR_");
const sb=ready?createClient(window.URC_SUPABASE_URL,window.URC_SUPABASE_ANON_KEY):null;
const rooms=["Garden","Kitchen","Hall","Backstage","Band Stand","Stage","Sanctuary","Forum","Hallway","WC","Office (west)","Vestry","Lounge","Storage","Youth Room","Office (east)","Side room"];
const desc={"Garden":"An outdoor garden. Search for hidden clues.","Kitchen":"A kitchen with possible ingredients and clues.","Hall":"A large hall connecting several parts of the building.","Backstage":"A restricted backstage area.","Band Stand":"A small band stand beside the stage.","Stage":"A performance space.","Sanctuary":"A spacious sanctuary.","Forum":"A long room connecting the sanctuary to the hallway.","Hallway":"A central corridor with several doorways.","WC":"A small room off the hallway.","Office (west)":"An office beside the WC.","Vestry":"A room connected to the central hallway.","Lounge":"A lounge and potential meeting point.","Storage":"A small storage room.","Youth Room":"A separate room on the east side.","Office (east)":"A small office beside the Youth Room.","Side room":"A small unlabelled room."};
const $=s=>document.querySelector(s);let portal="player",user=null,profile=null,known=new Set(),chosen=null,roomRules=new Map(),currentShards=0;
rooms.forEach(r=>{let o=document.createElement("option");o.value=r;o.textContent=r;$("#starting-room").append(o);let p=document.createElement("option");p.value=r;p.textContent=r;$("#puzzle-room").append(p)});
function toast(s){let t=$("#toast");t.textContent=s;t.classList.add("show");setTimeout(()=>t.classList.remove("show"),2500)}
document.querySelectorAll(".tab").forEach(b=>b.onclick=()=>{portal=b.dataset.tab;document.querySelectorAll(".tab").forEach(x=>x.classList.toggle("active",x===b));$("#portal-label").textContent=portal==="admin"?"ADMINISTRATOR SIGN IN":"PLAYER SIGN IN";$("#portal-title").textContent=portal==="admin"?"Game master access":"Welcome back";$("#auth-error").textContent=""});
const toEmail=u=>u.trim().toLowerCase()+"@players.urcescape.invalid";
async function enter(u){let p=await sb.from("profiles").select("*").eq("id",u.id).single();if(p.error)throw new Error("No player profile found. Check the SQL setup.");profile=p.data;if(portal==="admin"&&profile.role!=="admin")throw new Error("This account is not an administrator.");user=u;$("#session-label").textContent=profile.username;$("#signout").classList.remove("hidden");$("#auth-view").classList.add("hidden");$("#game-view").classList.remove("hidden");$("#admin-panel").classList.toggle("hidden",profile.role!=="admin");if(profile.role==="admin")await loadAdminPuzzles();$("#player-name").textContent=profile.username;let pr=await sb.from("player_progress").select("*").eq("player_id",u.id).maybeSingle();let xp=pr.data?.xp||0;$("#player-level").textContent=`Level ${Math.floor(xp/100)+1} · ${xp} XP`;$("#xp-label").textContent=xp+" XP";$("#xp-bar").style.width=(xp%100)+"%";currentShards=pr.data?.key_shards||0;$("#shards").textContent=currentShards;let d=await sb.from("player_rooms").select("room_name").eq("player_id",u.id);known=new Set((d.data||[]).map(x=>x.room_name));await loadRoomUnlocks();await loadInventory(u.id);render()}
async function loadInventory(playerId){const list=$("#inventory-list");list.replaceChildren();const {data,error}=await sb.from("player_inventory").select("item_id,item_name,description,icon,quantity").eq("player_id",playerId).order("acquired_at",{ascending:true});if(error){$("#inventory-count").textContent="Unavailable";list.textContent="Inventory setup is required. Ask the game master to apply the latest database setup.";console.error("Inventory load failed:",error);return}const items=data||[];const total=items.reduce((sum,item)=>sum+(item.quantity||1),0);$("#inventory-count").textContent=total+ (total===1?" item":" items");if(!items.length){list.textContent="Your inventory is empty. Keep exploring to find useful objects.";return}for(const item of items){const row=document.createElement("div");row.className="inventory-item";const icon=document.createElement("span");icon.className="inventory-icon";icon.textContent=item.icon||"🎒";const details=document.createElement("div");details.className="inventory-details";const name=document.createElement("b");name.textContent=item.item_name||item.item_id;const description=document.createElement("small");description.textContent=item.description||"No description available.";details.append(name,description);const quantity=document.createElement("span");quantity.className="inventory-quantity";quantity.textContent="×"+(item.quantity||1);row.append(icon,details,quantity);list.append(row)}}
async function loadRoomUnlocks(){
  const {data,error}=await sb.rpc("get_room_unlock_options");
  if(error){console.error("Room unlock options failed:",error);roomRules=new Map();return}
  roomRules=new Map((data||[]).map(rule=>[rule.room_name,rule]));
}
function render(){
  document.querySelectorAll(".room").forEach(el=>{
    const unlocked=known.has(el.dataset.room);
    el.classList.toggle("unexplored",!unlocked);
    el.classList.toggle("locked",!unlocked);
    el.classList.toggle("unlocked",unlocked);
  });
  $("#map-status").textContent=`${known.size} / ${rooms.length} rooms discovered`;
}
function showRoom(roomName){
  chosen=roomName;
  document.querySelectorAll(".room").forEach(x=>x.classList.toggle("selected",x.dataset.room===roomName));
  $("#room-name").textContent=roomName;
  $("#room-description").textContent=desc[roomName]||"A room waiting to be explored.";
  const unlocked=known.has(roomName),rule=roomRules.get(roomName),unlockButton=$("#unlock-room");
  $("#inspect").disabled=!unlocked;
  unlockButton.classList.toggle("hidden",unlocked);
  $("#puzzle-list").replaceChildren();$("#puzzle-play").replaceChildren();
  $("#puzzle-count").textContent=unlocked?"Loading…":"Unlock this room first";
  if(unlocked){
    $("#room-meta").textContent="✓ Discovered";
    loadRoomPuzzles(roomName);
    return;
  }
  if(!rule){
    $("#room-meta").textContent="No unlock rule has been configured for this room.";
    unlockButton.disabled=true;unlockButton.textContent="Unavailable";
    return;
  }
  const requirements=[];
  if(rule.required_room&&!rule.has_required_room)requirements.push("Discover "+rule.required_room+" first");
  if(rule.required_item_id&&!rule.has_required_item)requirements.push("Find item: "+rule.required_item_id);
  if(rule.unlock_cost_shards>0)requirements.push(rule.unlock_cost_shards+" key shards (you have "+currentShards+")");
  $("#room-meta").textContent=requirements.length?"Requirements: "+requirements.join(" · "):"Ready to unlock";
  unlockButton.disabled=!rule.can_unlock;
  unlockButton.textContent=rule.can_unlock?(rule.unlock_cost_shards?"Unlock · "+rule.unlock_cost_shards+" shards":"Unlock room"):"Requirements not met";
}
document.querySelectorAll(".room").forEach(el=>{el.onclick=()=>showRoom(el.dataset.room)});
$("#unlock-room").onclick=async()=>{
  if(!chosen||known.has(chosen))return;
  const button=$("#unlock-room");button.disabled=true;button.textContent="Unlocking…";
  try{
    const {data,error}=await sb.rpc("unlock_room",{p_room_name:chosen});
    if(error)throw error;
    if(!data?.success)throw new Error(data?.message||"Could not unlock this room.");
    toast(data.already_unlocked?"Room already discovered":"Unlocked "+chosen+"!");
    const unlockedName=chosen;
    const {data:progress}=await sb.from("player_progress").select("xp,key_shards").eq("player_id",user.id).maybeSingle();
    currentShards=progress?.key_shards??currentShards;$("#shards").textContent=currentShards;
    const {data:discovered}=await sb.from("player_rooms").select("room_name").eq("player_id",user.id);
    known=new Set((discovered||[]).map(x=>x.room_name));
    await loadRoomUnlocks();render();showRoom(unlockedName);
  }catch(err){toast(err.message||"Room could not be unlocked.");await loadRoomUnlocks();showRoom(chosen)}
};
$("#inspect").onclick=()=>toast(chosen+" is ready to explore.");
$("#login-form").onsubmit=async e=>{e.preventDefault();$("#auth-error").textContent="";if(!sb){$("#auth-error").textContent="Add your Supabase project URL and anon key in supabase-config.js first.";return}let b=$("#login-button");b.disabled=true;b.textContent="Signing in…";try{let {data,error}=await sb.auth.signInWithPassword({email:toEmail($("#username").value),password:$("#password").value});if(error)throw error;await enter(data.user)}catch(err){$("#auth-error").textContent=err.message==="Invalid login credentials"?"Incorrect username or password.":err.message}finally{b.disabled=false;b.textContent="Sign in"}};
$("#signout").onclick=async()=>{await sb?.auth.signOut();location.reload()};
$("#create-player").onsubmit=async e=>{e.preventDefault();$("#create-error").textContent="";let b=e.submitter;b.disabled=true;try{let {data,error}=await sb.functions.invoke("admin-create-player",{body:{username:$("#new-username").value,password:$("#new-password").value,starting_room:$("#starting-room").value,ability:$("#ability").value}});if(error)throw error;if(data.error)throw Error(data.error);toast("Created "+data.username);e.target.reset()}catch(err){$("#create-error").textContent=err.message+" (check that the Edge Function is deployed)"}finally{b.disabled=false}};
if(!ready)$("#auth-error").textContent="Setup required: add Supabase URL and anon key to supabase-config.js.";


// Puzzle interface: prompts are public to authenticated players, but answers
// are checked by a Supabase RPC and are never sent to the browser.
async function loadRoomPuzzles(roomName){
  const list=$("#puzzle-list"),play=$("#puzzle-play");
  list.replaceChildren();play.replaceChildren();
  $("#puzzle-count").textContent="Loading…";
  const {data,error}=await sb.rpc("get_room_puzzles",{p_room_name:roomName});
  if(error){
    $("#puzzle-count").textContent="Unavailable";
    list.textContent="Puzzle setup is required. The game master must apply the latest database setup.";
    console.error("Puzzle load failed:",error);
    return;
  }
  const puzzles=data||[];
  $("#puzzle-count").textContent=puzzles.length+(puzzles.length===1?" puzzle":" puzzles");
  if(!puzzles.length){
    list.textContent="No puzzles have been added to this room yet.";
    return;
  }
  for(const puzzle of puzzles){
    const button=document.createElement("button");
    button.type="button";
    button.className="puzzle-choice"+(puzzle.solved?" solved":"");
    button.textContent=(puzzle.solved?"✓ ":"🧩 ")+puzzle.title+(puzzle.solved?" · Solved":"");
    button.onclick=()=>showPuzzle(puzzle);
    list.append(button);
  }
}
function showPuzzle(puzzle){
  const play=$("#puzzle-play");
  play.replaceChildren();
  const title=document.createElement("h3");title.textContent=puzzle.title;
  const prompt=document.createElement("p");prompt.className="puzzle-prompt";prompt.textContent=puzzle.prompt;
  play.append(title,prompt);
  const reward=document.createElement("p");reward.className="puzzle-reward";
  reward.textContent="Reward: "+puzzle.reward_xp+" XP"+(puzzle.reward_shards?" · "+puzzle.reward_shards+" key shards":"");
  play.append(reward);
  if(puzzle.solved){
    const done=document.createElement("p");done.className="puzzle-success";done.textContent="You have already solved this puzzle.";
    play.append(done);return;
  }
  const hints=[puzzle.hint_1||puzzle.hint||"",puzzle.hint_2||"",puzzle.hint_3||""].filter(Boolean);
  let hintIndex=0;
  const hint=document.createElement("button");hint.type="button";hint.className="puzzle-hint";hint.textContent=hints.length?"Show hint 1":"No hints available";
  const hintText=document.createElement("p");hintText.className="puzzle-hint-text hidden";
  hint.onclick=()=>{if(hintIndex<hints.length){hintText.textContent=hints[hintIndex++];hintText.classList.remove("hidden");hint.textContent=hintIndex<hints.length?"Show hint "+(hintIndex+1):"All hints revealed"}};
  play.append(hint,hintText);
  const form=document.createElement("form");form.className="puzzle-answer-form";
  let input;
  if(puzzle.answer_type==="multiple_choice"){
    input=document.createElement("select");input.required=true;
    const placeholder=document.createElement("option");placeholder.value="";placeholder.textContent="Choose an answer";placeholder.disabled=true;placeholder.selected=true;input.append(placeholder);
    (puzzle.options||[]).forEach(option=>{const o=document.createElement("option");o.value=option;o.textContent=option;input.append(o)});
  }else{
    input=document.createElement("input");input.type=puzzle.answer_type==="numerical"?"number":"text";
    if(puzzle.answer_type==="numerical")input.step="any";
    input.placeholder=puzzle.answer_type==="cipher"?"Enter the decoded message":"Enter your answer";
    input.autocomplete="off";input.required=true;
  }
  const submit=document.createElement("button");submit.type="submit";submit.className="primary";submit.textContent="Submit answer";
  const feedback=document.createElement("p");feedback.className="puzzle-feedback";
  form.append(input,submit,feedback);
  form.onsubmit=async event=>{
    event.preventDefault();submit.disabled=true;submit.textContent="Checking…";feedback.textContent="";
    try{
      const {data,error}=await sb.rpc("submit_puzzle_answer",{p_puzzle_id:puzzle.id,p_answer:input.value});
      if(error)throw error;
      if(!data?.correct){feedback.textContent=data?.message||"That answer was not correct. Try again.";return}
      feedback.textContent=data.message||"Puzzle solved!";
      feedback.className="puzzle-feedback puzzle-success";
      if(!data.already_solved){
        const xp=data.xp_awarded||0,shards=data.shards_awarded||0;
        toast("Puzzle solved! +"+xp+" XP"+(shards?" · +"+shards+" shards":""));
        const {data:progress}=await sb.from("player_progress").select("*").eq("player_id",user.id).maybeSingle();
        const total=progress?.xp||0;currentShards=progress?.key_shards||0;
        $("#player-level").textContent="Level "+(Math.floor(total/100)+1)+" · "+total+" XP";
        $("#xp-label").textContent=total+" XP";$("#xp-bar").style.width=(total%100)+"%";
        $("#shards").textContent=currentShards;await loadRoomUnlocks();
      }
      await loadRoomPuzzles(chosen);
      const solved=document.createElement("p");solved.className="puzzle-success";solved.textContent="Puzzle completed. Your reward has been added.";
      play.replaceChildren(title,prompt,solved);
    }catch(err){feedback.textContent=err.message||"Could not submit your answer."}
    finally{submit.disabled=false;submit.textContent="Submit answer"}
  };
  play.append(form);
}

let editingPuzzleId=null,adminPuzzleCache=[];
async function loadAdminPuzzles(){
  const list=$("#admin-puzzle-list");if(!list)return;
  list.textContent="Loading puzzles…";
  const {data,error}=await sb.rpc("admin_list_puzzles");
  if(error){list.textContent="Could not load puzzles: "+error.message;return}
  adminPuzzleCache=data||[];list.replaceChildren();
  if(!adminPuzzleCache.length){list.textContent="No puzzles created yet.";return}
  for(const puzzle of adminPuzzleCache){
    const row=document.createElement("div");row.className="admin-puzzle-row";
    const details=document.createElement("div");details.className="admin-puzzle-details";
    const title=document.createElement("b");title.textContent=puzzle.title;
    const meta=document.createElement("small");meta.textContent=puzzle.room_name+" · "+puzzle.answer_type.replace("_"," ")+" · "+puzzle.reward_xp+" XP"+(puzzle.reward_shards?" · "+puzzle.reward_shards+" shards":"")+(puzzle.active?" · Active":" · Hidden");
    details.append(title,meta);
    const actions=document.createElement("div");actions.className="admin-puzzle-actions";
    const edit=document.createElement("button");edit.type="button";edit.className="secondary";edit.textContent="Edit";edit.onclick=()=>editAdminPuzzle(puzzle);
    const del=document.createElement("button");del.type="button";del.className="danger";del.textContent="Delete";del.onclick=async()=>{
      if(!confirm('Delete "'+puzzle.title+'"? This also removes its solve records.'))return;
      const {error}=await sb.rpc("admin_delete_puzzle",{p_id:puzzle.id});
      if(error){toast(error.message);return}toast("Puzzle deleted");if(editingPuzzleId===puzzle.id)resetPuzzleEditor();await loadAdminPuzzles();
    };
    actions.append(edit,del);row.append(details,actions);list.append(row);
  }
}
function resetPuzzleEditor(){
  editingPuzzleId=null;$("#puzzle-editor").reset();$("#puzzle-editor-title").textContent="Create puzzle";
  $("#puzzle-save").textContent="Create puzzle";$("#puzzle-cancel").classList.add("hidden");
  $("#puzzle-active").checked=true;togglePuzzleFields();
}
function togglePuzzleFields(){
  const type=$("#puzzle-type").value;
  $("#puzzle-options-wrap").classList.toggle("hidden",type!=="multiple_choice");
  $("#puzzle-tolerance-wrap").classList.toggle("hidden",type!=="numerical");
}
function editAdminPuzzle(p){
  editingPuzzleId=p.id;$("#puzzle-editor-title").textContent="Edit puzzle";
  $("#puzzle-room").value=p.room_name;$("#puzzle-title").value=p.title;$("#puzzle-prompt").value=p.prompt;
  $("#puzzle-type").value=p.answer_type;$("#puzzle-options").value=(p.options||[]).join("\n");
  $("#puzzle-answer").value=p.answer;$("#puzzle-tolerance").value=p.numeric_tolerance||0;
  $("#puzzle-hint-1").value=p.hint_1||"";$("#puzzle-hint-2").value=p.hint_2||"";$("#puzzle-hint-3").value=p.hint_3||"";
  $("#puzzle-xp").value=p.reward_xp;$("#puzzle-shards").value=p.reward_shards;$("#puzzle-active").checked=p.active;
  $("#puzzle-editor-title").textContent="Edit puzzle";$("#puzzle-save").textContent="Save changes";$("#puzzle-cancel").classList.remove("hidden");
  togglePuzzleFields();$("#puzzle-editor").scrollIntoView({behavior:"smooth",block:"start"});
}
$("#puzzle-type").addEventListener("change",togglePuzzleFields);
$("#puzzle-cancel").onclick=resetPuzzleEditor;
$("#puzzle-editor").onsubmit=async e=>{
  e.preventDefault();const button=$("#puzzle-save");button.disabled=true;button.textContent="Saving…";
  const type=$("#puzzle-type").value;
  const options=type==="multiple_choice"?$("#puzzle-options").value.split("\n").map(x=>x.trim()).filter(Boolean):[];
  const payload={p_id:editingPuzzleId,p_room_name:$("#puzzle-room").value,p_title:$("#puzzle-title").value,
    p_prompt:$("#puzzle-prompt").value,p_answer_type:type,p_options:options,p_answer:$("#puzzle-answer").value,
    p_numeric_tolerance:type==="numerical"?Number($("#puzzle-tolerance").value||0):0,
    p_hint_1:$("#puzzle-hint-1").value,p_hint_2:$("#puzzle-hint-2").value,p_hint_3:$("#puzzle-hint-3").value,
    p_reward_xp:Number($("#puzzle-xp").value||0),p_reward_shards:Number($("#puzzle-shards").value||0),
    p_active:$("#puzzle-active").checked};
  try{const {error}=await sb.rpc("admin_save_puzzle",payload);if(error)throw error;toast(editingPuzzleId?"Puzzle updated":"Puzzle created");resetPuzzleEditor();await loadAdminPuzzles()}
  catch(err){toast(err.message||"Could not save puzzle")}
  finally{button.disabled=false;button.textContent=editingPuzzleId?"Save changes":"Create puzzle"}
};
