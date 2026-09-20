export const FIREBASE_CONFIG = {
  apiKey: process.env.FIREBASE_API_KEY,
  authDomain: process.env.FIREBASE_AUTH_DOMAIN,
  projectId: process.env.FIREBASE_PROJECT_ID,
  storageBucket: process.env.FIREBASE_STORAGE_BUCKET,
  messagingSenderId: process.env.FIREBASE_MESSAGING_SENDER_ID,
  appId: process.env.FIREBASE_APP_ID
}

/**
 * When set (e.g. "localhost:9099"), the client talks to a locally running Firebase
 * Auth emulator instead of Google, so the whole stack can run without internet.
 *
 * The server needs no change to follow along: firebase-admin reads the same
 * FIREBASE_AUTH_EMULATOR_HOST variable natively and skips token verification.
 *
 * Leave it empty in .env to use real Firebase. Note the two modes have SEPARATE
 * account databases -- an account registered against the emulator does not exist in
 * the real Firebase project, and vice versa. Changing this value requires rebuilding
 * the client (npm run build-client), because esbuild inlines it at build time.
 */
export const AUTH_EMULATOR_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST
