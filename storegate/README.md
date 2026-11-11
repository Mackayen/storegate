# StoreGate

Stock receiving and dispatch for storerooms, on a Supabase backend. Every movement is signed off in a set order, produces a delivery note, and ends with a gate pass the guard scans.

## What it does

- Receive, dispatch and transfer stock between storerooms. Stock per storeroom is always visible, and every change is kept in an append only ledger.
- A storeman prepares a movement, then submits it with their PIN. That creates the delivery note and notifies the next approver.
- Each approver signs with their PIN. Their saved signature is stamped on the document. When the last person signs, the stock moves and the gate pass is created.
- The guard scans the gate pass QR code. The app shows what was checked and who signed. A pass can be used once.
- Notifications appear in the app straight away and are also emailed.
- Works as an installable web app on phones and laptops. USB barcode scanners work because they type into the scan field and press Enter. Camera scanning was removed for now.
- Items can be marked as serial numbered. Receive them with serial numbers, or add the serial numbers later from the Search page. Every unit that is dispatched or transferred must have its serial number scanned, and those units leave stock.
- Delivery notes have a delivery address. Details (supplier or customer, delivery address, vehicle, driver, notes) can be edited by admins, storemen, dispatch managers and procurement at any stage until the movement is rejected or cancelled. Each change is recorded with who made it, and shows under Amendments on the note. The gate check always shows the current details. Items, quantities and serial numbers can only be changed while the movement is a draft (Edit items). After submit they are signed and locked, so to change them reject or cancel and start again.
- Search page: stock by name, SKU, barcode, serial number, note or storeroom, with filters for working, not working, written off and dispatched units. The search runs in the database with bound parameters.
- Storemen and admins can flag a unit as not working (red, with a note), add notes, write a unit or a quantity off with a reason, and add a replacement back into the same pile. Everything stays in the unit's history. The Stock page shows how many are not working.

## Roles

admin, storeman, dispatch manager, procurement, security (the guard), viewer. Storemen, dispatch managers, procurement and admins can prepare movements. The sign off chain after "prepared by" is stored in the table `signoff_steps` and is edited under Admin. It currently runs dispatch manager, then procurement.

## Set up Supabase

1. Create a project at supabase.com.
2. Open the SQL editor and run the six files in `supabase/migrations` in order.
3. Authentication > Sign In / Providers: turn off "Allow new users to sign up". Turn on "Confirm email". Set a minimum password length of 12 or more.
4. Create the first user under Authentication > Users > Add user. Then make that user the admin by running this with their email:

       update public.profiles set role = 'admin', active = true
       where id = (select id from auth.users where email = 'you@example.com');

5. Create everyone else the same way. New accounts are inactive until an admin activates them and assigns a role under Admin > Users.
6. Each person signs in, opens Profile, sets a 6 digit PIN and draws their signature once. Nobody can submit or sign before both are set.
7. Admin > Storerooms and Admin > Items: add your storerooms and items. Item barcodes are what the scanner reads.

Turn on an authenticator app (TOTP) for the admin account under Authentication > Multi-Factor.

## Email notifications

1. Create a Resend account and verify a sending domain or address.
2. Set the function secrets:

       supabase secrets set WEBHOOK_SECRET=<long random string> RESEND_API_KEY=<key> FROM_EMAIL="StoreGate <noreply@yourdomain>" APP_URL=https://your-app-address

3. Deploy: `supabase functions deploy notify-email --no-verify-jwt`
4. Database > Webhooks > Create: table `notifications`, event Insert, type Supabase Edge Function, function `notify-email`, and add the HTTP header `x-webhook-secret` with the same value as WEBHOOK_SECRET.

## Run and host

    cp .env.example .env      # fill in the project URL and the anon key (never the service role key)
    npm install
    npm run dev               # local
    npm run build             # produces dist/

Free hosting on Cloudflare Pages: connect the repository, build command `npm run build`, output directory `dist`, and add the two VITE_ variables. `public/_headers` sets the security headers and `public/_redirects` handles page routes.

Or serve `dist/` from a PC on the network with Caddy or Nginx and HTTPS. The PC does almost no work.

## Security model

- Row level security is on every table. The browser can read what a member is allowed to see and write almost nothing directly. All stock, sign off, delivery note and gate pass changes go through database functions that check the caller's role.
- Default grants are revoked. Anonymous visitors can read nothing and call nothing.
- Stock changes only happen when the last signature is added, inside one transaction. A dispatch cannot take stock below zero.
- A hash of the movement is stored at submission and checked at every signature, so edits after submission are caught.
- PINs are bcrypt hashed in a table the API cannot reach. Five wrong attempts lock signing for 15 minutes, and the counter survives the failed call.
- The ledger, sign offs, delivery notes and audit log reject updates and deletes, including from privileged roles.
- Signatures are in a private storage bucket. A member can read another person's signature only after it was used on a signed movement.
- New accounts are inactive until an admin activates them, and the role is never read from user supplied metadata.
- The page is served with a strict content security policy, no framing, and no inline scripts.

## Free plan notes

Supabase free projects pause after a week with no activity and have no automatic backups. Use `scripts/backup.sh` once a day and keep the copies off the machine.

## Tested

The database tests in `tests/` pass 257 of 257 against Postgres 16 (78 flow and security, 126 serial numbers, search, write offs and replacements, 53 delivery note edits). The built app was checked in a browser with a mocked backend for login redirect, the guard screen and the role guards. It has not yet been run against a live Supabase project, so do a full receive, dispatch and gate scan with test accounts before real use.

## Decisions still open

- The sign off chain for each movement type, and whether the receiver or requester signs too.
- A person cannot sign twice on one movement. If a dispatch manager prepares a movement, a second dispatch manager has to do the dispatch manager check. Decide whether that is wanted or whether the preparer's own step should count.
- PIN or full password at each signature. A PIN is built.
- A 2D scanner is needed to read the QR code on gate passes. A 1D scanner works for item barcodes only. The pass also prints a manual entry code.
- Camera scanning is removed for now. USB scanners only.
- A damaged unit cannot be dispatched. Replacements are added without a sign off, by storeman or admin only, and are recorded in the history.
