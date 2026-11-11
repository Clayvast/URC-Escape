# URC Escape v2

## Included
- Polygon-shaped clickable areas mapped to the original 1728 x 1152 floor plan.
- Player and admin sign-in portals.
- Supabase username/password login (internally maps usernames to synthetic email addresses).
- Per-player room discovery and progress reads.
- Admin player-creation form with a secure Edge Function.
- SQL schema and basic row-level security.

## Local preview
Open this folder in VS Code. Because the JavaScript uses ES modules, serve it over localhost rather than opening the file directly. In a terminal in this folder run `python -m http.server 8000`, then visit `http://localhost:8000`.

## Supabase setup
1. Create a Supabase project.
2. In Project Settings -> API, copy the Project URL and anon/public key into `supabase-config.js`.
3. Never put the service_role key in the browser.
4. Run `supabase-setup.sql` in the Supabase SQL Editor. If the base setup has already been run, do not rerun it; apply only new feature migrations.
5. Create your first admin Auth user in Authentication -> Users. Use an email like `adminname@players.urcescape.invalid`, confirm it, and set a password.
6. Run `update public.profiles set role='admin' where username='adminname';` replacing the username.

## Puzzle system
After applying the base setup, run `puzzle-setup.sql` once in the Supabase SQL Editor. Puzzle answers are not readable by players: the browser receives prompts and hints, while a database function validates submitted answers and awards XP/key shards. Add puzzle records to `public.puzzles` through the Supabase Table Editor for now; the in-game admin editor is a later feature. The `room_name` must exactly match one of the floor-plan room names, and the player must have discovered that room before its puzzles appear.

## Room unlocking
After the base setup and puzzle migration, run `room-unlocking-setup.sql` once in the Supabase SQL Editor. It creates server-validated room unlock rules and the `unlock_room` RPC. The example progression starts at the player's configured starting room and uses key shards plus prerequisite rooms. Adjust `public.room_unlock_rules` in the Supabase Table Editor to change costs, prerequisites, or required item IDs. Players cannot directly insert discoveries or spend shards through the browser; unlocking is validated in the database.

## Admin player creation
Deploy `supabase/functions/admin-create-player/index.ts` as an Edge Function called `admin-create-player`. Supabase CLI steps:
- `supabase login`
- `supabase link --project-ref YOUR_PROJECT_REF`
- `supabase functions deploy admin-create-player`
Set Edge Function secrets: SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY. The service role key must only exist as a server-side secret.

## Publish online
1. Push this folder to a private GitHub repository.
2. In Vercel, import that repository. Choose Other as framework preset, leave build command blank and use `.` as output directory (static site).
3. Deploy; Vercel supplies an HTTPS address to share.
4. Set the Vercel URL as Site URL / Redirect URL in Supabase Authentication URL Configuration if required.

Players can then sign in from different computers. Their room discoveries are stored in Supabase, not on your computer, so your computer does not need to stay on.

## Current limitations
This is still an early prototype. It saves discovered rooms and reads XP/shards, but does not yet implement messaging, trading or advanced reward actions. These must be added with server-side validation and database policies before a public launch. The current room polygons are a first trace and may need small adjustments after you test them.