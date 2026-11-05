-- StoreGate 0002: workflow functions
-- All writes to movements, sign offs, stock, delivery notes and gate passes go through these
-- functions. They run as the table owner, check the caller's role themselves, and pin search_path.

-- Helpers ------------------------------------------------------------------

create function public.is_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active)
$$;

create function public.has_any_role(p_roles text[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and active and role::text = any (p_roles)
  )
$$;

create function public._audit(p_action text, p_table text, p_record text, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.audit_log (actor, action, table_name, record_id, details)
  values (auth.uid(), p_action, p_table, p_record, p_details)
$$;

create function public._notify(p_roles text[], p_title text, p_body text, p_movement uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.notifications (user_id, title, body, movement_id)
  select id, p_title, p_body, p_movement
  from public.profiles
  where active and role::text = any (p_roles) and id is distinct from auth.uid()
$$;

create function public._notify_user(p_user uuid, p_title text, p_body text, p_movement uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.notifications (user_id, title, body, movement_id)
  select id, p_title, p_body, p_movement from public.profiles where id = p_user and active
$$;

-- Returns 'ok', 'not_set', 'locked' or 'wrong'. Never raises, so the attempt counter is kept.
create function public._check_pin(p_user uuid, p_pin text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  r public.user_pins%rowtype;
begin
  select * into r from public.user_pins where user_id = p_user for update;
  if not found then
    return 'not_set';
  end if;
  if r.locked_until is not null and r.locked_until > now() then
    return 'locked';
  end if;
  if p_pin is not null and r.pin_hash = extensions.crypt(p_pin, r.pin_hash) then
    update public.user_pins set attempts = 0, locked_until = null where user_id = p_user;
    return 'ok';
  end if;
  update public.user_pins
  set attempts = case when attempts + 1 >= 5 then 0 else attempts + 1 end,
      locked_until = case when attempts + 1 >= 5 then now() + interval '15 minutes' else null end
  where user_id = p_user;
  return 'wrong';
end $$;

-- Hash of the parts of a movement that must not change after submission.
create function public._movement_hash(p_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select encode(extensions.digest(
    concat_ws('|',
      m.ref, m.type::text,
      coalesce(m.from_storeroom_id::text, ''), coalesce(m.to_storeroom_id::text, ''),
      coalesce(m.counterparty, ''), coalesce(m.vehicle_reg, ''), coalesce(m.driver_name, ''),
      (select coalesce(string_agg(l.item_id::text || ':' || l.qty::text, ',' order by l.item_id), '')
         from public.movement_lines l where l.movement_id = m.id)
    ), 'sha256'), 'hex')
  from public.movements m where m.id = p_id
$$;

create function public._check_stock(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r record;
begin
  for r in
    select i.sku, l.qty as need, coalesce(s.qty, 0) as have
    from public.movements m
    join public.movement_lines l on l.movement_id = m.id
    join public.items i on i.id = l.item_id
    left join public.stock_levels s
      on s.storeroom_id = m.from_storeroom_id and s.item_id = l.item_id
    where m.id = p_id and m.from_storeroom_id is not null and coalesce(s.qty, 0) < l.qty
  loop
    raise exception 'Insufficient stock for % (available %, needed %)', r.sku, r.have, r.need;
  end loop;
end $$;

create function public._apply_stock(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.movements%rowtype;
  l record;
  v_cur numeric;
  v_bal numeric;
begin
  select * into m from public.movements where id = p_id;
  for l in
    select ml.item_id, ml.qty, i.sku
    from public.movement_lines ml join public.items i on i.id = ml.item_id
    where ml.movement_id = p_id
    order by ml.item_id
  loop
    if m.from_storeroom_id is not null then
      select qty into v_cur from public.stock_levels
      where storeroom_id = m.from_storeroom_id and item_id = l.item_id for update;
      if v_cur is null or v_cur < l.qty then
        raise exception 'Insufficient stock for % (available %, needed %)', l.sku, coalesce(v_cur, 0), l.qty;
      end if;
      update public.stock_levels set qty = qty - l.qty
      where storeroom_id = m.from_storeroom_id and item_id = l.item_id
      returning qty into v_bal;
      insert into public.stock_ledger (movement_id, item_id, storeroom_id, delta, balance_after)
      values (p_id, l.item_id, m.from_storeroom_id, -l.qty, v_bal);
    end if;
    if m.to_storeroom_id is not null then
      insert into public.stock_levels as s (storeroom_id, item_id, qty)
      values (m.to_storeroom_id, l.item_id, l.qty)
      on conflict (storeroom_id, item_id) do update set qty = s.qty + excluded.qty
      returning s.qty into v_bal;
      insert into public.stock_ledger (movement_id, item_id, storeroom_id, delta, balance_after)
      values (p_id, l.item_id, m.to_storeroom_id, l.qty, v_bal);
    end if;
  end loop;
end $$;

-- Movements ----------------------------------------------------------------

create function public.create_movement(
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
  if not public.has_any_role(array['admin', 'storeman']) then
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

-- Prepared by signature. Creates the delivery note and starts the sign off chain.
create function public.submit_movement(p_id uuid, p_pin text) returns jsonb
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
     or not public.has_any_role(array['admin', 'storeman']) then
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

create function public.sign_movement(p_id uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  m public.movements%rowtype;
  v_role text;
  v_last int;
  v_step jsonb;
  v_next jsonb;
  v_sig text;
  v_check text;
begin
  select * into m from public.movements where id = p_id for update;
  if not found or not public.is_member() then
    raise exception 'Not allowed';
  end if;
  if m.status <> 'pending_signoff' then
    raise exception 'This movement is not waiting for sign off';
  end if;

  select role::text into v_role from public.profiles where id = auth.uid();
  select coalesce(max(step_order), 0) into v_last from public.signoffs where movement_id = p_id;

  select e into v_step
  from jsonb_array_elements(m.steps_snapshot) as t (e)
  where (e ->> 'order')::int > v_last
  order by (e ->> 'order')::int
  limit 1;
  if v_step is null then
    raise exception 'All steps are already signed';
  end if;

  if v_step ->> 'role' <> v_role then
    raise exception 'This step needs the % role', v_step ->> 'role';
  end if;
  if exists (select 1 from public.signoffs where movement_id = p_id and user_id = auth.uid()) then
    raise exception 'You have already signed this movement';
  end if;
  if public._movement_hash(p_id) is distinct from m.content_hash then
    raise exception 'The movement changed after it was submitted';
  end if;

  select storage_path into v_sig from public.user_signatures where user_id = auth.uid() and active;
  if v_sig is null then
    raise exception 'Draw your signature on your profile first';
  end if;

  v_check := public._check_pin(auth.uid(), p_pin);
  if v_check <> 'ok' then
    return jsonb_build_object('ok', false, 'error', v_check);
  end if;

  insert into public.signoffs (movement_id, step_order, step_label, role, user_id, signature_path, content_hash)
  values (p_id, (v_step ->> 'order')::int, v_step ->> 'label', (v_step ->> 'role')::public.app_role,
          auth.uid(), v_sig, m.content_hash);

  select e into v_next
  from jsonb_array_elements(m.steps_snapshot) as t (e)
  where (e ->> 'order')::int > (v_step ->> 'order')::int
  order by (e ->> 'order')::int
  limit 1;

  if v_next is not null then
    perform public._notify(
      array[v_next ->> 'role'], 'Sign off needed',
      m.ref || ' is waiting for: ' || (v_next ->> 'label'), p_id
    );
    return jsonb_build_object('ok', true, 'completed', false);
  end if;

  -- Last signature: move the stock, close the movement, issue the gate pass.
  perform public._apply_stock(p_id);
  update public.movements set status = 'signed_off', completed_at = now() where id = p_id;

  if m.type in ('receive', 'dispatch') then
    insert into public.gate_passes (movement_id, number, code)
    values (
      p_id,
      'GP-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.gate_pass_seq')::text, 6, '0'),
      encode(extensions.gen_random_bytes(16), 'hex')
    );
    perform public._notify(array['security'], 'Gate pass issued',
      m.ref || ' is fully signed off and cleared for the gate', p_id);
  end if;
  perform public._notify_user(m.created_by, 'Movement signed off', m.ref || ' is fully signed off', p_id);

  return jsonb_build_object('ok', true, 'completed', true);
end $$;

create function public.reject_movement(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.movements%rowtype;
  v_role text;
  v_last int;
  v_step jsonb;
begin
  if p_reason is null or char_length(trim(p_reason)) not between 3 and 500 then
    raise exception 'Give a reason of 3 to 500 characters';
  end if;
  select * into m from public.movements where id = p_id for update;
  if not found or not public.is_member() then
    raise exception 'Not allowed';
  end if;
  if m.status <> 'pending_signoff' then
    raise exception 'This movement is not waiting for sign off';
  end if;
  select role::text into v_role from public.profiles where id = auth.uid();
  select coalesce(max(step_order), 0) into v_last from public.signoffs where movement_id = p_id;
  select e into v_step
  from jsonb_array_elements(m.steps_snapshot) as t (e)
  where (e ->> 'order')::int > v_last
  order by (e ->> 'order')::int
  limit 1;
  if v_step is null or v_step ->> 'role' <> v_role then
    raise exception 'Only the next approver can reject';
  end if;

  update public.movements set status = 'rejected', rejection_reason = trim(p_reason) where id = p_id;
  perform public._notify_user(m.created_by, 'Movement rejected', m.ref || ': ' || trim(p_reason), p_id);
end $$;

create function public.cancel_movement(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.movements%rowtype;
begin
  select * into m from public.movements where id = p_id for update;
  if not found or not (m.created_by = auth.uid() or public.has_any_role(array['admin'])) then
    raise exception 'Not allowed';
  end if;
  if m.status not in ('draft', 'pending_signoff') then
    raise exception 'This movement can no longer be cancelled';
  end if;
  update public.movements
  set status = 'cancelled', rejection_reason = left(nullif(trim(p_reason), ''), 500)
  where id = p_id;
end $$;

-- Gate ---------------------------------------------------------------------

create function public.verify_gate_pass(p_code text) returns jsonb
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
    'lines', (select jsonb_agg(jsonb_build_object('sku', i.sku, 'name', i.name, 'unit', i.unit, 'qty', l.qty)
                               order by i.sku)
              from public.movement_lines l join public.items i on i.id = l.item_id
              where l.movement_id = m.id),
    'signed_by', (select jsonb_agg(jsonb_build_object('label', s.step_label, 'name', p.full_name, 'at', s.signed_at)
                                    order by s.step_order)
                  from public.signoffs s join public.profiles p on p.id = s.user_id
                  where s.movement_id = m.id)
  );
end $$;

create function public.release_gate_pass(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  if not public.has_any_role(array['admin', 'security']) then
    raise exception 'Not allowed';
  end if;
  if p_code is null or p_code !~ '^[0-9a-f]{32}$' then
    return jsonb_build_object('ok', false, 'error', 'not_available');
  end if;
  update public.gate_passes
  set status = 'used', used_at = now(), used_by = auth.uid()
  where code = p_code and status = 'issued'
  returning id into v_id;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_available');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Profile, PIN, signature --------------------------------------------------

create function public.my_security_status() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'has_pin', exists (select 1 from public.user_pins where user_id = auth.uid()),
    'has_signature', exists (select 1 from public.user_signatures where user_id = auth.uid() and active)
  )
$$;

create function public.set_pin(p_new text, p_current text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_check text;
begin
  if not public.is_member() then
    raise exception 'Not allowed';
  end if;
  if p_new is null or p_new !~ '^[0-9]{6}$' then
    raise exception 'The PIN must be exactly 6 digits';
  end if;
  if p_new ~ '^(.)\1{5}$' or p_new in ('123456', '654321', '012345', '123123') then
    raise exception 'Choose a PIN that is harder to guess';
  end if;
  if exists (select 1 from public.user_pins where user_id = auth.uid()) then
    v_check := public._check_pin(auth.uid(), p_current);
    if v_check <> 'ok' then
      return jsonb_build_object('ok', false, 'error', v_check);
    end if;
  end if;
  insert into public.user_pins (user_id, pin_hash)
  values (auth.uid(), extensions.crypt(p_new, extensions.gen_salt('bf', 10)))
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash, attempts = 0, locked_until = null, updated_at = now();
  perform public._audit('PIN_SET', 'user_pins', auth.uid()::text);
  return jsonb_build_object('ok', true);
end $$;

create function public.save_signature(p_path text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_member() then
    raise exception 'Not allowed';
  end if;
  if p_path is null or p_path !~ ('^' || auth.uid()::text || '/[0-9a-f-]{36}\.png$') then
    raise exception 'Invalid signature path';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'signatures' and name = p_path) then
    raise exception 'Signature upload not found';
  end if;
  update public.user_signatures set active = false where user_id = auth.uid() and active;
  insert into public.user_signatures (user_id, storage_path) values (auth.uid(), p_path);
end $$;

-- Admin --------------------------------------------------------------------

create function public.admin_list_users() returns table (
  id uuid, email text, full_name text, role public.app_role, active boolean,
  has_pin boolean, has_signature boolean, last_sign_in_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_any_role(array['admin']) then
    raise exception 'Not allowed';
  end if;
  return query
  select p.id, u.email::text, p.full_name, p.role, p.active,
         exists (select 1 from public.user_pins up where up.user_id = p.id),
         exists (select 1 from public.user_signatures us where us.user_id = p.id and us.active),
         u.last_sign_in_at
  from public.profiles p join auth.users u on u.id = p.id
  order by p.full_name;
end $$;

create function public.admin_update_user(p_user uuid, p_name text, p_role public.app_role, p_active boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_current public.app_role;
begin
  if not public.has_any_role(array['admin']) then
    raise exception 'Not allowed';
  end if;
  if p_name is null or char_length(trim(p_name)) not between 1 and 120 then
    raise exception 'Enter a name of 1 to 120 characters';
  end if;
  select role into v_current from public.profiles where id = p_user;
  if v_current is null then
    raise exception 'Unknown user';
  end if;
  if p_user = auth.uid() and (p_role <> v_current or p_active is not true) then
    raise exception 'You cannot change your own role or deactivate yourself';
  end if;
  update public.profiles set full_name = trim(p_name), role = p_role, active = p_active where id = p_user;
end $$;

create function public.admin_reset_pin(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_any_role(array['admin']) then
    raise exception 'Not allowed';
  end if;
  delete from public.user_pins where user_id = p_user;
  perform public._audit('PIN_RESET', 'user_pins', p_user::text);
end $$;
