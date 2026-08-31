-- The anomaly rule engine's small scoring helpers were defined without a
-- fixed search_path, so the database linter flags them as
-- function_search_path_mutable (a caller-controlled search_path could shadow
-- the unqualified references inside them). Pin search_path without needing
-- to restate each function body.

alter function public.anomaly_rule_config_is_valid(text, jsonb) set search_path = public;
alter function public.anomaly_risk_level(integer) set search_path = public;
alter function public.anomaly_decayed_points(integer, timestamptz, timestamptz) set search_path = public;
alter function public.anomaly_rule_points(text, integer) set search_path = public;
alter function public.anomaly_severity_for_points(integer, boolean) set search_path = public;
alter function public.anomaly_rule_title(text) set search_path = public;
alter function public.anomaly_is_prime_slot(uuid, timestamptz) set search_path = public;
alter function public.payment_anomaly_eligible(public.reservation_requests) set search_path = public;

notify pgrst, 'reload schema';
