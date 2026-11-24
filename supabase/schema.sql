-- RenewalWatch database setup.
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
-- Safe to run on a brand new project.

create extension if not exists pgcrypto;

-- ============ TABLES ============

create table if not exists public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'My Company',
  plan text not null default 'free' check (plan in ('free', 'pro')),
  stripe_customer_id text,
  stripe_subscription_id text,
  reminder_days int[] not null default '{30,7}',
  notify_emails text[] not null default '{}',
  created_at timestamptz not null default now()
);

create table if not exists public.members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null,
  role text not null default 'member' check (role in ('owner', 'member')),
  created_at timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

create table if not exists public.invites (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  email text not null,
  created_at timestamptz not null default now(),
  primary key (workspace_id, email)
);

create table if not exists public.items (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  category text not null,
  name text not null check (char_length(name) between 1 and 200),
  vendor text,
  model text,
  serial text,
  asset_tag text,
  assigned_to text,
  location text,
  status text not null default 'active' check (status in ('active', 'spare', 'repair', 'retired')),
  purchase_date date,
  cost numeric(12,2),
  expiry_date date,
  renewal_cost numeric(12,2),
  billing_cycle text check (billing_cycle in ('one_time', 'monthly', 'annual', 'multi_year')),
  auto_renew boolean not null default false,
  recur_months int check (recur_months between 1 and 120),
  last_done date,
  notes text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists items_workspace_idx on public.items (workspace_id);
create index if not exists items_expiry_idx on public.items (expiry_date);
create index if not exists members_user_idx on public.members (user_id);
create index if not exists workspaces_customer_idx on public.workspaces (stripe_customer_id);

-- ============ HELPERS ============

create or replace function public.is_member(ws uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where workspace_id = ws and user_id = auth.uid());
$$;

create or replace function public.is_owner(ws uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where workspace_id = ws and user_id = auth.uid() and role = 'owner');
$$;

create or replace function public.workspace_plan(ws uuid) returns text
language sql stable security definer set search_path = public as $$
  select plan from workspaces where id = ws;
$$;

-- ============ ROW LEVEL SECURITY ============

alter table public.workspaces enable row level security;
alter table public.members enable row level security;
alter table public.invites enable row level security;
alter table public.items enable row level security;

drop policy if exists ws_select on public.workspaces;
create policy ws_select on public.workspaces for select using (public.is_member(id));
drop policy if exists ws_update on public.workspaces;
create policy ws_update on public.workspaces for update using (public.is_owner(id)) with check (public.is_owner(id));

-- Users can only change these columns. Plan and Stripe fields are set by the server only.
revoke insert, update, delete on public.workspaces from anon, authenticated;
grant select on public.workspaces to authenticated;
grant update (name, reminder_days, notify_emails) on public.workspaces to authenticated;

drop policy if exists members_select on public.members;
create policy members_select on public.members for select using (public.is_member(workspace_id));
drop policy if exists members_delete on public.members;
create policy members_delete on public.members for delete using (public.is_owner(workspace_id) and role <> 'owner');
revoke insert, update on public.members from anon, authenticated;

drop policy if exists invites_select on public.invites;
create policy invites_select on public.invites for select using (public.is_member(workspace_id));
drop policy if exists invites_insert on public.invites;
create policy invites_insert on public.invites for insert
  with check (public.is_owner(workspace_id) and public.workspace_plan(workspace_id) = 'pro');
drop policy if exists invites_delete on public.invites;
create policy invites_delete on public.invites for delete using (public.is_owner(workspace_id));

drop policy if exists items_all on public.items;
create policy items_all on public.items for all
  using (public.is_member(workspace_id)) with check (public.is_member(workspace_id));

-- ============ FREE PLAN LIMITS ============

create or replace function public.enforce_item_limits() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  p text;
  cnt int;
  free_cats text[] := array['computer','peripheral','printer','mobile','warranty','other_hw'];
begin
  new.updated_at := now();
  -- Let row level security reject non-members without revealing anything.
  if auth.uid() is not null and not is_member(new.workspace_id) then return new; end if;
  select plan into p from workspaces where id = new.workspace_id;
  if p = 'free' then
    if not (new.category = any(free_cats))
       and (tg_op = 'INSERT' or old.category is distinct from new.category) then
      raise exception 'PRO_CATEGORY: This category is part of the Pro plan.';
    end if;
    if tg_op = 'INSERT' then
      select count(*) into cnt from items where workspace_id = new.workspace_id;
      if cnt >= 25 then
        raise exception 'FREE_LIMIT: The free plan holds up to 25 items.';
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists items_limits on public.items;
create trigger items_limits before insert or update on public.items
  for each row execute function public.enforce_item_limits();

create or replace function public.enforce_workspace_settings() returns trigger
language plpgsql set search_path = public as $$
begin
  -- Custom reminder schedules and extra recipients are Pro features.
  -- Only applies to signed-in users; the server (service role) can change anything.
  if new.plan = 'free' and coalesce(auth.jwt() ->> 'role', '') = 'authenticated'
     and (new.reminder_days is distinct from old.reminder_days or new.notify_emails is distinct from old.notify_emails) then
    raise exception 'PRO_SETTING: Custom reminders are part of the Pro plan.';
  end if;
  return new;
end;
$$;

drop trigger if exists workspace_settings on public.workspaces;
create trigger workspace_settings before update on public.workspaces
  for each row execute function public.enforce_workspace_settings();

-- ============ SIGNUP AND INVITES ============

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare ws uuid;
begin
  insert into workspaces (name) values ('My Company') returning id into ws;
  insert into members (workspace_id, user_id, email, role) values (ws, new.id, lower(new.email), 'owner');
  -- Join any workspaces this email was invited to.
  insert into members (workspace_id, user_id, email, role)
    select i.workspace_id, new.id, lower(new.email), 'member' from invites i where lower(i.email) = lower(new.email)
    on conflict do nothing;
  delete from invites where lower(email) = lower(new.email);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Called by the app at login so existing users pick up new invites.
create or replace function public.accept_invites() returns void
language plpgsql security definer set search_path = public as $$
declare em text := lower(auth.jwt() ->> 'email');
begin
  if auth.uid() is null or em is null then return; end if;
  insert into members (workspace_id, user_id, email, role)
    select i.workspace_id, auth.uid(), em, 'member' from invites i where lower(i.email) = em
    on conflict do nothing;
  delete from invites where lower(email) = em;
end;
$$;

grant execute on function public.accept_invites() to authenticated;

-- ============ TABLE ACCESS ============
-- Newer Supabase projects don't grant table access automatically, so grant it explicitly.
-- Row level security above still limits each user to their own workspace.
grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on public.items to authenticated;
grant select, delete on public.members to authenticated;
grant select, insert, delete on public.invites to authenticated;
grant select on public.workspaces to authenticated;
grant update (name, reminder_days, notify_emails) on public.workspaces to authenticated;
grant all on public.workspaces, public.members, public.invites, public.items to service_role;
grant execute on function public.is_member(uuid), public.is_owner(uuid), public.workspace_plan(uuid), public.accept_invites() to authenticated, service_role;

-- ============ CALENDAR AND ATTACHMENTS ============
-- Calendar: a secret link per workspace
alter table public.workspaces add column if not exists calendar_token uuid not null default gen_random_uuid();
create unique index if not exists workspaces_calendar_token_idx on public.workspaces (calendar_token);
grant update (name, reminder_days, notify_emails, calendar_token) on public.workspaces to authenticated;

-- Attachments: private storage, files saved as <workspace id>/<item id>/<file name>
create or replace function public.path_workspace(p text) returns uuid
language plpgsql immutable as $$
begin
  return split_part(p, '/', 1)::uuid;
exception when others then
  return null;
end;
$$;
grant execute on function public.path_workspace(text) to authenticated, service_role;

insert into storage.buckets (id, name, public, file_size_limit)
values ('attachments', 'attachments', false, 10485760)
on conflict (id) do update set public = false, file_size_limit = 10485760;

drop policy if exists rw_attach_select on storage.objects;
create policy rw_attach_select on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and public.is_member(public.path_workspace(name)));

drop policy if exists rw_attach_insert on storage.objects;
create policy rw_attach_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments'
    and public.is_member(public.path_workspace(name))
    and public.workspace_plan(public.path_workspace(name)) = 'pro');

drop policy if exists rw_attach_delete on storage.objects;
create policy rw_attach_delete on storage.objects for delete to authenticated
  using (bucket_id = 'attachments' and public.is_member(public.path_workspace(name)));

-- ============ HISTORY AND VALUE ============
-- Useful life in years, for working out current value
alter table public.items add column if not exists useful_life_years int check (useful_life_years between 1 and 30);

-- History of who had each item, status and location changes
create table if not exists public.item_events (
  id bigint generated always as identity primary key,
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  item_id uuid not null references public.items(id) on delete cascade,
  kind text not null check (kind in ('created', 'assigned', 'status', 'location')),
  from_value text,
  to_value text,
  actor text,
  created_at timestamptz not null default now()
);
create index if not exists item_events_item_idx on public.item_events (item_id, created_at desc);

alter table public.item_events enable row level security;
drop policy if exists events_select on public.item_events;
create policy events_select on public.item_events for select using (public.is_member(workspace_id));
revoke insert, update, delete on public.item_events from anon, authenticated;
grant select on public.item_events to authenticated;
grant all on public.item_events to service_role;

create or replace function public.log_item_events() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text := coalesce(auth.jwt() ->> 'email', 'RenewalWatch');
begin
  if tg_op = 'INSERT' then
    insert into item_events (workspace_id, item_id, kind, to_value, actor)
      values (new.workspace_id, new.id, 'created', new.assigned_to, who);
    return new;
  end if;
  if lower(coalesce(trim(new.assigned_to), '')) is distinct from lower(coalesce(trim(old.assigned_to), '')) then
    insert into item_events (workspace_id, item_id, kind, from_value, to_value, actor)
      values (new.workspace_id, new.id, 'assigned', old.assigned_to, new.assigned_to, who);
  end if;
  if new.status is distinct from old.status then
    insert into item_events (workspace_id, item_id, kind, from_value, to_value, actor)
      values (new.workspace_id, new.id, 'status', old.status, new.status, who);
  end if;
  if lower(coalesce(trim(new.location), '')) is distinct from lower(coalesce(trim(old.location), '')) then
    insert into item_events (workspace_id, item_id, kind, from_value, to_value, actor)
      values (new.workspace_id, new.id, 'location', old.location, new.location, who);
  end if;
  return new;
end;
$$;

drop trigger if exists items_history on public.items;
create trigger items_history after insert or update on public.items
  for each row execute function public.log_item_events();
