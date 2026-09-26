-- Seed the assistant's policy answers.
--
-- Every entry restates something the application already enforces or already
-- displays -- PermitReadiness.messageFor, FacilityBookingBlockReason,
-- AccountRole.privileges, the down-payment formula in
-- 20260824090000_downpayment_policy_and_exemption.sql, the cancellation rule in
-- 20260822160000_atomic_requester_cancellation.sql. Nothing here is new policy.
-- If the rule changes, this text changes with it; it is not an independent
-- source of truth.
--
-- Idempotent on slug so the migration can be re-run during a rollout.

insert into public.assistant_knowledge_base
  (slug, topic, audience, question, answer, keywords)
values
  -- Reservation basics -------------------------------------------------------
  (
    'reservation.how_to_book',
    'reservation',
    array['internal', 'external'],
    'What are the requirements for reserving a facility?',
    'Pick a facility that accepts your account type, choose a date and time inside its opening hours, give the headcount and the purpose, and accept the reservation terms. An administrator then reviews it. Your booking is not confirmed until that review, and any required payment, is done.',
    array['how to book', 'paano mag reserve', 'requirements', 'kailangan', 'reserve', 'book a facility']
  ),
  (
    'reservation.approval_flow',
    'reservation',
    array['internal', 'external'],
    'What happens after I submit a reservation?',
    'It goes to an administrator for a decision. From there it is either approved, sent back with changes requested, or declined. If payment is required, an approved reservation waits for payment before it becomes confirmed.',
    array['status', 'approved', 'pending', 'kumusta', 'na-approve', 'what happens next']
  ),
  (
    'reservation.duration_limits',
    'reservation',
    array['internal', 'external'],
    'How far ahead and how long can I book?',
    'Each facility sets its own limits: a maximum booking length, how many days ahead you may reserve, and a buffer between bookings. A single booking must also start and end on the same day. The facility page shows its own limits.',
    array['how long', 'how far ahead', 'advance', 'max duration', 'gaano katagal']
  ),

  -- Payment ------------------------------------------------------------------
  (
    'payment.who_pays',
    'payment',
    array['internal', 'external'],
    'Do I have to pay to reserve a facility?',
    'Verified students and faculty reserve at no charge, and their requested add-ons are free too. Staff, guests and outside renters pay the facility rate for their account type plus any add-ons.',
    array['bayad', 'magkano', 'free', 'libre', 'exempt', 'do i pay', 'charge']
  ),
  (
    'payment.down_payment',
    'payment',
    array['internal', 'external'],
    'How much is the down payment?',
    'The down payment is a percentage of your total, set per facility and always between 20% and 50%. Paying it holds the booking; the remaining balance is due before your schedule starts. The exact amount is shown on your reservation.',
    array['down payment', 'downpayment', 'deposit', 'paunang bayad', 'reservation fee']
  ),
  (
    'payment.deadlines',
    'payment',
    array['internal', 'external'],
    'When is my payment due?',
    'The down payment is due within the facility''s deposit window, counted from when your reservation was approved. The balance is due a set lead time before your schedule starts. Both dates appear on your reservation, and missing them can release the booking.',
    array['deadline', 'due', 'kailan bayad', 'overdue', 'when do i pay', 'balance due']
  ),
  (
    'payment.how_to_pay',
    'payment',
    array['internal', 'external'],
    'How do I pay for my reservation?',
    'Pay through the facility''s listed payment method, then submit the reference number and a photo of your proof of payment on the reservation. An administrator verifies it. Until it is verified the amount still shows as outstanding.',
    array['how to pay', 'paano magbayad', 'gcash', 'proof', 'reference number']
  ),
  (
    'payment.refunds',
    'payment',
    array['external'],
    'Will I get a refund if I cancel after paying?',
    'There is no automatic refund. A refund is recorded by an administrator against your reservation, so contact the office that handles your booking to ask for one.',
    array['refund', 'sauli', 'money back', 'cancel after paying']
  ),

  -- Cancellation -------------------------------------------------------------
  (
    'cancellation.window',
    'cancellation',
    array['internal', 'external'],
    'Can I cancel my reservation, and is there a fee?',
    'You can cancel any reservation that has not started yet, and there is no cancellation fee. Once a schedule has begun, or once the reservation has been declined, expired or completed, it can no longer be cancelled from the app.',
    array['cancel', 'kansela', 'kanselahin', 'fee', 'penalty', 'bawi']
  ),
  (
    'cancellation.repeated',
    'cancellation',
    array['internal', 'external'],
    'Does cancelling often affect my account?',
    'Cancellations very close to the start time are counted as a risk signal on your account. They do not block you by themselves, but a pattern of them is visible to administrators reviewing your requests.',
    array['late cancellation', 'palaging kansela', 'no show', 'record']
  ),

  -- Permits ------------------------------------------------------------------
  (
    'permit.requirements',
    'permit',
    array['internal', 'external'],
    'What is needed before my permit is released?',
    'The reservation must be approved, any required payment verified, the official form items mapped by an administrator, and every signature slot filled -- including yours. Only then is the permit generated and sent to you.',
    array['permit', 'permiso', 'requirements', 'kailangan', 'before permit']
  ),
  (
    'permit.download',
    'permit',
    array['internal', 'external'],
    'Why can I not download my permit yet?',
    'A permit becomes downloadable only after it has been generated and then released to you by an administrator. If your reservation shows the permit as prepared but you cannot open it, it has not been sent yet.',
    array['download', 'permit not available', 'bakit wala pa', 'cannot download']
  ),
  (
    'permit.external_details',
    'permit',
    array['external'],
    'What extra details do external renters need for a permit?',
    'An external permit also needs your company or organization name, complete address, contact numbers and admission fee. The official external form has only eight item rows, so selected items must fit within them.',
    array['external permit', 'company', 'address', 'admission fee', 'outside renter']
  ),
  (
    'permit.signature',
    'permit',
    array['internal', 'external'],
    'Do I need to sign anything?',
    'Yes. When your signature is requested you draw it in the app on your reservation. Your signature is bound to the exact permit contents, so if the reservation materially changes the signature is invalidated and asked for again.',
    array['signature', 'pirma', 'sign', 'e-signature']
  ),

  -- Facilities and lanes -----------------------------------------------------
  (
    'facility.external_rules',
    'facility',
    array['external'],
    'What are the rules for external renters?',
    'Outside renters and paying customers book facilities that accept external bookings. You pay the guest rate plus any add-ons, settle a down payment to hold the booking, and clear the balance before the schedule. Your permit also needs your company details and admission fee.',
    array['external renter', 'outside', 'guest', 'renter rules', 'taga labas']
  ),
  (
    'facility.internal_rules',
    'facility',
    array['internal'],
    'What are the rules for campus organizations?',
    'Campus organization representatives book on behalf of their organization slot. Verified students and faculty are exempt from facility charges. Facilities still enforce their own opening hours, booking limits and approval requirements.',
    array['internal', 'campus', 'organization', 'student org', 'faculty']
  ),
  (
    'facility.unavailable',
    'facility',
    array['internal', 'external'],
    'Why can I not book a particular facility?',
    'A facility can be unavailable because it is inactive or under maintenance, because it does not accept your account type, or because no active administrator is currently handling bookings for your account type. The facility card states which one applies.',
    array['cannot book', 'unavailable', 'bakit hindi', 'maintenance', 'no administrator']
  ),
  (
    'facility.hours',
    'facility',
    array['internal', 'external'],
    'What are a facility''s opening hours?',
    'Each facility sets its own open days and opening and closing times, and bookings must fit inside them. The facility page lists the exact hours, and the assistant only offers time slots that already fit.',
    array['hours', 'open', 'oras', 'bukas', 'schedule', 'opening']
  ),

  -- Equipment ----------------------------------------------------------------
  (
    'equipment.availability',
    'equipment',
    array['internal', 'external'],
    'What equipment is available and how do I request it?',
    'Equipment is listed per facility as amenities. You request the ones you need while booking, and an administrator confirms them. Some are priced per booking and some per occurrence, and verified students and faculty are not charged for them.',
    array['equipment', 'kagamitan', 'amenities', 'projector', 'sound system', 'chairs']
  ),
  (
    'equipment.stock',
    'equipment',
    array['internal', 'external'],
    'How many of an item are left?',
    'SmartReserve does not track stock counts for equipment. It can tell you what a facility offers and whether an item is already requested by an overlapping booking, but not how many units remain.',
    array['how many', 'stock', 'ilan', 'left', 'quantity', 'available units']
  ),

  -- Account ------------------------------------------------------------------
  (
    'account.types',
    'account',
    array['internal', 'external'],
    'What kind of account do I have?',
    'SmartReserve has three roles: regular user, internal administrator and external administrator. Student, faculty, staff and outside-user are booking categories, not roles. Your category decides your rate and which facilities you may book.',
    array['account type', 'role', 'anong account', 'student', 'guest', 'category']
  ),
  (
    'account.verification',
    'account',
    array['internal', 'external'],
    'Why does verification matter?',
    'Verification is what makes you a campus requester rather than a guest. It decides your rate, whether you are exempt from charges, which facilities accept your booking, and which administrators handle your request.',
    array['verification', 'verified', 'campus claim', 'beripikasyon', 'why verify']
  )
on conflict (slug) do update set
  topic = excluded.topic,
  audience = excluded.audience,
  question = excluded.question,
  answer = excluded.answer,
  keywords = excluded.keywords,
  version = public.assistant_knowledge_base.version + 1,
  updated_at = now();

notify pgrst, 'reload schema';
