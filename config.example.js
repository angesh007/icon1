/* ============================================================
   Fallback config — only needed if you are NOT using .env + Node.

   Preferred:  cp .env.example .env   ->  npm run config
   Manual:     cp config.example.js config.js  ->  edit below

   Either way the result is a gitignored `config.js`. Never commit it.
   ============================================================ */

window.ICON_CONFIG = {
  // Settings -> Data API -> Project URL
  SUPABASE_URL: 'https://YOUR_PROJECT_REF.supabase.co',

  // Settings -> API Keys -> Publishable key (a.k.a. anon public)
  // Safe in the browser. Never paste the secret / service_role key here.
  SUPABASE_KEY: 'YOUR_PUBLISHABLE_KEY',

  // Fallback shop, used only when the URL has no ?shop=<slug>.
  // Per-shop settings live on the salons row and are edited in the
  // owner console, not here.
  SALON_ID: 1,

  // Fallback wait-estimate values, used before a shop has loaded.
  MINUTES_PER_CLIENT: 15,
  ACTIVE_CHAIRS: 1

  // Optional: always open one particular shop from the bare URL.
  // , SHOP_SLUG: 'perimeter'
};
