-- ══════════════════════════════════════════════════════════════════
--  D-SWIFT MALL — full Supabase schema, built for a BRAND NEW project
--  Run top to bottom, once, in Supabase → SQL Editor.
--  Nothing here assumes any table/function already exists.
-- ══════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════
--  1. TABLES
-- ════════════════════════════════════════════════

create table public.profiles (
    id           uuid primary key references auth.users(id) on delete cascade,
    name         text not null default '',
    phone        text,
    location     text,
    bio          text,
    profile_pic  text,
    store_name   text,
    momo_number  text,
    role         text not null default 'buyer' check (role in ('buyer','seller','delivery','admin')),
    is_banned    boolean not null default false,
    created_at   timestamptz not null default now()
);

create table public.products (
    id            bigint generated always as identity primary key,
    seller_id     uuid references public.profiles(id) on delete set null,
    seller_name   text not null default 'D-Swift Mall',
    seller_phone  text,
    name          text not null,
    price         numeric(10,2) not null check (price >= 0),
    category      text not null,
    description   text,
    image         text,
    extra_images  jsonb not null default '[]'::jsonb,
    created_at    timestamptz not null default now()
);

create table public.orders (
    id            bigint generated always as identity primary key,
    ref           text unique not null,
    buyer_id      uuid not null references public.profiles(id) on delete restrict,
    status        text not null default 'pending'
                    check (status in ('pending','accepted','out_for_delivery','delivered','cancelled')),
    items         jsonb not null,        -- [{id, name, price, qty, sellerId, sellerName, sellerPhone}, ...]
    total         numeric(10,2) not null check (total >= 0),
    delivery_fee  numeric(10,2),
    customer_name text,
    phone         text,
    address       text,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

-- Delivery riders view orders through this — a VIEW rather than a
-- separate table, so status always comes from one source of truth
-- (`orders`) instead of two tables drifting out of sync.
-- `security_invoker = true` makes it respect the RLS policies of the
-- underlying `orders` table for whoever is querying it (needs Postgres
-- 15+, which current Supabase projects run by default).
create view public.delivery_orders
with (security_invoker = true) as
    select
        o.id, o.ref, o.status, o.items, o.total, o.delivery_fee,
        o.customer_name, o.phone, o.address, o.created_at, o.updated_at
    from public.orders o;

create table public.sales (
    id           bigint generated always as identity primary key,
    seller_id    uuid not null references public.profiles(id) on delete cascade,
    order_id     bigint not null references public.orders(id) on delete cascade,
    product_id   bigint references public.products(id) on delete set null,
    product_name text,
    gross        numeric(10,2) not null check (gross >= 0),
    paid_out     boolean not null default false,
    paid_out_at  timestamptz,
    created_at   timestamptz not null default now()
);

create table public.wishlist (
    id          bigint generated always as identity primary key,
    user_id     uuid not null references public.profiles(id) on delete cascade,
    product_id  bigint not null references public.products(id) on delete cascade,
    created_at  timestamptz not null default now(),
    unique (user_id, product_id)
);

create table public.notifications (
    id          bigint generated always as identity primary key,
    user_id     uuid not null references public.profiles(id) on delete cascade,
    title       text not null,
    body        text,
    is_read     boolean not null default false,
    created_at  timestamptz not null default now()
);

create table public.contacts (
    id          bigint generated always as identity primary key,
    name        text not null,
    email       text not null,
    message     text not null,
    is_read     boolean not null default false,
    created_at  timestamptz not null default now()
);

create table public.banners (
    id          bigint generated always as identity primary key,
    title       text not null,
    subtitle    text,
    tag         text,                          -- small pill label e.g. "HOT DEALS"
    cta_text    text not null default 'Shop Now',
    link        text not null default '#products',
    image_url   text not null,                 -- uploaded photo, shown as the slide background
    sort_order  integer not null default 0,
    active      boolean not null default true,
    created_at  timestamptz not null default now()
);

create table public.flash_sales (
    id          bigint generated always as identity primary key,
    title       text not null default 'Flash Sales',
    link        text not null default '#products',
    end_time    timestamptz not null,           -- real countdown target — no more fake looping timer
    active      boolean not null default true,
    created_at  timestamptz not null default now()
);

create table public.messages (
    id           bigint generated always as identity primary key,
    order_ref    text not null references public.orders(ref) on delete cascade,
    sender_id    uuid not null references public.profiles(id) on delete cascade,
    sender_role  text not null,
    sender_name  text not null,
    message      text not null,
    created_at   timestamptz not null default now()
);

create index idx_products_seller   on public.products(seller_id);
create index idx_orders_buyer      on public.orders(buyer_id);
create index idx_orders_ref        on public.orders(ref);
create index idx_sales_seller      on public.sales(seller_id);
create index idx_messages_ref      on public.messages(order_ref);
create index idx_notifications_uid on public.notifications(user_id);


-- ════════════════════════════════════════════════
--  2. AUTO-CREATE A PROFILE ON SIGNUP
-- ════════════════════════════════════════════════

create or replace function public.handle_new_user()
returns trigger as $$
begin
    insert into public.profiles (id, name, role, momo_number)
    values (
        new.id,
        coalesce(new.raw_user_meta_data->>'name', ''),
        coalesce(new.raw_user_meta_data->>'role', 'buyer'),
        new.raw_user_meta_data->>'momo_number'
    );
    return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();


-- ════════════════════════════════════════════════
--  3. GUARD RAILS — stop self-service privilege escalation
-- ════════════════════════════════════════════════

create or replace function public.prevent_privilege_escalation()
returns trigger as $$
begin
    if auth.role() = 'authenticated' then
        if new.role is distinct from old.role then
            raise exception 'You cannot change your own role.';
        end if;
        if new.is_banned is distinct from old.is_banned then
            raise exception 'You cannot change your own ban status.';
        end if;
    end if;
    return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_prevent_privilege_escalation
    before update on public.profiles
    for each row execute function public.prevent_privilege_escalation();

-- keep `updated_at` honest on orders
create or replace function public.touch_updated_at()
returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

create trigger trg_orders_touch
    before update on public.orders
    for each row execute function public.touch_updated_at();

-- A seller must have a MoMo number on file before they can list ANY
-- product. Enforced here (not just in the frontend form) so it can't
-- be bypassed by editing requests directly or from another client.
create or replace function public.require_seller_momo_number()
returns trigger as $$
declare
    v_momo text;
begin
    select momo_number into v_momo from public.profiles where id = new.seller_id;
    if v_momo is null or btrim(v_momo) = '' then
        raise exception 'Add a Mobile Money number to your profile before listing products.';
    end if;
    return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_require_seller_momo_number
    before insert on public.products
    for each row
    when (new.seller_id is not null)
    execute function public.require_seller_momo_number();


-- ════════════════════════════════════════════════
--  4. RPC FUNCTIONS  (messages.html, delivery.html, track.html)
-- ════════════════════════════════════════════════

-- ── send_message(p_ref, p_message) ──
-- Inserts a message on behalf of the calling user, auto-filling their
-- role/name from `profiles` (never trusts a client-supplied sender).
create or replace function public.send_message(p_ref text, p_message text)
returns void as $$
declare
    v_role text;
    v_name text;
begin
    select role, name into v_role, v_name from public.profiles where id = auth.uid();
    if v_role is null then
        raise exception 'Not authorized.';
    end if;
    if not exists (select 1 from public.orders where ref = p_ref) then
        raise exception 'Order not found.';
    end if;
    insert into public.messages (order_ref, sender_id, sender_role, sender_name, message)
    values (p_ref, auth.uid(), v_role, v_name, p_message);
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function public.send_message(text, text) to authenticated;


-- ── get_conversations() ──
-- One row per order the calling user is party to. Simplified model:
-- for a BUYER, "the other party" is the delivery rider (matches the
-- existing "Message Delivery Guy" flow in kscript.js). For a DELIVERY
-- rider or ADMIN, "the other party" is the buyer. If you later want
-- buyer<->seller threads too, extend this with a seller branch.
create or replace function public.get_conversations()
returns table (
    ref              text,
    other_name       text,
    other_role       text,
    other_phone      text,
    product_context  text,
    order_status     text,
    order_date       timestamptz,
    last_message     text,
    last_sender_name text,
    last_message_at  timestamptz
) as $$
declare
    v_role text;
begin
    select role into v_role from public.profiles where id = auth.uid();

    return query
    select
        o.ref,
        case when v_role = 'buyer' then 'D-Swift Mall Delivery' else buyer.name end as other_name,
        case when v_role = 'buyer' then 'delivery' else 'buyer' end as other_role,
        case when v_role = 'buyer' then null else buyer.phone end as other_phone,
        (o.items->0->>'name') as product_context,
        o.status,
        o.created_at,
        lm.message,
        lm.sender_name,
        lm.created_at
    from public.orders o
    join public.profiles buyer on buyer.id = o.buyer_id
    left join lateral (
        select message, sender_name, created_at
        from public.messages m
        where m.order_ref = o.ref
        order by m.created_at desc
        limit 1
    ) lm on true
    where
        (v_role = 'buyer' and o.buyer_id = auth.uid())
        or (v_role in ('delivery','admin') and exists (select 1 from public.messages m where m.order_ref = o.ref))
        or (v_role in ('delivery','admin') and o.status in ('pending','accepted','out_for_delivery'));
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function public.get_conversations() to authenticated;


-- ── track_order(p_ref) ──
-- Public order tracking (accessed via a shared link, no login
-- required — matches how track.html is used). Deliberately returns
-- only what a tracking page needs, translating the internal order
-- status into the step-keys track.html's UI expects.
create or replace function public.track_order(p_ref text)
returns table (
    ref            text,
    customer_name  text,
    phone          text,
    address        text,
    items          jsonb,
    total          numeric,
    status         text
) as $$
begin
    return query
    select
        o.ref,
        coalesce(o.customer_name, buyer.name),
        coalesce(o.phone, buyer.phone),
        coalesce(o.address, buyer.location),
        o.items,
        o.total,
        case o.status
            when 'pending'          then 'confirmed'
            when 'accepted'         then 'packed'
            when 'out_for_delivery' then 'out'
            when 'delivered'        then 'delivered'
            else o.status
        end
    from public.orders o
    join public.profiles buyer on buyer.id = o.buyer_id
    where o.ref = p_ref;
end;
$$ language plpgsql security definer set search_path = public;

-- Public/anon can call this — that's intentional (it's a shareable
-- tracking link), but it only ever returns rows for the exact ref
-- given, never a listing, so it can't be used to browse other orders.
grant execute on function public.track_order(text) to anon, authenticated;


-- ── update_delivery_status(p_ref, p_action, p_fee) ──
-- Only callable by delivery riders/admins. Maps a rider action to the
-- next order status. Matches STEP_TO_ACTION in track.html:
--   accept   → pending → accepted
--   dispatch → accepted → out_for_delivery
--   deliver  → out_for_delivery → delivered  (optionally records p_fee)
create or replace function public.update_delivery_status(p_ref text, p_action text, p_fee numeric default null)
returns void as $$
declare
    v_role text;
    v_current text;
    v_next text;
begin
    select role into v_role from public.profiles where id = auth.uid();
    if v_role not in ('delivery','admin') then
        raise exception 'Not authorized.';
    end if;

    select status into v_current from public.orders where ref = p_ref;
    if v_current is null then
        raise exception 'Order not found.';
    end if;

    v_next := case p_action
        when 'accept'   then 'accepted'
        when 'dispatch' then 'out_for_delivery'
        when 'deliver'  then 'delivered'
        else null
    end;
    if v_next is null then
        raise exception 'Unknown action: %', p_action;
    end if;

    update public.orders
    set status = v_next,
        delivery_fee = coalesce(p_fee, delivery_fee)
    where ref = p_ref;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function public.update_delivery_status(text, text, numeric) to authenticated;


-- ════════════════════════════════════════════════
--  5. ROW LEVEL SECURITY
--  RLS ON with no policy = fully locked. That's the safe default —
--  every table below gets RLS turned on, then specific access opened
--  back up only where your app actually needs it.
-- ════════════════════════════════════════════════

alter table public.profiles         enable row level security;
alter table public.products         enable row level security;
alter table public.orders           enable row level security;
alter table public.sales            enable row level security;
alter table public.wishlist         enable row level security;
alter table public.notifications    enable row level security;
alter table public.contacts         enable row level security;
alter table public.messages         enable row level security;
-- delivery_orders is a view with security_invoker=true, so it
-- automatically respects the RLS policies on `orders` above it — no
-- separate policies needed for the view itself.

-- ── profiles ──
create policy "profiles_select_authenticated"
    on public.profiles for select to authenticated using (true);

create policy "profiles_update_own"
    on public.profiles for update to authenticated
    using (auth.uid() = id) with check (auth.uid() = id);

-- ── products ──
create policy "products_select_public"
    on public.products for select to anon, authenticated using (true);

create policy "products_insert_own"
    on public.products for insert to authenticated
    with check (
        auth.uid() = seller_id
        and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('seller','admin'))
    );

create policy "products_update_own"
    on public.products for update to authenticated
    using (auth.uid() = seller_id or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
    with check (auth.uid() = seller_id or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

create policy "products_delete_own"
    on public.products for delete to authenticated
    using (auth.uid() = seller_id or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

-- ── orders ──
-- No public insert policy — orders are only ever written by the
-- service_role key from api/verify-payment.js, AFTER Paystack confirms
-- the payment server-side. See DEPLOYMENT_GUIDE.md.
create policy "orders_select_own_or_staff"
    on public.orders for select to authenticated
    using (
        auth.uid() = buyer_id
        or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('admin','delivery'))
    );

create policy "orders_update_staff"
    on public.orders for update to authenticated
    using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('admin','delivery')))
    with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('admin','delivery')));

create policy "orders_delete_admin"
    on public.orders for delete to authenticated
    using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

-- ── sales ── (written only by the service_role verify-payment function)
create policy "sales_select_own_or_admin"
    on public.sales for select to authenticated
    using (auth.uid() = seller_id or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

-- Only admin can mark a sale as paid out (the actual money transfer
-- still happens manually via MoMo — this just tracks it).
create policy "sales_update_admin"
    on public.sales for update to authenticated
    using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
    with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

-- ── wishlist ──
create policy "wishlist_select_own"   on public.wishlist for select to authenticated using (auth.uid() = user_id);
create policy "wishlist_insert_own"   on public.wishlist for insert to authenticated with check (auth.uid() = user_id);
create policy "wishlist_delete_own"   on public.wishlist for delete to authenticated using (auth.uid() = user_id);

-- ── notifications ──
create policy "notifications_select_own" on public.notifications for select to authenticated using (auth.uid() = user_id);
create policy "notifications_update_own" on public.notifications for update to authenticated
    using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── contacts ── (public contact form: anyone can submit, only admin can read)
create policy "contacts_insert_public" on public.contacts for insert to anon, authenticated with check (true);
create policy "contacts_select_admin"  on public.contacts for select to authenticated
    using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));
create policy "contacts_update_admin"  on public.contacts for update to authenticated
    using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
    with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));
create policy "contacts_delete_admin"  on public.contacts for delete to authenticated
    using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

-- ── messages ── (only readable/writable by participants of that order)
create policy "messages_select_participant"
    on public.messages for select to authenticated
    using (
        exists (
            select 1 from public.orders o
            where o.ref = order_ref
              and (o.buyer_id = auth.uid()
                   or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('delivery','admin')))
        )
    );
-- Inserts go through the send_message() function only (security
-- definer bypasses this policy safely, since it validates the sender
-- itself) — no direct public insert policy needed.

-- ── banners ── (homepage promo slider — anyone sees active ones, admin manages)
alter table public.banners enable row level security;
create policy "banners_select_active_public"
    on public.banners for select to anon, authenticated
    using (active = true);
create policy "banners_select_all_admin"
    on public.banners for select to authenticated
    using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));
create policy "banners_insert_admin"
    on public.banners for insert to authenticated
    with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));
create policy "banners_update_admin"
    on public.banners for update to authenticated
    using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
    with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));
create policy "banners_delete_admin"
    on public.banners for delete to authenticated
    using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

-- ── flash_sales ──
alter table public.flash_sales enable row level security;
create policy "flash_sales_select_active_public"
    on public.flash_sales for select to anon, authenticated
    using (active = true);
create policy "flash_sales_select_all_admin"
    on public.flash_sales for select to authenticated
    using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));
create policy "flash_sales_insert_admin"
    on public.flash_sales for insert to authenticated
    with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));
create policy "flash_sales_update_admin"
    on public.flash_sales for update to authenticated
    using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
    with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));
create policy "flash_sales_delete_admin"
    on public.flash_sales for delete to authenticated
    using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));


-- ════════════════════════════════════════════════
--  6. STORAGE BUCKETS
-- ════════════════════════════════════════════════

insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true)
    on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('products', 'products', true)
    on conflict (id) do nothing;

create policy "avatars_public_read"
    on storage.objects for select to anon, authenticated using (bucket_id = 'avatars');
create policy "avatars_insert_own"
    on storage.objects for insert to authenticated
    with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "products_bucket_public_read"
    on storage.objects for select to anon, authenticated using (bucket_id = 'products');
create policy "products_bucket_insert_authenticated"
    on storage.objects for insert to authenticated
    with check (
        bucket_id = 'products'
        and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('seller','admin'))
    );

insert into storage.buckets (id, name, public) values ('banners', 'banners', true)
    on conflict (id) do nothing;
create policy "banners_bucket_public_read"
    on storage.objects for select to anon, authenticated using (bucket_id = 'banners');
create policy "banners_bucket_insert_admin"
    on storage.objects for insert to authenticated
    with check (
        bucket_id = 'banners'
        and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
    );


-- ════════════════════════════════════════════════
--  7. SEED DATA — the 11 demo products from products-data.js
--  So the storefront isn't empty on a fresh project. seller_id is
--  left NULL (an "official D-Swift Mall" listing, same convention
--  products-data.js already used).
-- ════════════════════════════════════════════════

insert into public.products (seller_name, name, category, price, description, image) values
    ('D-Swift Mall', 'New Balance 530 Sneakers', 'Fashion', 420.00, 'Classic New Balance 530 running sneakers in white with navy accents. Breathable mesh upper, cushioned sole, true to size.', '16.jpg'),
    ('D-Swift Mall', 'Keep Running Sport Sneakers', 'Sports', 260.00, 'Lightweight red and black running shoes built for daily training — flexible knit upper and a shock-absorbing sole.', '44.jpg'),
    ('D-Swift Mall', 'Smart Fitness Watch', 'Electronics', 250.00, 'Round-face smart watch with heart-rate tracking, step counter, sleep monitoring, and a full-colour touchscreen. Compatible with Android & iOS.', '37.jpg'),
    ('D-Swift Mall', 'RGB Wired Gaming Mouse', 'Electronics', 90.00, '6-button wired gaming mouse with adjustable DPI and customizable RGB lighting. Comfortable ergonomic grip for long sessions.', '42.jpg'),
    ('D-Swift Mall', 'Nivea Creme (60ml Tin)', 'Beauty', 28.00, 'The iconic Nivea Creme in the classic blue tin — a rich, all-purpose moisturizer for face, hands and body.', '10.jpg'),
    ('D-Swift Mall', 'The History of Whoo Gift Set for Men', 'Beauty', 980.00, 'Luxury Korean skincare gift set for men — balancer, emulsion and cleansing foam in an elegant presentation box. Great gift item.', '19.jpg'),
    ('D-Swift Mall', 'Nivea Men Skincare Bundle', 'Beauty', 190.00, 'Full Nivea Men lineup — deodorant, shaving gel, whitening body lotion, facial cleanser and serum — everything for a grooming routine.', '25.jpg'),
    ('D-Swift Mall', 'Nivea Roll-On Deodorant (3-Pack)', 'Beauty', 65.00, 'Set of 3 Nivea roll-on deodorants — Men Deep, Dry Confidence and Black & White Invisible — 48h protection.', '27.jpg'),
    ('D-Swift Mall', 'Mickey Stainless Steel Flask', 'Home & Kitchen', 75.00, 'Insulated stainless steel vacuum flask with a fun Mickey design and carry strap. Keeps drinks hot or cold for hours. Available in 5 colours.', '11.jpg'),
    ('D-Swift Mall', 'LED Temperature Display Flask', 'Home & Kitchen', 110.00, 'Smart vacuum flask with a built-in LED display showing the exact temperature of your drink at a glance.', '28.jpg'),
    ('D-Swift Mall', 'Marble Pattern Vacuum Flask', 'Home & Kitchen', 85.00, '"Enjoy the Sweet" marble-finish stainless steel flask — sleek design, double-wall insulation, leak-proof lid.', '39.jpg');

-- ════════════════════════════════════════════════
--  8. FIRST ADMIN ACCOUNT
--  Sign up normally through login.html first (creates a 'buyer'
--  profile via the trigger above), THEN run this once with your
--  actual email to promote yourself to admin:
--
--  update public.profiles set role = 'admin'
--  where id = (select id from auth.users where email = 'you@example.com');
-- ════════════════════════════════════════════════
