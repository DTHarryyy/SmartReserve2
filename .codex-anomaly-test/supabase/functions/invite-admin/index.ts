import { createClient } from 'jsr:@supabase/supabase-js@2'

const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const inviteRedirectTo = Deno.env.get('INVITE_REDIRECT_TO') ?? ''

Deno.serve(async (request) => {
  if (request.method !== 'POST') {
    return Response.json({ error: 'Method not allowed' }, { status: 405 })
  }

  const authorization = request.headers.get('Authorization') ?? ''
  const client = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
  })
  const { data: userData, error: userError } = await client.auth.getUser()
  if (userError || !userData.user) {
    return Response.json({ error: 'Unauthorized' }, { status: 401 })
  }

  const admin = createClient(supabaseUrl, serviceRoleKey)
  const { data: actor, error: actorError } = await admin
    .from('profiles')
    .select('role,account_status')
    .eq('id', userData.user.id)
    .single()
  if (actorError || actor.role !== 'internal_admin' || actor.account_status !== 'active') {
    return Response.json({ error: 'Forbidden' }, { status: 403 })
  }

  const body = await request.json()
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : ''
  const role = typeof body.role === 'string' ? body.role : ''
  const note = typeof body.note === 'string' ? body.note.trim() : ''
  const validEmail = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)
  if (!validEmail || !['internal_admin', 'external_admin'].includes(role)) {
    return Response.json({ error: 'Invalid invitation request' }, { status: 400 })
  }

  const { data: invitation, error: invitationError } = await admin.auth.admin.inviteUserByEmail(email, {
    data: { invitation_note: note },
    redirectTo: inviteRedirectTo || undefined,
  })
  if (invitationError || !invitation.user) {
    return Response.json({ error: invitationError?.message ?? 'Invitation failed' }, { status: 400 })
  }

  const { error: profileError } = await admin
    .from('profiles')
    .update({
      role,
      account_status: 'invited',
      onboarding_complete: true,
    })
    .eq('id', invitation.user.id)
  if (profileError) {
    return Response.json({ error: profileError.message }, { status: 500 })
  }

  return Response.json({ id: invitation.user.id, email, role })
})
