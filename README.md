# Branchline with Supabase

<b>Coment: For localy running and testing use https://kyiralogo.github.io/Branchline/Branchline.html</b>

Create with a purpose to see the bigger picture around your projects and to manage your teammates goals. 
Works like a project tree where every role is a node with a progress ring, a goal checklist and private sub-goals.
The project created for local use and for use with Suobase database. If you run Branchline.html, you are running app localy and you don't want to run localy but with base you need don't Branchline.html.

## Files

| File | What it is |
|---|---|
| `index.html` | The whole app. |
| `config.js` | Your Supabase URL and key. The only file you edit. |
| `supabase/schema.sql` | Tables, locks and the functions the app calls. Run once. |
| `supabase/seed-demo.sql` | Optional demo project (code `DEMO42`, every PIN is `1111`). |

## Set up Supabase (about 5 minutes)

1. **Create a project.** Go to supabase.com, sign in, choose New project, give it a name and a database password, pick the region closest to your team and wait until it finishes starting.
2. **Create the tables and functions.** In the left menu open **SQL Editor**, choose **New query**, paste the full content of `supabase/schema.sql` and press **Run**. It should end with "Success. No rows returned". You can run it again safely.
3. **Optional demo.** New query again, paste `supabase/seed-demo.sql`, Run. This adds a sample bridge project you can sign in to.
4. **Copy your keys.** Open **Project Settings, then API** (newer dashboards: the **Connect** button at the top). Copy:
   - **Project URL**, for example `https://abcdefghijkl.supabase.co`
   - the **anon public** key (labelled **Publishable key** in newer projects)
5. **Paste them into `config.js`:**
   ```js
   window.BRANCHLINE_CONFIG = {
     SUPABASE_URL: "https://abcdefghijkl.supabase.co",
     SUPABASE_ANON_KEY: "eyJ...your anon key...",
     DEMO_CODE: "DEMO42"   // only if you ran the demo seed, otherwise ""
   };
   ```
   Never paste the **service_role** / **secret** key here. It bypasses every lock.
6. **Leave everything else at the defaults.** The app does not use Supabase Auth, so you do not need to enable any sign-in provider. The Data API must stay enabled (it is by default) with the `public` schema exposed.

## Run it

- **On your computer:** double-click `index.html`.
- **For your team:** upload the folder (`index.html` and `config.js`) to any static host, for example Netlify (drag and drop the folder at app.netlify.com/drop), Vercel, Cloudflare Pages or GitHub Pages. Share the page address and the project code.

## How it works

1. A project manager chooses **Create a new project**, which creates the level 1 node and a 6-character project code.
2. They open **Manage team**, add people below them and set each person's PIN. They tell each person the code and the PIN.
3. Each person chooses **Join an existing project**, enters the code, picks their node and signs in with the PIN.
4. The tree refreshes every 8 seconds and when the tab becomes visible again.

## What the database enforces

The browser can't read or write the tables. It can only call the functions in `schema.sql`, and each one checks the caller:

- You can edit your own node and the nodes directly below you. You can remove only nodes directly below you (everyone under them goes too).
- Sub-goals are returned only to their owner and to the people directly below the owner, and only those marked Shared.
- PINs are stored as bcrypt hashes. Five wrong PINs lock that node for 15 minutes.
- A sign-in lasts 30 days and is kept in the browser. Signing out ends it.

## Good to know

- Anyone who has a project code can see the names and roles of that project's people on the sign-in page. Treat the code as semi-private.
- Anyone can create a new project. If the address is public and you want to prevent that, tell me and I will add an invite key.
- Supabase free projects pause after a week without activity. Open the dashboard and press Restore to wake it. Your data is kept.
- Your data is in the `projects` and `nodes` tables (Table Editor). Use Database, Backups for backups.

## Troubleshooting

| Message | Fix |
|---|---|
| "Connect Supabase first" page | `config.js` has no URL or key yet. |
| "The database functions are missing" | Run `supabase/schema.sql` (step 2). If you just ran it, wait a minute. |
| "Supabase rejected the key" | Copy the anon / publishable key again. No spaces or quotes inside the value. |
| "Could not reach Supabase" | Check the URL in `config.js` and that the project is not paused. |
