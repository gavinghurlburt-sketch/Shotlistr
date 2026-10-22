import { createClient } from "@supabase/supabase-js";
import { Mp3Encoder } from "@breezystack/lamejs";
window.supabase = { createClient };
window.lamejs = { Mp3Encoder };
