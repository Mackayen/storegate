Database tests. They run the four migrations on a plain local Postgres 15 or 16 with a small stand in for Supabase (roles, auth.uid(), storage), then exercise the receive and dispatch flows, tamper detection, PIN lockout, gate pass single use and the access control rules.

    createdb sgtest
    psql -d sgtest -f tests/00_supabase_stub.sql
    for f in supabase/migrations/*.sql; do psql -d sgtest -v ON_ERROR_STOP=1 -f "$f"; done
    psql -d sgtest -f tests/01_flow_and_security.sql
    psql -d sgtest -f tests/02_serials.sql      # run after 01, it reuses its users

The last line printed should read "0 failed". Run it again after any change to the migrations.
