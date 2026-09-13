/**
 * The site is static files. This Worker exists for exactly one route.
 *
 * The scanner and the admin page both need the Supabase project URL and the
 * publishable key. Baking them into the HTML would mean a rebuild and a
 * redeploy to rotate a key; putting them in the repo would mean a commit.
 * Instead they live in Cloudflare's environment and are served here, so
 * rotating the key is an edit in the dashboard and nothing else.
 *
 * Everything else falls through to the static assets untouched, so the
 * scanner is still a folder of files that runs from cache with no network --
 * see the offline invariants in CLAUDE.md. /config.json is read once during
 * setup, on wifi, and cached on the phone. It is never on the path to a scan.
 *
 * The publishable key is designed to be public and is safe to serve here;
 * row-level security is what protects the data, not the secrecy of this
 * string. The service key must NEVER be put in these variables -- it would
 * be readable by anyone who opens the site.
 */
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/config.json") {
      return new Response(
        JSON.stringify({
          supaUrl: env.SUPABASE_URL || "",
          supaKey: env.SUPABASE_PUBLISHABLE_KEY || ""
        }),
        {
          headers: {
            "Content-Type": "application/json",
            // A phone must never be handed a stale project URL or a key that
            // has since been rotated.
            "Cache-Control": "no-store",
            // The admin page and the scanner are same-origin, but a volunteer
            // may have the app installed as an APK on https://localhost.
            "Access-Control-Allow-Origin": "*"
          }
        }
      );
    }

    return env.ASSETS.fetch(request);
  }
};
