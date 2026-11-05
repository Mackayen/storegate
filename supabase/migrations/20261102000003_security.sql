-- StoreGate 0003: row level security, grants, storage, realtime
-- Principle: the browser can read what members are allowed to see. Almost nothing can be written
-- directly. Writes go through the functions in 0002.

-- Start from nothing -------------------------------------------------------

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from public, anon, authenticated;

-- Row level security on every table ----------------------------------------

alter table public.profiles enable row level security;
alter table public.user_pins enable row level security;          -- no policies: unreachable from the API
alter table public.user_signatures enable row level security;
alter table public.storerooms enable row level security;
alter table public.items enable row level security;
alter table public.stock_levels enable row level security;
alter table public.signoff_steps enable row level security;
alter table public.movements enable row level security;
alter table public.movement_lines enable row level security;
alter table public.signoffs enable row level security;
alter table public.delivery_notes enable row level security;
alter table public.gate_passes enable row level security;
alter table public.stock_ledger enable row level security;
alter table public.notifications enable row level security;
alter table public.audit_log enable row level security;

-- Read access ----------------------------------------------------------------

create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_member());
create policy signatures_read_own on public.user_signatures for select to authenticated
  using (user_id = auth.uid());
create policy storerooms_read on public.storerooms for select to authenticated using (public.is_member());
create policy items_read on public.items for select to authenticated using (public.is_member());
create policy stock_levels_read on public.stock_levels for select to authenticated using (public.is_member());
create policy steps_read on public.signoff_steps for select to authenticated using (public.is_member());
create policy movements_read on public.movements for select to authenticated using (public.is_member());
create policy lines_read on public.movement_lines for select to authenticated using (public.is_member());
create policy signoffs_read on public.signoffs for select to authenticated using (public.is_member());
create policy delivery_notes_read on public.delivery_notes for select to authenticated using (public.is_member());
create policy ledger_read on public.stock_ledger for select to authenticated using (public.is_member());

-- Gate pass codes are bearer secrets, so only people who need them can read them.
create policy gate_passes_read on public.gate_passes for select to authenticated
  using (
    public.has_any_role(array['admin', 'security', 'supervisor', 'manager'])
    or exists (select 1 from public.movements m where m.id = movement_id and m.created_by = auth.uid())
  );

create policy notifications_read on public.notifications for select to authenticated
  using (user_id = auth.uid());
create policy notifications_mark_read on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy audit_read on public.audit_log for select to authenticated
  using (public.has_any_role(array['admin']));

-- Direct writes (master data only) ------------------------------------------

create policy storerooms_insert on public.storerooms for insert to authenticated
  with check (public.has_any_role(array['admin']));
create policy storerooms_update on public.storerooms for update to authenticated
  using (public.has_any_role(array['admin'])) with check (public.has_any_role(array['admin']));

create policy items_insert on public.items for insert to authenticated
  with check (public.has_any_role(array['admin', 'storeman']));
create policy items_update on public.items for update to authenticated
  using (public.has_any_role(array['admin', 'storeman']))
  with check (public.has_any_role(array['admin', 'storeman']));

create policy steps_insert on public.signoff_steps for insert to authenticated
  with check (public.has_any_role(array['admin']));
create policy steps_update on public.signoff_steps for update to authenticated
  using (public.has_any_role(array['admin'])) with check (public.has_any_role(array['admin']));
create policy steps_delete on public.signoff_steps for delete to authenticated
  using (public.has_any_role(array['admin']));

-- Table grants ----------------------------------------------------------------

grant select on
  public.profiles, public.user_signatures, public.storerooms, public.items, public.stock_levels,
  public.signoff_steps, public.movements, public.movement_lines, public.signoffs,
  public.delivery_notes, public.gate_passes, public.stock_ledger, public.notifications, public.audit_log
to authenticated;

grant insert, update on public.storerooms, public.items to authenticated;
grant insert, update, delete on public.signoff_steps to authenticated;
grant update (read) on public.notifications to authenticated;

-- Function grants ---------------------------------------------------------------
-- Functions starting with an underscore are internal and are not granted to anyone.

grant execute on function public.is_member() to authenticated;
grant execute on function public.has_any_role(text[]) to authenticated;
grant execute on function public.create_movement(public.movement_type, uuid, uuid, text, text, text, text, jsonb) to authenticated;
grant execute on function public.submit_movement(uuid, text) to authenticated;
grant execute on function public.sign_movement(uuid, text) to authenticated;
grant execute on function public.reject_movement(uuid, text) to authenticated;
grant execute on function public.cancel_movement(uuid, text) to authenticated;
grant execute on function public.verify_gate_pass(text) to authenticated;
grant execute on function public.release_gate_pass(text) to authenticated;
grant execute on function public.my_security_status() to authenticated;
grant execute on function public.set_pin(text, text) to authenticated;
grant execute on function public.save_signature(text) to authenticated;
grant execute on function public.admin_list_users() to authenticated;
grant execute on function public.admin_update_user(uuid, text, public.app_role, boolean) to authenticated;
grant execute on function public.admin_reset_pin(uuid) to authenticated;

-- Signature storage --------------------------------------------------------------
-- Private bucket, PNG only, 200 KB. A user can only upload into their own folder and can never
-- overwrite or delete. A signature can be read by its owner, or by any member once it has been
-- used on a signed movement.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('signatures', 'signatures', false, 204800, array['image/png'])
on conflict (id) do update
  set public = false, file_size_limit = 204800, allowed_mime_types = array['image/png'];

create policy signatures_upload on storage.objects for insert to authenticated
  with check (
    bucket_id = 'signatures'
    and public.is_member()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy signatures_download on storage.objects for select to authenticated
  using (
    bucket_id = 'signatures'
    and public.is_member()
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (select 1 from public.signoffs s where s.signature_path = name)
    )
  );

-- Realtime (row level security still applies to what each user receives) -----------

alter publication supabase_realtime add table public.notifications, public.movements, public.stock_levels;
