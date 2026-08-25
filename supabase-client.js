// ══════════════════════════════════════════════════════════════
//  D-SWIFT MALL  |  supabase-client.js
//  One shared Supabase client, loaded by every page BEFORE
//  kscript.js / loginscript.js / script.js.
//
//  Include this in <head> or right before your other scripts:
//    <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
//    <script src="supabase-client.js"></script>
//
//  ⚠️ REPLACE THE TWO VALUES BELOW WITH YOUR OWN NEW SUPABASE
//  PROJECT'S VALUES before deploying. Get them from your Supabase
//  dashboard → Project Settings → API Keys → "Publishable and secret
//  API keys" tab:
//    - SUPABASE_URL: your Project URL (Settings → Data API)
//    - SUPABASE_KEY: the key labeled "publishable" (starts with
//      sb_publishable_...) — safe to expose in browser code as long as
//      RLS is enabled on every table (which supabase_schema.sql does).
//      Never put the "secret" key here — that one only belongs in
//      Vercel's environment variables, used by api/verify-payment.js.
// ══════════════════════════════════════════════════════════════

const SUPABASE_URL = 'YOUR_NEW_SUPABASE_PROJECT_URL_HERE';   // e.g. https://xxxxxxxxxxxx.supabase.co
const SUPABASE_KEY = 'YOUR_NEW_SUPABASE_PUBLISHABLE_KEY_HERE'; // starts with sb_publishable_...

// `supabase` here is the global from the CDN script above (window.supabase).
// We rename our client to `sb` so it doesn't collide with that global.
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
    auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true, // needed for OAuth + email-confirmation redirects
    }
});

// ── Legacy localStorage bridge ────────────────────────
// Pages written before the Supabase migration (or not yet updated) read
// the logged-in user from localStorage under these three keys. Rather
// than rewrite every single page in one pass, we keep that bridge alive:
// this listener fires on load and on every login/logout/token-refresh,
// re-fetching the profiles row and mirroring it into the same keys the
// old PHP-based loginscript.js used to write. New code should prefer
// `sb.auth.getSession()` / `sb.from('profiles')` directly instead of
// reading localStorage — this bridge exists for the not-yet-migrated
// pages only, and can be deleted once every page is converted.
async function syncLegacyUserStorage(session) {
    if (!session) {
        localStorage.removeItem('swiftToken');
        localStorage.removeItem('swiftLoggedIn');
        localStorage.removeItem('swiftCurrentUser');
        return null;
    }

    const { data: profile, error } = await sb
        .from('profiles')
        .select('*')
        .eq('id', session.user.id)
        .single();

    if (error || !profile) return null;

    const legacyUser = {
        id:         profile.id,
        name:       profile.name,
        email:      session.user.email, // lives on the auth session, not the profiles table
        phone:      profile.phone,
        role:       profile.role,
        bio:        profile.bio,
        location:   profile.location,
        storeName:  profile.store_name,
        profilePic: profile.profile_pic,
        isVerified: !!session.user.email_confirmed_at,
        joinDate:   new Date(profile.created_at).toLocaleDateString('en-GB'),
    };

    localStorage.setItem('swiftToken', session.access_token);
    localStorage.setItem('swiftLoggedIn', 'true');
    localStorage.setItem('swiftCurrentUser', JSON.stringify(legacyUser));
    return legacyUser;
}

// Keeps localStorage current across tab switches, token refreshes, and
// sign-outs — not just the moment someone clicks "Log In".
sb.auth.onAuthStateChange((_event, session) => { syncLegacyUserStorage(session); });

