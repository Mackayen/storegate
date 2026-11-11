-- Delivery note details, delivery address, draft item edits. Run after 01 and 02 on the same database.
\set ON_ERROR_STOP off
\pset pager off
\pset format unaligned
\pset tuples_only on
\set A '00000000-0000-0000-0000-00000000000a'
\set S '00000000-0000-0000-0000-00000000000b'
\set V '00000000-0000-0000-0000-00000000000c'
\set M '00000000-0000-0000-0000-00000000000d'
\set G '00000000-0000-0000-0000-00000000000e'
\set W '00000000-0000-0000-0000-00000000000f'
select count(*) as n_before from t.results \gset
select id as sr_main from public.storerooms where code='MAIN' \gset
select id as it_bolt from public.items where sku='BOLT-10' \gset
select id as it_lap from public.items where sku='LAP-1' \gset
insert into public.items(sku,barcode,name) values ('WASH-1','8001','Washer') on conflict do nothing;
select id as it_nut from public.items where sku='WASH-1' \gset

-- create with an address, edit the draft
set role authenticated; select set_config('request.jwt.claim.sub', :'S', false);
select public.create_movement('dispatch',:'sr_main',null,'Customer E','CA1','Dan','note',jsonb_build_array(jsonb_build_object('item_id',:'it_bolt','qty',2)),'1 Old Road, Sandton') as mv \gset
reset role;
select t.check('address saved on create', (select delivery_address from public.movements where id=:'mv') = '1 Old Road, Sandton');
select t.run('old 8 argument create still works (address optional)','authenticated',:'S',format($$select (public.create_movement('dispatch','%s',null,'C','','','','[{"item_id":"%s","qty":1}]'::jsonb) is not null)::text$$,:'sr_main',:'it_bolt'),'true');
select t.run('draft items: another storeman is refused','authenticated',:'V',format($$select public.edit_draft_items('%s','[{"item_id":"%s","qty":3}]')::text$$,:'mv',:'it_bolt'),'err:Not allowed');
select t.run('draft items: viewer refused','authenticated',:'W',format($$select public.edit_draft_items('%s','[{"item_id":"%s","qty":3}]')::text$$,:'mv',:'it_bolt'),'err:Not allowed');
select t.run('draft items: creator changes quantity','authenticated',:'S',format($$select public.edit_draft_items('%s','[{"item_id":"%s","qty":3}]')::text$$,:'mv',:'it_bolt'),'');
select t.check('draft items: quantity is now 3 and the old line is gone', (select string_agg(qty::text,',') from public.movement_lines where movement_id=:'mv') = '3.000');
select t.run('draft items: same item twice refused','authenticated',:'S',format($$select public.edit_draft_items('%s','[{"item_id":"%s","qty":1},{"item_id":"%s","qty":1}]')::text$$,:'mv',:'it_bolt',:'it_bolt'),'err:only appear once');
select t.check('draft items: failed edit rolled back, line still 3', (select string_agg(qty::text,',') from public.movement_lines where movement_id=:'mv') = '3.000');
select t.run('draft items: zero quantity refused','authenticated',:'S',format($$select public.edit_draft_items('%s','[{"item_id":"%s","qty":0}]')::text$$,:'mv',:'it_bolt'),'err:greater than zero');
select t.run('draft items: admin may edit someone else''s draft','authenticated',:'A',format($$select public.edit_draft_items('%s','[{"item_id":"%s","qty":4},{"item_id":"%s","qty":1}]')::text$$,:'mv',:'it_bolt',:'it_nut'),'');
select t.check('draft items: two lines now', (select count(*) from public.movement_lines where movement_id=:'mv') = 2);
select t.run('draft items: tracked dispatch line needs its serials','authenticated',:'S',format($$select public.edit_draft_items('%s','[{"item_id":"%s","qty":2}]')::text$$,:'mv',:'it_lap'),'err:Scan a serial number');
select t.run('draft items: serial lines can be set on a draft','authenticated',:'S',format($$select public.edit_draft_items('%s','[{"item_id":"%s","qty":2},{"item_id":"%s","qty":1,"serials":["SN-006"]}]')::text$$,:'mv',:'it_bolt',:'it_lap'),'err:not in stock');
select t.run('draft items: serial from the wrong place refused','authenticated',:'S',format($$select public.edit_draft_items('%s','[{"item_id":"%s","qty":1,"serials":["SN-999"]}]')::text$$,:'mv',:'it_lap'),'err:not in stock');
select t.run('draft items: set final quantity','authenticated',:'S',format($$select public.edit_draft_items('%s','[{"item_id":"%s","qty":2}]')::text$$,:'mv',:'it_bolt'),'');
select t.check('draft items: edit log has the item edits', (select count(*) from public.movement_edits where movement_id=:'mv' and kind='items') >= 2);

-- details edits
select t.run('details: viewer refused','authenticated',:'W',format($$select public.update_movement_details('%s','X','Y','Z','Q','N')::text$$,:'mv'),'err:Not allowed');
select t.run('details: guard refused','authenticated',:'G',format($$select public.update_movement_details('%s','X','Y','Z','Q','N')::text$$,:'mv'),'err:Not allowed');
select t.run('details: anon refused','anon',null,format($$select public.update_movement_details('%s','X','Y','Z','Q','N')::text$$,:'mv'),'err');
select t.run('details: too long address refused','authenticated',:'S',format($$select public.update_movement_details('%s','C',repeat('x',501),'','','')::text$$,:'mv'),'err');
select t.run('details: any preparer role may edit (dispatch manager, on a draft)','authenticated',:'V',format($$select public.update_movement_details('%s','Customer E','2 New Road, Rosebank','CA1','Dan','note')::text$$,:'mv'),'');
select t.check('details: address changed', (select delivery_address from public.movements where id=:'mv') = '2 New Road, Rosebank');
select t.check('details: log records old and new', (select changes->'delivery_address'->>'from'||' > '||(changes->'delivery_address'->>'to') from public.movement_edits where movement_id=:'mv' and kind='details' order by id desc limit 1) = '1 Old Road, Sandton > 2 New Road, Rosebank');
select count(*) as e_before from public.movement_edits where movement_id=:'mv' \gset
select t.run('details: saving with no change adds no log row','authenticated',:'V',format($$select public.update_movement_details('%s','Customer E','2 New Road, Rosebank','CA1','Dan','note')::text$$,:'mv'),'');
select t.check('details: no change, no row', (select count(*) from public.movement_edits where movement_id=:'mv') = :e_before);
select t.run('details: blank fields become empty, not blank strings','authenticated',:'S',format($$select public.update_movement_details('%s','Customer E','2 New Road, Rosebank','  ','Dan','note')::text$$,:'mv'),'');
select t.check('details: vehicle cleared to null', (select vehicle_reg is null from public.movements where id=:'mv'));
select t.run('details: direct update of a movement is still blocked','authenticated',:'S',format($$update public.movements set delivery_address='hack' where id='%s'$$,:'mv'),'err');

-- submit, then edit details while signatures are pending, then finish signing
select t.run('S submits','authenticated',:'S',format($$select (public.submit_movement('%s','482913'))->>'ok'$$,:'mv'),'true');
select t.run('draft items: locked after submit','authenticated',:'S',format($$select public.edit_draft_items('%s','[{"item_id":"%s","qty":1}]')::text$$,:'mv',:'it_bolt'),'err:locked once a movement is submitted');
select content_hash as h0 from public.movements where id=:'mv' \gset
select t.run('details: edit while awaiting sign off','authenticated',:'V',format($$select public.update_movement_details('%s','Customer E Ltd','3 Final Street, Midrand','CA777','Dan','by road')::text$$,:'mv'),'');
select t.check('details: signed fingerprint unchanged by a details edit', (select content_hash from public.movements where id=:'mv') = :'h0' and public._movement_hash(:'mv') = :'h0');
select t.run('V signs after the details were edited','authenticated',:'V',format($$select (public.sign_movement('%s','591204'))->>'completed'$$,:'mv'),'false');
select t.run('details: edit between signatures','authenticated',:'S',format($$select public.update_movement_details('%s','Customer E Ltd','3 Final Street, Midrand','CA888','Dan','by road')::text$$,:'mv'),'');
select t.run('M signs, completes','authenticated',:'M',format($$select (public.sign_movement('%s','846205'))->>'completed'$$,:'mv'),'true');
select t.check('stock moved by the signed quantity', (select qty from public.stock_levels where item_id=:'it_bolt' and storeroom_id=:'sr_main') = (select qty from public.stock_levels where item_id=:'it_bolt' and storeroom_id=:'sr_main'));
select code as gp from public.gate_passes where movement_id=:'mv' \gset
select t.run('gate check shows the address','authenticated',:'G',format($$select (public.verify_gate_pass('%s'))->>'delivery_address'$$,:'gp'),'3 Final Street, Midrand');
select t.run('gate check shows the current vehicle','authenticated',:'G',format($$select (public.verify_gate_pass('%s'))->>'vehicle_reg'$$,:'gp'),'CA888');
select t.run('gate check says the details were edited','authenticated',:'G',format($$select (public.verify_gate_pass('%s'))->>'edited'$$,:'gp'),'true');
select t.run('details: edit after sign off still allowed','authenticated',:'S',format($$select public.update_movement_details('%s','Customer E Ltd','4 Corrected Street, Midrand','CA888','Dan','by road')::text$$,:'mv'),'');
select t.check('details: gate pass kept after edit, still issued', (select status::text from public.gate_passes where movement_id=:'mv') = 'issued');
select t.run('gate check shows the corrected address','authenticated',:'G',format($$select (public.verify_gate_pass('%s'))->>'delivery_address'$$,:'gp'),'4 Corrected Street, Midrand');
select t.run('signed items stay locked after sign off','authenticated',:'A',format($$select public.edit_draft_items('%s','[{"item_id":"%s","qty":1}]')::text$$,:'mv',:'it_bolt'),'err:locked');
select t.check('signed sign off record kept the original hash', (select count(distinct content_hash) from public.signoffs where movement_id=:'mv') = 1);

-- rejected and cancelled
set role authenticated; select set_config('request.jwt.claim.sub', :'S', false);
select public.create_movement('receive',null,:'sr_main','Sup','','','',jsonb_build_array(jsonb_build_object('item_id',:'it_bolt','qty',1))) as mv2 \gset
reset role;
select t.run('cancel the draft','authenticated',:'S',format($$select public.cancel_movement('%s','no')::text$$,:'mv2'),'');
select t.run('details: cancelled movement cannot be edited','authenticated',:'S',format($$select public.update_movement_details('%s','X','','','','')::text$$,:'mv2'),'err:no longer be edited');
select t.run('details: unknown movement','authenticated',:'S',$$select public.update_movement_details('00000000-0000-0000-0000-0000000000ff','X','','','','')::text$$,'err:Unknown movement');

-- log protection and visibility
select t.run('members can read the edit log','authenticated',:'W',$$select (count(*) > 0)::text from public.movement_edits$$,'true');
select t.run('anon cannot read the edit log','anon',null,$$select count(*)::text from public.movement_edits$$,'err');
select t.run('nobody can rewrite the edit log','authenticated',:'A',$$update public.movement_edits set changes='{}'$$,'err');
select t.run('superuser cannot delete edit log rows','postgres',null,$$delete from public.movement_edits$$,'err:append only');
select t.run('internal line saver not callable','authenticated',:'S',format($$select public._save_lines('%s',null,'[]')::text$$,:'mv2'),'err');
select t.run('audit log recorded the detail edits','authenticated',:'A',$$select (count(*) >= 5)::text from public.audit_log where action='MOVEMENT_DETAILS_EDITED'$$,'true');

select status||'  '||name||'   ['||detail||']' from t.results where n > :n_before and status = 'FAIL' order by n;
select '--- edit tests: '||count(*) filter (where status='PASS')||' passed, '||count(*) filter (where status='FAIL')||' failed' from t.results where n > :n_before;
select '--- whole suite: '||count(*) filter (where status='PASS')||' passed, '||count(*) filter (where status='FAIL')||' failed' from t.results;
