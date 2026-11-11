\set ON_ERROR_STOP off
\pset pager off
\pset format unaligned
\pset tuples_only on
create schema t;
create table t.results(n serial, name text, status text, detail text);
create function t.run(p_name text, p_role text, p_uid uuid, p_sql text, p_expect text) returns void language plpgsql as $$
declare v text; n bigint; err text; pass boolean;
begin
  begin
    perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
    execute format('set local role %I', p_role);
    if p_sql ~* '^\s*select' then execute p_sql into v; else execute p_sql; get diagnostics n = row_count; v := n::text; end if;
    reset role;
  exception when others then reset role; err := sqlerrm; v := null; end;
  pass := case when p_expect = 'err' then err is not null
               when p_expect like 'err:%' then err ilike '%'||substr(p_expect,5)||'%'
               when p_expect = 'ok' then err is null
               else err is null and v is not distinct from p_expect end;
  insert into t.results(name,status,detail) values (p_name, case when pass then 'PASS' else 'FAIL' end, coalesce('err='||err,'')||' v='||coalesce(v,'null'));
end $$;

-- users: inactive by default via trigger
insert into auth.users(id,email,raw_user_meta_data) values
 ('00000000-0000-0000-0000-00000000000a','a@x.test','{"full_name":"Ada Admin","role":"admin"}'),
 ('00000000-0000-0000-0000-00000000000b','s@x.test','{"full_name":"Sam Storeman"}'),
 ('00000000-0000-0000-0000-00000000000c','v@x.test','{"full_name":"Vee Supervisor"}'),
 ('00000000-0000-0000-0000-00000000000d','m@x.test','{"full_name":"Mo Manager"}'),
 ('00000000-0000-0000-0000-00000000000e','g@x.test','{"full_name":"Gus Guard"}'),
 ('00000000-0000-0000-0000-00000000000f','w@x.test','{"full_name":"Wes Viewer"}'),
 ('00000000-0000-0000-0000-000000000010','x@x.test','{"full_name":"Xan Inactive"}');
select 'new user default role/active (metadata role must be ignored): '||role||' '||active from public.profiles where full_name='Ada Admin';
update public.profiles set role='admin', active=true where full_name='Ada Admin';
update public.profiles set role='storeman', active=true where full_name='Sam Storeman';
update public.profiles set role='dispatch_manager', active=true where full_name='Vee Supervisor';
update public.profiles set role='procurement', active=true where full_name='Mo Manager';
update public.profiles set role='security', active=true where full_name='Gus Guard';
update public.profiles set role='viewer', active=true where full_name='Wes Viewer';
\set A '00000000-0000-0000-0000-00000000000a'
\set S '00000000-0000-0000-0000-00000000000b'
\set V '00000000-0000-0000-0000-00000000000c'
\set M '00000000-0000-0000-0000-00000000000d'
\set G '00000000-0000-0000-0000-00000000000e'
\set W '00000000-0000-0000-0000-00000000000f'
\set X '00000000-0000-0000-0000-000000000010'

-- master data
select t.run('admin creates storeroom MAIN','authenticated',:'A',$$insert into public.storerooms(code,name) values ('MAIN','Main store')$$,'1');
select t.run('admin creates storeroom YARD','authenticated',:'A',$$insert into public.storerooms(code,name) values ('YARD','Yard')$$,'1');
select t.run('storeman cannot create storeroom','authenticated',:'S',$$insert into public.storerooms(code,name) values ('BAD','Bad')$$,'err');
select t.run('storeman creates item','authenticated',:'S',$$insert into public.items(sku,barcode,name) values ('BOLT-10','6001','Bolt M10'),('NUT-10','6002','Nut M10')$$,'2');
select t.run('viewer cannot create item','authenticated',:'W',$$insert into public.items(sku,name) values ('X','X')$$,'err');
select id as sr_main from public.storerooms where code='MAIN' \gset
select id as sr_yard from public.storerooms where code='YARD' \gset
select id as it_bolt from public.items where sku='BOLT-10' \gset
select id as it_nut from public.items where sku='NUT-10' \gset

-- signatures: uploaded objects (simulated) + PIN + save
insert into storage.objects(bucket_id,name) select 'signatures', id||'/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.png' from public.profiles;
select t.run('set_pin weak rejected','authenticated',:'S',$$select public.set_pin('123456')::text$$,'err:harder');
select t.run('set_pin ok S','authenticated',:'S',$$select public.set_pin('482913')::text$$,'{"ok": true}');
select t.run('set_pin ok V','authenticated',:'V',$$select public.set_pin('591204')::text$$,'{"ok": true}');
select t.run('set_pin ok M','authenticated',:'M',$$select public.set_pin('730518')::text$$,'{"ok": true}');
select t.run('save_signature S','authenticated',:'S',format($$select public.save_signature('%s/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.png')::text$$,:'S'),'');
select t.run('save_signature V','authenticated',:'V',format($$select public.save_signature('%s/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.png')::text$$,:'V'),'');
select t.run('save_signature M','authenticated',:'M',format($$select public.save_signature('%s/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.png')::text$$,:'M'),'');
select t.run('cannot save someone else''s signature path','authenticated',:'V',format($$select public.save_signature('%s/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.png')::text$$,:'S'),'err:Invalid');

-- RECEIVE flow
select t.run('viewer cannot create movement','authenticated',:'W',format($$select public.create_movement('receive',null,'%s','Acme','','','',  '[{"item_id":"%s","qty":5}]')::text$$,:'sr_main',:'it_bolt'),'err:Not allowed');
select t.run('zero qty rejected','authenticated',:'S',format($$select public.create_movement('receive',null,'%s','Acme','','','', '[{"item_id":"%s","qty":0}]')::text$$,:'sr_main',:'it_bolt'),'err:Quantities');
set role authenticated; select set_config('request.jwt.claim.sub', :'S', false);
select public.create_movement('receive',null,:'sr_main','Acme Supplies','CA123','Dan','first delivery', jsonb_build_array(jsonb_build_object('item_id',:'it_bolt','qty',100),jsonb_build_object('item_id',:'it_nut','qty',50))) as mv1 \gset
reset role;
\echo submit with wrong PIN:
set role authenticated; select set_config('request.jwt.claim.sub', :'S', false);
select public.submit_movement(:'mv1','000111');
select public.submit_movement(:'mv1','482913');
reset role;
select 'status after submit: '||status from public.movements where id=:'mv1';
select 'delivery note: '||number from public.delivery_notes where movement_id=:'mv1';
select t.run('M cannot sign before V (wrong step)','authenticated',:'M',format($$select public.sign_movement('%s','730518')::text$$,:'mv1'),'err:needs the dispatch_manager');
select t.run('S cannot sign supervisor step','authenticated',:'S',format($$select public.sign_movement('%s','482913')::text$$,:'mv1'),'err:needs the dispatch_manager');
select t.run('V wrong pin returns ok=false','authenticated',:'V',format($$select (public.sign_movement('%s','999999'))->>'error'$$,:'mv1'),'wrong');
select t.run('V signs','authenticated',:'V',format($$select (public.sign_movement('%s','591204'))->>'completed'$$,:'mv1'),'false');
select t.run('stock unchanged until last signature','authenticated',:'S',$$select count(*)::text from public.stock_levels$$,'0');
select t.run('V cannot sign twice (role gone to manager step)','authenticated',:'V',format($$select public.sign_movement('%s','591204')::text$$,:'mv1'),'err');
-- tamper test on a copy later; complete now
select t.run('M signs, completes','authenticated',:'M',format($$select (public.sign_movement('%s','730518'))->>'completed'$$,:'mv1'),'true');
select 'bolt in MAIN: '||qty from public.stock_levels where item_id=:'it_bolt' and storeroom_id=:'sr_main';
select 'gate passes: '||count(*) from public.gate_passes where movement_id=:'mv1';
select 'security notified: '||count(*) from public.notifications n join public.profiles p on p.id=n.user_id where p.role='security' and n.title='Gate pass issued';
select 'ledger rows: '||count(*) from public.stock_ledger;

-- DISPATCH flow
select t.run('dispatch beyond stock blocked at submit','authenticated',:'S',format($$select (public.submit_movement(public.create_movement('dispatch','%s',null,'Customer','CA9','Dan','','[{"item_id":"%s","qty":101}]'),'482913'))::text$$,:'sr_main',:'it_bolt'),'err:Insufficient');
set role authenticated; select set_config('request.jwt.claim.sub', :'S', false);
select public.create_movement('dispatch',:'sr_main',null,'Customer Ltd','CA999','Dan','',jsonb_build_array(jsonb_build_object('item_id',:'it_bolt','qty',40))) as mv2 \gset
select public.submit_movement(:'mv2','482913');
reset role;
-- tamper: change a line after submission
update public.movement_lines set qty=41 where movement_id=:'mv2';
select t.run('tamper after submit detected on sign','authenticated',:'V',format($$select public.sign_movement('%s','591204')::text$$,:'mv2'),'err:changed after');
update public.movement_lines set qty=40 where movement_id=:'mv2';
select t.run('V signs dispatch','authenticated',:'V',format($$select (public.sign_movement('%s','591204'))->>'completed'$$,:'mv2'),'false');
select t.run('M signs dispatch','authenticated',:'M',format($$select (public.sign_movement('%s','730518'))->>'completed'$$,:'mv2'),'true');
select 'bolt in MAIN after dispatch: '||qty from public.stock_levels where item_id=:'it_bolt' and storeroom_id=:'sr_main';
select code as gp_code from public.gate_passes where movement_id=:'mv2' \gset
select t.run('guard verifies pass','authenticated',:'G',format($$select (public.verify_gate_pass('%s'))->>'status'$$,:'gp_code'),'issued');
select t.run('viewer cannot verify pass','authenticated',:'W',format($$select public.verify_gate_pass('%s')::text$$,:'gp_code'),'err:Not allowed');
select t.run('guard releases pass','authenticated',:'G',format($$select (public.release_gate_pass('%s'))->>'ok'$$,:'gp_code'),'true');
select t.run('second release refused','authenticated',:'G',format($$select (public.release_gate_pass('%s'))->>'ok'$$,:'gp_code'),'false');
select t.run('unknown code not found','authenticated',:'G',$$select (public.verify_gate_pass('00000000000000000000000000000000'))->>'found'$$,'false');
select t.run('sql-ish code rejected as not found','authenticated',:'G',$$select (public.verify_gate_pass('x'' or 1=1 --'))->>'found'$$,'false');

-- PIN lockout (persists across failed calls)
select t.run('lockout 1','authenticated',:'M',$$select (public.set_pin('846205','000000'))->>'error'$$,'wrong');
select t.run('lockout 2','authenticated',:'M',$$select (public.set_pin('846205','000001'))->>'error'$$,'wrong');
select t.run('lockout 3','authenticated',:'M',$$select (public.set_pin('846205','000002'))->>'error'$$,'wrong');
select t.run('lockout 4','authenticated',:'M',$$select (public.set_pin('846205','000003'))->>'error'$$,'wrong');
select t.run('lockout 5','authenticated',:'M',$$select (public.set_pin('846205','000004'))->>'error'$$,'wrong');
select t.run('locked even with correct pin','authenticated',:'M',$$select (public.set_pin('846205','730518'))->>'error'$$,'locked');

-- Access control
select t.run('anon cannot read stock','anon',null,$$select count(*)::text from public.stock_levels$$,'err');
select t.run('anon cannot call rpc','anon',null,$$select public.is_member()::text$$,'err');
select t.run('anon cannot read profiles','anon',null,$$select count(*)::text from public.profiles$$,'err');
select t.run('inactive user sees no stock rows','authenticated',:'X',$$select count(*)::text from public.stock_levels$$,'0');
select t.run('inactive user sees no movements','authenticated',:'X',$$select count(*)::text from public.movements$$,'0');
select t.run('viewer reads stock','authenticated',:'W',$$select count(*)::text from public.stock_levels$$,'2');
select t.run('viewer cannot update stock','authenticated',:'W',$$update public.stock_levels set qty=999999$$,'err');
select t.run('storeman cannot update stock directly','authenticated',:'S',$$update public.stock_levels set qty=999999$$,'err');
select t.run('storeman cannot insert movements directly','authenticated',:'S',format($$insert into public.movements(ref,type,to_storeroom_id,created_by) values ('X','receive','%s','%s')$$,:'sr_main',:'S'),'err');
select t.run('admin cannot insert movements directly either','authenticated',:'A',format($$insert into public.movements(ref,type,to_storeroom_id,created_by) values ('X','receive','%s','%s')$$,:'sr_main',:'A'),'err');
select t.run('nobody reads user_pins','authenticated',:'A',$$select count(*)::text from public.user_pins$$,'err');
select t.run('user cannot raise own role','authenticated',:'S',$$update public.profiles set role='admin' where id=auth.uid()$$,'err');
select t.run('user cannot reactivate self via update','authenticated',:'X',$$update public.profiles set active=true where id=auth.uid()$$,'err');
select t.run('storeman cannot read audit log','authenticated',:'S',$$select count(*)::text from public.audit_log$$,'0');
select t.run('admin reads audit log','authenticated',:'A',$$select (count(*)>10)::text from public.audit_log$$,'true');
select t.run('admin cannot delete audit rows','authenticated',:'A',$$delete from public.audit_log$$,'err');
select t.run('superuser cannot update ledger (append only)','postgres',null,$$update public.stock_ledger set delta=0$$,'err:append only');
select t.run('superuser cannot delete signoffs','postgres',null,$$delete from public.signoffs$$,'err:append only');
select t.run('superuser cannot truncate audit','postgres',null,$$truncate public.audit_log$$,'err:append only');
select t.run('viewer cannot read gate pass codes','authenticated',:'W',$$select count(*)::text from public.gate_passes$$,'0');
select t.run('dispatch manager can read gate passes','authenticated',:'V',$$select count(*)::text from public.gate_passes$$,'2');
select t.run('other user cannot read my signatures row','authenticated',:'V',$$select count(*)::text from public.user_signatures$$,'1');
select t.run('only own notifications visible','authenticated',:'V',$$select (count(*) = count(*) filter (where user_id=auth.uid()))::text from public.notifications$$,'true');
select t.run('cannot mark others notifications read','authenticated',:'W',format($$update public.notifications set read=true where user_id='%s'$$,:'V'),'0');
select t.run('cannot change notification text','authenticated',:'V',$$update public.notifications set title='x'$$,'err');
select t.run('internal fn _check_pin not callable','authenticated',:'V',format($$select public._check_pin('%s','591204')$$,:'V'),'err');
select t.run('internal fn _apply_stock not callable','authenticated',:'S',format($$select public._apply_stock('%s')::text$$,:'mv1'),'err');
select t.run('guard cannot create movement','authenticated',:'G',format($$select public.create_movement('receive',null,'%s','x','','','', '[{"item_id":"%s","qty":1}]')::text$$,:'sr_main',:'it_bolt'),'err:Not allowed');
select t.run('admin cannot demote self','authenticated',:'A',format($$select public.admin_update_user('%s','Ada','viewer',true)::text$$,:'A'),'err:cannot change');
select t.run('non admin cannot list users','authenticated',:'S',$$select count(*)::text from public.admin_list_users()$$,'err');
select t.run('admin activates user','authenticated',:'A',format($$select public.admin_update_user('%s','Xan','viewer',true)::text$$,:'X'),'');
select t.run('admin resets M pin (unlocks)','authenticated',:'A',format($$select public.admin_reset_pin('%s')::text$$,:'M'),'');
select t.run('signature bucket private','postgres',null,$$select (not public)::text from storage.buckets where id='signatures'$$,'true');


-- Preparers: dispatch manager and procurement may prepare movements too
select t.run('dispatch manager can create a movement','authenticated',:'V',format($$select (public.create_movement('dispatch','%s',null,'DM Co','','','', '[{"item_id":"%s","qty":1}]') is not null)::text$$,:'sr_main',:'it_bolt'),'true');
select t.run('procurement can create a movement','authenticated',:'M',format($$select (public.create_movement('dispatch','%s',null,'PR Co','','','', '[{"item_id":"%s","qty":1}]') is not null)::text$$,:'sr_main',:'it_bolt'),'true');
select t.run('security still cannot create a movement','authenticated',:'G',format($$select public.create_movement('dispatch','%s',null,'X','','','', '[{"item_id":"%s","qty":1}]')::text$$,:'sr_main',:'it_bolt'),'err:Not allowed');
select t.run('viewer still cannot create a movement','authenticated',:'W',format($$select public.create_movement('dispatch','%s',null,'X','','','', '[{"item_id":"%s","qty":1}]')::text$$,:'sr_main',:'it_bolt'),'err:Not allowed');
select t.run('procurement reads gate passes','authenticated',:'M',$$select count(*)::text from public.gate_passes$$,'2');
-- A dispatch manager who prepares a movement cannot also sign the dispatch manager step
select t.run('dispatch manager prepares and submits','authenticated',:'V',format($$select (public.submit_movement(public.create_movement('dispatch','%s',null,'Self Co','','','', '[{"item_id":"%s","qty":2}]'),'591204'))->>'ok'$$,:'sr_main',:'it_bolt'),'true');
select id as mv_self from public.movements where counterparty='Self Co' \gset
select t.run('preparer cannot sign their own check step','authenticated',:'V',format($$select public.sign_movement('%s','591204')::text$$,:'mv_self'),'err:already signed');

select status||'  '||name||'   ['||detail||']' from t.results order by n;
select '--- '||count(*) filter (where status='PASS')||' passed, '||count(*) filter (where status='FAIL')||' failed' from t.results;
