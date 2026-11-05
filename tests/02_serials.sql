-- Serial numbers, damaged flags, notes, write offs, replacements and search.
-- Run after 01_flow_and_security.sql on the same database (it reuses the users and the t schema).
\set ON_ERROR_STOP off
\pset pager off
\pset format unaligned
\pset tuples_only on
create function t.check(p_name text, p_cond boolean) returns void language sql as $$
  insert into t.results(name, status, detail) values (p_name, case when p_cond then 'PASS' else 'FAIL' end, '')
$$;
\set A '00000000-0000-0000-0000-00000000000a'
\set S '00000000-0000-0000-0000-00000000000b'
\set V '00000000-0000-0000-0000-00000000000c'
\set M '00000000-0000-0000-0000-00000000000d'
\set G '00000000-0000-0000-0000-00000000000e'
\set W '00000000-0000-0000-0000-00000000000f'
select count(*) as n_before from t.results \gset
select id as sr_main from public.storerooms where code='MAIN' \gset
select id as sr_yard from public.storerooms where code='YARD' \gset
select id as it_bolt from public.items where sku='BOLT-10' \gset
select t.run('M sets a PIN again','authenticated',:'M',$$select (public.set_pin('846205'))->>'ok'$$,'true');

-- the item tick
select t.run('storeman creates a serial tracked item','authenticated',:'S',$$insert into public.items(sku,barcode,name,tracks_serials) values ('LAP-1','7001','Lenovo ThinkPad',true)$$,'1');
select id as it_lap from public.items where sku='LAP-1' \gset

-- RECEIVE 10 laptops with 3 serials
select t.run('receive: same serial twice rejected','authenticated',:'S',format($$select public.create_movement('receive',null,'%s','Acme','','','','[{"item_id":"%s","qty":5,"serials":["SN-001","sn-001"]}]')::text$$,:'sr_main',:'it_lap'),'err:appears twice');
select t.run('receive: more serials than units rejected','authenticated',:'S',format($$select public.create_movement('receive',null,'%s','Acme','','','','[{"item_id":"%s","qty":2,"serials":["A1","A2","A3"]}]')::text$$,:'sr_main',:'it_lap'),'err:more serial numbers');
select t.run('receive: serials on an untracked item rejected','authenticated',:'S',format($$select public.create_movement('receive',null,'%s','Acme','','','','[{"item_id":"%s","qty":2,"serials":["B1"]}]')::text$$,:'sr_main',:'it_bolt'),'err:does not track');
select t.run('receive: fractional laptops rejected','authenticated',:'S',format($$select public.create_movement('receive',null,'%s','Acme','','','','[{"item_id":"%s","qty":2.5}]')::text$$,:'sr_main',:'it_lap'),'err:whole units');
select t.run('receive: blank serial rejected','authenticated',:'S',format($$select public.create_movement('receive',null,'%s','Acme','','','','[{"item_id":"%s","qty":2,"serials":["  "]}]')::text$$,:'sr_main',:'it_lap'),'err:Invalid serial');
select t.run('receive: control characters in a serial rejected','authenticated',:'S',format($$select public.create_movement('receive',null,'%s','Acme','','','', jsonb_build_array(jsonb_build_object('item_id','%s','qty',2,'serials',jsonb_build_array(E'AB\tCD'))))::text$$,:'sr_main',:'it_lap'),'err:Invalid serial');
set role authenticated; select set_config('request.jwt.claim.sub', :'S', false);
select public.create_movement('receive',null,:'sr_main','Acme','CA1','Dan','10 laptops',jsonb_build_array(jsonb_build_object('item_id',:'it_lap','qty',10,'serials',jsonb_build_array('SN-001','SN-002','SN-003')))) as mv_r \gset
select (public.submit_movement(:'mv_r','482913'))->>'ok';
reset role;
select t.run('receive: V signs','authenticated',:'V',format($$select (public.sign_movement('%s','591204'))->>'completed'$$,:'mv_r'),'false');
select t.run('receive: units do not exist before the last signature','authenticated',:'S',$$select count(*)::text from public.stock_units$$,'0');
select t.run('receive: M signs, completes','authenticated',:'M',format($$select (public.sign_movement('%s','846205'))->>'completed'$$,:'mv_r'),'true');
select t.check('receive: 3 serial units now exist in MAIN', (select count(*) from public.stock_units where item_id=:'it_lap' and storeroom_id=:'sr_main' and status='in_stock') = 3);
select t.check('receive: stock level is the full 10', (select qty from public.stock_levels where item_id=:'it_lap' and storeroom_id=:'sr_main') = 10);
select t.run('pile shows 10, 3 serialised, 7 unassigned','authenticated',:'W',format($$select qty||'/'||serialised||'/'||unassigned from public.stock_piles('lap','%s')$$,:'sr_main'),'10.000/3/7.000');
select t.check('receive: delivery note lists the serials', (select snapshot->'lines'->0->'serials' from public.delivery_notes where movement_id=:'mv_r') = '["SN-001","SN-002","SN-003"]'::jsonb);

-- add serials later
select t.run('viewer cannot add serials','authenticated',:'W',format($$select public.add_serials('%s','%s',array['SN-004'])::text$$,:'sr_main',:'it_lap'),'err:Not allowed');
select t.run('dispatch manager cannot add serials','authenticated',:'V',format($$select public.add_serials('%s','%s',array['SN-004'])::text$$,:'sr_main',:'it_lap'),'err:Not allowed');
select t.run('untracked item rejects add_serials','authenticated',:'S',format($$select public.add_serials('%s','%s',array['X'])::text$$,:'sr_main',:'it_bolt'),'err:does not track');
select t.run('storeman adds 4 more serials','authenticated',:'S',format($$select public.add_serials('%s','%s',array['SN-004','SN-005','SN-006','SN-007'])::text$$,:'sr_main',:'it_lap'),'4');
select t.run('cannot add more serials than units left (3 slots)','authenticated',:'S',format($$select public.add_serials('%s','%s',array['N1','N2','N3','N4'])::text$$,:'sr_main',:'it_lap'),'err:units here still need');
select t.run('existing serial refused, case insensitive','authenticated',:'S',format($$select public.add_serials('%s','%s',array['sn-001'])::text$$,:'sr_main',:'it_lap'),'err:already on record');
select t.run('failed add left nothing behind','authenticated',:'S',format($$select count(*)::text from public.stock_units where item_id='%s'$$,:'it_lap'),'7');

-- damaged flag, notes
select id as u_sn2 from public.stock_units where serial='SN-002' \gset
select t.run('dispatch manager cannot flag','authenticated',:'V',format($$select public.flag_unit('%s',true,'screen cracked')::text$$,:'u_sn2'),'err:Not allowed');
select t.run('viewer cannot flag','authenticated',:'W',format($$select public.flag_unit('%s',true,'screen cracked')::text$$,:'u_sn2'),'err:Not allowed');
select t.run('security cannot flag','authenticated',:'G',format($$select public.flag_unit('%s',true,'screen cracked')::text$$,:'u_sn2'),'err:Not allowed');
select t.run('flagging damaged needs a note','authenticated',:'S',format($$select public.flag_unit('%s',true,'')::text$$,:'u_sn2'),'err:Write a note');
select t.run('storeman flags SN-002 damaged','authenticated',:'S',format($$select public.flag_unit('%s',true,'Screen cracked in transit')::text$$,:'u_sn2'),'');
select t.run('pile now shows 1 not working','authenticated',:'W',format($$select damaged::text from public.stock_piles('lap','%s')$$,:'sr_main'),'1');
select t.run('damaged search finds only SN-002','authenticated',:'W',$$select string_agg(serial,',') from public.stock_units_search(null,null,'damaged')$$,'SN-002');
select t.run('note is searchable','authenticated',:'W',$$select string_agg(serial,',') from public.stock_units_search('cracked',null,'all')$$,'SN-002');
select t.run('storeman adds a note','authenticated',:'S',format($$select public.add_unit_note('%s','Claim lodged with supplier')::text$$,:'u_sn2'),'');
select t.run('viewer cannot add a note','authenticated',:'W',format($$select public.add_unit_note('%s','hello')::text$$,:'u_sn2'),'err:Not allowed');
select t.check('unit history has received, damaged, note in order', (select string_agg(kind, ',' order by id) from public.unit_events where unit_id=:'u_sn2') = 'received,damaged,note');
select t.run('mark SN-002 working again then flag it again','authenticated',:'S',format($$select public.flag_unit('%s',false,'Reseated the screen cable')::text$$,:'u_sn2'),'');
select t.run('working count back to 0','authenticated',:'W',format($$select damaged::text from public.stock_piles('lap','%s')$$,:'sr_main'),'0');
select t.run('flag it damaged again','authenticated',:'S',format($$select public.flag_unit('%s',true,'Screen failed again')::text$$,:'u_sn2'),'');

-- DISPATCH with serials
select t.run('dispatch: serial count must equal quantity','authenticated',:'S',format($$select public.create_movement('dispatch','%s',null,'Cust','','','','[{"item_id":"%s","qty":2,"serials":["SN-001"]}]')::text$$,:'sr_main',:'it_lap'),'err:Scan a serial number for every unit');
select t.run('dispatch: no serials at all is refused','authenticated',:'S',format($$select public.create_movement('dispatch','%s',null,'Cust','','','','[{"item_id":"%s","qty":2}]')::text$$,:'sr_main',:'it_lap'),'err:Scan a serial number for every unit');
select t.run('dispatch: unknown serial refused','authenticated',:'S',format($$select public.create_movement('dispatch','%s',null,'Cust','','','','[{"item_id":"%s","qty":1,"serials":["SN-999"]}]')::text$$,:'sr_main',:'it_lap'),'err:not in stock');
select t.run('dispatch: damaged unit refused','authenticated',:'S',format($$select public.create_movement('dispatch','%s',null,'Cust','','','','[{"item_id":"%s","qty":1,"serials":["SN-002"]}]')::text$$,:'sr_main',:'it_lap'),'err:flagged as damaged');
select t.run('dispatch: serial from the wrong storeroom refused','authenticated',:'S',format($$select public.create_movement('dispatch','%s',null,'Cust','','','','[{"item_id":"%s","qty":1,"serials":["SN-001"]}]')::text$$,:'sr_yard',:'it_lap'),'err:not in stock');
set role authenticated; select set_config('request.jwt.claim.sub', :'S', false);
select public.create_movement('dispatch',:'sr_main',null,'Customer A','CA555','Dan','',jsonb_build_array(jsonb_build_object('item_id',:'it_lap','qty',2,'serials',jsonb_build_array('sn-001','SN-003')))) as mv_a \gset
select (public.submit_movement(:'mv_a','482913'))->>'ok';
reset role;
select t.run('dispatch A: V signs','authenticated',:'V',format($$select (public.sign_movement('%s','591204'))->>'completed'$$,:'mv_a'),'false');
select t.check('dispatch A: units stay in stock until the last signature', (select count(*) from public.stock_units where serial in ('SN-001','SN-003') and status='in_stock') = 2);
select t.run('dispatch A: M signs, completes','authenticated',:'M',format($$select (public.sign_movement('%s','846205'))->>'completed'$$,:'mv_a'),'true');
select t.check('dispatch A: both scanned serials are out of stock', (select count(*) from public.stock_units where serial in ('SN-001','SN-003') and status='dispatched') = 2);
select t.check('dispatch A: stock quantity down to 8', (select qty from public.stock_levels where item_id=:'it_lap' and storeroom_id=:'sr_main') = 8);
select t.check('dispatch A: delivery note lists exactly the scanned serials', (select snapshot->'lines'->0->'serials' from public.delivery_notes where movement_id=:'mv_a') = '["SN-001","SN-003"]'::jsonb);
select code as gp_a from public.gate_passes where movement_id=:'mv_a' \gset
select t.run('dispatch A: gate check shows the serials','authenticated',:'G',format($$select jsonb_array_length((public.verify_gate_pass('%s'))->'lines'->0->'serials')::text$$,:'gp_a'),'2');
select t.run('dispatch A: dispatched serials cannot be sent again','authenticated',:'S',format($$select public.create_movement('dispatch','%s',null,'Cust','','','','[{"item_id":"%s","qty":1,"serials":["SN-001"]}]')::text$$,:'sr_main',:'it_lap'),'err:not in stock');
select t.check('dispatch A: unit history shows dispatched', (select string_agg(kind, ',' order by e.id) from public.unit_events e join public.stock_units u on u.id=e.unit_id where u.serial='SN-003') = 'received,dispatched');

-- reservation, cancel, tamper
set role authenticated; select set_config('request.jwt.claim.sub', :'S', false);
select public.create_movement('dispatch',:'sr_main',null,'Customer B','','','',jsonb_build_array(jsonb_build_object('item_id',:'it_lap','qty',1,'serials',jsonb_build_array('SN-004')))) as mv_b \gset
select public.create_movement('dispatch',:'sr_main',null,'Customer C','','','',jsonb_build_array(jsonb_build_object('item_id',:'it_lap','qty',1,'serials',jsonb_build_array('SN-004')))) as mv_c \gset
select (public.submit_movement(:'mv_b','482913'))->>'ok';
reset role;
select t.run('reservation: same unit cannot be on two pending movements','authenticated',:'S',format($$select (public.submit_movement('%s','482913'))::text$$,:'mv_c'),'err:already on another movement');
select t.run('write off blocked while the unit is on a pending movement','authenticated',:'S',format($$select public.write_off_unit((select id from public.stock_units where serial='SN-004'),'testing')::text$$),'err:awaiting sign off');
select t.run('cancel B frees the unit','authenticated',:'S',format($$select public.cancel_movement('%s','changed mind')::text$$,:'mv_b'),'');
select t.run('C can now be submitted','authenticated',:'S',format($$select (public.submit_movement('%s','482913'))->>'ok'$$,:'mv_c'),'true');
update public.movement_serials set serial='SN-005', unit_id=(select id from public.stock_units where serial='SN-005') where movement_id=:'mv_c';
select t.run('tampering with serials after submit is caught','authenticated',:'V',format($$select public.sign_movement('%s','591204')::text$$,:'mv_c'),'err:changed after');
update public.movement_serials set serial='SN-004', unit_id=(select id from public.stock_units where serial='SN-004') where movement_id=:'mv_c';
select t.run('C: V signs after restore','authenticated',:'V',format($$select (public.sign_movement('%s','591204'))->>'completed'$$,:'mv_c'),'false');
select t.run('C: M signs, completes','authenticated',:'M',format($$select (public.sign_movement('%s','846205'))->>'completed'$$,:'mv_c'),'true');
-- a unit flagged damaged after submit stops the movement at the last signature
set role authenticated; select set_config('request.jwt.claim.sub', :'S', false);
select public.create_movement('dispatch',:'sr_main',null,'Customer D','','','',jsonb_build_array(jsonb_build_object('item_id',:'it_lap','qty',1,'serials',jsonb_build_array('SN-005')))) as mv_d \gset
select (public.submit_movement(:'mv_d','482913'))->>'ok';
select public.flag_unit((select id from public.stock_units where serial='SN-005'),true,'Dropped on the floor');
reset role;
select t.run('D: V signs','authenticated',:'V',format($$select (public.sign_movement('%s','591204'))->>'completed'$$,:'mv_d'),'false');
select t.run('D: last signature refused because the unit is now damaged','authenticated',:'M',format($$select public.sign_movement('%s','846205')::text$$,:'mv_d'),'err:flagged as damaged');
select t.check('D: nothing moved when the last signature failed', (select status from public.stock_units where serial='SN-005') = 'in_stock'
   and (select status from public.movements where id=:'mv_d') = 'pending_signoff');
select t.run('D: rejected by M to clear it','authenticated',:'M',format($$select public.reject_movement('%s','Unit is damaged')::text$$,:'mv_d'),'');
select t.run('SN-005 flagged working again','authenticated',:'S',format($$select public.flag_unit((select id from public.stock_units where serial='SN-005'),false,'Checked, fine')::text$$),'');

-- WRITE OFF and replacement
select qty as q_before from public.stock_levels where item_id=:'it_lap' and storeroom_id=:'sr_main' \gset
select t.run('viewer cannot write off','authenticated',:'W',format($$select public.write_off_unit('%s','broken')::text$$,:'u_sn2'),'err:Not allowed');
select t.run('dispatch manager cannot write off','authenticated',:'V',format($$select public.write_off_unit('%s','broken')::text$$,:'u_sn2'),'err:Not allowed');
select t.run('write off needs a reason','authenticated',:'S',format($$select public.write_off_unit('%s','')::text$$,:'u_sn2'),'err:reason');
select t.run('storeman writes off SN-002','authenticated',:'S',format($$select public.write_off_unit('%s','Beyond repair, screen and board')::text$$,:'u_sn2'),'');
select t.check('write off: quantity down by exactly one', (select qty from public.stock_levels where item_id=:'it_lap' and storeroom_id=:'sr_main') = :q_before - 1);
select t.check('write off: unit kept, status written_off, damaged history kept', (select status::text||','||damaged::text from public.stock_units where id=:'u_sn2') = 'written_off,true');
select t.check('write off: history row has no movement but has the reason', (select count(*) from public.stock_ledger where kind='write_off' and unit_id=:'u_sn2' and movement_id is null and note like 'Beyond repair%') = 1);
select t.run('cannot write off twice','authenticated',:'S',format($$select public.write_off_unit('%s','again')::text$$,:'u_sn2'),'err:Only units in stock');
select t.run('written off unit cannot be flagged','authenticated',:'S',format($$select public.flag_unit('%s',false,'x')::text$$,:'u_sn2'),'err:Only units in stock');
select t.run('written off units are findable','authenticated',:'W',$$select string_agg(serial,',') from public.stock_units_search(null,null,'written_off')$$,'SN-002');
select t.run('written off unit leaves the in stock list','authenticated',:'W',$$select count(*)::text from public.stock_units_search('SN-002',null,'in_stock')$$,'0');
select t.run('viewer cannot add a replacement','authenticated',:'W',format($$select public.add_replacement('%s','SN-002B','new')::text$$,:'u_sn2'),'err:Not allowed');
select t.run('only written off units can be replaced','authenticated',:'S',format($$select public.add_replacement((select id from public.stock_units where serial='SN-007'),'X-1','new')::text$$),'err:Only a written off');
select t.run('replacement cannot reuse a serial','authenticated',:'S',format($$select public.add_replacement('%s','SN-004','new')::text$$,:'u_sn2'),'err:already on record');
select t.run('storeman adds the replacement to the same pile','authenticated',:'S',format($$select (public.add_replacement('%s','SN-002B','Warranty replacement'))::text is not null$$,:'u_sn2'),'true');
select t.check('replacement: quantity restored', (select qty from public.stock_levels where item_id=:'it_lap' and storeroom_id=:'sr_main') = :q_before);
select t.check('replacement: new unit is in stock, same storeroom, linked to the old one', (select count(*) from public.stock_units where serial='SN-002B' and status='in_stock' and storeroom_id=:'sr_main' and replaces_unit_id=:'u_sn2') = 1);
select t.run('a unit can only be replaced once','authenticated',:'S',format($$select public.add_replacement('%s','SN-002C','again')::text$$,:'u_sn2'),'err:already has a replacement');
select t.run('written off search shows it as replaced','authenticated',:'W',$$select replaced::text from public.stock_units_search('SN-002',null,'written_off')$$,'true');
-- quantity write offs
select t.run('bulk write off beyond stock refused','authenticated',:'S',format($$select public.write_off_stock('%s','%s',9999,'lost')::text$$,:'sr_main',:'it_bolt'),'err:are in stock');
select t.run('bulk write off needs a reason','authenticated',:'S',format($$select public.write_off_stock('%s','%s',1,'')::text$$,:'sr_main',:'it_bolt'),'err:reason');
select t.run('viewer cannot bulk write off','authenticated',:'W',format($$select public.write_off_stock('%s','%s',1,'lost')::text$$,:'sr_main',:'it_bolt'),'err:Not allowed');
select qty as bolt_before from public.stock_levels where item_id=:'it_bolt' and storeroom_id=:'sr_main' \gset
select t.run('storeman writes off 1 bolt','authenticated',:'S',format($$select public.write_off_stock('%s','%s',1,'Dropped down the drain')::text$$,:'sr_main',:'it_bolt'),'');
select t.check('bulk write off: quantity down by one', (select qty from public.stock_levels where item_id=:'it_bolt' and storeroom_id=:'sr_main') = :bolt_before - 1);
select t.run('serial pile: cannot bulk write off numbered units','authenticated',:'S',format($$select public.write_off_stock('%s','%s',5,'lost')::text$$,:'sr_main',:'it_lap'),'err:without a serial number');

-- TRANSFER with serials and a returned unit
set role authenticated; select set_config('request.jwt.claim.sub', :'S', false);
select public.create_movement('transfer',:'sr_main',:'sr_yard','Move to yard','','','',jsonb_build_array(jsonb_build_object('item_id',:'it_lap','qty',1,'serials',jsonb_build_array('SN-006')))) as mv_t \gset
select (public.submit_movement(:'mv_t','482913'))->>'ok';
reset role;
select t.run('transfer: V signs','authenticated',:'V',format($$select (public.sign_movement('%s','591204'))->>'completed'$$,:'mv_t'),'false');
select t.run('transfer: M signs, completes','authenticated',:'M',format($$select (public.sign_movement('%s','846205'))->>'completed'$$,:'mv_t'),'true');
select t.check('transfer: SN-006 is now in YARD and still in stock', (select storeroom_id::text||status::text from public.stock_units where serial='SN-006') = :'sr_yard'||'in_stock');
select t.run('written off serial cannot be received again','authenticated',:'S',format($$select public.create_movement('receive',null,'%s','Back','','','','[{"item_id":"%s","qty":1,"serials":["SN-002"]}]')::text$$,:'sr_yard',:'it_lap'),'err:already on record');
set role authenticated; select set_config('request.jwt.claim.sub', :'S', false);
select public.create_movement('receive',null,:'sr_yard','Customer A returned','','','',jsonb_build_array(jsonb_build_object('item_id',:'it_lap','qty',1,'serials',jsonb_build_array('SN-001')))) as mv_e \gset
select (public.submit_movement(:'mv_e','482913'))->>'ok';
reset role;
select t.run('return: V signs','authenticated',:'V',format($$select (public.sign_movement('%s','591204'))->>'completed'$$,:'mv_e'),'false');
select t.run('return: M signs, completes','authenticated',:'M',format($$select (public.sign_movement('%s','846205'))->>'completed'$$,:'mv_e'),'true');
select t.check('return: SN-001 is back in stock in YARD, same record, history kept', (select status::text||storeroom_id::text from public.stock_units where serial='SN-001') = 'in_stock'||:'sr_yard'
   and (select string_agg(kind, ',' order by e.id) from public.unit_events e join public.stock_units u on u.id=e.unit_id where u.serial='SN-001') = 'received,dispatched,received');
select t.run('final pile MAIN: 6 units, 3 serialised, 3 unassigned, 0 not working','authenticated',:'W',format($$select qty||'/'||serialised||'/'||unassigned||'/'||damaged from public.stock_piles('lap','%s')$$,:'sr_main'),'6.000/3/3.000/0');
select t.run('final pile YARD: 2 units, both serialised','authenticated',:'W',format($$select qty||'/'||serialised||'/'||unassigned from public.stock_piles('lap','%s')$$,:'sr_yard'),'2.000/2/0.000');

-- SEARCH: parameterised, wildcards literal, no injection
select t.run('search by SKU','authenticated',:'W',$$select count(*)::text from public.stock_piles('LAP-1')$$,'2');
select t.run('search by serial finds the pile','authenticated',:'W',$$select string_agg(storeroom_code,',' order by storeroom_code) from public.stock_piles('SN-007')$$,'MAIN');
select t.run('search by storeroom name','authenticated',:'W',$$select (count(*) > 0)::text from public.stock_piles('main store')$$,'true');
select t.run('search by barcode','authenticated',:'W',$$select count(*)::text from public.stock_piles('7001')$$,'2');
select t.run('percent sign is matched literally, not as a wildcard','authenticated',:'W',$$select count(*)::text from public.stock_piles('%')$$,'0');
select t.run('underscore is matched literally','authenticated',:'W',$$select count(*)::text from public.stock_piles('_')$$,'0');
select t.run('backslash is matched literally','authenticated',:'W',$$select count(*)::text from public.stock_units_search('\',null,'all')$$,'0');
select t.run('quote injection attempt returns nothing','authenticated',:'W',$$select count(*)::text from public.stock_piles('''; drop table public.items; --')$$,'0');
select t.run('union injection attempt returns nothing','authenticated',:'W',$$select count(*)::text from public.stock_units_search('x'' union select 1,2,3 --',null,'all')$$,'0');
select t.check('tables survived the injection attempts', to_regclass('public.items') is not null and to_regclass('public.stock_units') is not null);
select t.run('unknown state refused','authenticated',:'W',$$select count(*)::text from public.stock_units_search(null,null,'x'' or 1=1')$$,'err:Unknown state');
select t.run('limit is clamped to 500','authenticated',:'W',$$select (count(*) <= 500)::text from public.stock_units_search(null,null,'all',100000,0)$$,'true');
select t.run('negative offset is clamped','authenticated',:'W',$$select (count(*) > 0)::text from public.stock_units_search(null,null,'all',5,-10)$$,'true');
select t.run('anon cannot search','anon',null,$$select count(*)::text from public.stock_piles('x')$$,'err');
select t.run('anon cannot search units','anon',null,$$select count(*)::text from public.stock_units_search('x')$$,'err');

-- Access control on the new tables and functions
select t.run('members can read units','authenticated',:'W',$$select (count(*) > 0)::text from public.stock_units$$,'true');
select t.run('members can read unit history','authenticated',:'W',$$select (count(*) > 0)::text from public.unit_events$$,'true');
select t.run('members can read movement serials','authenticated',:'W',$$select (count(*) > 0)::text from public.movement_serials$$,'true');
select t.run('anon cannot read units','anon',null,$$select count(*)::text from public.stock_units$$,'err');
select t.run('storeman cannot insert units directly','authenticated',:'S',format($$insert into public.stock_units(item_id,storeroom_id,serial) values ('%s','%s','HACK')$$,:'it_lap',:'sr_main'),'err');
select t.run('storeman cannot update units directly','authenticated',:'S',$$update public.stock_units set damaged=false$$,'err');
select t.run('storeman cannot delete units','authenticated',:'S',$$delete from public.stock_units$$,'err');
select t.run('admin cannot edit unit history','authenticated',:'A',$$update public.unit_events set note='x'$$,'err');
select t.run('admin cannot forge unit history','authenticated',:'A',format($$insert into public.unit_events(unit_id,kind) select id,'note' from public.stock_units limit 1$$),'err');
select t.run('superuser cannot delete a unit','postgres',null,$$delete from public.stock_units$$,'err:append only');
select t.run('superuser cannot edit unit history','postgres',null,$$update public.unit_events set note='x'$$,'err:append only');
select t.run('internal serial checker not callable','authenticated',:'S',format($$select public._check_units('%s', true)::text$$,:'mv_a'),'err');
select t.run('serial tracking cannot be switched off once serials exist','authenticated',:'S',format($$update public.items set tracks_serials=false where id='%s'$$,:'it_lap'),'err:cannot be turned off');
select t.run('serial tracking can be switched on for another item','authenticated',:'S',$$update public.items set tracks_serials=true where sku='NUT-10'$$,'1');
select t.run('history page can read write offs with no movement','authenticated',:'W',$$select (count(*) >= 2)::text from public.stock_ledger where movement_id is null$$,'true');

select status||'  '||name||'   ['||detail||']' from t.results where n > :n_before and status = 'FAIL' order by n;
select '--- serial tests: '||count(*) filter (where status='PASS')||' passed, '||count(*) filter (where status='FAIL')||' failed' from t.results where n > :n_before;
select '--- whole suite: '||count(*) filter (where status='PASS')||' passed, '||count(*) filter (where status='FAIL')||' failed' from t.results;
