export const jbDevProject = 'apkrhhdmjxbvwtdktfaq';

export function createSupabaseTokenVerifier({ url, publishableKey, fetchUser = globalThis.fetch } = {}) {
  if (!url || !publishableKey) return undefined;
  const origin = 'https://' + jbDevProject + '.supabase.co';
  if (url !== origin && url !== origin + '/') throw new Error('Unsupported report Auth project');
  if (!/^sb_publishable_[A-Za-z0-9_-]+$/.test(publishableKey)) throw new Error('Expected an Auth publishable key');

  const issuer = origin + '/auth/v1';
  return async token => {
    // Claims only reject foreign/expired tokens. The provider still verifies every accepted token.
    if (typeof token !== 'string' || token.length > 16384 ||
        !/^[\w-]+\.[\w-]+\.[\w-]+$/.test(token)) return null;
    let claims;
    try {
      claims = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
    } catch {
      return null;
    }
    if (claims?.iss !== issuer || typeof claims.sub !== 'string' ||
        !Number.isFinite(claims.exp) || claims.exp <= Date.now() / 1000) return null;

    const response = await fetchUser(issuer + '/user', {
      headers: { apikey: publishableKey, Authorization: 'Bearer ' + token },
      redirect: 'error',
      signal: AbortSignal.timeout(10000),
    });
    if (response.status === 401 || response.status === 403) return null;
    if (!response.ok) throw new Error('Auth provider lookup failed');
    const user = await response.json();
    return user?.id === claims.sub ? { userId: user.id } : null;
  };
}
