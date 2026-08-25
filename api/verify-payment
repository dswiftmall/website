// ══════════════════════════════════════════════════════════════════
//  /api/verify-payment
//
//  This is the ONLY place your Paystack secret key and Supabase
//  service_role key are allowed to exist. Both are read from Vercel
//  environment variables (never from a file you commit to git).
//
//  What this replaces: right now, kscript.js trusts Paystack's
//  in-browser popup callback as proof of payment, and never checks
//  with Paystack's servers or writes anything to the `orders` table.
//  That is spoofable — anyone with browser dev tools could fire the
//  same success handler without paying a cedi.
//
//  What this does instead:
//   1. Frontend calls this endpoint with the Paystack `reference` it
//      got back from the popup (proves nothing on its own).
//   2. This function calls Paystack's server-to-server verify endpoint
//      using your SECRET key — the only trustworthy source of truth.
//   3. Only if Paystack confirms status === 'success' AND the amount
//      matches what the cart should have cost, does this function
//      write the order into Supabase using the service_role key
//      (which bypasses RLS on purpose — this is the trusted backend).
//
//  Wire-up on the frontend (kscript.js), replace the body of
//  onPaymentSuccess() with a call to this endpoint instead of writing
//  success state directly — see DEPLOYMENT_GUIDE.md "Secure checkout"
//  section for the exact snippet.
// ══════════════════════════════════════════════════════════════════

export default async function handler(req, res) {
    if (req.method !== 'POST') {
        return res.status(405).json({ error: 'Method not allowed' });
    }

    const { reference, buyerId, items } = req.body || {};
    if (!reference || !buyerId || !Array.isArray(items) || items.length === 0) {
        return res.status(400).json({ error: 'Missing reference, buyerId, or items.' });
    }

    const PAYSTACK_SECRET_KEY   = process.env.PAYSTACK_SECRET_KEY;
    const SUPABASE_URL          = process.env.SUPABASE_URL;
    const SUPABASE_SERVICE_ROLE = process.env.SUPABASE_SERVICE_ROLE_KEY;

    if (!PAYSTACK_SECRET_KEY || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE) {
        console.error('Missing required environment variables.');
        return res.status(500).json({ error: 'Server misconfigured.' });
    }

    try {
        // ── 1. Verify the transaction directly with Paystack's servers ──
        const verifyRes = await fetch(
            `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
            { headers: { Authorization: `Bearer ${PAYSTACK_SECRET_KEY}` } }
        );
        const verifyJson = await verifyRes.json();

        if (!verifyRes.ok || !verifyJson.status || verifyJson.data?.status !== 'success') {
            return res.status(402).json({ error: 'Payment could not be verified.' });
        }

        const paidAmountKobo = verifyJson.data.amount; // amount Paystack actually received, in kobo/pesewas

        // ── 2. Recompute the expected total server-side, and pull each
        //       item's REAL price + seller from the database — never
        //       trust price or seller info sent from the browser. ──
        const productMap = await lookupProducts(items.map(i => i.id), SUPABASE_URL, SUPABASE_SERVICE_ROLE);
        let expectedTotalGHS = 0;
        for (const i of items) {
            const p = productMap.get(i.id);
            if (!p) throw new Error(`Unknown product id ${i.id}`);
            expectedTotalGHS += p.price * i.qty;
        }
        const expectedKobo = Math.round(expectedTotalGHS * 100);

        if (paidAmountKobo < expectedKobo) {
            return res.status(402).json({ error: 'Paid amount does not match cart total.' });
        }

        // ── 3. Guard against replay: has this reference already been recorded? ──
        const existing = await supabaseRequest(
            SUPABASE_URL, SUPABASE_SERVICE_ROLE,
            `orders?ref=eq.${encodeURIComponent(reference)}&select=id`
        );
        if (Array.isArray(existing) && existing.length > 0) {
            return res.status(200).json({ ok: true, alreadyRecorded: true, orderId: existing[0].id });
        }

        // ── 4. Write the order using the service_role key (bypasses RLS
        //       on purpose — this backend function IS the trusted writer).
        //       Status starts at 'pending', matching what delivery.html
        //       expects for a freshly-placed, unaccepted order. ──
        const orderItems = items.map(i => {
            const p = productMap.get(i.id);
            return { id: i.id, name: p.name, price: p.price, qty: i.qty, sellerId: p.sellerId, sellerName: p.sellerName };
        });

        const orderRows = await supabaseRequest(
            SUPABASE_URL, SUPABASE_SERVICE_ROLE,
            'orders', 'POST',
            {
                buyer_id: buyerId,
                ref:      reference,
                status:   'pending',
                total:    expectedTotalGHS,
                items:    orderItems,
            }
        );
        const order = orderRows?.[0];

        // ── 5. Write one `sales` row per seller represented in this
        //       order, so seller dashboards / profile.html's earnings
        //       total pick it up. Skip items with no seller_id (the
        //       official D-Swift Mall catalog isn't a seller payout). ──
        if (order) {
            const salesRows = orderItems
                .filter(i => i.sellerId)
                .map(i => ({
                    seller_id:    i.sellerId,
                    order_id:     order.id,
                    product_id:   i.id,
                    product_name: i.name,
                    gross:        i.price * i.qty,
                }));
            if (salesRows.length) {
                await supabaseRequest(SUPABASE_URL, SUPABASE_SERVICE_ROLE, 'sales', 'POST', salesRows);
            }
        }

        return res.status(200).json({ ok: true, order: order || null });
    } catch (err) {
        console.error('verify-payment error:', err);
        return res.status(500).json({ error: 'Unexpected server error.' });
    }
}

// Looks up each product's real price + seller from Supabase (never
// trusts price/seller info sent from the browser).
async function lookupProducts(ids, supabaseUrl, serviceRoleKey) {
    const idList = ids.join(',');
    const products = await supabaseRequest(
        supabaseUrl, serviceRoleKey,
        `products?id=in.(${idList})&select=id,name,price,seller_id,seller_name`
    );
    const map = new Map();
    for (const p of products) {
        map.set(p.id, { name: p.name, price: parseFloat(p.price), sellerId: p.seller_id, sellerName: p.seller_name });
    }
    return map;
}

// Minimal Supabase REST helper (avoids needing the full supabase-js
// SDK inside this function — one less dependency to manage here).
async function supabaseRequest(url, serviceRoleKey, path, method = 'GET', body = null) {
    const res = await fetch(`${url}/rest/v1/${path}`, {
        method,
        headers: {
            apikey: serviceRoleKey,
            Authorization: `Bearer ${serviceRoleKey}`,
            'Content-Type': 'application/json',
            Prefer: method === 'POST' ? 'return=representation' : undefined,
        },
        body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) {
        const text = await res.text();
        throw new Error(`Supabase request failed: ${res.status} ${text}`);
    }
    return res.json();
}
