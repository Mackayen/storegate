-- StoreGate 0005: serial numbers, damaged flags, notes, write offs, replacements and stock search
-- Run after 0001 to 0004. Safe to run once on a database that already holds data.
--
-- Model
--   items.tracks_serials   an item that needs serial numbers (laptops, not bolts)
--   stock_units            one row per serial numbered unit: in stock, dispatched or written off
--   unit_events            append only history of each unit (received, damaged, note, written off ...)
--   movement_serials       the serial numbers on a movement. Part of the signed fingerprint.
-- Stock quantity stays in stock_levels. A serial tracked pile can hold more units than have a serial
-- recorded yet. Serials can be added later with add_serials().

alter table public.items add column tracks_serials boolean not null default false;

create type public.unit_status as enum ('in_stock', 'dispatched', 'written_off');

create table public.stock_units (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.items (id),
  storeroom_id uuid not null references public.storerooms (id),   -- where it is, or where it was last
  serial text not null check (char_length(serial) between 1 and 64 and serial !~ '[[:cntrl:]]'),
  status public.unit_status not null default 'in_stock',
  damaged boolean not null default false,
  note text check (note is null or char_length(note) <= 500),
  received_movement_id uuid references public.movements (id),
  last_movement_id uuid references public.movements (id),
  replaces_unit_id uuid references public.stock_units (id),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index stock_units_serial_unique on public.stock_units (item_id, lower(serial));
create unique index stock_units_one_replacement on public.stock_units (replaces_unit_id) where replaces_unit_id is not null;
create index stock_units_pile_idx on public.stock_units (storeroom_id, item_id, status);

create table public.unit_events (
  id bigint generated always as identity primary key,
  unit_id uuid not null references public.stock_units (id),
  at timestamptz not null default now(),
  actor uuid references public.profiles (id),
  kind text not null check (kind in
    ('received', 'serial_added', 'damaged', 'repaired', 'note', 'dispatched', 'transferred', 'written_off', 'replacement_added')),
  note text check (note is null or char_length(note) <= 500),
  movement_id uuid references public.movements (id)
);
create index unit_events_unit_idx on public.unit_events (unit_id, id);

create table public.movement_serials (
  id uuid primary key default gen_random_uuid(),
  movement_id uuid not null references public.movements (id) on delete cascade,
  item_id uuid not null references public.items (id),
  serial text not null check (char_length(serial) between 1 and 64 and serial !~ '[[:cntrl:]]'),
  unit_id uuid references public.stock_units (id)
);
create unique index movement_serials_unique on public.movement_serials (movement_id, item_id, lower(serial));
create index movement_serials_unit_idx on public.movement_serials (unit_id);

-- Records can never be edited away. Units are never deleted, only moved to written_off.
create trigger unit_events_append_only before update or delete on public.unit_events
  for each row execute function public.forbid_change();
create trigger unit_events_no_truncate before truncate on public.unit_events
  for each statement execute function public.forbid_change();
create trigger stock_units_no_delete before delete on public.stock_units
  for each row execute function public.forbid_change();
create trigger stock_units_no_truncate before truncate on public.stock_units
  for each statement execute function public.forbid_change();

-- Serial tracking cannot be switched off for an item that already has serial numbers on record.
create function public.items_serial_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.tracks_serials and not new.tracks_serials
     and exists (select 1 from public.stock_units where item_id = new.id) then
    raise exception 'This item has serial numbers on record, so serial tracking cannot be turned off';
  end if;
  return new;
end $$;
create trigger items_serial_guard before update on public.items
  for each row execute function public.items_serial_guard();

-- The stock history can now also hold write offs and replacements, which have no movement.
alter table public.stock_ledger alter column movement_id drop not null;
alter table public.stock_ledger add column kind text not null default 'movement'
  check (kind in ('movement', 'write_off', 'replacement'));
alter table public.stock_ledger add column unit_id uuid references public.stock_units (id);
alter table public.stock_ledger add column note text;
alter table public.stock_ledger add column created_by uuid references public.profiles (id);
alter table public.stock_ledger add constraint ledger_movement_or_kind
  check (movement_id is not null or kind <> 'movement');

-- Helpers ------------------------------------------------------------------

-- Turns a search term into a safe ILIKE pattern: % and _ typed by the user are matched literally.
create function public._like(p text) returns text
language sql immutable set search_path = '' as $$
  select '%' || replace(replace(replace(coalesce(p, ''), '\', '\\'), '%', '\%'), '_', '\_') || '%'
$$;

create function public._clean_serial(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare
  v text := regexp_replace(coalesce(p, ''), '^\s+|\s+$', '', 'g');
begin
  if v = '' or char_length(v) > 64 or v ~ '[[:cntrl:]]' then
    raise exception 'Invalid serial number';
  end if;
  return v;
end $$;

-- The fingerprint now also covers serial numbers. A movement without serials hashes exactly as before,
-- so movements already waiting for sign off stay valid.
create or replace function public._movement_hash(p_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select encode(extensions.digest(
    concat_ws('|',
      m.ref, m.type::text,
      coalesce(m.from_storeroom_id::text, ''), coalesce(m.to_storeroom_id::text, ''),
      coalesce(m.counterparty, ''), coalesce(m.vehicle_reg, ''), coalesce(m.driver_name, ''),
      (select coalesce(string_agg(l.item_id::text || ':' || l.qty::text, ',' order by l.item_id), '')
         from public.movement_lines l where l.movement_id = m.id),
      (select nullif(string_agg(s.item_id::text || ':' || lower(s.serial), ',' order by s.item_id, lower(s.serial)), '')
         from public.movement_serials s where s.movement_id = m.id)
    ), 'sha256'), 'hex')
  from public.movements m where m.id = p_id
$$;

-- Checks on the serial numbers of a movement. Reservations only matter when submitting: two movements
-- awaiting sign off cannot hold the same unit.
create function public._check_units(p_id uuid, p_reservations boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.movements%rowtype;
  r record;
begin
  select * into m from public.movements where id = p_id;
  if m.from_storeroom_id is not null then
    for r in
      select s.serial, u.id as unit_id, u.status, u.storeroom_id, u.damaged
      from public.movement_serials s left join public.stock_units u on u.id = s.unit_id
      where s.movement_id = p_id
    loop
      if r.unit_id is null or r.status <> 'in_stock' or r.storeroom_id <> m.from_storeroom_id then
        raise exception 'Serial % is no longer in stock in the source storeroom', r.serial;
      end if;
      if r.damaged then
        raise exception 'Serial % is flagged as damaged and cannot be sent', r.serial;
      end if;
      if p_reservations and exists (
        select 1 from public.movement_serials s2 join public.movements m2 on m2.id = s2.movement_id
        where s2.unit_id = r.unit_id and s2.movement_id <> p_id and m2.status = 'pending_signoff'
      ) then
        raise exception 'Serial % is already on another movement awaiting sign off', r.serial;
      end if;
    end loop;
  else
    for r in select s.serial, s.item_id from public.movement_serials s where s.movement_id = p_id loop
      if exists (
        select 1 from public.stock_units u
        where u.item_id = r.item_id and lower(u.serial) = lower(r.serial) and u.status <> 'dispatched'
      ) then
        raise exception 'Serial % is already on record', r.serial;
      end if;
    end loop;
  end if;
end $$;

-- Quantity checks and unit checks together. submit_movement calls this name.
alter function public._check_stock(uuid) rename to _check_stock_levels;
create function public._check_stock(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._check_stock_levels(p_id);
  perform public._check_units(p_id, true);
end $$;

-- Moves quantities (as before) and then the serial numbered units. sign_movement calls this name.
alter function public._apply_stock(uuid) rename to _apply_stock_levels;
create function public._apply_stock(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.movements%rowtype;
  r record;
  v_unit uuid;
begin
  select * into m from public.movements where id = p_id;
  perform public._check_units(p_id, false);
  perform public._apply_stock_levels(p_id);

  if m.from_storeroom_id is not null then
    for r in select s.unit_id from public.movement_serials s where s.movement_id = p_id loop
      if m.to_storeroom_id is null then
        update public.stock_units set status = 'dispatched', last_movement_id = p_id, updated_at = now()
        where id = r.unit_id;
        insert into public.unit_events (unit_id, actor, kind, movement_id) values (r.unit_id, auth.uid(), 'dispatched', p_id);
      else
        update public.stock_units set storeroom_id = m.to_storeroom_id, last_movement_id = p_id, updated_at = now()
        where id = r.unit_id;
        insert into public.unit_events (unit_id, actor, kind, movement_id) values (r.unit_id, auth.uid(), 'transferred', p_id);
      end if;
    end loop;
  else
    for r in select s.id as sid, s.item_id, s.serial from public.movement_serials s where s.movement_id = p_id loop
      select id into v_unit from public.stock_units where item_id = r.item_id and lower(serial) = lower(r.serial);
      if v_unit is not null then
        -- a unit that was dispatched earlier and has come back
        update public.stock_units
        set status = 'in_stock', storeroom_id = m.to_storeroom_id, damaged = false,
            received_movement_id = p_id, last_movement_id = p_id, updated_at = now()
        where id = v_unit;
      else
        insert into public.stock_units (item_id, storeroom_id, serial, received_movement_id, last_movement_id, created_by)
        values (r.item_id, m.to_storeroom_id, r.serial, p_id, p_id, m.created_by)
        returning id into v_unit;
      end if;
      update public.movement_serials set unit_id = v_unit where id = r.sid;
      insert into public.unit_events (unit_id, actor, kind, movement_id) values (v_unit, auth.uid(), 'received', p_id);
    end loop;
  end if;
end $$;

-- Movements with serial numbers --------------------------------------------
-- Lines may carry a "serials" list. Receiving: optional, at most the quantity. Dispatch and transfer:
-- exactly one in stock, working serial number for every unit that leaves.

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
  v_tracks boolean;
  v_serials jsonb;
  v_serial text;
  v_n int;
  v_seen text[];
  v_unit public.stock_units%rowtype;
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
    select tracks_serials into v_tracks from public.items where id = v_item and active;
    if not found then
      raise exception 'Unknown or inactive item';
    end if;
    insert into public.movement_lines (movement_id, item_id, qty) values (v_id, v_item, v_qty);

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
          insert into public.movement_serials (movement_id, item_id, serial) values (v_id, v_item, v_serial);
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
          values (v_id, v_item, v_unit.serial, v_unit.id);
        end if;
      end loop;
    end if;
  end loop;

  return v_id;
end $$;

-- Unit management: storeman and admin only ---------------------------------

create function public.add_serials(p_storeroom uuid, p_item uuid, p_serials text[]) returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_have numeric;
  v_known int;
  v_serial text;
  v_seen text[] := '{}';
  v_unit uuid;
  v_n int;
begin
  if not public.has_any_role(array['admin', 'storeman']) then
    raise exception 'Not allowed';
  end if;
  if not exists (select 1 from public.items where id = p_item and active and tracks_serials) then
    raise exception 'This item does not track serial numbers';
  end if;
  v_n := coalesce(array_length(p_serials, 1), 0);
  if v_n not between 1 and 200 then
    raise exception 'Add between 1 and 200 serial numbers';
  end if;
  select qty into v_have from public.stock_levels
  where storeroom_id = p_storeroom and item_id = p_item for update;
  if v_have is null or v_have <= 0 then
    raise exception 'There is no stock of this item in that storeroom';
  end if;
  select count(*) into v_known from public.stock_units
  where storeroom_id = p_storeroom and item_id = p_item and status = 'in_stock';
  if v_n > v_have - v_known then
    raise exception 'Only % units here still need a serial number', v_have - v_known;
  end if;

  foreach v_serial in array p_serials loop
    v_serial := public._clean_serial(v_serial);
    if lower(v_serial) = any (v_seen) then
      raise exception 'Serial % appears twice', v_serial;
    end if;
    v_seen := v_seen || lower(v_serial);
    if exists (select 1 from public.stock_units where item_id = p_item and lower(serial) = lower(v_serial)) then
      raise exception 'Serial % is already on record', v_serial;
    end if;
    insert into public.stock_units (item_id, storeroom_id, serial, created_by)
    values (p_item, p_storeroom, v_serial, auth.uid()) returning id into v_unit;
    insert into public.unit_events (unit_id, actor, kind) values (v_unit, auth.uid(), 'serial_added');
  end loop;
  perform public._audit('UNIT_SERIALS_ADDED', 'stock_units', p_item::text, jsonb_build_object('count', v_n, 'storeroom', p_storeroom));
  return v_n;
end $$;

create function public.flag_unit(p_unit uuid, p_damaged boolean, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  u public.stock_units%rowtype;
  v_note text := nullif(regexp_replace(coalesce(p_note, ''), '^\s+|\s+$', '', 'g'), '');
begin
  if not public.has_any_role(array['admin', 'storeman']) then
    raise exception 'Not allowed';
  end if;
  if p_damaged is null then
    raise exception 'Choose damaged or working';
  end if;
  if v_note is not null and char_length(v_note) > 500 then
    raise exception 'Keep the note to 500 characters';
  end if;
  select * into u from public.stock_units where id = p_unit for update;
  if not found then
    raise exception 'Unknown unit';
  end if;
  if u.status <> 'in_stock' then
    raise exception 'Only units in stock can be flagged';
  end if;
  if p_damaged and (v_note is null or char_length(v_note) < 3) then
    raise exception 'Write a note saying what is wrong';
  end if;
  update public.stock_units set damaged = p_damaged, note = coalesce(v_note, note), updated_at = now()
  where id = p_unit;
  insert into public.unit_events (unit_id, actor, kind, note)
  values (p_unit, auth.uid(), case when p_damaged then 'damaged' else 'repaired' end, v_note);
  perform public._audit(case when p_damaged then 'UNIT_DAMAGED' else 'UNIT_WORKING' end, 'stock_units', p_unit::text,
                        jsonb_build_object('note', v_note));
end $$;

create function public.add_unit_note(p_unit uuid, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_note text := regexp_replace(coalesce(p_note, ''), '^\s+|\s+$', '', 'g');
begin
  if not public.has_any_role(array['admin', 'storeman']) then
    raise exception 'Not allowed';
  end if;
  if char_length(v_note) not between 3 and 500 then
    raise exception 'Write a note of 3 to 500 characters';
  end if;
  update public.stock_units set note = v_note, updated_at = now() where id = p_unit;
  if not found then
    raise exception 'Unknown unit';
  end if;
  insert into public.unit_events (unit_id, actor, kind, note) values (p_unit, auth.uid(), 'note', v_note);
end $$;

create function public.write_off_unit(p_unit uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  u public.stock_units%rowtype;
  v_reason text := regexp_replace(coalesce(p_reason, ''), '^\s+|\s+$', '', 'g');
  v_bal numeric;
begin
  if not public.has_any_role(array['admin', 'storeman']) then
    raise exception 'Not allowed';
  end if;
  if char_length(v_reason) not between 3 and 500 then
    raise exception 'Give a reason of 3 to 500 characters';
  end if;
  select * into u from public.stock_units where id = p_unit for update;
  if not found then
    raise exception 'Unknown unit';
  end if;
  if u.status <> 'in_stock' then
    raise exception 'Only units in stock can be written off';
  end if;
  if exists (
    select 1 from public.movement_serials s join public.movements m on m.id = s.movement_id
    where s.unit_id = p_unit and m.status = 'pending_signoff'
  ) then
    raise exception 'This unit is on a movement awaiting sign off. Reject or finish that movement first';
  end if;
  update public.stock_levels set qty = qty - 1
  where storeroom_id = u.storeroom_id and item_id = u.item_id and qty >= 1
  returning qty into v_bal;
  if not found then
    raise exception 'The stock level does not cover this unit';
  end if;
  update public.stock_units set status = 'written_off', note = v_reason, updated_at = now() where id = p_unit;
  insert into public.stock_ledger (item_id, storeroom_id, delta, balance_after, kind, unit_id, note, created_by)
  values (u.item_id, u.storeroom_id, -1, v_bal, 'write_off', p_unit, v_reason, auth.uid());
  insert into public.unit_events (unit_id, actor, kind, note) values (p_unit, auth.uid(), 'written_off', v_reason);
  perform public._audit('UNIT_WRITTEN_OFF', 'stock_units', p_unit::text, jsonb_build_object('reason', v_reason));
end $$;

-- For stock without serial numbers, or the units in a serial pile that have no serial recorded yet.
create function public.write_off_stock(p_storeroom uuid, p_item uuid, p_qty numeric, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_reason text := regexp_replace(coalesce(p_reason, ''), '^\s+|\s+$', '', 'g');
  v_have numeric;
  v_serialised int;
  v_tracks boolean;
  v_bal numeric;
begin
  if not public.has_any_role(array['admin', 'storeman']) then
    raise exception 'Not allowed';
  end if;
  if p_qty is null or p_qty <= 0 or p_qty > 1000000 then
    raise exception 'Quantity must be greater than zero';
  end if;
  if char_length(v_reason) not between 3 and 500 then
    raise exception 'Give a reason of 3 to 500 characters';
  end if;
  select tracks_serials into v_tracks from public.items where id = p_item;
  if not found then
    raise exception 'Unknown item';
  end if;
  if v_tracks and p_qty <> trunc(p_qty) then
    raise exception 'Serial tracked items can only be written off in whole units';
  end if;
  select qty into v_have from public.stock_levels
  where storeroom_id = p_storeroom and item_id = p_item for update;
  if v_have is null then
    raise exception 'There is no stock of this item in that storeroom';
  end if;
  select count(*) into v_serialised from public.stock_units
  where storeroom_id = p_storeroom and item_id = p_item and status = 'in_stock';
  if p_qty > v_have - v_serialised then
    if v_tracks then
      raise exception 'Only % units without a serial number can be written off this way. Write off numbered units one by one',
        v_have - v_serialised;
    end if;
    raise exception 'Only % are in stock', v_have;
  end if;
  update public.stock_levels set qty = qty - p_qty
  where storeroom_id = p_storeroom and item_id = p_item returning qty into v_bal;
  insert into public.stock_ledger (item_id, storeroom_id, delta, balance_after, kind, note, created_by)
  values (p_item, p_storeroom, -p_qty, v_bal, 'write_off', v_reason, auth.uid());
  perform public._audit('STOCK_WRITTEN_OFF', 'stock_levels', p_item::text,
                        jsonb_build_object('storeroom', p_storeroom, 'qty', p_qty, 'reason', v_reason));
end $$;

-- Puts a replacement back into the same pile a written off unit came from. One replacement per unit.
create function public.add_replacement(p_unit uuid, p_serial text, p_note text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  old public.stock_units%rowtype;
  v_serial text;
  v_note text := nullif(regexp_replace(coalesce(p_note, ''), '^\s+|\s+$', '', 'g'), '');
  v_new uuid;
  v_bal numeric;
begin
  if not public.has_any_role(array['admin', 'storeman']) then
    raise exception 'Not allowed';
  end if;
  if v_note is not null and char_length(v_note) > 500 then
    raise exception 'Keep the note to 500 characters';
  end if;
  v_serial := public._clean_serial(p_serial);
  select * into old from public.stock_units where id = p_unit for update;
  if not found then
    raise exception 'Unknown unit';
  end if;
  if old.status <> 'written_off' then
    raise exception 'Only a written off unit can be replaced';
  end if;
  if exists (select 1 from public.stock_units where replaces_unit_id = p_unit) then
    raise exception 'This unit already has a replacement';
  end if;
  if exists (select 1 from public.stock_units where item_id = old.item_id and lower(serial) = lower(v_serial)) then
    raise exception 'Serial % is already on record', v_serial;
  end if;

  insert into public.stock_units (item_id, storeroom_id, serial, replaces_unit_id, note, created_by)
  values (old.item_id, old.storeroom_id, v_serial, p_unit, v_note, auth.uid())
  returning id into v_new;
  insert into public.stock_levels as s (storeroom_id, item_id, qty) values (old.storeroom_id, old.item_id, 1)
  on conflict (storeroom_id, item_id) do update set qty = s.qty + 1
  returning s.qty into v_bal;
  insert into public.stock_ledger (item_id, storeroom_id, delta, balance_after, kind, unit_id, note, created_by)
  values (old.item_id, old.storeroom_id, 1, v_bal, 'replacement', v_new, v_note, auth.uid());
  insert into public.unit_events (unit_id, actor, kind, note)
  values (v_new, auth.uid(), 'replacement_added', coalesce(v_note, 'Replaces ' || old.serial));
  insert into public.unit_events (unit_id, actor, kind, note)
  values (p_unit, auth.uid(), 'replacement_added', 'Replaced by ' || v_serial);
  perform public._audit('UNIT_REPLACED', 'stock_units', p_unit::text, jsonb_build_object('new_unit', v_new, 'serial', v_serial));
  return v_new;
end $$;

-- Search --------------------------------------------------------------------
-- Plain SQL with bound parameters. The search text is never joined into a query string, and % and _
-- typed by the user are matched literally. They run as the caller, so row level security still applies.

create function public.stock_piles(p_query text default null, p_storeroom uuid default null)
returns table (
  storeroom_id uuid, storeroom_code text, storeroom_name text,
  item_id uuid, sku text, item_name text, unit text, tracks_serials boolean,
  qty numeric, serialised int, damaged int, unassigned numeric
)
language sql stable set search_path = '' as $$
  select s.id, s.code, s.name, i.id, i.sku, i.name, i.unit, i.tracks_serials,
         l.qty,
         coalesce(u.n, 0)::int,
         coalesce(u.bad, 0)::int,
         case when i.tracks_serials then greatest(l.qty - coalesce(u.n, 0), 0) else 0 end
  from public.stock_levels l
  join public.storerooms s on s.id = l.storeroom_id
  join public.items i on i.id = l.item_id
  left join lateral (
    select count(*) as n, count(*) filter (where su.damaged) as bad
    from public.stock_units su
    where su.item_id = l.item_id and su.storeroom_id = l.storeroom_id and su.status = 'in_stock'
  ) u on true
  where l.qty > 0
    and (p_storeroom is null or l.storeroom_id = p_storeroom)
    and (
      nullif(btrim(coalesce(p_query, '')), '') is null
      or i.sku ilike public._like(btrim(p_query))
      or i.name ilike public._like(btrim(p_query))
      or coalesce(i.barcode, '') ilike public._like(btrim(p_query))
      or s.code ilike public._like(btrim(p_query))
      or s.name ilike public._like(btrim(p_query))
      or exists (
        select 1 from public.stock_units su2
        where su2.item_id = l.item_id and su2.storeroom_id = l.storeroom_id and su2.status = 'in_stock'
          and (su2.serial ilike public._like(btrim(p_query)) or coalesce(su2.note, '') ilike public._like(btrim(p_query)))
      )
    )
  order by s.code, i.sku
$$;

create function public.stock_units_search(
  p_query text default null, p_storeroom uuid default null, p_state text default 'in_stock',
  p_limit int default 200, p_offset int default 0
)
returns table (
  unit_id uuid, serial text, status public.unit_status, damaged boolean, note text,
  item_id uuid, sku text, item_name text,
  storeroom_id uuid, storeroom_code text, storeroom_name text,
  replaces_unit_id uuid, replaced boolean, updated_at timestamptz
)
language plpgsql stable set search_path = '' as $$
begin
  if p_state not in ('in_stock', 'working', 'damaged', 'written_off', 'dispatched', 'all') then
    raise exception 'Unknown state';
  end if;
  return query
  select u.id, u.serial, u.status, u.damaged, u.note,
         i.id, i.sku, i.name,
         s.id, s.code, s.name,
         u.replaces_unit_id,
         exists (select 1 from public.stock_units r where r.replaces_unit_id = u.id),
         u.updated_at
  from public.stock_units u
  join public.items i on i.id = u.item_id
  join public.storerooms s on s.id = u.storeroom_id
  where (p_storeroom is null or u.storeroom_id = p_storeroom)
    and (
      p_state = 'all'
      or (p_state = 'in_stock' and u.status = 'in_stock')
      or (p_state = 'working' and u.status = 'in_stock' and not u.damaged)
      or (p_state = 'damaged' and u.status = 'in_stock' and u.damaged)
      or (p_state = 'written_off' and u.status = 'written_off')
      or (p_state = 'dispatched' and u.status = 'dispatched')
    )
    and (
      nullif(btrim(coalesce(p_query, '')), '') is null
      or u.serial ilike public._like(btrim(p_query))
      or coalesce(u.note, '') ilike public._like(btrim(p_query))
      or i.sku ilike public._like(btrim(p_query))
      or i.name ilike public._like(btrim(p_query))
      or coalesce(i.barcode, '') ilike public._like(btrim(p_query))
      or s.code ilike public._like(btrim(p_query))
    )
  order by u.damaged desc, i.sku, u.serial
  limit least(greatest(coalesce(p_limit, 200), 1), 500)
  offset greatest(coalesce(p_offset, 0), 0);
end $$;

-- Delivery note and gate check now list the serial numbers on each line.
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
      'lines', (select jsonb_agg(jsonb_build_object('sku', i.sku, 'name', i.name, 'unit', i.unit, 'qty', l.qty, 'serials', (select coalesce(jsonb_agg(ms.serial order by lower(ms.serial)), '[]'::jsonb) from public.movement_serials ms where ms.movement_id = m.id and ms.item_id = l.item_id))
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

-- Access ----------------------------------------------------------------------

alter table public.stock_units enable row level security;
alter table public.unit_events enable row level security;
alter table public.movement_serials enable row level security;

create policy stock_units_read on public.stock_units for select to authenticated using (public.is_member());
create policy unit_events_read on public.unit_events for select to authenticated using (public.is_member());
create policy movement_serials_read on public.movement_serials for select to authenticated using (public.is_member());

-- Functions made after the blanket revoke in migration 3 start out callable by everyone, so close them.
revoke all on function public._like(text), public._clean_serial(text), public._check_units(uuid, boolean),
  public._check_stock(uuid), public._apply_stock(uuid), public._check_stock_levels(uuid), public._apply_stock_levels(uuid),
  public.add_serials(uuid, uuid, text[]), public.flag_unit(uuid, boolean, text), public.add_unit_note(uuid, text),
  public.write_off_unit(uuid, text), public.write_off_stock(uuid, uuid, numeric, text),
  public.add_replacement(uuid, text, text), public.stock_piles(text, uuid),
  public.stock_units_search(text, uuid, text, int, int)
  from public, anon, authenticated;

grant select on public.stock_units, public.unit_events, public.movement_serials to authenticated;

grant execute on function public._like(text) to authenticated;
grant execute on function public.add_serials(uuid, uuid, text[]) to authenticated;
grant execute on function public.flag_unit(uuid, boolean, text) to authenticated;
grant execute on function public.add_unit_note(uuid, text) to authenticated;
grant execute on function public.write_off_unit(uuid, text) to authenticated;
grant execute on function public.write_off_stock(uuid, uuid, numeric, text) to authenticated;
grant execute on function public.add_replacement(uuid, text, text) to authenticated;
grant execute on function public.stock_piles(text, uuid) to authenticated;
grant execute on function public.stock_units_search(text, uuid, text, int, int) to authenticated;

alter publication supabase_realtime add table public.stock_units;
