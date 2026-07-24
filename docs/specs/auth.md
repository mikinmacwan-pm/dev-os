# Spec: Authentication

Implements Supabase Auth (email/password) sign up, sign in, sign out, session persistence, and route protection. No custom `users` table — all identity data lives in Supabase-managed `auth.users`.

## User Flow

**Sign up:** Landing page → "Get Started Free" → sign-up form (email, password) → `supabase.auth.signUp()` with `emailRedirectTo` pointing at the callback route → confirmation-email sent screen → user clicks the emailed link → `/auth/callback` exchanges the code for a session → redirect to `/dashboard` (empty state).

**Sign in:** `/login` form → `supabase.auth.signInWithPassword()` → on success, redirect to `/dashboard`; on failure, show a generic "Invalid email or password" error (do not reveal which field is wrong).

**Sign out:** User menu → "Sign out" → `supabase.auth.signOut()` → redirect to `/`.

**Session persistence / route protection:** every request to `(app)/*` routes passes through `middleware.ts`, which refreshes the Supabase session cookie and redirects to `/login?redirect=<original path>` if no valid session exists.

## DB Schema

No custom tables. Relies on Supabase-managed `auth.users(id, email, ...)`. Every other table's `user_id` foreign key references `auth.users(id) on delete cascade` (see `docs/specs/supabase-schema.sql`) — deleting a user cascades to all of their contracts, key terms, chat data, and feedback.

## DB Tasks

None beyond what Supabase Auth manages internally. No custom writes required for this spec.

## Implementation

`lib/supabase/client.ts` — browser client:
```ts
import { createBrowserClient } from "@supabase/ssr";

export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  );
}
```

`lib/supabase/server.ts` — server client (route handlers, server components), reads/writes cookies via `next/headers`:
```ts
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

export async function createClient() {
  const cookieStore = await cookies();
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => cookieStore.getAll(),
        setAll: (list) => list.forEach(({ name, value, options }) => cookieStore.set(name, value, options)),
      },
    }
  );
}
```

`middleware.ts` — refreshes the session on every request and gates `(app)` routes:
```ts
export async function middleware(request: NextRequest) {
  const { supabase, response } = createMiddlewareClient(request);
  const { data: { user } } = await supabase.auth.getUser();

  if (!user && request.nextUrl.pathname.startsWith("/dashboard")) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("redirect", request.nextUrl.pathname);
    return NextResponse.redirect(url);
  }
  if (!user && request.nextUrl.pathname.startsWith("/contracts")) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("redirect", request.nextUrl.pathname);
    return NextResponse.redirect(url);
  }
  return response;
}

export const config = { matcher: ["/dashboard/:path*", "/contracts/:path*"] };
```

`app/auth/callback/route.ts` — email-confirmation code exchange:
```ts
export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get("code");
  if (code) {
    const supabase = await createClient();
    await supabase.auth.exchangeCodeForSession(code);
  }
  return NextResponse.redirect(`${origin}/dashboard`);
}
```

Every server-side data-fetching function used by protected pages calls a shared `getAuthenticatedUser()` helper (`lib/supabase/auth.ts`) that reads the session via the server client and `redirect("/login")`s if absent — a second, explicit guard on top of the middleware.

## State Management

Client components read the current user via a `useUser()` hook backed by React Query (`["user"]`), populated on mount from `supabase.auth.getUser()` and invalidated by a `supabase.auth.onAuthStateChange()` listener registered once in the root `(app)` layout.

## Component Spec

- `<AuthForm mode="signup" | "login">` — email + password fields, client-side validation (valid email shape, password ≥ 8 chars), submit button showing a loading state, error banner for Supabase auth errors.
- `<CheckYourEmailNotice email />` — shown after successful sign-up, before email confirmation.
- `<UserMenu>` — avatar/email + "Sign out" in the authenticated app shell.

## Design

Per `docs/design.md` (applied via the `/design-system` skill at implementation time): primary CTA button uses the brand primary colour, Inter for all form labels/inputs, error text uses the design system's semantic "error" token (not a hardcoded red).

## Edge Cases

- **Invalid credentials:** generic "Invalid email or password" — never indicate whether the email exists.
- **Duplicate sign-up:** Supabase returns a conflict — show "An account with this email already exists — try signing in instead" with a link to `/login`.
- **Auth call exceeds 10s (FR-01):** show a timeout message and allow retry; do not leave the button in a permanent loading state.
- **Session expires mid-session:** middleware redirects to `/login?redirect=<path>`; on successful re-auth, redirect back to the original path.
- **Unconfirmed email attempts sign-in:** Supabase returns `email_not_confirmed` — show "Please confirm your email first" with a "resend confirmation" action.

## Acceptance Criteria

- [ ] Sign-up completes and redirects to `/dashboard` within 10 seconds (US-001, FR-01).
- [ ] Sign-in with valid credentials redirects to `/dashboard`.
- [ ] Sign-in with invalid credentials shows "Invalid email or password" without indicating which field was wrong.
- [ ] Sign-up with an already-registered email shows a clear "account already exists" message with a link to `/login`.
- [ ] Unauthenticated requests to `/dashboard/*` or `/contracts/*` redirect to `/login?redirect=<path>`; a successful login returns the user to that original path.
- [ ] Sign-out clears the session and redirects to `/`.
- [ ] The session persists across page reloads and new tabs until it naturally expires or the user signs out.
