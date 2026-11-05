-- StoreGate 0001: types, tables, integrity triggers
-- Run migrations in order (0001, 0002, 0003) in the Supabase SQL editor or with the Supabase CLI.

create extension if not exists pgcrypto with schema extensions;

create type public.app_role as enum ('admin', 'storeman', 'supervisor', 'manager', 'security', 'viewer');
create type public.movement_type as enum ('receive', 'dispatch', 'transfer');
create type public.movement_status as enum ('draft', 'pending_signoff', 'signed_off', 'rejected', 'cancelled');
create type public.pass_status as enum ('issued', 'used', 'void');

create sequence public.movement_seq;
create sequence public.delivery_note_seq;
create sequence public.gate_pass_seq;

-- People -------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null check (char_length(full_name) between 1 and 120),
  role public.app_role not null default 'viewer',
  -- New accounts stay inactive until an admin activates them, even if public sign up is left on.
  active boolean not null default false,
  created_at timestamptz not null default now()
);

-- PIN hashes live in their own table with no policies and no grants.
-- Only the SECURITY DEFINER functions in 0002 can read or write it.
create table public.user_pins (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  pin_hash text not null,
  attempts int not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);

create table public.user_signatures (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id),
  storage_path text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index user_signatures_one_active on public.user_signatures (user_id) where active;

-- Stock master data --------------------------------------------------------

create table public.storerooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (char_length(code) between 1 and 20),
  name text not null check (char_length(name) between 1 and 120),
  active boolean not null default true
);

create table public.items (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique check (char_length(sku) between 1 and 64),
  barcode text unique check (barcode is null or char_length(barcode) between 1 and 64),
  name text not null check (char_length(name) between 1 and 200),
  unit text not null default 'ea' check (char_length(unit) between 1 and 16),
  active boolean not null default true
);

create table public.stock_levels (
  storeroom_id uuid not null references public.storerooms (id),
  item_id uuid not null references public.items (id),
  qty numeric(14, 3) not null default 0 check (qty >= 0),
  primary key (storeroom_id, item_id)
);

-- Sign off chain. Step 0 is always the person who prepares the movement.
create table public.signoff_steps (
  step_order int primary key check (step_order > 0),
  role public.app_role not null check (role <> 'viewer'),
  label text not null check (char_length(label) between 1 and 60)
);
insert into public.signoff_steps (step_order, role, label) values
  (1, 'supervisor', 'Supervisor check'),
  (2, 'manager', 'Manager approval');

-- Movements ----------------------------------------------------------------

create table public.movements (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique,
  type public.movement_type not null,
  status public.movement_status not null default 'draft',
  from_storeroom_id uuid references public.storerooms (id),
  to_storeroom_id uuid references public.storerooms (id),
  counterparty text check (counterparty is null or char_length(counterparty) <= 200),
  vehicle_reg text check (vehicle_reg is null or char_length(vehicle_reg) <= 30),
  driver_name text check (driver_name is null or char_length(driver_name) <= 120),
  notes text check (notes is null or char_length(notes) <= 1000),
  rejection_reason text check (rejection_reason is null or char_length(rejection_reason) <= 500),
  steps_snapshot jsonb,
  content_hash text,
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  completed_at timestamptz,
  constraint movement_locations check (
    (type = 'receive' and to_storeroom_id is not null and from_storeroom_id is null) or
    (type = 'dispatch' and from_storeroom_id is not null and to_storeroom_id is null) or
    (type = 'transfer' and from_storeroom_id is not null and to_storeroom_id is not null
       and from_storeroom_id <> to_storeroom_id)
  )
);
create index movements_status_idx on public.movements (status);
create index movements_created_by_idx on public.movements (created_by);

create table public.movement_lines (
  id uuid primary key default gen_random_uuid(),
  movement_id uuid not null references public.movements (id) on delete cascade,
  item_id uuid not null references public.items (id),
  qty numeric(14, 3) not null check (qty > 0),
  unique (movement_id, item_id)
);

create table public.signoffs (
  id uuid primary key default gen_random_uuid(),
  movement_id uuid not null references public.movements (id),
  step_order int not null,
  step_label text not null,
  role public.app_role not null,
  user_id uuid not null references public.profiles (id),
  signed_at timestamptz not null default now(),
  signature_path text not null,
  content_hash text not null,
  unique (movement_id, step_order),
  unique (movement_id, user_id)
);
create index signoffs_movement_idx on public.signoffs (movement_id);

create table public.delivery_notes (
  id uuid primary key default gen_random_uuid(),
  movement_id uuid not null unique references public.movements (id),
  number text not null unique,
  issued_at timestamptz not null default now(),
  snapshot jsonb not null
);

create table public.gate_passes (
  id uuid primary key default gen_random_uuid(),
  movement_id uuid not null unique references public.movements (id),
  number text not null unique,
  code text not null unique check (code ~ '^[0-9a-f]{32}$'),
  status public.pass_status not null default 'issued',
  issued_at timestamptz not null default now(),
  used_at timestamptz,
  used_by uuid references public.profiles (id)
);

create table public.stock_ledger (
  id bigint generated always as identity primary key,
  movement_id uuid not null references public.movements (id),
  item_id uuid not null references public.items (id),
  storeroom_id uuid not null references public.storerooms (id),
  delta numeric(14, 3) not null,
  balance_after numeric(14, 3) not null,
  created_at timestamptz not null default now()
);
create index stock_ledger_created_idx on public.stock_ledger (created_at desc);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  title text not null,
  body text,
  movement_id uuid references public.movements (id),
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, read, created_at desc);

create table public.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor uuid,
  action text not null,
  table_name text not null,
  record_id text not null default '',
  details jsonb not null default '{}'::jsonb
);
create index audit_log_at_idx on public.audit_log (at desc);

-- Triggers -----------------------------------------------------------------

-- New auth users get a profile with the lowest role. The role is never read from user metadata.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
                  nullif(split_part(new.email, '@', 1), ''),
                  'New user'), 120)
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Generic row audit.
create function public.audit_row() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  j jsonb;
begin
  j := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  insert into public.audit_log (actor, action, table_name, record_id, details)
  values (
    auth.uid(),
    tg_op,
    tg_table_name,
    coalesce(j ->> 'id', j ->> 'step_order', ''),
    case when tg_op = 'UPDATE' then jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new)) else j end
  );
  return null;
end $$;

create trigger audit_profiles after insert or update or delete on public.profiles
  for each row execute function public.audit_row();
create trigger audit_storerooms after insert or update or delete on public.storerooms
  for each row execute function public.audit_row();
create trigger audit_items after insert or update or delete on public.items
  for each row execute function public.audit_row();
create trigger audit_signoff_steps after insert or update or delete on public.signoff_steps
  for each row execute function public.audit_row();
create trigger audit_movements after insert or update or delete on public.movements
  for each row execute function public.audit_row();
create trigger audit_signoffs after insert or update or delete on public.signoffs
  for each row execute function public.audit_row();
create trigger audit_gate_passes after insert or update or delete on public.gate_passes
  for each row execute function public.audit_row();
create trigger audit_user_signatures after insert or update or delete on public.user_signatures
  for each row execute function public.audit_row();
create trigger audit_delivery_notes after insert or update or delete on public.delivery_notes
  for each row execute function public.audit_row();

-- Append only tables. These triggers fire for every role, including service_role.
create function public.forbid_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception '% is append only', tg_table_name;
end $$;

create trigger audit_log_append_only before update or delete on public.audit_log
  for each row execute function public.forbid_change();
create trigger audit_log_no_truncate before truncate on public.audit_log
  for each statement execute function public.forbid_change();
create trigger signoffs_append_only before update or delete on public.signoffs
  for each row execute function public.forbid_change();
create trigger signoffs_no_truncate before truncate on public.signoffs
  for each statement execute function public.forbid_change();
create trigger ledger_append_only before update or delete on public.stock_ledger
  for each row execute function public.forbid_change();
create trigger ledger_no_truncate before truncate on public.stock_ledger
  for each statement execute function public.forbid_change();
create trigger delivery_notes_append_only before update or delete on public.delivery_notes
  for each row execute function public.forbid_change();
create trigger delivery_notes_no_truncate before truncate on public.delivery_notes
  for each statement execute function public.forbid_change();
