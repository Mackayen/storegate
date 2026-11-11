-- StoreGate 0006: edit delivery note details, delivery address, edit drafts
-- Run after 0001 to 0005.
--
-- Rules
--   Details (supplier or customer, delivery address, vehicle, driver, notes) can be edited at any time
--   after a movement exists, until it is rejected or cancelled. Every change is kept in movement_edits.
--   Items, quantities and serial numbers can only be changed while the movement is still a draft.
--   After submit they are signed, so they are locked. To change them, reject or cancel and start again.
-- The signed fingerprint now covers only what moves stock (type, storerooms, items, quantities, serials).
-- Details are not part of it, so editing a vehicle or address does not invalidate signatures.

alter table public.movements add column delivery_address text
  check (delivery_address is null or char_length(delivery_address) <= 500);

create table public.movement_edits (
  id bigint generated always as identity primary key,
  movement_id uuid not null references public.movements (id),
  at timestamptz not null default now(),
  actor uuid references public.profiles (id),
  kind text not null check (kind in ('details', 'items')),
  changes jsonb not null default '{}'::jsonb
);
create index movement_edits_movement_idx on public.movement_edits (movement_id, id);
create trigger movement_edits_append_only before update or delete on public.movement_edits
  for each row execute function public.forbid_change();
create trigger movement_edits_no_truncate before truncate on public.movement_edits
  for each statement execute function public.forbid_change();

-- Fingerprint without the editable details.
create or replace function public._movement_hash(p_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select encode(extensions.digest(
    concat_ws('|',
      m.ref, m.type::text,
      coalesce(m.from_storeroom_id::text, ''), coalesce(m.to_storeroom_id::text, ''),
      (select coalesce(string_agg(l.item_id::text || ':' || l.qty::text, ',' order by l.item_id), '')
         from public.movement_lines l where l.movement_id = m.id),
      (select nullif(string_agg(s.item_id::text || ':' || lower(s.serial), ',' order by s.item_id, lower(s.serial)), '')
         from public.movement_serials s where s.movement_id = m.id)
    ), 'sha256'), 'hex')
  from public.movements m where m.id = p_id
$$;

-- Movements already waiting for sign off were fingerprinted with the old definition. Re-stamp them once
-- from their current, unchanged content so they can still be signed. Earlier signatures keep the hash
-- they were made with.
update public.movements set content_hash = public._movement_hash(id)
where status = 'pending_signoff';

-- The line checks of create_movement, now shared with draft editing ---------------------------

create function public._save_lines(p_id uuid, p_from uuid, p_lines jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_line jsonb;
  v_item uuid;
  v_qty numeric;
  v_tracks boolean;
  v_serials jsonb;
  v_serial text;
  v_n int;
  v_seen text[];
  v_unit public.stock_units%rowtype;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) not between 1 and 200 then
    raise exception 'Add between 1 and 200 lines';
  end if;

  for v_line in select e from jsonb_array_elements(p_lines) as t (e) loop
    v_item := (v_line ->> 'item_id')::uuid;
    v_qty := (v_line ->> 'qty')::numeric;
    if v_qty is null or v_qty <= 0 or v_qty > 1000000 then
      raise exception 'Quantities must be greater than zero';
    end if;
    select tracks_serials into v_tracks from public.items where id = v_item and active;
    if not found then
      raise exception 'Unknown or inactive item';
    end if;
    if exists (select 1 from public.movement_lines where movement_id = p_id and item_id = v_item) then
      raise exception 'An item can only appear once. Combine the quantities';
    end if;
    insert into public.movement_lines (movement_id, item_id, qty) values (p_id, v_item, v_qty);

    v_serials := coalesce(v_line -> 'serials', '[]'::jsonb);
    if jsonb_typeof(v_serials) <> 'array' then
      raise exception 'Serial numbers must be a list';
    end if;
    v_n := jsonb_array_length(v_serials);
    if v_n > 0 and not v_tracks then
      raise exception 'This item does not track serial numbers';
    end if;

    if v_tracks then
      if v_qty <> trunc(v_qty) then
        raise exception 'Serial tracked items can only move in whole units';
      end if;
      if p_from is not null and v_n <> v_qty then
        raise exception 'Scan a serial number for every unit that leaves (% units, % serial numbers)', trunc(v_qty), v_n;
      end if;
      if v_n > v_qty then
        raise exception 'There are more serial numbers than units';
      end if;
      v_seen := '{}';
      for v_serial in select jsonb_array_elements_text(v_serials) loop
        v_serial := public._clean_serial(v_serial);
        if lower(v_serial) = any (v_seen) then
          raise exception 'Serial % appears twice', v_serial;
        end if;
        v_seen := v_seen || lower(v_serial);

        if p_from is null then
          if exists (
            select 1 from public.stock_units
            where item_id = v_item and lower(serial) = lower(v_serial) and status <> 'dispatched'
          ) then
            raise exception 'Serial % is already on record', v_serial;
          end if;
          insert into public.movement_serials (movement_id, item_id, serial) values (p_id, v_item, v_serial);
        else
          select * into v_unit from public.stock_units
          where item_id = v_item and lower(serial) = lower(v_serial);
          if not found or v_unit.status <> 'in_stock' or v_unit.storeroom_id <> p_from then
            raise exception 'Serial % is not in stock in that storeroom', v_serial;
          end if;
          if v_unit.damaged then
            raise exception 'Serial % is flagged as damaged and cannot be sent', v_serial;
          end if;
          insert into public.movement_serials (movement_id, item_id, serial, unit_id)
          values (p_id, v_item, v_unit.serial, v_unit.id);
        end if;
      end loop;
    end if;
  end loop;
end $$;

-- create_movement gains an optional delivery address. The old signature is replaced.
drop function public.create_movement(public.movement_type, uuid, uuid, text, text, text, text, jsonb);
create function public.create_movement(
  p_type public.movement_type,
  p_from uuid,
  p_to uuid,
  p_counterparty text,
  p_vehicle text,
  p_driver text,
  p_notes text,
  p_lines jsonb,
  p_address text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  if not public.has_any_role(array['admin', 'storeman', 'dispatch_manager', 'procurement']) then
    raise exception 'Not allowed';
  end if;
  if p_from is not null and not exists (select 1 from public.storerooms where id = p_from and active) then
    raise exception 'Invalid source storeroom';
  end if;
  if p_to is not null and not exists (select 1 from public.storerooms where id = p_to and active) then
    raise exception 'Invalid destination storeroom';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) not between 1 and 200 then
    raise exception 'Add between 1 and 200 lines';
  end if;

  insert into public.movements (
    ref, type, from_storeroom_id, to_storeroom_id, counterparty, delivery_address, vehicle_reg, driver_name, notes, created_by
  ) values (
    'MV-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.movement_seq')::text, 6, '0'),
    p_type, p_from, p_to,
    nullif(trim(p_counterparty), ''), nullif(trim(p_address), ''), nullif(trim(p_vehicle), ''),
    nullif(trim(p_driver), ''), nullif(trim(p_notes), ''),
    auth.uid()
  ) returning id into v_id;

  perform public._save_lines(v_id, p_from, p_lines);
  return v_id;
end $$;

-- Replace the items on a draft. Only the person who made it, or an admin.
create function public.edit_draft_items(p_id uuid, p_lines jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.movements%rowtype;
begin
  select * into m from public.movements where id = p_id for update;
  if not found or not public.has_any_role(array['admin', 'storeman', 'dispatch_manager', 'procurement'])
     or (m.created_by <> auth.uid() and not public.has_any_role(array['admin'])) then
    raise exception 'Not allowed';
  end if;
  if m.status <> 'draft' then
    raise exception 'Items are locked once a movement is submitted. Reject or cancel it and start again';
  end if;
  delete from public.movement_serials where movement_id = p_id;
  delete from public.movement_lines where movement_id = p_id;
  perform public._save_lines(p_id, m.from_storeroom_id, p_lines);
  insert into public.movement_edits (movement_id, actor, kind) values (p_id, auth.uid(), 'items');
end $$;

-- Edit the details that appear on the delivery note. Allowed at any stage except rejected or cancelled.
create function public.update_movement_details(
  p_id uuid, p_counterparty text, p_address text, p_vehicle text, p_driver text, p_notes text
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.movements%rowtype;
  v_cp text := nullif(trim(coalesce(p_counterparty, '')), '');
  v_ad text := nullif(trim(coalesce(p_address, '')), '');
  v_ve text := nullif(trim(coalesce(p_vehicle, '')), '');
  v_dr text := nullif(trim(coalesce(p_driver, '')), '');
  v_no text := nullif(trim(coalesce(p_notes, '')), '');
  v_changes jsonb := '{}'::jsonb;
begin
  if not public.has_any_role(array['admin', 'storeman', 'dispatch_manager', 'procurement']) then
    raise exception 'Not allowed';
  end if;
  select * into m from public.movements where id = p_id for update;
  if not found then
    raise exception 'Unknown movement';
  end if;
  if m.status in ('rejected', 'cancelled') then
    raise exception 'This movement is % and can no longer be edited', m.status;
  end if;
  if char_length(coalesce(v_cp, '')) > 200 or char_length(coalesce(v_ad, '')) > 500
     or char_length(coalesce(v_ve, '')) > 30 or char_length(coalesce(v_dr, '')) > 120
     or char_length(coalesce(v_no, '')) > 1000 then
    raise exception 'One of the fields is too long';
  end if;

  if v_cp is distinct from m.counterparty then
    v_changes := v_changes || jsonb_build_object('counterparty', jsonb_build_object('from', m.counterparty, 'to', v_cp));
  end if;
  if v_ad is distinct from m.delivery_address then
    v_changes := v_changes || jsonb_build_object('delivery_address', jsonb_build_object('from', m.delivery_address, 'to', v_ad));
  end if;
  if v_ve is distinct from m.vehicle_reg then
    v_changes := v_changes || jsonb_build_object('vehicle_reg', jsonb_build_object('from', m.vehicle_reg, 'to', v_ve));
  end if;
  if v_dr is distinct from m.driver_name then
    v_changes := v_changes || jsonb_build_object('driver_name', jsonb_build_object('from', m.driver_name, 'to', v_dr));
  end if;
  if v_no is distinct from m.notes then
    v_changes := v_changes || jsonb_build_object('notes', jsonb_build_object('from', m.notes, 'to', v_no));
  end if;
  if v_changes = '{}'::jsonb then
    return;
  end if;

  update public.movements
  set counterparty = v_cp, delivery_address = v_ad, vehicle_reg = v_ve, driver_name = v_dr, notes = v_no
  where id = p_id;
  insert into public.movement_edits (movement_id, actor, kind, changes) values (p_id, auth.uid(), 'details', v_changes);
  perform public._audit('MOVEMENT_DETAILS_EDITED', 'movements', p_id::text, v_changes);
end $$;

-- The gate check shows the current address and details, so an edit after sign off reaches the guard.
create or replace function public.verify_gate_pass(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  g public.gate_passes%rowtype;
  m public.movements%rowtype;
begin
  if not public.has_any_role(array['admin', 'security']) then
    raise exception 'Not allowed';
  end if;
  if p_code is null or p_code !~ '^[0-9a-f]{32}$' then
    return jsonb_build_object('found', false);
  end if;
  select * into g from public.gate_passes where code = p_code;
  if not found then
    perform public._audit('GATE_SCAN_UNKNOWN', 'gate_passes', '', jsonb_build_object('prefix', left(p_code, 6)));
    return jsonb_build_object('found', false);
  end if;
  select * into m from public.movements where id = g.movement_id;
  perform public._audit('GATE_SCAN', 'gate_passes', g.id::text);
  return jsonb_build_object(
    'found', true,
    'status', g.status,
    'pass_number', g.number,
    'issued_at', g.issued_at,
    'used_at', g.used_at,
    'movement_ref', m.ref,
    'type', m.type,
    'vehicle_reg', m.vehicle_reg,
    'driver_name', m.driver_name,
    'counterparty', m.counterparty,
    'delivery_address', m.delivery_address,
    'edited', exists (select 1 from public.movement_edits e where e.movement_id = m.id and e.kind = 'details'),
    'lines', (select jsonb_agg(jsonb_build_object('sku', i.sku, 'name', i.name, 'unit', i.unit, 'qty', l.qty, 'serials', (select coalesce(jsonb_agg(ms.serial order by lower(ms.serial)), '[]'::jsonb) from public.movement_serials ms where ms.movement_id = m.id and ms.item_id = l.item_id))
                               order by i.sku)
              from public.movement_lines l join public.items i on i.id = l.item_id
              where l.movement_id = m.id),
    'signed_by', (select jsonb_agg(jsonb_build_object('label', s.step_label, 'name', p.full_name, 'at', s.signed_at)
                                    order by s.step_order)
                  from public.signoffs s join public.profiles p on p.id = s.user_id
                  where s.movement_id = m.id)
  );
end $$;

-- Access ---------------------------------------------------------------------------------------

alter table public.movement_edits enable row level security;
create policy movement_edits_read on public.movement_edits for select to authenticated using (public.is_member());

revoke all on function public._save_lines(uuid, uuid, jsonb),
  public.create_movement(public.movement_type, uuid, uuid, text, text, text, text, jsonb, text),
  public.edit_draft_items(uuid, jsonb),
  public.update_movement_details(uuid, text, text, text, text, text)
  from public, anon, authenticated;

grant select on public.movement_edits to authenticated;
grant execute on function public.create_movement(public.movement_type, uuid, uuid, text, text, text, text, jsonb, text) to authenticated;
grant execute on function public.edit_draft_items(uuid, jsonb) to authenticated;
grant execute on function public.update_movement_details(uuid, text, text, text, text, text) to authenticated;
