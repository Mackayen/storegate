-- StoreGate 0004: rename two roles and let dispatch managers and procurement prepare movements
-- Run after 0001, 0002 and 0003. Safe to run once on a database that already holds data.

-- 1. Rename the roles. Existing users and past sign offs keep their role under the new name.
alter type public.app_role rename value 'supervisor' to 'dispatch_manager';
alter type public.app_role rename value 'manager' to 'procurement';

update public.signoff_steps set label = 'Dispatch manager check'
  where role = 'dispatch_manager' and label = 'Supervisor check';
update public.signoff_steps set label = 'Procurement approval'
  where role = 'procurement' and label = 'Manager approval';

-- Movements that are already in progress keep a copy of their sign off steps. Rename inside it too.
update public.movements
set steps_snapshot = replace(replace(replace(replace(steps_snapshot::text,
      '"supervisor"', '"dispatch_manager"'), '"manager"', '"procurement"'),
      'Supervisor check', 'Dispatch manager check'), 'Manager approval', 'Procurement approval')::jsonb
where steps_snapshot is not null;

-- 2. Gate pass codes can be read by the renamed roles.
drop policy gate_passes_read on public.gate_passes;
create policy gate_passes_read on public.gate_passes for select to authenticated
  using (
    public.has_any_role(array['admin', 'security', 'dispatch_manager', 'procurement'])
    or exists (select 1 from public.movements m where m.id = movement_id and m.created_by = auth.uid())
  );

-- 3. Who may prepare and submit a movement: storeman, dispatch manager and procurement (and admin).
create or replace function public.create_movement(
  p_type public.movement_type,
  p_from uuid,
  p_to uuid,
  p_counterparty text,
  p_vehicle text,
  p_driver text,
  p_notes text,
  p_lines jsonb
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_line jsonb;
  v_item uuid;
  v_qty numeric;
begin
  if not public.has_any_role(array['admin', 'storeman', 'dispatch_manager', 'procurement']) then
    raise exception 'Not allowed';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) not between 1 and 200 then
    raise exception 'Add between 1 and 200 lines';
  end if;
  if p_from is not null and not exists (select 1 from public.storerooms where id = p_from and active) then
    raise exception 'Invalid source storeroom';
  end if;
  if p_to is not null and not exists (select 1 from public.storerooms where id = p_to and active) then
    raise exception 'Invalid destination storeroom';
  end if;

  insert into public.movements (
    ref, type, from_storeroom_id, to_storeroom_id, counterparty, vehicle_reg, driver_name, notes, created_by
  ) values (
    'MV-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.movement_seq')::text, 6, '0'),
    p_type, p_from, p_to,
    nullif(trim(p_counterparty), ''), nullif(trim(p_vehicle), ''),
    nullif(trim(p_driver), ''), nullif(trim(p_notes), ''),
    auth.uid()
  ) returning id into v_id;

  for v_line in select e from jsonb_array_elements(p_lines) as t (e) loop
    v_item := (v_line ->> 'item_id')::uuid;
    v_qty := (v_line ->> 'qty')::numeric;
    if v_qty is null or v_qty <= 0 or v_qty > 1000000 then
      raise exception 'Quantities must be greater than zero';
    end if;
    if not exists (select 1 from public.items where id = v_item and active) then
      raise exception 'Unknown or inactive item';
    end if;
    insert into public.movement_lines (movement_id, item_id, qty) values (v_id, v_item, v_qty);
  end loop;

  return v_id;
end $$;

create or replace function public.submit_movement(p_id uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  m public.movements%rowtype;
  v_check text;
  v_sig text;
  v_steps jsonb;
  v_hash text;
  v_role public.app_role;
begin
  select * into m from public.movements where id = p_id for update;
  if not found or m.created_by <> auth.uid()
     or not public.has_any_role(array['admin', 'storeman', 'dispatch_manager', 'procurement']) then
    raise exception 'Not allowed';
  end if;
  if m.status <> 'draft' then
    raise exception 'Only drafts can be submitted';
  end if;
  if not exists (select 1 from public.movement_lines where movement_id = p_id) then
    raise exception 'The movement has no lines';
  end if;

  select storage_path into v_sig from public.user_signatures where user_id = auth.uid() and active;
  if v_sig is null then
    raise exception 'Draw your signature on your profile first';
  end if;

  v_check := public._check_pin(auth.uid(), p_pin);
  if v_check <> 'ok' then
    return jsonb_build_object('ok', false, 'error', v_check);
  end if;

  select jsonb_agg(jsonb_build_object('order', step_order, 'role', role, 'label', label) order by step_order)
    into v_steps from public.signoff_steps;
  if v_steps is null then
    raise exception 'No sign off steps are configured';
  end if;

  perform public._check_stock(p_id);
  v_hash := public._movement_hash(p_id);

  update public.movements
  set status = 'pending_signoff', submitted_at = now(), steps_snapshot = v_steps, content_hash = v_hash
  where id = p_id;

  insert into public.delivery_notes (movement_id, number, snapshot)
  select
    m.id,
    'DN-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.delivery_note_seq')::text, 6, '0'),
    jsonb_build_object(
      'movement_ref', m.ref,
      'type', m.type,
      'counterparty', m.counterparty,
      'vehicle_reg', m.vehicle_reg,
      'driver_name', m.driver_name,
      'notes', m.notes,
      'from', (select jsonb_build_object('code', s.code, 'name', s.name)
               from public.storerooms s where s.id = m.from_storeroom_id),
      'to', (select jsonb_build_object('code', s.code, 'name', s.name)
             from public.storerooms s where s.id = m.to_storeroom_id),
      'prepared_by', (select p.full_name from public.profiles p where p.id = m.created_by),
      'content_hash', v_hash,
      'lines', (select jsonb_agg(jsonb_build_object('sku', i.sku, 'name', i.name, 'unit', i.unit, 'qty', l.qty)
                                 order by i.sku)
                from public.movement_lines l join public.items i on i.id = l.item_id
                where l.movement_id = m.id)
    );

  select role into v_role from public.profiles where id = auth.uid();
  insert into public.signoffs (movement_id, step_order, step_label, role, user_id, signature_path, content_hash)
  values (p_id, 0, 'Prepared by', v_role, auth.uid(), v_sig, v_hash);

  perform public._notify(
    array[v_steps -> 0 ->> 'role'],
    'Sign off needed',
    m.ref || ' is waiting for: ' || (v_steps -> 0 ->> 'label'),
    p_id
  );

  return jsonb_build_object('ok', true);
end $$;
