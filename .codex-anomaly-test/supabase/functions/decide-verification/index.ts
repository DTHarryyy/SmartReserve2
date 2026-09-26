import { createClient } from 'jsr:@supabase/supabase-js@2'

const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (body: unknown, status = 200) =>
  Response.json(body, {
    status,
    headers: { ...corsHeaders, 'Cache-Control': 'no-store' },
  })

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const authorization = request.headers.get('Authorization') ?? ''
  const client = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
  })
  const { data: userData, error: userError } = await client.auth.getUser()
  if (userError || !userData.user) return json({ error: 'Unauthorized' }, 401)

  let body: Record<string, unknown>
  try {
    body = await request.json()
  } catch (_) {
    return json({ error: 'Request body must be valid JSON' }, 400)
  }

  const submissionId = typeof body.submission_id === 'string' ? body.submission_id : ''
  const decision = typeof body.decision === 'string' ? body.decision : ''
  const reason = typeof body.reason === 'string' ? body.reason.trim() : ''
  const allowed = ['approved', 'changes_requested', 'rejected']
  if (!submissionId || !allowed.includes(decision)) {
    return json({ error: 'Invalid decision request' }, 400)
  }
  if ((decision === 'changes_requested' || decision === 'rejected') && !reason) {
    return json({ error: 'A reason is required' }, 400)
  }

  const admin = createClient(supabaseUrl, serviceRoleKey)
  const { data, error } = await admin.rpc('decide_verification_atomic', {
    p_submission_id: submissionId,
    p_decision: decision,
    p_reason: reason,
    p_actor: userData.user.id,
  })

  if (error) {
    if (error.code === '42501') return json({ error: 'Forbidden' }, 403)
    if (error.code === 'P0002') return json({ error: 'Submission not found' }, 404)
    if (error.code === '40001') {
      return json({ error: 'This submission was already decided' }, 409)
    }
    if (error.code === '22023') return json({ error: error.message }, 400)
    return json({ error: error.message }, 500)
  }

  const result = Array.isArray(data) ? data[0] : data
  const finalDecision = decision === 'approved' || decision === 'rejected'
  const documentPath = result?.document_path as string | null | undefined
  let cleanupWarning: string | null = null

  if (finalDecision && documentPath) {
    const { error: storageError } = await admin.storage
      .from('verification-documents')
      .remove([documentPath])
    if (storageError) {
      cleanupWarning = 'Decision saved, but document cleanup must be retried.'
    } else {
      const { error: clearError } = await admin
        .from('verification_submissions')
        .update({ document_path: null })
        .eq('id', submissionId)
      if (clearError) cleanupWarning = 'Document deleted, but its metadata cleanup must be retried.'
    }
  }

  const { data: updated, error: updatedError } = await admin
    .from('verification_submissions')
    .select('id,user_id,status,reason,decided_at,decided_by,document_path')
    .eq('id', submissionId)
    .single()
  if (updatedError) return json({ error: updatedError.message }, 500)

  return json({ ok: true, submission: updated, warning: cleanupWarning })
})
