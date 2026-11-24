-- RenewalWatch upgrade: calendar subscription + file attachments.
-- Paste into Supabase > SQL Editor > New query, then Run. Safe to run more than once.

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
