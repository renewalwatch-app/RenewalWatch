# RenewalWatch setup

RenewalWatch tracks IT assets and renewal dates and emails reminders before things expire.
It runs on GitHub, Vercel, Supabase, Stripe and Resend. Nothing needs installing or building.

Plan on about 45 minutes. Do the steps in this order.

## 1. Buy the domain

renewalwatch.ca was available on Nov 20, 2026. Buy it at Namecheap. Every other service below uses it.

## 2. Put the code on GitHub

1. Create a new private repository named `renewalwatch`.
2. Click "uploading an existing file", then drag in everything from this folder, including the `api`, `assets` and `supabase` folders.
3. Commit.

## 3. Supabase (database and sign-in)

1. Create a new project. Pick the Canada (Central) region.
2. Go to SQL Editor, click New query, paste in all of `supabase/schema.sql` and click Run. It should say "Success".
3. Go to Authentication, then URL Configuration:
   1. Set Site URL to `https://renewalwatch.ca`
   2. Add these Redirect URLs: `https://renewalwatch.ca/app` and `https://*.vercel.app/app`
4. Go to Project Settings, then API Keys, and copy three values:
   1. Project URL, which goes in `SUPABASE_URL`
   2. The publishable or anon key, which goes in `SUPABASE_ANON_KEY`
   3. The secret or service_role key, which goes in `SUPABASE_SERVICE_KEY`. Keep this one private.

## 4. Resend (reminder emails and sign-up emails)

1. Create a free account at resend.com.
2. Add the domain `renewalwatch.ca`. Resend shows you some DNS records; add them in Namecheap under Advanced DNS, then wait for Resend to verify them.
3. Create an API key. It goes in `RESEND_API_KEY`.
4. Supabase's built-in email only sends a few messages per hour, so switch it to Resend. In Supabase, go to Authentication, then Emails, then SMTP Settings, turn on custom SMTP and enter:
   1. Host: `smtp.resend.com`
   2. Port: `465`
   3. Username: `resend`
   4. Password: your Resend API key
   5. Sender email: `noreply@renewalwatch.ca`
   6. Sender name: `RenewalWatch`

## 5. Stripe (Pro subscription)

Do this in Test mode first. Repeat it in Live mode when you're ready to charge.

1. Under Product catalog, add a product named "RenewalWatch Pro" with two recurring prices: $12 CAD per month and $120 CAD per year.
2. Create one Payment Link for the monthly price and another for the yearly price. Under "After payment", choose "Don't show confirmation page" and redirect to `https://www.renewalwatch.ca/app?upgraded=1`. The monthly link goes in `STRIPE_PAYMENT_LINK` and the yearly link goes in `STRIPE_PAYMENT_LINK_YEARLY`.
3. Go to Settings, then Billing, then Customer portal. Activate it, allow cancelling and updating the payment method, and copy the login link. It goes in `STRIPE_PORTAL_LINK`.
4. Go to Developers, then Webhooks, and add an endpoint:
   1. URL: `https://www.renewalwatch.ca/api/stripe-webhook`
   2. Events: `checkout.session.completed`, `customer.subscription.updated`, `customer.subscription.deleted`
   3. Copy the signing secret (it starts with `whsec_`). It goes in `STRIPE_WEBHOOK_SECRET`.

## 6. Vercel (hosting)

1. Click Add New, then Project, and import the `renewalwatch` GitHub repo. Leave Framework Preset as "Other" and leave the build settings blank.
2. Add these environment variables before you deploy:

| Name | Value |
|---|---|
| SUPABASE_URL | from step 3 |
| SUPABASE_ANON_KEY | from step 3 |
| SUPABASE_SERVICE_KEY | from step 3 (secret) |
| STRIPE_PAYMENT_LINK | from step 5 (monthly) |
| STRIPE_PAYMENT_LINK_YEARLY | from step 5 (yearly) |
| STRIPE_PORTAL_LINK | from step 5 |
| STRIPE_WEBHOOK_SECRET | from step 5 (secret) |
| RESEND_API_KEY | from step 4 (secret) |
| REMINDER_FROM | `RenewalWatch <reminders@renewalwatch.ca>` |
| APP_URL | `https://renewalwatch.ca` |
| CRON_SECRET | any random string of 32 or more characters (secret) |
| PRICE_LABEL | `$12/month` |
| PRICE_LABEL_YEARLY | `$120/year` |
| GA_MEASUREMENT_ID | your Google Analytics ID, like `G-ABC123XYZ` (optional) |

3. Deploy.
4. Go to Settings, then Domains, and add `renewalwatch.ca`. Vercel shows DNS records to add in Namecheap.
5. Vercel calls the daily reminder job at 6 AM Eastern on its own, using CRON_SECRET.

If you change an environment variable later, redeploy so the change takes effect.

## 7. Test it

1. Open `https://renewalwatch.ca/app`, create an account and confirm the email.
2. Add a laptop with a warranty date 7 days from today.
3. Click Upgrade and pay with Stripe's test card 4242 4242 4242 4242. You should come back to the app as Pro within a few seconds.
4. To trigger reminders right away, run this from any terminal:
   `curl -H "Authorization: Bearer YOUR_CRON_SECRET" https://renewalwatch.ca/api/cron-reminders`
   An email should arrive for the laptop.

## Costs

1. Domain: about $15 a year.
2. Supabase free tier: 500 MB database and 50,000 monthly users. Free projects pause after a week with no activity, but the daily reminder job counts as activity.
3. Resend free tier: 3,000 emails a month and 100 a day.
4. Stripe: no monthly fee, only a percentage of each payment.
5. Vercel: the Hobby (free) plan is for non-commercial use only. Testing on it is fine. Once you charge customers, Vercel's terms require the Pro plan (US$20 a month).

## What's in the app

The Free plan covers up to 25 items: computers, peripherals, printers, phones, extended warranties and other hardware. It includes reminders 30 and 7 days before each date, on the day itself, and weekly for anything overdue, plus CSV export.

The Pro plan adds:

1. Unlimited items.
2. Servers and infrastructure: physical servers, VMs, network devices, NAS/SAN storage, UPS units and backup jobs.
3. Software and cloud: software licenses, SaaS subscriptions, security services and cloud accounts.
4. Internet-facing items: domains and SSL certificates.
5. Contracts: support contracts, ISP circuits, phone systems, leases, and compliance or cyber insurance.
6. Recurring IT tasks.
7. A custom reminder schedule and extra recipients.
8. Team members.
9. A 12-month renewal spend forecast.
10. A license check that flags unused or over-allocated seats.
11. Health checks for unpatched servers, OS end of support, stale firmware, untested backups, UPS self-tests, 5-year-old laptops, and domains or SSL certificates that won't auto-renew.
12. A People view with printable offboarding checklists.
13. CSV import.
14. Automatic domain and SSL expiry lookups, refreshed daily.
15. A calendar subscription link for Outlook, Google Calendar and iPhone.
16. File attachments on each item, up to 10 MB per file.
17. QR labels (30 per sheet, Avery 5160) that open the item when scanned, plus a history of assignment, status and location changes.
18. Equipment value (straight-line depreciation) and a 12-month replacement list.

## Files

1. `index.html`: landing page
2. `app.html` and `assets/app.js`: the app
3. `assets/categories.js`: item types and their fields. Edit this to add a category, and also add the category to `free_cats` in schema.sql if it should be free.
4. `api/config.js`: public settings for the browser
5. `api/stripe-webhook.js`: switches workspaces to Pro or Free
6. `api/cron-reminders.js`: the daily reminder emails
7. `supabase/schema.sql`: tables, security rules and free-plan limits
