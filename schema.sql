-- Branchline: database schema for Supabase
-- Run this whole file once in Supabase: SQL Editor > New query > paste > Run.
--
-- Design:
--   * Three tables (projects, nodes, sessions). Row Level Security is ON and no
--     policy exists, so the browser can never read or write the tables directly.
--   * The browser only calls the functions at the bottom (through supabase.rpc).
--     Every function checks the caller's session token and enforces the rules:
--       - you can edit your own node and the nodes directly below you
--       - you can remove only nodes directly below you (their subtree goes too)
--       - sub-goals are returned only to their owner and to the people directly
--         below the owner, and only the ones marked "shared"
--       - PINs are stored as bcrypt hashes; 5 wrong PINs lock a node for 15 minutes

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- tables

create table if not exists public.projects (
  code        text primary key,
  name        text not null check (char_length(name) between 1 and 80),
  root_id     text,
  created_at  timestamptz not null default now()
);

create table if not exists public.nodes (
  id              text primary key,
  project_code    text not null references public.projects(code) on delete cascade,
  parent_id       text references public.nodes(id) on delete cascade,
  sort_order      integer not null default 0,
  name            text not null check (char_length(name) between 1 and 60),
  role            text not null check (char_length(role) between 1 and 60),
  pin_hash        text not null,
  goals           jsonb not null default '[]'::jsonb,
  subgoals        jsonb not null default '[]'::jsonb,
  failed_attempts integer not null default 0,
  locked_until    timestamptz,
  created_at      timestamptz not null default now()
);

create index if not exists nodes_project_idx on public.nodes (project_code);
create index if not exists nodes_parent_idx  on public.nodes (parent_id);
-- exactly one top node (level 1) per project
create unique index if not exists nodes_one_root_idx on public.nodes (project_code) where parent_id is null;

create table if not exists public.sessions (
  token       uuid primary key default gen_random_uuid(),
  node_id     text not null references public.nodes(id) on delete cascade,
  expires_at  timestamptz not null default now() + interval '30 days'
);
create index if not exists sessions_node_idx on public.sessions (node_id);

-- lock the tables: RLS on, no policies, no direct grants
alter table public.projects enable row level security;
alter table public.nodes    enable row level security;
alter table public.sessions enable row level security;
revoke all on table public.projects, public.nodes, public.sessions from anon, authenticated;

-- ---------------------------------------------------------------- internal helpers

create or replace function public._norm_goals(p jsonb) returns jsonb
language plpgsql set search_path = public, extensions as $$
begin
  if p is null or jsonb_typeof(p) <> 'array' then return '[]'::jsonb; end if;
  if jsonb_array_length(p) > 40 then raise exception 'Too many goals (the limit is 40).'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',   left(coalesce(nullif(e.v->>'id', ''), substr(md5(random()::text), 1, 8)), 40),
             'text', left(btrim(e.v->>'text'), 120),
             'pct',  least(100, greatest(0, coalesce(nullif(e.v->>'pct', '')::numeric, 0)))::int
           ) order by e.ord)
    from jsonb_array_elements(p) with ordinality as e(v, ord)
    where btrim(coalesce(e.v->>'text', '')) <> ''
  ), '[]'::jsonb);
end $$;

create or replace function public._norm_subgoals(p jsonb) returns jsonb
language plpgsql set search_path = public, extensions as $$
begin
  if p is null or jsonb_typeof(p) <> 'array' then return '[]'::jsonb; end if;
  if jsonb_array_length(p) > 200 then raise exception 'Too many sub-goals (the limit is 200).'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',     left(coalesce(nullif(e.v->>'id', ''), substr(md5(random()::text), 1, 8)), 40),
             'text',   left(btrim(e.v->>'text'), 140),
             'done',   coalesce((e.v->>'done')::boolean, false),
             'shared', coalesce((e.v->>'shared')::boolean, false)
           ) order by e.ord)
    from jsonb_array_elements(p) with ordinality as e(v, ord)
    where btrim(coalesce(e.v->>'text', '')) <> ''
  ), '[]'::jsonb);
end $$;

-- Resolves a session token to the signed-in node, or raises 'invalid_session'.
create or replace function public._me(p_token uuid) returns public.nodes
language plpgsql security definer set search_path = public, extensions as $$
declare r public.nodes;
begin
  select n.* into r
    from public.sessions s join public.nodes n on n.id = s.node_id
   where s.token = p_token and s.expires_at > now();
  if not found then raise exception 'invalid_session'; end if;
  return r;
end $$;

create or replace function public._new_node_id() returns text
language sql set search_path = public, extensions as $$
  select 'n' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)
$$;

-- ---------------------------------------------------------------- public functions

-- Create a project and its first node (level 1). Returns the project code, node id and a session token.
create or replace function public.create_project(
  p_name text, p_user_name text, p_role text, p_pin text, p_goals jsonb default '[]'::jsonb
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  alph constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text; v_id text; v_token uuid; i int;
begin
  p_name      := btrim(coalesce(p_name, ''));
  p_user_name := btrim(coalesce(p_user_name, ''));
  p_role      := btrim(coalesce(p_role, ''));
  if p_name = ''      then raise exception 'Enter a project name.'; end if;
  if p_user_name = '' then raise exception 'Enter your name.'; end if;
  if p_role = ''      then raise exception 'Enter your role.'; end if;
  if coalesce(p_pin, '') !~ '^\d{4,8}$' then raise exception 'The PIN must be 4 to 8 digits.'; end if;

  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(alph, 1 + (get_byte(gen_random_bytes(1), 0) % length(alph)), 1);
    end loop;
    exit when not exists (select 1 from public.projects where code = v_code);
  end loop;

  v_id := public._new_node_id();
  insert into public.projects (code, name, root_id) values (v_code, left(p_name, 80), v_id);
  insert into public.nodes (id, project_code, parent_id, sort_order, name, role, pin_hash, goals)
  values (v_id, v_code, null, 1, left(p_user_name, 60), left(p_role, 60),
          crypt(p_pin, gen_salt('bf')), public._norm_goals(p_goals));
  insert into public.sessions (node_id) values (v_id) returning token into v_token;

  return jsonb_build_object('code', v_code, 'node_id', v_id, 'token', v_token);
end $$;

-- What the "join" page needs before sign-in: project name and who is in the tree (no goals, no PINs).
create or replace function public.lookup_project(p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  select jsonb_build_object(
           'name', p.name,
           'root_id', p.root_id,
           'nodes', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'id', n.id, 'parent_id', n.parent_id, 'sort_order', n.sort_order,
                       'name', n.name, 'role', n.role) order by n.sort_order, n.name)
                from public.nodes n where n.project_code = p.code), '[]'::jsonb))
    into v
    from public.projects p
   where p.code = upper(btrim(coalesce(p_code, '')));
  return v;  -- null when the code does not exist
end $$;

-- Sign in to one node with its PIN. Returns {token} or {error}.
-- (Returns instead of raising, so the failed-attempt counter is not rolled back.)
create or replace function public.login(p_code text, p_node_id text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare n public.nodes; v_token uuid;
begin
  select * into n from public.nodes
   where id = p_node_id and project_code = upper(btrim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if n.locked_until is not null and n.locked_until > now() then
    return jsonb_build_object('error', 'locked');
  end if;

  if n.pin_hash = crypt(coalesce(p_pin, ''), n.pin_hash) then
    update public.nodes set failed_attempts = 0, locked_until = null where id = n.id;
    delete from public.sessions where expires_at < now();
    insert into public.sessions (node_id) values (n.id) returning token into v_token;
    return jsonb_build_object('token', v_token);
  end if;

  update public.nodes
     set failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end,
         locked_until    = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else null end
   where id = n.id;
  return jsonb_build_object('error', 'wrong_pin');
end $$;

create or replace function public.logout(p_token uuid) returns void
language sql security definer set search_path = public, extensions as $$
  delete from public.sessions where token = p_token;
$$;

-- The whole tree for the signed-in person. Sub-goals are filtered here, on the server:
--   own node            -> all sub-goals
--   the node directly above you -> only sub-goals marked shared
--   everyone else       -> none
create or replace function public.get_project(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare me public.nodes; v jsonb;
begin
  me := public._me(p_token);
  select jsonb_build_object(
           'code', p.code, 'name', p.name, 'root_id', p.root_id, 'me', me.id,
           'nodes', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'id', n.id, 'parent_id', n.parent_id, 'sort_order', n.sort_order,
                       'name', n.name, 'role', n.role, 'goals', n.goals,
                       'subgoals', case
                          when n.id = me.id then n.subgoals
                          when n.id = me.parent_id then coalesce((
                              select jsonb_agg(x.s order by x.o)
                                from jsonb_array_elements(n.subgoals) with ordinality as x(s, o)
                               where coalesce((x.s->>'shared')::boolean, false)), '[]'::jsonb)
                          else '[]'::jsonb end
                     ) order by n.sort_order, n.name)
                from public.nodes n where n.project_code = p.code), '[]'::jsonb))
    into v
    from public.projects p
   where p.code = me.project_code;
  return v;
end $$;

-- Change one goal's percentage. Allowed on your own node and on nodes directly below you.
create or replace function public.set_goal(p_token uuid, p_node_id text, p_goal_id text, p_pct int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.nodes; t public.nodes; v_pct int;
begin
  me := public._me(p_token);
  select * into t from public.nodes where id = p_node_id and project_code = me.project_code;
  if not found or not (t.id = me.id or coalesce(t.parent_id = me.id, false)) then
    raise exception 'You can only change your own node and the people directly below you.';
  end if;
  v_pct := least(100, greatest(0, coalesce(p_pct, 0)));
  update public.nodes nd
     set goals = coalesce((
           select jsonb_agg(case when g.v->>'id' = p_goal_id
                                 then jsonb_set(g.v, '{pct}', to_jsonb(v_pct)) else g.v end order by g.ord)
             from jsonb_array_elements(nd.goals) with ordinality as g(v, ord)), '[]'::jsonb)
   where nd.id = t.id;
end $$;

-- Replace the signed-in person's own sub-goals (nobody else can write them).
create or replace function public.save_my_subgoals(p_token uuid, p_subgoals jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.nodes;
begin
  me := public._me(p_token);
  update public.nodes set subgoals = public._norm_subgoals(p_subgoals) where id = me.id;
end $$;

-- Add a node directly below the signed-in person. Returns the new node id.
create or replace function public.add_node(
  p_token uuid, p_name text, p_role text, p_pin text, p_goals jsonb default '[]'::jsonb
) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare me public.nodes; v_id text; v_order int;
begin
  me := public._me(p_token);
  p_name := btrim(coalesce(p_name, ''));
  p_role := btrim(coalesce(p_role, ''));
  if p_name = '' then raise exception 'Enter a name.'; end if;
  if p_role = '' then raise exception 'Enter a role.'; end if;
  if coalesce(p_pin, '') !~ '^\d{4,8}$' then raise exception 'The PIN must be 4 to 8 digits.'; end if;
  if (select count(*) from public.nodes where project_code = me.project_code) >= 300 then
    raise exception 'This project has reached the limit of 300 nodes.';
  end if;

  select coalesce(max(sort_order), 0) + 1 into v_order from public.nodes where parent_id = me.id;
  v_id := public._new_node_id();
  insert into public.nodes (id, project_code, parent_id, sort_order, name, role, pin_hash, goals)
  values (v_id, me.project_code, me.id, v_order, left(p_name, 60), left(p_role, 60),
          crypt(p_pin, gen_salt('bf')), public._norm_goals(p_goals));
  return v_id;
end $$;

-- Edit your own node or a node directly below you. A null or empty PIN keeps the current PIN.
create or replace function public.update_node(
  p_token uuid, p_node_id text, p_name text, p_role text, p_goals jsonb, p_pin text default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.nodes; t public.nodes;
begin
  me := public._me(p_token);
  select * into t from public.nodes where id = p_node_id and project_code = me.project_code;
  if not found or not (t.id = me.id or coalesce(t.parent_id = me.id, false)) then
    raise exception 'You can only change your own node and the people directly below you.';
  end if;
  p_name := btrim(coalesce(p_name, ''));
  p_role := btrim(coalesce(p_role, ''));
  if p_name = '' then raise exception 'Enter a name.'; end if;
  if p_role = '' then raise exception 'Enter a role.'; end if;
  if coalesce(p_pin, '') <> '' and p_pin !~ '^\d{4,8}$' then raise exception 'The PIN must be 4 to 8 digits.'; end if;

  update public.nodes
     set name = left(p_name, 60),
         role = left(p_role, 60),
         goals = public._norm_goals(p_goals),
         pin_hash = case when coalesce(p_pin, '') <> '' then crypt(p_pin, gen_salt('bf')) else pin_hash end,
         failed_attempts = case when coalesce(p_pin, '') <> '' then 0 else failed_attempts end,
         locked_until    = case when coalesce(p_pin, '') <> '' then null else locked_until end
   where id = t.id;
end $$;

-- Remove a node directly below you, together with everyone below that node.
create or replace function public.remove_node(p_token uuid, p_node_id text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.nodes;
begin
  me := public._me(p_token);
  delete from public.nodes where id = p_node_id and parent_id = me.id and project_code = me.project_code;
  if not found then
    raise exception 'You can only remove people directly below you.';
  end if;
end $$;

-- ---------------------------------------------------------------- who may call what

revoke execute on function public._norm_goals(jsonb), public._norm_subgoals(jsonb),
                           public._me(uuid), public._new_node_id() from public, anon, authenticated;

revoke execute on function
  public.create_project(text, text, text, text, jsonb),
  public.lookup_project(text),
  public.login(text, text, text),
  public.logout(uuid),
  public.get_project(uuid),
  public.set_goal(uuid, text, text, int),
  public.save_my_subgoals(uuid, jsonb),
  public.add_node(uuid, text, text, text, jsonb),
  public.update_node(uuid, text, text, text, jsonb, text),
  public.remove_node(uuid, text)
from public;

grant execute on function
  public.create_project(text, text, text, text, jsonb),
  public.lookup_project(text),
  public.login(text, text, text),
  public.logout(uuid),
  public.get_project(uuid),
  public.set_goal(uuid, text, text, int),
  public.save_my_subgoals(uuid, jsonb),
  public.add_node(uuid, text, text, text, jsonb),
  public.update_node(uuid, text, text, text, jsonb, text),
  public.remove_node(uuid, text)
to anon, authenticated;

-- make the new functions visible to the Supabase API right away
notify pgrst, 'reload schema';

create or replace function public._in_subtree(p_root text, p_id text) returns boolean
language sql stable set search_path = public, extensions as $$
  with recursive up as (
    select id, parent_id from public.nodes where id = p_id
    union all
    select n.id, n.parent_id from public.nodes n join up u on n.id = u.parent_id
  )
  select exists (select 1 from up where id = p_root)
$$;

create or replace function public.move_node(p_token uuid, p_node_id text, p_new_parent_id text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.nodes; t public.nodes; np public.nodes; v_order int;
begin
  me := public._me(p_token);
  perform pg_advisory_xact_lock(hashtext(me.project_code));

  select * into t from public.nodes where id = p_node_id and project_code = me.project_code;
  if not found or t.id = me.id or not public._in_subtree(me.id, t.id) then
    raise exception 'You can only move people who are below you in the tree.';
  end if;

  select * into np from public.nodes where id = p_new_parent_id and project_code = me.project_code;
  if not found or not public._in_subtree(me.id, np.id) then
    raise exception 'Choose a new manager from your own part of the tree.';
  end if;
  if public._in_subtree(t.id, np.id) then
    raise exception 'A person cannot be moved under themselves or under someone who reports to them.';
  end if;
  if t.parent_id is not distinct from np.id then return; end if;

  select coalesce(max(sort_order), 0) + 1 into v_order from public.nodes where parent_id = np.id;
  update public.nodes set parent_id = np.id, sort_order = v_order where id = t.id;
end $$;

revoke execute on function public._in_subtree(text, text) from public, anon, authenticated;
revoke execute on function public.move_node(uuid, text, text) from public;
grant execute on function public.move_node(uuid, text, text) to anon, authenticated;
notify pgrst, 'reload schema';


create or replace function public._norm_goals(p jsonb) returns jsonb
language plpgsql set search_path = public, extensions as $$
begin
  if p is null or jsonb_typeof(p) <> 'array' then return '[]'::jsonb; end if;
  if jsonb_array_length(p) > 100 then raise exception 'Too many goals (the limit is 100).'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',       left(coalesce(nullif(e.v->>'id', ''), substr(md5(random()::text), 1, 8)), 40),
             'text',     left(btrim(e.v->>'text'), 120),
             'pct',      least(100, greatest(0, coalesce(nullif(e.v->>'pct', '')::numeric, 0)))::int,
             'category', left(btrim(coalesce(e.v->>'category', '')), 40)
           ) order by e.ord)
    from jsonb_array_elements(p) with ordinality as e(v, ord)
    where btrim(coalesce(e.v->>'text', '')) <> ''
  ), '[]'::jsonb);
end $$;


create table if not exists public.node_links (
  node_id     text primary key references public.nodes(id) on delete cascade,
  token_hash  text not null unique,
  expires_at  timestamptz not null,
  created_at  timestamptz not null default now()
);
alter table public.node_links enable row level security;
revoke all on table public.node_links from anon, authenticated;

create or replace function public.create_login_link(p_token uuid, p_node_id text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare me public.nodes; t public.nodes; v_raw text; v_exp timestamptz := now() + interval '7 days';
begin
  me := public._me(p_token);
  select * into t from public.nodes where id = p_node_id and project_code = me.project_code;
  if not found or t.parent_id is distinct from me.id then
    raise exception 'You can create login links only for people directly below you.';
  end if;
  v_raw := encode(gen_random_bytes(24), 'hex');
  insert into public.node_links (node_id, token_hash, expires_at)
  values (t.id, encode(digest(v_raw, 'sha256'), 'hex'), v_exp)
  on conflict (node_id) do update
    set token_hash = excluded.token_hash, expires_at = excluded.expires_at, created_at = now();
  return jsonb_build_object('link', v_raw, 'expires_at', v_exp);
end $$;

create or replace function public.login_with_link(p_link text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare l public.node_links; n public.nodes; v_token uuid;
begin
  if coalesce(p_link, '') !~* '^[0-9a-f]{32,64}$' then
    return jsonb_build_object('error', 'invalid_link');
  end if;
  select * into l from public.node_links
   where token_hash = encode(digest(lower(p_link), 'sha256'), 'hex') and expires_at > now();
  if not found then return jsonb_build_object('error', 'invalid_link'); end if;

  select * into n from public.nodes where id = l.node_id;
  update public.nodes set failed_attempts = 0, locked_until = null where id = n.id;
  delete from public.sessions where expires_at < now();
  insert into public.sessions (node_id) values (n.id) returning token into v_token;
  return jsonb_build_object('token', v_token, 'code', n.project_code, 'node_id', n.id);
end $$;

create or replace function public._drop_link_on_pin_change() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from public.node_links where node_id = new.id;
  return new;
end $$;

drop trigger if exists nodes_pin_change_drops_link on public.nodes;
create trigger nodes_pin_change_drops_link
  after update of pin_hash on public.nodes
  for each row when (old.pin_hash is distinct from new.pin_hash)
  execute function public._drop_link_on_pin_change();

revoke execute on function public._drop_link_on_pin_change() from public, anon, authenticated;
revoke execute on function public.create_login_link(uuid, text), public.login_with_link(text) from public;
grant execute on function public.create_login_link(uuid, text), public.login_with_link(text) to anon, authenticated;
notify pgrst, 'reload schema';
