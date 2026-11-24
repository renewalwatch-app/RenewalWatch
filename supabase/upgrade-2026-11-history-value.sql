-- RenewalWatch upgrade: assignment history + equipment value (depreciation).
-- Paste into Supabase > SQL Editor > New query, then Run. Safe to run more than once.

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
