// ══════════════════════════════════════════════════════════════════
//  /api/notify-admin
//
//  Called by Supabase Database Webhooks whenever something worth
//  knowing about happens (new order, new contact message, new seller
//  signup). Formats a short email and sends it via Resend.
//
//  SECURITY: Supabase Database Webhooks let you attach a custom HTTP
//  header when you set them up. We use that to send a shared secret
//  (WEBHOOK_SECRET) that this function checks before doing anything —
//  otherwise this URL would be public and anyone could spam emails to
//  your inbox by guessing the endpoint.
// ══════════════════════════════════════════════════════════════════

export default async function handler(req, res) {
    if (req.method !== 'POST') {
        return res.status(405).json({ error: 'Method not allowed' });
    }

    const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET;
    const RESEND_API_KEY = process.env.RESEND_API_KEY;
    const ADMIN_EMAIL    = process.env.ADMIN_EMAIL;

    if (!WEBHOOK_SECRET || !RESEND_API_KEY || !ADMIN_EMAIL) {
        console.error('Missing required environment variables.');
        return res.status(500).json({ error: 'Server misconfigured.' });
    }

    // Verify this request really came from our own Supabase webhook,
    // not some random POST to a guessed URL.
    const gotSecret = req.headers['x-webhook-secret'];
    if (gotSecret !== WEBHOOK_SECRET) {
        return res.status(401).json({ error: 'Unauthorized.' });
    }

    const { table, type, record } = req.body || {};
    if (!table || !type || !record) {
        return res.status(400).json({ error: 'Malformed webhook payload.' });
    }

    const email = buildEmail(table, type, record);
    if (!email) {
        // Not an event we care about — acknowledge it so Supabase
        // doesn't keep retrying, just don't send anything.
        return res.status(200).json({ ok: true, skipped: true });
    }

    try {
        const sendRes = await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: {
                Authorization: `Bearer ${RESEND_API_KEY}`,
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                from: 'D-Swift Mall <notifications@dswiftmall.com>',
                to: [ADMIN_EMAIL],
                subject: email.subject,
                html: email.html,
            }),
        });

        if (!sendRes.ok) {
            const text = await sendRes.text();
            console.error('Resend error:', text);
            return res.status(502).json({ error: 'Email send failed.' });
        }

        return res.status(200).json({ ok: true });
    } catch (err) {
        console.error('notify-admin error:', err);
        return res.status(500).json({ error: 'Unexpected server error.' });
    }
}

// Builds a subject + HTML body for each event type this function
// knows about. Returns null for anything not explicitly handled.
function buildEmail(table, type, record) {
    if (table === 'orders' && type === 'INSERT') {
        const itemsHtml = (record.items || [])
            .map(i => `<li>${escapeHtml(i.name)} × ${i.qty} — GH₵ ${Number(i.price * i.qty).toFixed(2)}</li>`)
            .join('');
        return {
            subject: `🛒 New order — GH₵ ${Number(record.total).toFixed(2)} (${record.ref})`,
            html: `
                <h2>New order placed</h2>
                <p><strong>Reference:</strong> ${escapeHtml(record.ref)}</p>
                <p><strong>Total:</strong> GH₵ ${Number(record.total).toFixed(2)}</p>
                <p><strong>Status:</strong> ${escapeHtml(record.status)}</p>
                <p><strong>Items:</strong></p>
                <ul>${itemsHtml}</ul>
                <p><a href="https://dswiftmall.com/admin.html">View in Admin Dashboard →</a></p>
            `,
        };
    }

    if (table === 'contacts' && type === 'INSERT') {
        return {
            subject: `📩 New contact message from ${record.name}`,
            html: `
                <h2>New contact form submission</h2>
                <p><strong>Name:</strong> ${escapeHtml(record.name)}</p>
                <p><strong>Email:</strong> ${escapeHtml(record.email)}</p>
                <p><strong>Message:</strong></p>
                <p>${escapeHtml(record.message)}</p>
                <p><a href="https://dswiftmall.com/admin.html">View in Admin Dashboard →</a></p>
            `,
        };
    }

    if (table === 'profiles' && type === 'INSERT' && record.role === 'seller') {
        return {
            subject: `🧑‍💼 New seller signed up: ${record.name}`,
            html: `
                <h2>New seller account created</h2>
                <p><strong>Name:</strong> ${escapeHtml(record.name)}</p>
                <p><strong>Phone:</strong> ${escapeHtml(record.phone || 'not set')}</p>
                <p><strong>MoMo Number:</strong> ${escapeHtml(record.momo_number || 'not set yet')}</p>
                <p><a href="https://dswiftmall.com/admin.html">View in Admin Dashboard →</a></p>
            `,
        };
    }

    return null;
}

function escapeHtml(str) {
    return String(str ?? '')
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
