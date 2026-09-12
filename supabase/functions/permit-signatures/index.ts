import { createClient } from 'npm:@supabase/supabase-js@2';
import { Resvg, initWasm } from 'npm:@resvg/resvg-wasm';
import wasm from 'npm:@resvg/resvg-wasm/index_bg.wasm';
import { encodeBase64, protectedRenditionPayload } from './contract.ts';

const url = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(url, serviceKey);
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, content-type' };
let wasmReady: Promise<void> | undefined;
const ready = () => wasmReady ??= initWasm(wasm);

const response = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...cors, 'Content-Type': 'application/json' },
});

async function caller(request: Request) {
  const token = request.headers.get('authorization')?.replace(/^Bearer\s+/i, '');
  if (!token) return null;
  const { data } = await admin.auth.getUser(token);
  return data.user ?? null;
}

async function isInternalAdmin(id: string) {
  const { data } = await admin.from('profiles').select('role,account_status').eq('id', id).maybeSingle();
  return data?.role === 'internal_admin' && data.account_status === 'active';
}

function bytes(value: string) {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (request.method !== 'POST') return response({ error: 'POST required' }, 405);
  const user = await caller(request);
  if (!user) return response({ error: 'Sign in required' }, 401);
  const body = await request.json().catch(() => ({}));
  const action = body.action;
  const internal = await isInternalAdmin(user.id);
  try {
    if (action === 'upload_ceo') {
      if (!internal) return response({ error: 'Internal Admin access required' }, 403);
      if (!['image/png', 'image/jpeg'].includes(body.mimeType) || typeof body.bytesBase64 !== 'string') return response({ error: 'PNG or JPEG required' }, 400);
      const source = bytes(body.bytesBase64);
      if (!source.length || source.length > 5 * 1024 * 1024) return response({ error: 'Signature must be 5 MB or smaller' }, 400);
      const path = `${user.id}/${crypto.randomUUID()}-${body.fileName ?? 'ceo-signature'}`;
      const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', source))).map((byte) => byte.toString(16).padStart(2, '0')).join('');
      const { error: uploadError } = await admin.storage.from('ceo-signatures').upload(path, source, { contentType: body.mimeType, upsert: false });
      if (uploadError) throw uploadError;
      const { error } = await admin.rpc('record_ceo_signature_replacement', { p_storage_path: path, p_file_name: body.fileName ?? 'ceo-signature', p_mime_type: body.mimeType, p_byte_size: source.length, p_sha256: hash, p_actor_id: user.id });
      if (error) { await admin.storage.from('ceo-signatures').remove([path]); throw error; }
      return response({ ok: true });
    }
    const requestId = body.requestId;
    const permitId = body.permitId;
    if (typeof requestId !== 'string' || typeof permitId !== 'string') return response({ error: 'Permit reference is required' }, 400);
    const { data: permit } = await admin.from('reservation_permits').select('id,request_id,ceo_signature_id,reservation_requests!inner(requester_id)').eq('id', permitId).eq('request_id', requestId).maybeSingle();
    if (!permit) return response({ error: 'Permit not found' }, 404);
    const requesterId = (permit.reservation_requests as { requester_id: string }).requester_id;
    if (!internal && requesterId !== user.id) return response({ error: 'Permit access denied' }, 403);
    if (!permit.ceo_signature_id) return response({ error: 'CEO signature is unavailable' }, 409);
    const { data: revision, error: revisionError } = await admin.from('ceo_signature_revisions').select('storage_path').eq('id', permit.ceo_signature_id).single();
    if (revisionError) throw revisionError;
    const { data: source, error: downloadError } = await admin.storage.from('ceo-signatures').download(revision.storage_path);
    if (downloadError) throw downloadError;
    const raw = new Uint8Array(await source.arrayBuffer());
    if (action === 'official') {
      if (!internal) return response({ error: 'Internal Admin access required' }, 403);
      await admin.rpc('reservation_event', { p_request_id: requestId, p_action: 'generated official permit copy', p_details: { permit_id: permitId } });
      return response({ mimeType: 'image/png', sourceBase64: encodeBase64(raw) });
    }
    if (action !== 'protected') return response({ error: 'Unknown action' }, 400);
    await ready();
    const embedded = encodeBase64(raw);
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="900" height="300"><rect width="100%" height="100%" fill="white"/><image href="data:image/png;base64,${embedded}" x="220" y="60" width="460" height="120" preserveAspectRatio="xMidYMid meet"/><text x="450" y="250" text-anchor="middle" font-family="sans-serif" font-size="18" fill="#b91c1c" opacity=".65">SMARTRESERVE • PROTECTED USER COPY</text></svg>`;
    const flattened = new Resvg(svg, { fitTo: { mode: 'width', value: 900 } }).render().asPng();
    await admin.rpc('reservation_event', { p_request_id: requestId, p_action: 'generated protected permit copy', p_details: { permit_id: permitId } });
    return response(protectedRenditionPayload(flattened));
  } catch (error) {
    return response({ error: error instanceof Error ? error.message : 'Permit signature operation failed' }, 500);
  }
});
