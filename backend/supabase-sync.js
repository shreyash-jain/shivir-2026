/* ------------------------------------------------------------------ *
 * Supabase sync — replaces the existing sync() block in index.html.
 *
 * Replace everything from `let syncing = false;` down to and including
 * `setInterval(sync, 25000);`
 *
 * Also add two fields to the setup screen (see SETUP PATCH at the bottom)
 * and run schema.sql in the Supabase SQL editor first.
 * ------------------------------------------------------------------ */

const BATCH = 200;        // rows per request; small enough to survive a weak signal
const TIMEOUT = 12000;    // a hung fetch on a dead network would block the queue forever

/* PostgREST wants bare column names, not the shape we keep on the phone. */
function toRow(s){
  return {
    uuid:         s.uuid,
    dedupe:       s.dedupe,
    code:         s.code,
    session_id:   s.sessionId,
    session_name: s.sessionName,
    venue:        s.venue,
    scanned_at:   s.at,
    day:          s.day,
    volunteer:    s.volunteer,
    device:       s.device,
    source:       s.source
  };
}

async function postBatch(rows){
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT);
  try{
    const res = await fetch(S.supaUrl.replace(/\/+$/,"") + "/rest/v1/scans", {
      method: "POST",
      signal: ctrl.signal,
      headers: {
        "Content-Type": "application/json",
        "apikey": S.supaKey,
        "Authorization": "Bearer " + S.supaKey,
        // A retry after a dropped response must be a no-op, not an error.
        "Prefer": "resolution=ignore-duplicates,return=minimal"
      },
      body: JSON.stringify(rows.map(toRow))
    });
    if (res.ok) return { ok:true };

    // 4xx means these rows will never be accepted - retrying forever would
    // wedge the queue behind them, so surface it instead of looping.
    const permanent = res.status >= 400 && res.status < 500 && res.status !== 429;
    return { ok:false, permanent, status:res.status, detail: await res.text().catch(()=> "") };
  }catch(e){
    return { ok:false, permanent:false, detail:String(e) };   // offline or timed out
  }finally{
    clearTimeout(timer);
  }
}

let syncing = false;
let lastSyncError = "";

async function sync(){
  if (syncing || !S.supaUrl || !S.supaKey || !navigator.onLine) return;
  syncing = true;
  try{
    const pending = (await allScans()).filter(s => !s.sent);
    for (let i = 0; i < pending.length; i += BATCH){
      const chunk = pending.slice(i, i + BATCH);
      const r = await postBatch(chunk);
      if (r.ok){
        lastSyncError = "";
        for (const s of chunk){ s.sent = 1; await tx("scans","readwrite", st => st.put(s)); }
      } else {
        lastSyncError = r.permanent
          ? `Server rejected ${chunk.length} scans (${r.status}). They are still saved on this phone.`
          : "No connection. Scans are saved and will send later.";
        break;              // keep order; try again on the next tick
      }
    }
  }catch(e){
    lastSyncError = "Sync failed. Scans are safe on this phone.";
  }
  syncing = false;
  refreshReview();
}

window.addEventListener("online", sync);
setInterval(sync, 25000);


/* ------------------------------------------------------------------ *
 * SETUP PATCH
 *
 * 1. In the Sync section of the setup screen, replace the single
 *    #endpoint field with these two:
 *
 *    <div class="field">
 *      <label for="supaUrl">Project URL</label>
 *      <input id="supaUrl" placeholder="https://xxxx.supabase.co" inputmode="url">
 *    </div>
 *    <div class="field">
 *      <label for="supaKey">Publishable key</label>
 *      <input id="supaKey" placeholder="sb_publishable_…">
 *    </div>
 *
 * 2. Replace the #endpoint listener with:
 *
 *    $("supaUrl").addEventListener("change", () => { S.supaUrl = $("supaUrl").value.trim(); persistCfg(); });
 *    $("supaKey").addEventListener("change", () => { S.supaKey = $("supaKey").value.trim(); persistCfg(); });
 *
 * 3. In persistCfg(), store supaUrl and supaKey instead of endpoint.
 *    In boot(), read them back and set the two input values.
 *
 * 4. In the shareCfg handler and the #cfg= importer, carry supaUrl and
 *    supaKey instead of endpoint — that way one setup link configures
 *    all 50 phones with the server details already filled in.
 *
 * 5. Show lastSyncError in the Review sheet so a volunteer can see that
 *    scans are queued rather than lost.
 * ------------------------------------------------------------------ */
