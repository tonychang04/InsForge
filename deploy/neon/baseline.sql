--
-- PostgreSQL database dump
--

\restrict 7wCrLgx0qj4VxUTHtUZZDQCiaeLRikeYlNnX6hYJfewue1HO7Hmz5ySOKtLHyF4

-- Dumped from database version 15.18 (Debian 15.18-1.pgdg13+1)
-- Dumped by pg_dump version 18.4 (Debian 18.4-1.pgdg13+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: ai; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ai;


--
-- Name: auth; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA auth;


--
-- Name: compute; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA compute;


--
-- Name: pg_cron; Type: EXTENSION; Schema: -; Owner: -
--



--
-- Name: EXTENSION pg_cron; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: deployments; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA deployments;


--
-- Name: email; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA email;


--
-- Name: functions; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA functions;


--
-- Name: payments; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA payments;


--
-- Name: realtime; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA realtime;


--
-- Name: schedules; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA schedules;


--
-- Name: storage; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA storage;


--
-- Name: system; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA system;


--
-- Name: http; Type: EXTENSION; Schema: -; Owner: -
--



--
-- Name: EXTENSION http; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: email(); Type: FUNCTION; Schema: auth; Owner: -
--

CREATE FUNCTION auth.email() RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT nullif(auth.jwt() ->> 'email', '')::text
$$;


--
-- Name: jwt(); Type: FUNCTION; Schema: auth; Owner: -
--

CREATE FUNCTION auth.jwt() RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb
$$;


--
-- Name: role(); Type: FUNCTION; Schema: auth; Owner: -
--

CREATE FUNCTION auth.role() RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT nullif(auth.jwt() ->> 'role', '')::text
$$;


--
-- Name: uid(); Type: FUNCTION; Schema: auth; Owner: -
--

CREATE FUNCTION auth.uid() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT nullif(auth.jwt() ->> 'sub', '')::uuid
$$;


--
-- Name: channel_name(); Type: FUNCTION; Schema: realtime; Owner: -
--

CREATE FUNCTION realtime.channel_name() RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT current_setting('realtime.channel_name', true);
$$;


--
-- Name: cleanup_messages(integer); Type: FUNCTION; Schema: realtime; Owner: -
--

CREATE FUNCTION realtime.cleanup_messages(p_batch_size integer DEFAULT 1000) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_retention_days INT;
  v_cutoff TIMESTAMPTZ;
  v_deleted_count INT := 0;
  v_total_deleted INT := 0;
BEGIN
  -- Get retention days from realtime.config
  SELECT retention_days INTO v_retention_days
  FROM realtime.config LIMIT 1;
  
  -- Handle "Never" (e.g. NULL or < 0)
  IF v_retention_days IS NULL OR v_retention_days < 0 THEN
    RETURN 0;
  END IF;
  
  -- Calculate cutoff time
  v_cutoff := NOW() - (v_retention_days || ' days')::INTERVAL;
  
  LOOP
    WITH deleted AS (
      DELETE FROM realtime.messages
      WHERE id IN (
        SELECT id FROM realtime.messages
        WHERE created_at < v_cutoff
        ORDER BY created_at ASC
        LIMIT p_batch_size
      )
      RETURNING id
    )
    SELECT COUNT(*) INTO v_deleted_count FROM deleted;
    
    v_total_deleted := v_total_deleted + v_deleted_count;
    
    -- Exit loop if no rows deleted or batch not full
    EXIT WHEN v_deleted_count < p_batch_size;
  END LOOP;
  
  RETURN v_total_deleted;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'realtime.cleanup_messages failed: %', SQLERRM;
  RETURN v_total_deleted;
END;
$$;


--
-- Name: notify_on_message_insert(); Type: FUNCTION; Schema: realtime; Owner: -
--

CREATE FUNCTION realtime.notify_on_message_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Send only message_id to bypass pg_notify 8KB payload limit
  -- Backend will fetch full message from DB
  PERFORM pg_notify('realtime_message', NEW.id::text);
  RETURN NEW;
END;
$$;


--
-- Name: publish(text, text, jsonb); Type: FUNCTION; Schema: realtime; Owner: -
--

CREATE FUNCTION realtime.publish(p_channel_name text, p_event_name text, p_payload jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_channel_id UUID;
  v_message_id UUID;
BEGIN
  -- Find matching channel: exact match first, then wildcard pattern match
  -- For wildcard patterns like "order:%", check if p_channel_name LIKE pattern
  SELECT id INTO v_channel_id
  FROM realtime.channels
  WHERE enabled = TRUE
    AND (pattern = p_channel_name OR p_channel_name LIKE pattern)
  ORDER BY pattern = p_channel_name DESC
  LIMIT 1;

  -- If no channel found, raise a warning and return NULL
  IF v_channel_id IS NULL THEN
    RAISE WARNING 'Realtime: No matching channel found for "%"', p_channel_name;
    RETURN NULL;
  END IF;

  -- Insert message record (system-triggered, so sender_type = 'system')
  INSERT INTO realtime.messages (
    event_name,
    channel_id,
    channel_name,
    payload,
    sender_type
  ) VALUES (
    p_event_name,
    v_channel_id,
    p_channel_name,
    p_payload,
    'system'
  )
  RETURNING id INTO v_message_id;

  RETURN v_message_id;
END;
$$;


--
-- Name: build_http_headers(jsonb); Type: FUNCTION; Schema: schedules; Owner: -
--



--
-- Name: cleanup_job_logs(integer); Type: FUNCTION; Schema: schedules; Owner: -
--

CREATE FUNCTION schedules.cleanup_job_logs(p_batch_size integer DEFAULT 1000) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_retention_days INT;
  v_cutoff TIMESTAMPTZ;
  v_deleted_count INT := 0;
  v_total_deleted INT := 0;
BEGIN
  IF p_batch_size IS NULL OR p_batch_size <= 0 THEN
    RAISE WARNING 'schedules.cleanup_job_logs received invalid batch size: %', p_batch_size;
    RETURN 0;
  END IF;

  SELECT retention_days INTO v_retention_days
  FROM schedules.config LIMIT 1;
  
  IF v_retention_days IS NULL OR v_retention_days <= 0 THEN
    RETURN 0;
  END IF;
  
  v_cutoff := NOW() - (v_retention_days || ' days')::INTERVAL;
  
  LOOP
    WITH deleted AS (
      DELETE FROM schedules.job_logs
      WHERE id IN (
        SELECT id FROM schedules.job_logs
        WHERE executed_at < v_cutoff
        ORDER BY executed_at ASC
        LIMIT p_batch_size
      )
      RETURNING id
    )
    SELECT COUNT(*) INTO v_deleted_count FROM deleted;
    
    v_total_deleted := v_total_deleted + v_deleted_count;
    
    EXIT WHEN v_deleted_count < p_batch_size;
  END LOOP;
  
  RETURN v_total_deleted;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'schedules.cleanup_job_logs failed: %', SQLERRM;
  RETURN v_total_deleted;
END;
$$;


--
-- Name: decrypt_headers(text); Type: FUNCTION; Schema: schedules; Owner: -
--

CREATE FUNCTION schedules.decrypt_headers(p_encrypted_headers text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_key TEXT;
  v_decrypted TEXT;
BEGIN
  IF p_encrypted_headers IS NULL OR p_encrypted_headers = '' THEN
    RETURN '{}'::JSONB;
  END IF;

  v_key := current_setting('app.encryption_key', true);
  IF v_key IS NULL OR v_key = '' THEN
    RAISE EXCEPTION 'Encryption key app.encryption_key is not set';
  END IF;

  -- Try to decode and decrypt
  BEGIN
    v_decrypted := pgp_sym_decrypt(decode(p_encrypted_headers, 'base64'), v_key);
    RETURN v_decrypted::JSONB;
  EXCEPTION WHEN others THEN
    RAISE WARNING 'Decryption failed for value: %, error: %', left(p_encrypted_headers, 50), SQLERRM;
    RAISE;  -- Re-raise so execute_job logs the actual failure reason
  END;
END;
$$;


--
-- Name: delete_job(uuid); Type: FUNCTION; Schema: schedules; Owner: -
--

CREATE FUNCTION schedules.delete_job(p_job_id uuid) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_cron_job_id BIGINT;
BEGIN
  SELECT cron_job_id INTO v_cron_job_id
  FROM schedules.jobs WHERE id = p_job_id;

  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'Job not found';
    RETURN;
  END IF;

  IF v_cron_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_cron_job_id);
  END IF;

  DELETE FROM schedules.jobs WHERE id = p_job_id;

  RETURN QUERY SELECT TRUE, 'Cron job deleted successfully';
EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT FALSE, SQLERRM;
END;
$$;


--
-- Name: disable_job(uuid); Type: FUNCTION; Schema: schedules; Owner: -
--

CREATE FUNCTION schedules.disable_job(p_job_id uuid) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_cron_job_id BIGINT;
BEGIN
  SELECT cron_job_id INTO v_cron_job_id
  FROM schedules.jobs WHERE id = p_job_id;

  IF v_cron_job_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'No cron job found for this job';
    RETURN;
  END IF;

  PERFORM cron.unschedule(v_cron_job_id);

  UPDATE schedules.jobs
  SET cron_job_id = NULL, is_active = FALSE, updated_at = NOW()
  WHERE id = p_job_id;

  RETURN QUERY SELECT TRUE, 'Cron job disabled successfully';
EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT FALSE, SQLERRM;
END;
$$;


--
-- Name: enable_job(uuid); Type: FUNCTION; Schema: schedules; Owner: -
--

CREATE FUNCTION schedules.enable_job(p_job_id uuid) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_job RECORD;
  v_new_cron_id BIGINT;
  v_function_call TEXT;
BEGIN
  SELECT id, cron_schedule, function_url
  INTO v_job
  FROM schedules.jobs
  WHERE id = p_job_id;

  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'Job not found';
    RETURN;
  END IF;

  v_function_call := format('SELECT schedules.execute_job(%L::UUID)', p_job_id);
  SELECT cron.schedule(v_job.cron_schedule, v_function_call) INTO v_new_cron_id;

  UPDATE schedules.jobs
  SET cron_job_id = v_new_cron_id,
      is_active = TRUE,
      updated_at = NOW()
  WHERE id = p_job_id;

  RETURN QUERY SELECT TRUE, 'Cron job enabled successfully';
EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT FALSE, SQLERRM;
END;
$$;


--
-- Name: encrypt_headers(jsonb); Type: FUNCTION; Schema: schedules; Owner: -
--

CREATE FUNCTION schedules.encrypt_headers(p_headers jsonb) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_key TEXT;
  v_encrypted TEXT;
BEGIN
  IF p_headers IS NULL OR p_headers = '{}'::JSONB THEN
    RETURN NULL;
  END IF;

  v_key := current_setting('app.encryption_key', true);
  IF v_key IS NULL OR v_key = '' THEN
    RAISE EXCEPTION 'Encryption key app.encryption_key is not set';
  END IF;

  -- pgp_sym_encrypt returns bytea; encode to base64 for TEXT storage
  v_encrypted := encode(pgp_sym_encrypt(p_headers::TEXT, v_key), 'base64');

  RETURN v_encrypted;
END;
$$;


--
-- Name: execute_job(uuid); Type: FUNCTION; Schema: schedules; Owner: -
--

CREATE FUNCTION schedules.execute_job(p_job_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_job RECORD;
  v_http_request http_request;
  v_http_response http_response;
  v_success BOOLEAN;
  v_status INT;
  v_body TEXT;
  v_decrypted_headers JSONB;
  v_final_body JSONB;
  v_start_time TIMESTAMP := clock_timestamp();
  v_end_time TIMESTAMP;
  v_duration_ms BIGINT;
  v_error_message TEXT;
BEGIN
  -- Bound the per-call HTTP timeout. http_set_curlopt is per-session;
  -- pg_cron may reuse a session across ticks but the values are stable so
  -- repeated calls are harmless.
  PERFORM http_set_curlopt('CURLOPT_TIMEOUT_MS', '300000');
  PERFORM http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '5000');

  SELECT
    j.id,
    j.name,
    j.function_url,
    j.http_method,
    j.body,
    j.encrypted_headers
  INTO v_job
  FROM schedules.jobs AS j
  WHERE j.id = p_job_id;

  IF NOT FOUND THEN
    PERFORM schedules.log_job_execution(p_job_id, 'unknown', FALSE, 404, 0, 'Job not found');
    RETURN;
  END IF;

  BEGIN
    -- Decrypt headers
    v_decrypted_headers := schedules.decrypt_headers(v_job.encrypted_headers);

    -- Build the final request body
    v_final_body := COALESCE(v_job.body, '{}'::JSONB);

    -- Construct HTTP request
    v_http_request := (
      v_job.http_method::http_method,
      v_job.function_url,
      schedules.build_http_headers(v_decrypted_headers),
      'application/json',
      v_final_body::TEXT
    );
    v_start_time := clock_timestamp();
    -- Execute HTTP call (synchronous; bounded by curl timeouts set above)
    v_http_response := http(v_http_request);
    v_end_time := clock_timestamp();
    v_duration_ms := EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000;
    v_status := v_http_response.status;
    v_body := v_http_response.content;
    v_success := v_status BETWEEN 200 AND 299;

    -- Log execution
    v_error_message := CASE WHEN v_success THEN 'Success' ELSE 'HTTP ' || v_status END;
    PERFORM schedules.log_job_execution(v_job.id, v_job.name, v_success, v_status, v_duration_ms, v_error_message);

  EXCEPTION WHEN OTHERS THEN
    v_end_time := clock_timestamp();
    v_duration_ms := EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000;
    PERFORM schedules.log_job_execution(v_job.id, v_job.name, FALSE, 500, v_duration_ms, SQLERRM);
  END;
END;
$$;


--
-- Name: log_job_execution(uuid, text, boolean, integer, bigint, text); Type: FUNCTION; Schema: schedules; Owner: -
--

CREATE FUNCTION schedules.log_job_execution(p_job_id uuid, p_job_name text, p_success boolean, p_response_status integer, p_duration_ms bigint, p_message text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO schedules.job_logs (
    job_id,
    executed_at,
    status_code,
    success,
    duration_ms,
    message
  ) VALUES (
    p_job_id,
    NOW(),
    p_response_status,
    p_success,
    p_duration_ms,
    p_message
  );

  -- Update last_executed_at in jobs table
  UPDATE schedules.jobs
  SET last_executed_at = NOW(),
      updated_at = NOW()
  WHERE id = p_job_id;
END;
$$;


--
-- Name: upsert_job(uuid, text, text, text, text, jsonb, jsonb, jsonb); Type: FUNCTION; Schema: schedules; Owner: -
--

CREATE FUNCTION schedules.upsert_job(p_job_id uuid, p_name text, p_cron_expression text, p_http_method text, p_function_url text, p_headers_template jsonb, p_resolved_headers jsonb, p_body jsonb) RETURNS TABLE(cron_job_id bigint, success boolean, message text)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_existing_cron_id BIGINT;
  v_new_cron_id BIGINT;
  v_function_call TEXT;
  v_encrypted_headers TEXT;
BEGIN
  -- Encrypt resolved headers (with actual secret values) before storing
  v_encrypted_headers := schedules.encrypt_headers(p_resolved_headers);

  -- Unschedule any existing job for this schedule to prevent duplicates
  SELECT j.cron_job_id INTO v_existing_cron_id
  FROM schedules.jobs AS j
  WHERE j.id = p_job_id;

  IF v_existing_cron_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_existing_cron_id);
  END IF;

  -- Schedule the new cron job
  v_function_call := format('SELECT schedules.execute_job(%L::UUID)', p_job_id);
  SELECT cron.schedule(p_cron_expression, v_function_call) INTO v_new_cron_id;

  -- Insert or update the job record
  -- headers = original template (safe to display)
  -- encrypted_headers = resolved values (used at runtime)
  INSERT INTO schedules.jobs (
    id, name, cron_schedule, function_url, http_method, encrypted_headers, headers, body, cron_job_id, is_active, created_at, updated_at
  ) VALUES (
    p_job_id,
    p_name,
    p_cron_expression,
    p_function_url,
    p_http_method,
    v_encrypted_headers,
    p_headers_template,
    p_body,
    v_new_cron_id,
    TRUE,
    NOW(),
    NOW()
  ) ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    cron_schedule = EXCLUDED.cron_schedule,
    function_url = EXCLUDED.function_url,
    http_method = EXCLUDED.http_method,
    encrypted_headers = EXCLUDED.encrypted_headers,
    headers = EXCLUDED.headers,
    body = EXCLUDED.body,
    cron_job_id = EXCLUDED.cron_job_id,
    is_active = TRUE,
    updated_at = NOW();

  RETURN QUERY SELECT v_new_cron_id, TRUE, 'Cron job scheduled successfully';
EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT NULL::BIGINT, FALSE, SQLERRM;
END;
$$;


--
-- Name: extension(text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.extension(name text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $_$
  SELECT (regexp_match(name, '\.([^./\\]+)$'))[1]
$_$;


--
-- Name: filename(text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.filename(name text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
  SELECT (regexp_split_to_array(name, '/'))[
    array_upper(regexp_split_to_array(name, '/'), 1)
  ]
$$;


--
-- Name: foldername(text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.foldername(name text) RETURNS text[]
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
  SELECT (regexp_split_to_array(name, '/'))[
    1 : array_upper(regexp_split_to_array(name, '/'), 1) - 1
  ]
$$;


--
-- Name: reload_postgrest_schema(); Type: FUNCTION; Schema: system; Owner: -
--

CREATE FUNCTION system.reload_postgrest_schema() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    NOTIFY pgrst, 'reload schema';
    RAISE NOTICE 'PostgREST schema reload notification sent';
END
$$;


--
-- Name: update_updated_at(); Type: FUNCTION; Schema: system; Owner: -
--

CREATE FUNCTION system.update_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: config; Type: TABLE; Schema: auth; Owner: -
--

CREATE TABLE auth.config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    require_email_verification boolean DEFAULT false NOT NULL,
    password_min_length integer DEFAULT 6 NOT NULL,
    require_number boolean DEFAULT false NOT NULL,
    require_lowercase boolean DEFAULT false NOT NULL,
    require_uppercase boolean DEFAULT false NOT NULL,
    require_special_char boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    verify_email_method text DEFAULT 'code'::text NOT NULL,
    reset_password_method text DEFAULT 'code'::text NOT NULL,
    allowed_redirect_urls text[] DEFAULT '{}'::text[],
    disable_signup boolean DEFAULT false NOT NULL,
    CONSTRAINT _auth_configs_password_min_length_check CHECK (((password_min_length >= 4) AND (password_min_length <= 128))),
    CONSTRAINT _auth_configs_reset_password_method_check CHECK ((reset_password_method = ANY (ARRAY['code'::text, 'link'::text]))),
    CONSTRAINT _auth_configs_verify_email_method_check CHECK ((verify_email_method = ANY (ARRAY['code'::text, 'link'::text])))
);


--
-- Name: custom_oauth_configs; Type: TABLE; Schema: auth; Owner: -
--

CREATE TABLE auth.custom_oauth_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key text NOT NULL,
    name text NOT NULL,
    discovery_endpoint text NOT NULL,
    client_id text NOT NULL,
    secret_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT custom_oauth_configs_key_format_check CHECK ((key ~ '^[a-z0-9_-]+$'::text))
);


--
-- Name: email_otps; Type: TABLE; Schema: auth; Owner: -
--

CREATE TABLE auth.email_otps (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text NOT NULL,
    purpose text NOT NULL,
    otp_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    redirect_to text
);


--
-- Name: oauth_configs; Type: TABLE; Schema: auth; Owner: -
--

CREATE TABLE auth.oauth_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider text NOT NULL,
    client_id text,
    secret_id uuid,
    scopes text[],
    redirect_uri text,
    use_shared_key boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: user_providers; Type: TABLE; Schema: auth; Owner: -
--

CREATE TABLE auth.user_providers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    provider text NOT NULL,
    provider_account_id text NOT NULL,
    access_token text,
    refresh_token text,
    provider_data jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: users; Type: TABLE; Schema: auth; Owner: -
--

CREATE TABLE auth.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text NOT NULL,
    password text,
    email_verified boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    profile jsonb DEFAULT '{}'::jsonb,
    metadata jsonb DEFAULT '{}'::jsonb,
    is_project_admin boolean DEFAULT false NOT NULL,
    is_anonymous boolean DEFAULT false NOT NULL
);


--
-- Name: services; Type: TABLE; Schema: compute; Owner: -
--

CREATE TABLE compute.services (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id text NOT NULL,
    name text NOT NULL,
    image_url text NOT NULL,
    port integer DEFAULT 8080 NOT NULL,
    cpu text DEFAULT 'shared-1x'::text NOT NULL,
    memory integer DEFAULT 512 NOT NULL,
    env_vars_encrypted text,
    region text DEFAULT 'iad'::text NOT NULL,
    fly_app_id text,
    fly_machine_id text,
    status text DEFAULT 'creating'::text NOT NULL,
    endpoint_url text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    protocol text DEFAULT 'http'::text NOT NULL,
    CONSTRAINT chk_compute_services_protocol CHECK ((protocol = ANY (ARRAY['http'::text, 'tcp'::text]))),
    CONSTRAINT services_port_check CHECK (((port >= 1) AND (port <= 65535))),
    CONSTRAINT services_status_check CHECK ((status = ANY (ARRAY['creating'::text, 'deploying'::text, 'running'::text, 'stopped'::text, 'failed'::text, 'destroying'::text])))
);


--
-- Name: files; Type: TABLE; Schema: deployments; Owner: -
--

CREATE TABLE deployments.files (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    deployment_id uuid NOT NULL,
    file_path text NOT NULL,
    sha text NOT NULL,
    size_bytes integer NOT NULL,
    uploaded_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT files_sha_check CHECK ((sha ~ '^[a-f0-9]{40}$'::text)),
    CONSTRAINT files_size_bytes_check CHECK ((size_bytes >= 0))
);


--
-- Name: runs; Type: TABLE; Schema: deployments; Owner: -
--

CREATE TABLE deployments.runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider text DEFAULT 'vercel'::text NOT NULL,
    provider_deployment_id text,
    status text DEFAULT 'WAITING'::text NOT NULL,
    url text,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: config; Type: TABLE; Schema: email; Owner: -
--

CREATE TABLE email.config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    host text DEFAULT ''::text NOT NULL,
    port integer DEFAULT 465 NOT NULL,
    username text DEFAULT ''::text NOT NULL,
    password_encrypted text DEFAULT ''::text NOT NULL,
    sender_email text DEFAULT ''::text NOT NULL,
    sender_name text DEFAULT ''::text NOT NULL,
    min_interval_seconds integer DEFAULT 60 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: templates; Type: TABLE; Schema: email; Owner: -
--

CREATE TABLE email.templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    template_type text NOT NULL,
    subject text NOT NULL,
    body_html text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: definitions; Type: TABLE; Schema: functions; Owner: -
--

CREATE TABLE functions.definitions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    code text NOT NULL,
    status character varying(50) DEFAULT 'draft'::character varying,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deployed_at timestamp with time zone
);


--
-- Name: deployments; Type: TABLE; Schema: functions; Owner: -
--

CREATE TABLE functions.deployments (
    id text NOT NULL,
    project_id text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    url text,
    function_count integer,
    functions jsonb,
    error_message text,
    build_logs jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: checkout_sessions; Type: TABLE; Schema: payments; Owner: -
--

CREATE TABLE payments.checkout_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment text NOT NULL,
    mode text NOT NULL,
    status text DEFAULT 'initialized'::text NOT NULL,
    payment_status text,
    subject_type text,
    subject_id text,
    customer_email text,
    line_items jsonb DEFAULT '[]'::jsonb NOT NULL,
    success_url text NOT NULL,
    cancel_url text NOT NULL,
    idempotency_key text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    stripe_checkout_session_id text,
    stripe_customer_id text,
    stripe_payment_intent_id text,
    stripe_subscription_id text,
    url text,
    last_error text,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT checkout_sessions_environment_check CHECK ((environment = ANY (ARRAY['test'::text, 'live'::text]))),
    CONSTRAINT checkout_sessions_line_items_check CHECK ((jsonb_typeof(line_items) = 'array'::text)),
    CONSTRAINT checkout_sessions_mode_check CHECK ((mode = ANY (ARRAY['payment'::text, 'subscription'::text]))),
    CONSTRAINT checkout_sessions_payment_status_check CHECK (((payment_status IS NULL) OR (payment_status = ANY (ARRAY['paid'::text, 'unpaid'::text, 'no_payment_required'::text])))),
    CONSTRAINT checkout_sessions_status_check CHECK ((status = ANY (ARRAY['initialized'::text, 'open'::text, 'completed'::text, 'expired'::text, 'failed'::text])))
);


--
-- Name: customer_portal_sessions; Type: TABLE; Schema: payments; Owner: -
--

CREATE TABLE payments.customer_portal_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment text NOT NULL,
    status text DEFAULT 'initialized'::text NOT NULL,
    subject_type text NOT NULL,
    subject_id text NOT NULL,
    stripe_customer_id text,
    return_url text,
    configuration_id text,
    url text,
    last_error text,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT customer_portal_sessions_environment_check CHECK ((environment = ANY (ARRAY['test'::text, 'live'::text]))),
    CONSTRAINT customer_portal_sessions_status_check CHECK ((status = ANY (ARRAY['initialized'::text, 'created'::text, 'failed'::text])))
);


--
-- Name: customers; Type: TABLE; Schema: payments; Owner: -
--

CREATE TABLE payments.customers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment text NOT NULL,
    stripe_customer_id text NOT NULL,
    email text,
    name text,
    phone text,
    deleted boolean DEFAULT false NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    stripe_created_at timestamp with time zone,
    synced_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT customers_environment_check CHECK ((environment = ANY (ARRAY['test'::text, 'live'::text])))
);


--
-- Name: payment_history; Type: TABLE; Schema: payments; Owner: -
--

CREATE TABLE payments.payment_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment text NOT NULL,
    type text NOT NULL,
    status text NOT NULL,
    subject_type text,
    subject_id text,
    stripe_customer_id text,
    customer_email_snapshot text,
    stripe_checkout_session_id text,
    stripe_payment_intent_id text,
    stripe_invoice_id text,
    stripe_charge_id text,
    stripe_refund_id text,
    stripe_subscription_id text,
    stripe_product_id text,
    stripe_price_id text,
    amount bigint,
    amount_refunded bigint,
    currency text,
    description text,
    paid_at timestamp with time zone,
    failed_at timestamp with time zone,
    refunded_at timestamp with time zone,
    stripe_created_at timestamp with time zone,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT payment_history_environment_check CHECK ((environment = ANY (ARRAY['test'::text, 'live'::text])))
);


--
-- Name: prices; Type: TABLE; Schema: payments; Owner: -
--

CREATE TABLE payments.prices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment text NOT NULL,
    stripe_price_id text NOT NULL,
    stripe_product_id text,
    active boolean NOT NULL,
    currency text NOT NULL,
    unit_amount bigint,
    unit_amount_decimal text,
    type text NOT NULL,
    lookup_key text,
    billing_scheme text,
    tax_behavior text,
    recurring_interval text,
    recurring_interval_count integer,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    synced_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT prices_environment_check CHECK ((environment = ANY (ARRAY['test'::text, 'live'::text])))
);


--
-- Name: products; Type: TABLE; Schema: payments; Owner: -
--

CREATE TABLE payments.products (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment text NOT NULL,
    stripe_product_id text NOT NULL,
    name text NOT NULL,
    description text,
    active boolean NOT NULL,
    default_price_id text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    synced_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT products_environment_check CHECK ((environment = ANY (ARRAY['test'::text, 'live'::text])))
);


--
-- Name: stripe_connections; Type: TABLE; Schema: payments; Owner: -
--

CREATE TABLE payments.stripe_connections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment text NOT NULL,
    stripe_account_id text,
    stripe_account_email text,
    account_livemode boolean,
    status text DEFAULT 'unconfigured'::text NOT NULL,
    webhook_endpoint_id text,
    webhook_endpoint_url text,
    webhook_configured_at timestamp with time zone,
    last_synced_at timestamp with time zone,
    last_sync_status text,
    last_sync_error text,
    last_sync_counts jsonb DEFAULT '{}'::jsonb NOT NULL,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT stripe_connections_environment_check CHECK ((environment = ANY (ARRAY['test'::text, 'live'::text]))),
    CONSTRAINT stripe_connections_last_sync_status_check CHECK (((last_sync_status IS NULL) OR (last_sync_status = ANY (ARRAY['succeeded'::text, 'failed'::text])))),
    CONSTRAINT stripe_connections_status_check CHECK ((status = ANY (ARRAY['unconfigured'::text, 'connected'::text, 'error'::text])))
);


--
-- Name: stripe_customer_mappings; Type: TABLE; Schema: payments; Owner: -
--

CREATE TABLE payments.stripe_customer_mappings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment text NOT NULL,
    subject_type text NOT NULL,
    subject_id text NOT NULL,
    stripe_customer_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT stripe_customer_mappings_environment_check CHECK ((environment = ANY (ARRAY['test'::text, 'live'::text])))
);


--
-- Name: subscription_items; Type: TABLE; Schema: payments; Owner: -
--

CREATE TABLE payments.subscription_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment text NOT NULL,
    stripe_subscription_item_id text NOT NULL,
    stripe_subscription_id text NOT NULL,
    stripe_product_id text,
    stripe_price_id text,
    quantity bigint,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT subscription_items_environment_check CHECK ((environment = ANY (ARRAY['test'::text, 'live'::text])))
);


--
-- Name: subscriptions; Type: TABLE; Schema: payments; Owner: -
--

CREATE TABLE payments.subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment text NOT NULL,
    stripe_subscription_id text NOT NULL,
    stripe_customer_id text NOT NULL,
    subject_type text,
    subject_id text,
    status text NOT NULL,
    current_period_start timestamp with time zone,
    current_period_end timestamp with time zone,
    cancel_at_period_end boolean DEFAULT false NOT NULL,
    cancel_at timestamp with time zone,
    canceled_at timestamp with time zone,
    trial_start timestamp with time zone,
    trial_end timestamp with time zone,
    latest_invoice_id text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    synced_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT subscriptions_environment_check CHECK ((environment = ANY (ARRAY['test'::text, 'live'::text])))
);


--
-- Name: webhook_events; Type: TABLE; Schema: payments; Owner: -
--

CREATE TABLE payments.webhook_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    environment text NOT NULL,
    stripe_event_id text NOT NULL,
    event_type text NOT NULL,
    livemode boolean NOT NULL,
    stripe_account_id text,
    object_type text,
    object_id text,
    processing_status text DEFAULT 'pending'::text NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_error text,
    payload jsonb NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT webhook_events_environment_check CHECK ((environment = ANY (ARRAY['test'::text, 'live'::text]))),
    CONSTRAINT webhook_events_processing_status_check CHECK ((processing_status = ANY (ARRAY['pending'::text, 'processed'::text, 'failed'::text, 'ignored'::text])))
);


--
-- Name: channels; Type: TABLE; Schema: realtime; Owner: -
--

CREATE TABLE realtime.channels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pattern text NOT NULL,
    description text,
    webhook_urls text[],
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: config; Type: TABLE; Schema: realtime; Owner: -
--

CREATE TABLE realtime.config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    retention_days integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT config_retention_days_check CHECK (((retention_days IS NULL) OR (retention_days > 0)))
);


--
-- Name: messages; Type: TABLE; Schema: realtime; Owner: -
--

CREATE TABLE realtime.messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_name text NOT NULL,
    channel_id uuid,
    channel_name text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    sender_type text DEFAULT 'system'::text NOT NULL,
    sender_id uuid,
    ws_audience_count integer DEFAULT 0 NOT NULL,
    wh_audience_count integer DEFAULT 0 NOT NULL,
    wh_delivered_count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT messages_sender_type_check CHECK ((sender_type = ANY (ARRAY['system'::text, 'user'::text])))
);


--
-- Name: config; Type: TABLE; Schema: schedules; Owner: -
--

CREATE TABLE schedules.config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    retention_days integer DEFAULT 7,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT config_retention_days_check CHECK (((retention_days IS NULL) OR (retention_days > 0)))
);


--
-- Name: job_logs; Type: TABLE; Schema: schedules; Owner: -
--

CREATE TABLE schedules.job_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    job_id uuid,
    executed_at timestamp with time zone DEFAULT now(),
    status_code integer,
    success boolean,
    duration_ms bigint,
    message text
);


--
-- Name: jobs; Type: TABLE; Schema: schedules; Owner: -
--

CREATE TABLE schedules.jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    cron_schedule text NOT NULL,
    function_url text NOT NULL,
    http_method text DEFAULT 'POST'::text NOT NULL,
    encrypted_headers text,
    headers jsonb,
    body jsonb,
    is_active boolean DEFAULT true NOT NULL,
    cron_job_id bigint,
    last_executed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: buckets; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.buckets (
    name text NOT NULL,
    public boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: config; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    max_file_size_mb integer DEFAULT 50 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT config_max_file_size_mb_check CHECK (((max_file_size_mb >= 1) AND (max_file_size_mb <= 200)))
);


--
-- Name: objects; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.objects (
    bucket text NOT NULL,
    key text NOT NULL,
    size integer NOT NULL,
    mime_type text,
    uploaded_at timestamp with time zone DEFAULT now(),
    uploaded_by text,
    uploaded_via text DEFAULT 'rest'::text NOT NULL,
    s3_access_key_id text,
    etag text,
    CONSTRAINT objects_uploaded_via_check CHECK ((uploaded_via = ANY (ARRAY['rest'::text, 's3'::text, 'dashboard'::text])))
);


--
-- Name: s3_access_keys; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.s3_access_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    access_key_id text NOT NULL,
    secret_access_key_encrypted text NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone
);


--
-- Name: audit_logs; Type: TABLE; Schema: system; Owner: -
--

CREATE TABLE system.audit_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor text NOT NULL,
    action text NOT NULL,
    module text NOT NULL,
    details jsonb,
    ip_address inet,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: custom_migrations; Type: TABLE; Schema: system; Owner: -
--

CREATE TABLE system.custom_migrations (
    version text NOT NULL,
    name text NOT NULL,
    statements text[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT custom_migrations_version_check CHECK ((version ~ '^[0-9]{1,64}$'::text))
);


--
-- Name: mcp_usage; Type: TABLE; Schema: system; Owner: -
--

CREATE TABLE system.mcp_usage (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tool_name character varying(255) NOT NULL,
    success boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: migrations; Type: TABLE; Schema: system; Owner: -
--

CREATE TABLE system.migrations (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    run_on timestamp without time zone NOT NULL
);


--
-- Name: migrations_id_seq; Type: SEQUENCE; Schema: system; Owner: -
--

CREATE SEQUENCE system.migrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: migrations_id_seq; Type: SEQUENCE OWNED BY; Schema: system; Owner: -
--

ALTER SEQUENCE system.migrations_id_seq OWNED BY system.migrations.id;


--
-- Name: secrets; Type: TABLE; Schema: system; Owner: -
--

CREATE TABLE system.secrets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key text NOT NULL,
    value_ciphertext text NOT NULL,
    is_active boolean DEFAULT true,
    last_used_at timestamp with time zone,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    is_reserved boolean DEFAULT false
);


--
-- Name: migrations id; Type: DEFAULT; Schema: system; Owner: -
--

ALTER TABLE ONLY system.migrations ALTER COLUMN id SET DEFAULT nextval('system.migrations_id_seq'::regclass);


--
-- Data for Name: config; Type: TABLE DATA; Schema: auth; Owner: -
--

COPY auth.config (id, require_email_verification, password_min_length, require_number, require_lowercase, require_uppercase, require_special_char, created_at, updated_at, verify_email_method, reset_password_method, allowed_redirect_urls, disable_signup) FROM stdin;
\.


--
-- Data for Name: custom_oauth_configs; Type: TABLE DATA; Schema: auth; Owner: -
--

COPY auth.custom_oauth_configs (id, key, name, discovery_endpoint, client_id, secret_id, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: email_otps; Type: TABLE DATA; Schema: auth; Owner: -
--

COPY auth.email_otps (id, email, purpose, otp_hash, expires_at, consumed_at, created_at, updated_at, redirect_to) FROM stdin;
\.


--
-- Data for Name: oauth_configs; Type: TABLE DATA; Schema: auth; Owner: -
--

COPY auth.oauth_configs (id, provider, client_id, secret_id, scopes, redirect_uri, use_shared_key, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: user_providers; Type: TABLE DATA; Schema: auth; Owner: -
--

COPY auth.user_providers (id, user_id, provider, provider_account_id, access_token, refresh_token, provider_data, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: auth; Owner: -
--

COPY auth.users (id, email, password, email_verified, created_at, updated_at, profile, metadata, is_project_admin, is_anonymous) FROM stdin;
\.


--
-- Data for Name: services; Type: TABLE DATA; Schema: compute; Owner: -
--

COPY compute.services (id, project_id, name, image_url, port, cpu, memory, env_vars_encrypted, region, fly_app_id, fly_machine_id, status, endpoint_url, created_at, updated_at, protocol) FROM stdin;
\.


--
-- Data for Name: job; Type: TABLE DATA; Schema: cron; Owner: -
--



--
-- Data for Name: job_run_details; Type: TABLE DATA; Schema: cron; Owner: -
--



--
-- Data for Name: files; Type: TABLE DATA; Schema: deployments; Owner: -
--

COPY deployments.files (id, deployment_id, file_path, sha, size_bytes, uploaded_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: runs; Type: TABLE DATA; Schema: deployments; Owner: -
--

COPY deployments.runs (id, provider, provider_deployment_id, status, url, metadata, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: config; Type: TABLE DATA; Schema: email; Owner: -
--

COPY email.config (id, enabled, host, port, username, password_encrypted, sender_email, sender_name, min_interval_seconds, created_at, updated_at) FROM stdin;
df6e117b-117d-4e4d-8e5b-1b394ba3091a	f		465					60	2026-06-10 07:08:20.324+00	2026-06-10 07:08:20.324+00
\.


--
-- Data for Name: templates; Type: TABLE DATA; Schema: email; Owner: -
--

COPY email.templates (id, template_type, subject, body_html, created_at, updated_at) FROM stdin;
7bcfed9c-8b1f-44e3-8fb4-0888700f7bdc	email-verification-code	Verify your email	<!DOCTYPE html><html><head><meta charset="utf-8"></head><body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:600px;margin:0 auto;padding:40px 20px;color:#1a1a1a;"><div style="text-align:center;padding:32px;background:#f9fafb;border-radius:12px;border:1px solid #e5e7eb;"><h2 style="margin:0 0 8px;font-size:20px;font-weight:600;">Verify your email</h2><p style="margin:0 0 24px;color:#6b7280;font-size:14px;">Enter this code to verify your email address</p><div style="background:#ffffff;border:2px solid #e5e7eb;border-radius:8px;padding:16px 32px;display:inline-block;margin-bottom:24px;"><span style="font-size:32px;font-weight:700;letter-spacing:8px;color:#111827;">{{ token }}</span></div><p style="margin:0;color:#9ca3af;font-size:12px;">This code expires in 15 minutes</p></div></body></html>	2026-06-10 07:08:20.324+00	2026-06-10 07:08:20.324+00
099a352f-55ae-4529-8c11-3241a0897e69	email-verification-link	Verify your email	<!DOCTYPE html><html><head><meta charset="utf-8"></head><body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:600px;margin:0 auto;padding:40px 20px;color:#1a1a1a;"><div style="text-align:center;padding:32px;background:#f9fafb;border-radius:12px;border:1px solid #e5e7eb;"><h2 style="margin:0 0 8px;font-size:20px;font-weight:600;">Verify your email</h2><p style="margin:0 0 24px;color:#6b7280;font-size:14px;">Click the button below to verify your email address</p><a href="{{ link }}" style="display:inline-block;background:#111827;color:#ffffff;text-decoration:none;padding:12px 32px;border-radius:6px;font-size:14px;font-weight:500;">Verify Email</a><p style="margin:24px 0 0;color:#9ca3af;font-size:12px;">This link expires in 24 hours</p></div></body></html>	2026-06-10 07:08:20.324+00	2026-06-10 07:08:20.324+00
c0f82566-9888-4800-83c7-ad24e03fedd7	reset-password-code	Reset your password	<!DOCTYPE html><html><head><meta charset="utf-8"></head><body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:600px;margin:0 auto;padding:40px 20px;color:#1a1a1a;"><div style="text-align:center;padding:32px;background:#f9fafb;border-radius:12px;border:1px solid #e5e7eb;"><h2 style="margin:0 0 8px;font-size:20px;font-weight:600;">Reset your password</h2><p style="margin:0 0 24px;color:#6b7280;font-size:14px;">Enter this code to reset your password</p><div style="background:#ffffff;border:2px solid #e5e7eb;border-radius:8px;padding:16px 32px;display:inline-block;margin-bottom:24px;"><span style="font-size:32px;font-weight:700;letter-spacing:8px;color:#111827;">{{ token }}</span></div><p style="margin:0;color:#9ca3af;font-size:12px;">This code expires in 15 minutes</p></div></body></html>	2026-06-10 07:08:20.324+00	2026-06-10 07:08:20.324+00
0c0ba2c8-ccb8-44b0-9e30-a313d3b43522	reset-password-link	Reset your password	<!DOCTYPE html><html><head><meta charset="utf-8"></head><body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:600px;margin:0 auto;padding:40px 20px;color:#1a1a1a;"><div style="text-align:center;padding:32px;background:#f9fafb;border-radius:12px;border:1px solid #e5e7eb;"><h2 style="margin:0 0 8px;font-size:20px;font-weight:600;">Reset your password</h2><p style="margin:0 0 24px;color:#6b7280;font-size:14px;">Click the button below to reset your password</p><a href="{{ link }}" style="display:inline-block;background:#111827;color:#ffffff;text-decoration:none;padding:12px 32px;border-radius:6px;font-size:14px;font-weight:500;">Reset Password</a><p style="margin:24px 0 0;color:#9ca3af;font-size:12px;">This link expires in 24 hours</p></div></body></html>	2026-06-10 07:08:20.324+00	2026-06-10 07:08:20.324+00
\.


--
-- Data for Name: definitions; Type: TABLE DATA; Schema: functions; Owner: -
--

COPY functions.definitions (id, slug, name, description, code, status, created_at, updated_at, deployed_at) FROM stdin;
\.


--
-- Data for Name: deployments; Type: TABLE DATA; Schema: functions; Owner: -
--

COPY functions.deployments (id, project_id, status, url, function_count, functions, error_message, build_logs, created_at) FROM stdin;
\.


--
-- Data for Name: checkout_sessions; Type: TABLE DATA; Schema: payments; Owner: -
--

COPY payments.checkout_sessions (id, environment, mode, status, payment_status, subject_type, subject_id, customer_email, line_items, success_url, cancel_url, idempotency_key, metadata, stripe_checkout_session_id, stripe_customer_id, stripe_payment_intent_id, stripe_subscription_id, url, last_error, raw, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: customer_portal_sessions; Type: TABLE DATA; Schema: payments; Owner: -
--

COPY payments.customer_portal_sessions (id, environment, status, subject_type, subject_id, stripe_customer_id, return_url, configuration_id, url, last_error, raw, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: customers; Type: TABLE DATA; Schema: payments; Owner: -
--

COPY payments.customers (id, environment, stripe_customer_id, email, name, phone, deleted, metadata, raw, stripe_created_at, synced_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: payment_history; Type: TABLE DATA; Schema: payments; Owner: -
--

COPY payments.payment_history (id, environment, type, status, subject_type, subject_id, stripe_customer_id, customer_email_snapshot, stripe_checkout_session_id, stripe_payment_intent_id, stripe_invoice_id, stripe_charge_id, stripe_refund_id, stripe_subscription_id, stripe_product_id, stripe_price_id, amount, amount_refunded, currency, description, paid_at, failed_at, refunded_at, stripe_created_at, raw, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: prices; Type: TABLE DATA; Schema: payments; Owner: -
--

COPY payments.prices (id, environment, stripe_price_id, stripe_product_id, active, currency, unit_amount, unit_amount_decimal, type, lookup_key, billing_scheme, tax_behavior, recurring_interval, recurring_interval_count, metadata, raw, synced_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: products; Type: TABLE DATA; Schema: payments; Owner: -
--

COPY payments.products (id, environment, stripe_product_id, name, description, active, default_price_id, metadata, raw, synced_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: stripe_connections; Type: TABLE DATA; Schema: payments; Owner: -
--

COPY payments.stripe_connections (id, environment, stripe_account_id, stripe_account_email, account_livemode, status, webhook_endpoint_id, webhook_endpoint_url, webhook_configured_at, last_synced_at, last_sync_status, last_sync_error, last_sync_counts, raw, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: stripe_customer_mappings; Type: TABLE DATA; Schema: payments; Owner: -
--

COPY payments.stripe_customer_mappings (id, environment, subject_type, subject_id, stripe_customer_id, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: subscription_items; Type: TABLE DATA; Schema: payments; Owner: -
--

COPY payments.subscription_items (id, environment, stripe_subscription_item_id, stripe_subscription_id, stripe_product_id, stripe_price_id, quantity, metadata, raw, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: subscriptions; Type: TABLE DATA; Schema: payments; Owner: -
--

COPY payments.subscriptions (id, environment, stripe_subscription_id, stripe_customer_id, subject_type, subject_id, status, current_period_start, current_period_end, cancel_at_period_end, cancel_at, canceled_at, trial_start, trial_end, latest_invoice_id, metadata, raw, synced_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: webhook_events; Type: TABLE DATA; Schema: payments; Owner: -
--

COPY payments.webhook_events (id, environment, stripe_event_id, event_type, livemode, stripe_account_id, object_type, object_id, processing_status, attempt_count, last_error, payload, received_at, processed_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: channels; Type: TABLE DATA; Schema: realtime; Owner: -
--

COPY realtime.channels (id, pattern, description, webhook_urls, enabled, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: config; Type: TABLE DATA; Schema: realtime; Owner: -
--

COPY realtime.config (id, retention_days, created_at, updated_at) FROM stdin;
38b9d535-7aeb-4049-b265-3c79d4541705	\N	2026-06-10 07:08:20.324+00	2026-06-10 07:08:20.324+00
\.


--
-- Data for Name: messages; Type: TABLE DATA; Schema: realtime; Owner: -
--

COPY realtime.messages (id, event_name, channel_id, channel_name, payload, sender_type, sender_id, ws_audience_count, wh_audience_count, wh_delivered_count, created_at) FROM stdin;
\.


--
-- Data for Name: config; Type: TABLE DATA; Schema: schedules; Owner: -
--

COPY schedules.config (id, retention_days, created_at, updated_at) FROM stdin;
6f676872-15be-4df6-846e-3d4ea659d54b	7	2026-06-10 07:08:20.324+00	2026-06-10 07:08:20.324+00
\.


--
-- Data for Name: job_logs; Type: TABLE DATA; Schema: schedules; Owner: -
--

COPY schedules.job_logs (id, job_id, executed_at, status_code, success, duration_ms, message) FROM stdin;
\.


--
-- Data for Name: jobs; Type: TABLE DATA; Schema: schedules; Owner: -
--

COPY schedules.jobs (id, name, cron_schedule, function_url, http_method, encrypted_headers, headers, body, is_active, cron_job_id, last_executed_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: buckets; Type: TABLE DATA; Schema: storage; Owner: -
--

COPY storage.buckets (name, public, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: config; Type: TABLE DATA; Schema: storage; Owner: -
--

COPY storage.config (id, max_file_size_mb, created_at, updated_at) FROM stdin;
c5579ee7-22d6-475a-8419-5c8687071580	50	2026-06-10 07:08:20.324+00	2026-06-10 07:08:20.324+00
\.


--
-- Data for Name: objects; Type: TABLE DATA; Schema: storage; Owner: -
--

COPY storage.objects (bucket, key, size, mime_type, uploaded_at, uploaded_by, uploaded_via, s3_access_key_id, etag) FROM stdin;
\.


--
-- Data for Name: s3_access_keys; Type: TABLE DATA; Schema: storage; Owner: -
--

COPY storage.s3_access_keys (id, access_key_id, secret_access_key_encrypted, description, created_at, last_used_at) FROM stdin;
\.


--
-- Data for Name: audit_logs; Type: TABLE DATA; Schema: system; Owner: -
--

COPY system.audit_logs (id, actor, action, module, details, ip_address, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: custom_migrations; Type: TABLE DATA; Schema: system; Owner: -
--

COPY system.custom_migrations (version, name, statements, created_at) FROM stdin;
\.


--
-- Data for Name: mcp_usage; Type: TABLE DATA; Schema: system; Owner: -
--

COPY system.mcp_usage (id, tool_name, success, created_at) FROM stdin;
\.


--
-- Data for Name: migrations; Type: TABLE DATA; Schema: system; Owner: -
--

COPY system.migrations (id, name, run_on) FROM stdin;
1	000_create-base-tables	2026-06-10 07:08:20.324
2	001_create-helper-functions	2026-06-10 07:08:20.324
3	002_rename-auth-tables	2026-06-10 07:08:20.324
4	003_create-users-table	2026-06-10 07:08:20.324
5	004_add-reload-postgrest-func	2026-06-10 07:08:20.324
6	005_enable-project-admin-modify-users	2026-06-10 07:08:20.324
7	006_modify-ai-usage-table	2026-06-10 07:08:20.324
8	007_drop-metadata-table	2026-06-10 07:08:20.324
9	008_add-system-tables	2026-06-10 07:08:20.324
10	009_add-function-secrets	2026-06-10 07:08:20.324
11	010_modify-ai-config-modalities	2026-06-10 07:08:20.324
12	011_refactor-secrets-table	2026-06-10 07:08:20.324
13	012_add-storage-uploaded-by	2026-06-10 07:08:20.324
14	013_create-auth-schema-functions	2026-06-10 07:08:20.324
15	014_add-updated-at-trigger-user-table	2026-06-10 07:08:20.324
16	015_create-auth-config-and-email-otp-tables	2026-06-10 07:08:20.324
17	016_update-auth-config-and-email-otp	2026-06-10 07:08:20.324
18	017_create-realtime-schema	2026-06-10 07:08:20.324
19	018_schema-rework	2026-06-10 07:08:20.324
20	019_create-deployments-table	2026-06-10 07:08:20.324
21	020_add-audio-modality	2026-06-10 07:08:20.324
22	021_create-schedules-schema	2026-06-10 07:08:20.324
23	022_create-function-deployments	2026-06-10 07:08:20.324
24	023_ai-configs-soft-delete	2026-06-10 07:08:20.324
25	024_add-realtime-message-retention	2026-06-10 07:08:20.324
26	025_create-storage-config-table	2026-06-10 07:08:20.324
27	026_create-custom-oauth-configs	2026-06-10 07:08:20.324
28	027_add-redirect-url-whitelist	2026-06-10 07:08:20.324
29	028_secure-schedules-encryption-functions	2026-06-10 07:08:20.324
30	029_create-smtp-config-and-email-templates	2026-06-10 07:08:20.324
31	030_rename-code-to-token-in-email-templates	2026-06-10 07:08:20.324
32	031_create-deployment-files	2026-06-10 07:08:20.324
33	032_create-custom-migrations	2026-06-10 07:08:20.324
34	033_create-s3-access-keys	2026-06-10 07:08:20.324
35	033_relax-custom-migrations-version-check	2026-06-10 07:08:20.324
36	034_extend-storage-objects-for-s3-protocol	2026-06-10 07:08:20.324
37	035_fix-secrets-deduplicate-and-unique	2026-06-10 07:08:20.324
38	036_storage-third-party-auth-support	2026-06-10 07:08:20.324
39	037_schedules-http-timeout	2026-06-10 07:08:20.324
40	038_create-compute-services	2026-06-10 07:08:20.324
41	039_create-payments-schema	2026-06-10 07:08:20.324
42	040_create-payments-customers-table	2026-06-10 07:08:20.324
43	041_consolidate-retention-jobs	2026-06-10 07:08:20.324
44	042_add-disable-signup-flag	2026-06-10 07:08:20.324
45	043_drop-deprecated-ai-configs-and-usage	2026-06-10 07:08:20.324
46	044_prefer-request-jwt-claims	2026-06-10 07:08:20.324
47	045_project-admin-public-privileges	2026-06-10 07:08:20.324
48	046_transfer-public-object-ownership	2026-06-10 07:08:20.324
49	047_compute-services-add-protocol	2026-06-10 07:08:20.324
50	047_harden-internal-runtime-defaults	2026-06-10 07:08:20.324
51	048_project-admin-database-create-privilege	2026-06-10 07:08:20.324
\.


--
-- Data for Name: secrets; Type: TABLE DATA; Schema: system; Owner: -
--

COPY system.secrets (id, key, value_ciphertext, is_active, last_used_at, expires_at, created_at, updated_at, is_reserved) FROM stdin;
\.


--
-- Name: jobid_seq; Type: SEQUENCE SET; Schema: cron; Owner: -
--



--
-- Name: runid_seq; Type: SEQUENCE SET; Schema: cron; Owner: -
--



--
-- Name: migrations_id_seq; Type: SEQUENCE SET; Schema: system; Owner: -
--

SELECT pg_catalog.setval('system.migrations_id_seq', 51, true);


--
-- Name: user_providers _account_pkey; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.user_providers
    ADD CONSTRAINT _account_pkey PRIMARY KEY (id);


--
-- Name: user_providers _account_provider_provider_account_id_key; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.user_providers
    ADD CONSTRAINT _account_provider_provider_account_id_key UNIQUE (provider, provider_account_id);


--
-- Name: config _auth_configs_pkey; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.config
    ADD CONSTRAINT _auth_configs_pkey PRIMARY KEY (id);


--
-- Name: email_otps _email_otps_email_purpose_key; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.email_otps
    ADD CONSTRAINT _email_otps_email_purpose_key UNIQUE (email, purpose);


--
-- Name: email_otps _email_otps_pkey; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.email_otps
    ADD CONSTRAINT _email_otps_pkey PRIMARY KEY (id);


--
-- Name: oauth_configs _oauth_configs_pkey; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.oauth_configs
    ADD CONSTRAINT _oauth_configs_pkey PRIMARY KEY (id);


--
-- Name: oauth_configs _oauth_configs_provider_key; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.oauth_configs
    ADD CONSTRAINT _oauth_configs_provider_key UNIQUE (provider);


--
-- Name: users _user_email_key; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.users
    ADD CONSTRAINT _user_email_key UNIQUE (email);


--
-- Name: users _user_pkey; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.users
    ADD CONSTRAINT _user_pkey PRIMARY KEY (id);


--
-- Name: custom_oauth_configs custom_oauth_configs_key_key; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.custom_oauth_configs
    ADD CONSTRAINT custom_oauth_configs_key_key UNIQUE (key);


--
-- Name: custom_oauth_configs custom_oauth_configs_pkey; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.custom_oauth_configs
    ADD CONSTRAINT custom_oauth_configs_pkey PRIMARY KEY (id);


--
-- Name: services services_pkey; Type: CONSTRAINT; Schema: compute; Owner: -
--

ALTER TABLE ONLY compute.services
    ADD CONSTRAINT services_pkey PRIMARY KEY (id);


--
-- Name: services services_project_id_name_key; Type: CONSTRAINT; Schema: compute; Owner: -
--

ALTER TABLE ONLY compute.services
    ADD CONSTRAINT services_project_id_name_key UNIQUE (project_id, name);


--
-- Name: runs deployments_pkey; Type: CONSTRAINT; Schema: deployments; Owner: -
--

ALTER TABLE ONLY deployments.runs
    ADD CONSTRAINT deployments_pkey PRIMARY KEY (id);


--
-- Name: runs deployments_provider_deployment_id_key; Type: CONSTRAINT; Schema: deployments; Owner: -
--

ALTER TABLE ONLY deployments.runs
    ADD CONSTRAINT deployments_provider_deployment_id_key UNIQUE (provider_deployment_id);


--
-- Name: files files_deployment_id_file_path_key; Type: CONSTRAINT; Schema: deployments; Owner: -
--

ALTER TABLE ONLY deployments.files
    ADD CONSTRAINT files_deployment_id_file_path_key UNIQUE (deployment_id, file_path);


--
-- Name: files files_pkey; Type: CONSTRAINT; Schema: deployments; Owner: -
--

ALTER TABLE ONLY deployments.files
    ADD CONSTRAINT files_pkey PRIMARY KEY (id);


--
-- Name: config config_pkey; Type: CONSTRAINT; Schema: email; Owner: -
--

ALTER TABLE ONLY email.config
    ADD CONSTRAINT config_pkey PRIMARY KEY (id);


--
-- Name: templates email_templates_type_unique; Type: CONSTRAINT; Schema: email; Owner: -
--

ALTER TABLE ONLY email.templates
    ADD CONSTRAINT email_templates_type_unique UNIQUE (template_type);


--
-- Name: templates templates_pkey; Type: CONSTRAINT; Schema: email; Owner: -
--

ALTER TABLE ONLY email.templates
    ADD CONSTRAINT templates_pkey PRIMARY KEY (id);


--
-- Name: definitions _edge_functions_pkey; Type: CONSTRAINT; Schema: functions; Owner: -
--

ALTER TABLE ONLY functions.definitions
    ADD CONSTRAINT _edge_functions_pkey PRIMARY KEY (id);


--
-- Name: definitions _edge_functions_slug_key; Type: CONSTRAINT; Schema: functions; Owner: -
--

ALTER TABLE ONLY functions.definitions
    ADD CONSTRAINT _edge_functions_slug_key UNIQUE (slug);


--
-- Name: deployments deployments_pkey; Type: CONSTRAINT; Schema: functions; Owner: -
--

ALTER TABLE ONLY functions.deployments
    ADD CONSTRAINT deployments_pkey PRIMARY KEY (id);


--
-- Name: checkout_sessions checkout_sessions_environment_stripe_checkout_session_id_key; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.checkout_sessions
    ADD CONSTRAINT checkout_sessions_environment_stripe_checkout_session_id_key UNIQUE (environment, stripe_checkout_session_id);


--
-- Name: checkout_sessions checkout_sessions_pkey; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.checkout_sessions
    ADD CONSTRAINT checkout_sessions_pkey PRIMARY KEY (id);


--
-- Name: customer_portal_sessions customer_portal_sessions_pkey; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.customer_portal_sessions
    ADD CONSTRAINT customer_portal_sessions_pkey PRIMARY KEY (id);


--
-- Name: customers customers_environment_stripe_customer_id_key; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.customers
    ADD CONSTRAINT customers_environment_stripe_customer_id_key UNIQUE (environment, stripe_customer_id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: payment_history payment_history_pkey; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.payment_history
    ADD CONSTRAINT payment_history_pkey PRIMARY KEY (id);


--
-- Name: prices prices_environment_stripe_price_id_key; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.prices
    ADD CONSTRAINT prices_environment_stripe_price_id_key UNIQUE (environment, stripe_price_id);


--
-- Name: prices prices_pkey; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.prices
    ADD CONSTRAINT prices_pkey PRIMARY KEY (id);


--
-- Name: products products_environment_stripe_product_id_key; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.products
    ADD CONSTRAINT products_environment_stripe_product_id_key UNIQUE (environment, stripe_product_id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: stripe_connections stripe_connections_environment_key; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.stripe_connections
    ADD CONSTRAINT stripe_connections_environment_key UNIQUE (environment);


--
-- Name: stripe_connections stripe_connections_pkey; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.stripe_connections
    ADD CONSTRAINT stripe_connections_pkey PRIMARY KEY (id);


--
-- Name: stripe_customer_mappings stripe_customer_mappings_environment_stripe_customer_id_key; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.stripe_customer_mappings
    ADD CONSTRAINT stripe_customer_mappings_environment_stripe_customer_id_key UNIQUE (environment, stripe_customer_id);


--
-- Name: stripe_customer_mappings stripe_customer_mappings_environment_subject_type_subject_i_key; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.stripe_customer_mappings
    ADD CONSTRAINT stripe_customer_mappings_environment_subject_type_subject_i_key UNIQUE (environment, subject_type, subject_id);


--
-- Name: stripe_customer_mappings stripe_customer_mappings_pkey; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.stripe_customer_mappings
    ADD CONSTRAINT stripe_customer_mappings_pkey PRIMARY KEY (id);


--
-- Name: subscription_items subscription_items_environment_stripe_subscription_item_id_key; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.subscription_items
    ADD CONSTRAINT subscription_items_environment_stripe_subscription_item_id_key UNIQUE (environment, stripe_subscription_item_id);


--
-- Name: subscription_items subscription_items_pkey; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.subscription_items
    ADD CONSTRAINT subscription_items_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_environment_stripe_subscription_id_key; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.subscriptions
    ADD CONSTRAINT subscriptions_environment_stripe_subscription_id_key UNIQUE (environment, stripe_subscription_id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: webhook_events webhook_events_environment_stripe_event_id_key; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.webhook_events
    ADD CONSTRAINT webhook_events_environment_stripe_event_id_key UNIQUE (environment, stripe_event_id);


--
-- Name: webhook_events webhook_events_pkey; Type: CONSTRAINT; Schema: payments; Owner: -
--

ALTER TABLE ONLY payments.webhook_events
    ADD CONSTRAINT webhook_events_pkey PRIMARY KEY (id);


--
-- Name: channels channels_pattern_key; Type: CONSTRAINT; Schema: realtime; Owner: -
--

ALTER TABLE ONLY realtime.channels
    ADD CONSTRAINT channels_pattern_key UNIQUE (pattern);


--
-- Name: channels channels_pkey; Type: CONSTRAINT; Schema: realtime; Owner: -
--

ALTER TABLE ONLY realtime.channels
    ADD CONSTRAINT channels_pkey PRIMARY KEY (id);


--
-- Name: config config_pkey; Type: CONSTRAINT; Schema: realtime; Owner: -
--

ALTER TABLE ONLY realtime.config
    ADD CONSTRAINT config_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: realtime; Owner: -
--

ALTER TABLE ONLY realtime.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: config config_pkey; Type: CONSTRAINT; Schema: schedules; Owner: -
--

ALTER TABLE ONLY schedules.config
    ADD CONSTRAINT config_pkey PRIMARY KEY (id);


--
-- Name: job_logs job_logs_pkey; Type: CONSTRAINT; Schema: schedules; Owner: -
--

ALTER TABLE ONLY schedules.job_logs
    ADD CONSTRAINT job_logs_pkey PRIMARY KEY (id);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: schedules; Owner: -
--

ALTER TABLE ONLY schedules.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);


--
-- Name: buckets _storage_buckets_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.buckets
    ADD CONSTRAINT _storage_buckets_pkey PRIMARY KEY (name);


--
-- Name: objects _storage_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.objects
    ADD CONSTRAINT _storage_pkey PRIMARY KEY (bucket, key);


--
-- Name: config config_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.config
    ADD CONSTRAINT config_pkey PRIMARY KEY (id);


--
-- Name: s3_access_keys s3_access_keys_access_key_id_key; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.s3_access_keys
    ADD CONSTRAINT s3_access_keys_access_key_id_key UNIQUE (access_key_id);


--
-- Name: s3_access_keys s3_access_keys_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.s3_access_keys
    ADD CONSTRAINT s3_access_keys_pkey PRIMARY KEY (id);


--
-- Name: audit_logs _audit_logs_pkey; Type: CONSTRAINT; Schema: system; Owner: -
--

ALTER TABLE ONLY system.audit_logs
    ADD CONSTRAINT _audit_logs_pkey PRIMARY KEY (id);


--
-- Name: mcp_usage _mcp_usage_pkey; Type: CONSTRAINT; Schema: system; Owner: -
--

ALTER TABLE ONLY system.mcp_usage
    ADD CONSTRAINT _mcp_usage_pkey PRIMARY KEY (id);


--
-- Name: secrets _secrets_name_key; Type: CONSTRAINT; Schema: system; Owner: -
--

ALTER TABLE ONLY system.secrets
    ADD CONSTRAINT _secrets_name_key UNIQUE (key);


--
-- Name: secrets _secrets_pkey; Type: CONSTRAINT; Schema: system; Owner: -
--

ALTER TABLE ONLY system.secrets
    ADD CONSTRAINT _secrets_pkey PRIMARY KEY (id);


--
-- Name: custom_migrations custom_migrations_pkey; Type: CONSTRAINT; Schema: system; Owner: -
--

ALTER TABLE ONLY system.custom_migrations
    ADD CONSTRAINT custom_migrations_pkey PRIMARY KEY (version);


--
-- Name: migrations migrations_pkey; Type: CONSTRAINT; Schema: system; Owner: -
--

ALTER TABLE ONLY system.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (id);


--
-- Name: idx_auth_configs_singleton; Type: INDEX; Schema: auth; Owner: -
--

CREATE UNIQUE INDEX idx_auth_configs_singleton ON auth.config USING btree ((1));


--
-- Name: idx_email_otps_email_purpose; Type: INDEX; Schema: auth; Owner: -
--

CREATE INDEX idx_email_otps_email_purpose ON auth.email_otps USING btree (email, purpose);


--
-- Name: idx_email_otps_expires_at; Type: INDEX; Schema: auth; Owner: -
--

CREATE INDEX idx_email_otps_expires_at ON auth.email_otps USING btree (expires_at);


--
-- Name: idx_email_otps_otp_hash; Type: INDEX; Schema: auth; Owner: -
--

CREATE INDEX idx_email_otps_otp_hash ON auth.email_otps USING btree (otp_hash);


--
-- Name: idx_oauth_configs_provider; Type: INDEX; Schema: auth; Owner: -
--

CREATE INDEX idx_oauth_configs_provider ON auth.oauth_configs USING btree (provider);


--
-- Name: idx_compute_services_project; Type: INDEX; Schema: compute; Owner: -
--

CREATE INDEX idx_compute_services_project ON compute.services USING btree (project_id);


--
-- Name: idx_compute_services_status; Type: INDEX; Schema: compute; Owner: -
--

CREATE INDEX idx_compute_services_status ON compute.services USING btree (status);


--
-- Name: idx_deployment_files_deployment_id; Type: INDEX; Schema: deployments; Owner: -
--

CREATE INDEX idx_deployment_files_deployment_id ON deployments.files USING btree (deployment_id);


--
-- Name: idx_deployment_files_uploaded_at; Type: INDEX; Schema: deployments; Owner: -
--

CREATE INDEX idx_deployment_files_uploaded_at ON deployments.files USING btree (deployment_id, uploaded_at);


--
-- Name: idx_deployments_created_at; Type: INDEX; Schema: deployments; Owner: -
--

CREATE INDEX idx_deployments_created_at ON deployments.runs USING btree (created_at DESC);


--
-- Name: idx_deployments_provider; Type: INDEX; Schema: deployments; Owner: -
--

CREATE INDEX idx_deployments_provider ON deployments.runs USING btree (provider);


--
-- Name: idx_deployments_status; Type: INDEX; Schema: deployments; Owner: -
--

CREATE INDEX idx_deployments_status ON deployments.runs USING btree (status);


--
-- Name: email_config_singleton_idx; Type: INDEX; Schema: email; Owner: -
--

CREATE UNIQUE INDEX email_config_singleton_idx ON email.config USING btree ((1));


--
-- Name: idx_function_deployments_created; Type: INDEX; Schema: functions; Owner: -
--

CREATE INDEX idx_function_deployments_created ON functions.deployments USING btree (created_at DESC);


--
-- Name: idx_function_deployments_status; Type: INDEX; Schema: functions; Owner: -
--

CREATE INDEX idx_function_deployments_status ON functions.deployments USING btree (status);


--
-- Name: idx_payments_checkout_sessions_environment_customer; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_checkout_sessions_environment_customer ON payments.checkout_sessions USING btree (environment, stripe_customer_id) WHERE (stripe_customer_id IS NOT NULL);


--
-- Name: idx_payments_checkout_sessions_environment_idempotency; Type: INDEX; Schema: payments; Owner: -
--

CREATE UNIQUE INDEX idx_payments_checkout_sessions_environment_idempotency ON payments.checkout_sessions USING btree (environment, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: idx_payments_checkout_sessions_environment_status; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_checkout_sessions_environment_status ON payments.checkout_sessions USING btree (environment, status);


--
-- Name: idx_payments_checkout_sessions_environment_stripe_session; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_checkout_sessions_environment_stripe_session ON payments.checkout_sessions USING btree (environment, stripe_checkout_session_id) WHERE (stripe_checkout_session_id IS NOT NULL);


--
-- Name: idx_payments_checkout_sessions_environment_subject; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_checkout_sessions_environment_subject ON payments.checkout_sessions USING btree (environment, subject_type, subject_id) WHERE ((subject_type IS NOT NULL) AND (subject_id IS NOT NULL));


--
-- Name: idx_payments_customer_portal_sessions_environment_customer; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_customer_portal_sessions_environment_customer ON payments.customer_portal_sessions USING btree (environment, stripe_customer_id) WHERE (stripe_customer_id IS NOT NULL);


--
-- Name: idx_payments_customer_portal_sessions_environment_status; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_customer_portal_sessions_environment_status ON payments.customer_portal_sessions USING btree (environment, status);


--
-- Name: idx_payments_customer_portal_sessions_environment_subject; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_customer_portal_sessions_environment_subject ON payments.customer_portal_sessions USING btree (environment, subject_type, subject_id);


--
-- Name: idx_payments_customers_environment_created; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_customers_environment_created ON payments.customers USING btree (environment, stripe_created_at DESC);


--
-- Name: idx_payments_customers_environment_deleted; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_customers_environment_deleted ON payments.customers USING btree (environment, deleted);


--
-- Name: idx_payments_customers_environment_email; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_customers_environment_email ON payments.customers USING btree (environment, email) WHERE (email IS NOT NULL);


--
-- Name: idx_payments_payment_history_environment_checkout_session; Type: INDEX; Schema: payments; Owner: -
--

CREATE UNIQUE INDEX idx_payments_payment_history_environment_checkout_session ON payments.payment_history USING btree (environment, stripe_checkout_session_id) WHERE ((stripe_checkout_session_id IS NOT NULL) AND (type <> 'refund'::text));


--
-- Name: idx_payments_payment_history_environment_created; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_payment_history_environment_created ON payments.payment_history USING btree (environment, stripe_created_at DESC);


--
-- Name: idx_payments_payment_history_environment_customer; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_payment_history_environment_customer ON payments.payment_history USING btree (environment, stripe_customer_id) WHERE (stripe_customer_id IS NOT NULL);


--
-- Name: idx_payments_payment_history_environment_invoice; Type: INDEX; Schema: payments; Owner: -
--

CREATE UNIQUE INDEX idx_payments_payment_history_environment_invoice ON payments.payment_history USING btree (environment, stripe_invoice_id) WHERE ((stripe_invoice_id IS NOT NULL) AND (type <> 'refund'::text));


--
-- Name: idx_payments_payment_history_environment_payment_intent; Type: INDEX; Schema: payments; Owner: -
--

CREATE UNIQUE INDEX idx_payments_payment_history_environment_payment_intent ON payments.payment_history USING btree (environment, stripe_payment_intent_id) WHERE ((stripe_payment_intent_id IS NOT NULL) AND (type <> 'refund'::text));


--
-- Name: idx_payments_payment_history_environment_refund; Type: INDEX; Schema: payments; Owner: -
--

CREATE UNIQUE INDEX idx_payments_payment_history_environment_refund ON payments.payment_history USING btree (environment, stripe_refund_id) WHERE (stripe_refund_id IS NOT NULL);


--
-- Name: idx_payments_payment_history_environment_subject; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_payment_history_environment_subject ON payments.payment_history USING btree (environment, subject_type, subject_id);


--
-- Name: idx_payments_prices_environment_lookup_key; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_prices_environment_lookup_key ON payments.prices USING btree (environment, lookup_key) WHERE (lookup_key IS NOT NULL);


--
-- Name: idx_payments_prices_environment_product; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_prices_environment_product ON payments.prices USING btree (environment, stripe_product_id);


--
-- Name: idx_payments_products_environment_active; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_products_environment_active ON payments.products USING btree (environment, active);


--
-- Name: idx_payments_stripe_customer_mappings_environment_subject; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_stripe_customer_mappings_environment_subject ON payments.stripe_customer_mappings USING btree (environment, subject_type, subject_id);


--
-- Name: idx_payments_subscription_items_environment_price; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_subscription_items_environment_price ON payments.subscription_items USING btree (environment, stripe_price_id) WHERE (stripe_price_id IS NOT NULL);


--
-- Name: idx_payments_subscription_items_environment_subscription; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_subscription_items_environment_subscription ON payments.subscription_items USING btree (environment, stripe_subscription_id);


--
-- Name: idx_payments_subscriptions_environment_customer; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_subscriptions_environment_customer ON payments.subscriptions USING btree (environment, stripe_customer_id);


--
-- Name: idx_payments_subscriptions_environment_status; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_subscriptions_environment_status ON payments.subscriptions USING btree (environment, status);


--
-- Name: idx_payments_subscriptions_environment_subject; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_subscriptions_environment_subject ON payments.subscriptions USING btree (environment, subject_type, subject_id);


--
-- Name: idx_payments_webhook_events_environment_object; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_webhook_events_environment_object ON payments.webhook_events USING btree (environment, object_type, object_id) WHERE (object_id IS NOT NULL);


--
-- Name: idx_payments_webhook_events_environment_status; Type: INDEX; Schema: payments; Owner: -
--

CREATE INDEX idx_payments_webhook_events_environment_status ON payments.webhook_events USING btree (environment, processing_status);


--
-- Name: idx_realtime_channels_enabled; Type: INDEX; Schema: realtime; Owner: -
--

CREATE INDEX idx_realtime_channels_enabled ON realtime.channels USING btree (enabled);


--
-- Name: idx_realtime_channels_pattern; Type: INDEX; Schema: realtime; Owner: -
--

CREATE INDEX idx_realtime_channels_pattern ON realtime.channels USING btree (pattern);


--
-- Name: idx_realtime_config_singleton; Type: INDEX; Schema: realtime; Owner: -
--

CREATE UNIQUE INDEX idx_realtime_config_singleton ON realtime.config USING btree ((1));


--
-- Name: idx_realtime_messages_channel_id; Type: INDEX; Schema: realtime; Owner: -
--

CREATE INDEX idx_realtime_messages_channel_id ON realtime.messages USING btree (channel_id);


--
-- Name: idx_realtime_messages_channel_name; Type: INDEX; Schema: realtime; Owner: -
--

CREATE INDEX idx_realtime_messages_channel_name ON realtime.messages USING btree (channel_name);


--
-- Name: idx_realtime_messages_created_at; Type: INDEX; Schema: realtime; Owner: -
--

CREATE INDEX idx_realtime_messages_created_at ON realtime.messages USING btree (created_at DESC);


--
-- Name: idx_realtime_messages_event_name; Type: INDEX; Schema: realtime; Owner: -
--

CREATE INDEX idx_realtime_messages_event_name ON realtime.messages USING btree (event_name);


--
-- Name: idx_realtime_messages_sender; Type: INDEX; Schema: realtime; Owner: -
--

CREATE INDEX idx_realtime_messages_sender ON realtime.messages USING btree (sender_type, sender_id);


--
-- Name: idx_job_logs_executed_at; Type: INDEX; Schema: schedules; Owner: -
--

CREATE INDEX idx_job_logs_executed_at ON schedules.job_logs USING btree (executed_at DESC);


--
-- Name: idx_job_logs_job_id; Type: INDEX; Schema: schedules; Owner: -
--

CREATE INDEX idx_job_logs_job_id ON schedules.job_logs USING btree (job_id);


--
-- Name: idx_jobs_cron_job_id; Type: INDEX; Schema: schedules; Owner: -
--

CREATE INDEX idx_jobs_cron_job_id ON schedules.jobs USING btree (cron_job_id);


--
-- Name: idx_jobs_is_active; Type: INDEX; Schema: schedules; Owner: -
--

CREATE INDEX idx_jobs_is_active ON schedules.jobs USING btree (is_active);


--
-- Name: idx_schedules_config_singleton; Type: INDEX; Schema: schedules; Owner: -
--

CREATE UNIQUE INDEX idx_schedules_config_singleton ON schedules.config USING btree ((1));


--
-- Name: idx_s3_access_keys_last_used_at; Type: INDEX; Schema: storage; Owner: -
--

CREATE INDEX idx_s3_access_keys_last_used_at ON storage.s3_access_keys USING btree (last_used_at);


--
-- Name: idx_storage_config_singleton; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX idx_storage_config_singleton ON storage.config USING btree ((1));


--
-- Name: idx_storage_objects_s3_access_key_id; Type: INDEX; Schema: storage; Owner: -
--

CREATE INDEX idx_storage_objects_s3_access_key_id ON storage.objects USING btree (s3_access_key_id) WHERE (s3_access_key_id IS NOT NULL);


--
-- Name: idx_storage_uploaded_by; Type: INDEX; Schema: storage; Owner: -
--

CREATE INDEX idx_storage_uploaded_by ON storage.objects USING btree (uploaded_by);


--
-- Name: idx_audit_logs_actor; Type: INDEX; Schema: system; Owner: -
--

CREATE INDEX idx_audit_logs_actor ON system.audit_logs USING btree (actor);


--
-- Name: idx_audit_logs_created_at; Type: INDEX; Schema: system; Owner: -
--

CREATE INDEX idx_audit_logs_created_at ON system.audit_logs USING btree (created_at DESC);


--
-- Name: idx_audit_logs_module; Type: INDEX; Schema: system; Owner: -
--

CREATE INDEX idx_audit_logs_module ON system.audit_logs USING btree (module);


--
-- Name: idx_mcp_usage_created_at; Type: INDEX; Schema: system; Owner: -
--

CREATE INDEX idx_mcp_usage_created_at ON system.mcp_usage USING btree (created_at DESC);


--
-- Name: idx_secrets_name; Type: INDEX; Schema: system; Owner: -
--

CREATE INDEX idx_secrets_name ON system.secrets USING btree (key);


--
-- Name: config update_config_updated_at; Type: TRIGGER; Schema: auth; Owner: -
--

CREATE TRIGGER update_config_updated_at BEFORE UPDATE ON auth.config FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: custom_oauth_configs update_custom_oauth_configs_updated_at; Type: TRIGGER; Schema: auth; Owner: -
--

CREATE TRIGGER update_custom_oauth_configs_updated_at BEFORE UPDATE ON auth.custom_oauth_configs FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: email_otps update_email_otps_updated_at; Type: TRIGGER; Schema: auth; Owner: -
--

CREATE TRIGGER update_email_otps_updated_at BEFORE UPDATE ON auth.email_otps FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: oauth_configs update_oauth_configs_updated_at; Type: TRIGGER; Schema: auth; Owner: -
--

CREATE TRIGGER update_oauth_configs_updated_at BEFORE UPDATE ON auth.oauth_configs FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: services update_compute_services_updated_at; Type: TRIGGER; Schema: compute; Owner: -
--

CREATE TRIGGER update_compute_services_updated_at BEFORE UPDATE ON compute.services FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: files update_files_updated_at; Type: TRIGGER; Schema: deployments; Owner: -
--

CREATE TRIGGER update_files_updated_at BEFORE UPDATE ON deployments.files FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: runs update_runs_updated_at; Type: TRIGGER; Schema: deployments; Owner: -
--

CREATE TRIGGER update_runs_updated_at BEFORE UPDATE ON deployments.runs FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: definitions update_definitions_updated_at; Type: TRIGGER; Schema: functions; Owner: -
--

CREATE TRIGGER update_definitions_updated_at BEFORE UPDATE ON functions.definitions FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: checkout_sessions trg_payments_checkout_sessions_updated_at; Type: TRIGGER; Schema: payments; Owner: -
--

CREATE TRIGGER trg_payments_checkout_sessions_updated_at BEFORE UPDATE ON payments.checkout_sessions FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: customer_portal_sessions trg_payments_customer_portal_sessions_updated_at; Type: TRIGGER; Schema: payments; Owner: -
--

CREATE TRIGGER trg_payments_customer_portal_sessions_updated_at BEFORE UPDATE ON payments.customer_portal_sessions FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: customers trg_payments_customers_updated_at; Type: TRIGGER; Schema: payments; Owner: -
--

CREATE TRIGGER trg_payments_customers_updated_at BEFORE UPDATE ON payments.customers FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: payment_history trg_payments_payment_history_updated_at; Type: TRIGGER; Schema: payments; Owner: -
--

CREATE TRIGGER trg_payments_payment_history_updated_at BEFORE UPDATE ON payments.payment_history FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: prices trg_payments_prices_updated_at; Type: TRIGGER; Schema: payments; Owner: -
--

CREATE TRIGGER trg_payments_prices_updated_at BEFORE UPDATE ON payments.prices FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: products trg_payments_products_updated_at; Type: TRIGGER; Schema: payments; Owner: -
--

CREATE TRIGGER trg_payments_products_updated_at BEFORE UPDATE ON payments.products FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: stripe_connections trg_payments_stripe_connections_updated_at; Type: TRIGGER; Schema: payments; Owner: -
--

CREATE TRIGGER trg_payments_stripe_connections_updated_at BEFORE UPDATE ON payments.stripe_connections FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: stripe_customer_mappings trg_payments_stripe_customer_mappings_updated_at; Type: TRIGGER; Schema: payments; Owner: -
--

CREATE TRIGGER trg_payments_stripe_customer_mappings_updated_at BEFORE UPDATE ON payments.stripe_customer_mappings FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: subscription_items trg_payments_subscription_items_updated_at; Type: TRIGGER; Schema: payments; Owner: -
--

CREATE TRIGGER trg_payments_subscription_items_updated_at BEFORE UPDATE ON payments.subscription_items FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: subscriptions trg_payments_subscriptions_updated_at; Type: TRIGGER; Schema: payments; Owner: -
--

CREATE TRIGGER trg_payments_subscriptions_updated_at BEFORE UPDATE ON payments.subscriptions FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: webhook_events trg_payments_webhook_events_updated_at; Type: TRIGGER; Schema: payments; Owner: -
--

CREATE TRIGGER trg_payments_webhook_events_updated_at BEFORE UPDATE ON payments.webhook_events FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: messages trg_message_notify; Type: TRIGGER; Schema: realtime; Owner: -
--

CREATE TRIGGER trg_message_notify AFTER INSERT ON realtime.messages FOR EACH ROW EXECUTE FUNCTION realtime.notify_on_message_insert();


--
-- Name: channels update_channels_updated_at; Type: TRIGGER; Schema: realtime; Owner: -
--

CREATE TRIGGER update_channels_updated_at BEFORE UPDATE ON realtime.channels FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: config update_realtime_config_updated_at; Type: TRIGGER; Schema: realtime; Owner: -
--

CREATE TRIGGER update_realtime_config_updated_at BEFORE UPDATE ON realtime.config FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: jobs trg_jobs_updated_at; Type: TRIGGER; Schema: schedules; Owner: -
--

CREATE TRIGGER trg_jobs_updated_at BEFORE UPDATE ON schedules.jobs FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: config update_schedules_config_updated_at; Type: TRIGGER; Schema: schedules; Owner: -
--

CREATE TRIGGER update_schedules_config_updated_at BEFORE UPDATE ON schedules.config FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: config update_storage_config_updated_at; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER update_storage_config_updated_at BEFORE UPDATE ON storage.config FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: audit_logs update_audit_logs_updated_at; Type: TRIGGER; Schema: system; Owner: -
--

CREATE TRIGGER update_audit_logs_updated_at BEFORE UPDATE ON system.audit_logs FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: secrets update_secrets_updated_at; Type: TRIGGER; Schema: system; Owner: -
--

CREATE TRIGGER update_secrets_updated_at BEFORE UPDATE ON system.secrets FOR EACH ROW EXECUTE FUNCTION system.update_updated_at();


--
-- Name: user_providers _account_user_id_fkey; Type: FK CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.user_providers
    ADD CONSTRAINT _account_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: custom_oauth_configs custom_oauth_configs_secret_id_fkey; Type: FK CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.custom_oauth_configs
    ADD CONSTRAINT custom_oauth_configs_secret_id_fkey FOREIGN KEY (secret_id) REFERENCES system.secrets(id) ON DELETE RESTRICT;


--
-- Name: oauth_configs oauth_configs_secret_id_fkey; Type: FK CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.oauth_configs
    ADD CONSTRAINT oauth_configs_secret_id_fkey FOREIGN KEY (secret_id) REFERENCES system.secrets(id) ON DELETE RESTRICT;


--
-- Name: user_providers user_providers_user_id_fkey; Type: FK CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.user_providers
    ADD CONSTRAINT user_providers_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: files files_deployment_id_fkey; Type: FK CONSTRAINT; Schema: deployments; Owner: -
--

ALTER TABLE ONLY deployments.files
    ADD CONSTRAINT files_deployment_id_fkey FOREIGN KEY (deployment_id) REFERENCES deployments.runs(id) ON DELETE CASCADE;


--
-- Name: messages messages_channel_id_fkey; Type: FK CONSTRAINT; Schema: realtime; Owner: -
--

ALTER TABLE ONLY realtime.messages
    ADD CONSTRAINT messages_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES realtime.channels(id) ON DELETE SET NULL;


--
-- Name: job_logs job_logs_job_id_fkey; Type: FK CONSTRAINT; Schema: schedules; Owner: -
--

ALTER TABLE ONLY schedules.job_logs
    ADD CONSTRAINT job_logs_job_id_fkey FOREIGN KEY (job_id) REFERENCES schedules.jobs(id) ON DELETE CASCADE;


--
-- Name: objects objects_bucket_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.objects
    ADD CONSTRAINT objects_bucket_fkey FOREIGN KEY (bucket) REFERENCES storage.buckets(name) ON DELETE CASCADE;


--
-- Name: SCHEMA auth; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA auth TO PUBLIC;
GRANT USAGE ON SCHEMA auth TO project_admin;


--
-- Name: SCHEMA compute; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA compute TO project_admin;


--
-- Name: SCHEMA deployments; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA deployments TO project_admin;


--
-- Name: SCHEMA email; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA email TO project_admin;


--
-- Name: SCHEMA functions; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA functions TO project_admin;


--
-- Name: SCHEMA payments; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA payments TO anon;
GRANT USAGE ON SCHEMA payments TO authenticated;
GRANT USAGE ON SCHEMA payments TO project_admin;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT ALL ON SCHEMA public TO project_admin;


--
-- Name: SCHEMA realtime; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA realtime TO authenticated;
GRANT USAGE ON SCHEMA realtime TO anon;
GRANT USAGE ON SCHEMA realtime TO project_admin;


--
-- Name: SCHEMA schedules; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA schedules TO project_admin;


--
-- Name: SCHEMA storage; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA storage TO authenticated;
GRANT USAGE ON SCHEMA storage TO project_admin;


--
-- Name: SCHEMA system; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA system TO project_admin;


--
-- Name: FUNCTION jwt(); Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON FUNCTION auth.jwt() TO authenticated;
GRANT ALL ON FUNCTION auth.jwt() TO anon;


--
-- Name: FUNCTION armor(bytea); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.armor(bytea) TO project_admin;


--
-- Name: FUNCTION armor(bytea, text[], text[]); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.armor(bytea, text[], text[]) TO project_admin;


--
-- Name: FUNCTION bytea_to_text(data bytea); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION crypt(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.crypt(text, text) TO project_admin;


--
-- Name: FUNCTION dearmor(text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.dearmor(text) TO project_admin;


--
-- Name: FUNCTION decrypt(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.decrypt(bytea, bytea, text) TO project_admin;


--
-- Name: FUNCTION decrypt_iv(bytea, bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.decrypt_iv(bytea, bytea, bytea, text) TO project_admin;


--
-- Name: FUNCTION digest(bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.digest(bytea, text) TO project_admin;


--
-- Name: FUNCTION digest(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.digest(text, text) TO project_admin;


--
-- Name: FUNCTION encrypt(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.encrypt(bytea, bytea, text) TO project_admin;


--
-- Name: FUNCTION encrypt_iv(bytea, bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.encrypt_iv(bytea, bytea, bytea, text) TO project_admin;


--
-- Name: FUNCTION gen_random_bytes(integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gen_random_bytes(integer) TO project_admin;


--
-- Name: FUNCTION gen_random_uuid(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gen_random_uuid() TO project_admin;


--
-- Name: FUNCTION gen_salt(text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gen_salt(text) TO project_admin;


--
-- Name: FUNCTION gen_salt(text, integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.gen_salt(text, integer) TO project_admin;


--
-- Name: FUNCTION hmac(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.hmac(bytea, bytea, text) TO project_admin;


--
-- Name: FUNCTION hmac(text, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.hmac(text, text, text) TO project_admin;


--
-- Name: FUNCTION http(request public.http_request); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_delete(uri character varying); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_delete(uri character varying, content character varying, content_type character varying); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_get(uri character varying); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_get(uri character varying, data jsonb); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_head(uri character varying); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_header(field character varying, value character varying); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_headers(VARIADIC args text[]); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_list_curlopt(); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_patch(uri character varying, content character varying, content_type character varying); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_post(uri character varying, data jsonb); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_post(uri character varying, content character varying, content_type character varying); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_put(uri character varying, content character varying, content_type character varying); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_reset_curlopt(); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION http_set_curlopt(curlopt character varying, value character varying); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION pgp_armor_headers(text, OUT key text, OUT value text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_armor_headers(text, OUT key text, OUT value text) TO project_admin;


--
-- Name: FUNCTION pgp_key_id(bytea); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_key_id(bytea) TO project_admin;


--
-- Name: FUNCTION pgp_pub_decrypt(bytea, bytea); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_decrypt(bytea, bytea) TO project_admin;


--
-- Name: FUNCTION pgp_pub_decrypt(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_decrypt(bytea, bytea, text) TO project_admin;


--
-- Name: FUNCTION pgp_pub_decrypt(bytea, bytea, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_decrypt(bytea, bytea, text, text) TO project_admin;


--
-- Name: FUNCTION pgp_pub_decrypt_bytea(bytea, bytea); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_decrypt_bytea(bytea, bytea) TO project_admin;


--
-- Name: FUNCTION pgp_pub_decrypt_bytea(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_decrypt_bytea(bytea, bytea, text) TO project_admin;


--
-- Name: FUNCTION pgp_pub_decrypt_bytea(bytea, bytea, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_decrypt_bytea(bytea, bytea, text, text) TO project_admin;


--
-- Name: FUNCTION pgp_pub_encrypt(text, bytea); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_encrypt(text, bytea) TO project_admin;


--
-- Name: FUNCTION pgp_pub_encrypt(text, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_encrypt(text, bytea, text) TO project_admin;


--
-- Name: FUNCTION pgp_pub_encrypt_bytea(bytea, bytea); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_encrypt_bytea(bytea, bytea) TO project_admin;


--
-- Name: FUNCTION pgp_pub_encrypt_bytea(bytea, bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_pub_encrypt_bytea(bytea, bytea, text) TO project_admin;


--
-- Name: FUNCTION pgp_sym_decrypt(bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_decrypt(bytea, text) TO project_admin;


--
-- Name: FUNCTION pgp_sym_decrypt(bytea, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_decrypt(bytea, text, text) TO project_admin;


--
-- Name: FUNCTION pgp_sym_decrypt_bytea(bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_decrypt_bytea(bytea, text) TO project_admin;


--
-- Name: FUNCTION pgp_sym_decrypt_bytea(bytea, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_decrypt_bytea(bytea, text, text) TO project_admin;


--
-- Name: FUNCTION pgp_sym_encrypt(text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_encrypt(text, text) TO project_admin;


--
-- Name: FUNCTION pgp_sym_encrypt(text, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_encrypt(text, text, text) TO project_admin;


--
-- Name: FUNCTION pgp_sym_encrypt_bytea(bytea, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_encrypt_bytea(bytea, text) TO project_admin;


--
-- Name: FUNCTION pgp_sym_encrypt_bytea(bytea, text, text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pgp_sym_encrypt_bytea(bytea, text, text) TO project_admin;


--
-- Name: FUNCTION text_to_bytea(data text); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION urlencode(string bytea); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION urlencode(data jsonb); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION urlencode(string character varying); Type: ACL; Schema: public; Owner: -
--



--
-- Name: FUNCTION channel_name(); Type: ACL; Schema: realtime; Owner: -
--

GRANT ALL ON FUNCTION realtime.channel_name() TO authenticated;
GRANT ALL ON FUNCTION realtime.channel_name() TO anon;
GRANT ALL ON FUNCTION realtime.channel_name() TO project_admin;


--
-- Name: FUNCTION cleanup_messages(p_batch_size integer); Type: ACL; Schema: realtime; Owner: -
--

REVOKE ALL ON FUNCTION realtime.cleanup_messages(p_batch_size integer) FROM PUBLIC;


--
-- Name: FUNCTION publish(p_channel_name text, p_event_name text, p_payload jsonb); Type: ACL; Schema: realtime; Owner: -
--

REVOKE ALL ON FUNCTION realtime.publish(p_channel_name text, p_event_name text, p_payload jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION realtime.publish(p_channel_name text, p_event_name text, p_payload jsonb) TO project_admin;


--
-- Name: FUNCTION cleanup_job_logs(p_batch_size integer); Type: ACL; Schema: schedules; Owner: -
--

REVOKE ALL ON FUNCTION schedules.cleanup_job_logs(p_batch_size integer) FROM PUBLIC;


--
-- Name: FUNCTION decrypt_headers(p_encrypted_headers text); Type: ACL; Schema: schedules; Owner: -
--

REVOKE ALL ON FUNCTION schedules.decrypt_headers(p_encrypted_headers text) FROM PUBLIC;


--
-- Name: FUNCTION encrypt_headers(p_headers jsonb); Type: ACL; Schema: schedules; Owner: -
--

REVOKE ALL ON FUNCTION schedules.encrypt_headers(p_headers jsonb) FROM PUBLIC;


--
-- Name: FUNCTION reload_postgrest_schema(); Type: ACL; Schema: system; Owner: -
--

GRANT ALL ON FUNCTION system.reload_postgrest_schema() TO project_admin;


--
-- Name: FUNCTION update_updated_at(); Type: ACL; Schema: system; Owner: -
--

GRANT ALL ON FUNCTION system.update_updated_at() TO project_admin;


--
-- Name: TABLE config; Type: ACL; Schema: auth; Owner: -
--

GRANT SELECT ON TABLE auth.config TO project_admin;


--
-- Name: TABLE custom_oauth_configs; Type: ACL; Schema: auth; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE auth.custom_oauth_configs TO project_admin;


--
-- Name: TABLE email_otps; Type: ACL; Schema: auth; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE auth.email_otps TO project_admin;


--
-- Name: TABLE oauth_configs; Type: ACL; Schema: auth; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE auth.oauth_configs TO project_admin;


--
-- Name: TABLE user_providers; Type: ACL; Schema: auth; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE auth.user_providers TO project_admin;


--
-- Name: TABLE users; Type: ACL; Schema: auth; Owner: -
--

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,UPDATE ON TABLE auth.users TO project_admin;


--
-- Name: TABLE services; Type: ACL; Schema: compute; Owner: -
--

GRANT SELECT ON TABLE compute.services TO project_admin;


--
-- Name: TABLE files; Type: ACL; Schema: deployments; Owner: -
--

GRANT SELECT ON TABLE deployments.files TO project_admin;


--
-- Name: TABLE runs; Type: ACL; Schema: deployments; Owner: -
--

GRANT SELECT ON TABLE deployments.runs TO project_admin;


--
-- Name: TABLE config; Type: ACL; Schema: email; Owner: -
--

GRANT SELECT ON TABLE email.config TO project_admin;


--
-- Name: TABLE templates; Type: ACL; Schema: email; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE email.templates TO project_admin;


--
-- Name: TABLE definitions; Type: ACL; Schema: functions; Owner: -
--

GRANT SELECT ON TABLE functions.definitions TO project_admin;


--
-- Name: TABLE deployments; Type: ACL; Schema: functions; Owner: -
--

GRANT SELECT ON TABLE functions.deployments TO project_admin;


--
-- Name: TABLE checkout_sessions; Type: ACL; Schema: payments; Owner: -
--

GRANT SELECT,INSERT ON TABLE payments.checkout_sessions TO anon;
GRANT SELECT,INSERT ON TABLE payments.checkout_sessions TO authenticated;
GRANT SELECT,INSERT,TRIGGER ON TABLE payments.checkout_sessions TO project_admin;


--
-- Name: TABLE customer_portal_sessions; Type: ACL; Schema: payments; Owner: -
--

GRANT SELECT,INSERT ON TABLE payments.customer_portal_sessions TO anon;
GRANT SELECT,INSERT ON TABLE payments.customer_portal_sessions TO authenticated;
GRANT SELECT,INSERT,TRIGGER ON TABLE payments.customer_portal_sessions TO project_admin;


--
-- Name: TABLE customers; Type: ACL; Schema: payments; Owner: -
--

GRANT SELECT,TRIGGER ON TABLE payments.customers TO project_admin;


--
-- Name: TABLE payment_history; Type: ACL; Schema: payments; Owner: -
--

GRANT SELECT,TRIGGER ON TABLE payments.payment_history TO project_admin;


--
-- Name: TABLE prices; Type: ACL; Schema: payments; Owner: -
--

GRANT SELECT ON TABLE payments.prices TO project_admin;


--
-- Name: TABLE products; Type: ACL; Schema: payments; Owner: -
--

GRANT SELECT ON TABLE payments.products TO project_admin;


--
-- Name: TABLE stripe_connections; Type: ACL; Schema: payments; Owner: -
--

GRANT SELECT ON TABLE payments.stripe_connections TO project_admin;


--
-- Name: TABLE stripe_customer_mappings; Type: ACL; Schema: payments; Owner: -
--

GRANT SELECT ON TABLE payments.stripe_customer_mappings TO project_admin;


--
-- Name: TABLE subscription_items; Type: ACL; Schema: payments; Owner: -
--

GRANT SELECT ON TABLE payments.subscription_items TO project_admin;


--
-- Name: TABLE subscriptions; Type: ACL; Schema: payments; Owner: -
--

GRANT SELECT,TRIGGER ON TABLE payments.subscriptions TO project_admin;


--
-- Name: TABLE webhook_events; Type: ACL; Schema: payments; Owner: -
--

GRANT SELECT ON TABLE payments.webhook_events TO project_admin;


--
-- Name: TABLE channels; Type: ACL; Schema: realtime; Owner: -
--

GRANT SELECT ON TABLE realtime.channels TO authenticated;
GRANT SELECT ON TABLE realtime.channels TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE realtime.channels TO project_admin;


--
-- Name: TABLE config; Type: ACL; Schema: realtime; Owner: -
--

GRANT SELECT ON TABLE realtime.config TO project_admin;


--
-- Name: TABLE messages; Type: ACL; Schema: realtime; Owner: -
--

GRANT INSERT ON TABLE realtime.messages TO authenticated;
GRANT INSERT ON TABLE realtime.messages TO anon;
GRANT SELECT,INSERT ON TABLE realtime.messages TO project_admin;


--
-- Name: TABLE config; Type: ACL; Schema: schedules; Owner: -
--

GRANT SELECT ON TABLE schedules.config TO project_admin;


--
-- Name: TABLE job_logs; Type: ACL; Schema: schedules; Owner: -
--

GRANT SELECT ON TABLE schedules.job_logs TO project_admin;


--
-- Name: TABLE jobs; Type: ACL; Schema: schedules; Owner: -
--

GRANT SELECT ON TABLE schedules.jobs TO project_admin;


--
-- Name: TABLE buckets; Type: ACL; Schema: storage; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE storage.buckets TO authenticated;
GRANT SELECT ON TABLE storage.buckets TO project_admin;


--
-- Name: TABLE config; Type: ACL; Schema: storage; Owner: -
--

GRANT SELECT ON TABLE storage.config TO project_admin;


--
-- Name: TABLE objects; Type: ACL; Schema: storage; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE storage.objects TO authenticated;
GRANT SELECT ON TABLE storage.objects TO project_admin;


--
-- Name: COLUMN objects.bucket; Type: ACL; Schema: storage; Owner: -
--

GRANT REFERENCES(bucket) ON TABLE storage.objects TO project_admin;


--
-- Name: COLUMN objects.key; Type: ACL; Schema: storage; Owner: -
--

GRANT REFERENCES(key) ON TABLE storage.objects TO project_admin;


--
-- Name: TABLE s3_access_keys; Type: ACL; Schema: storage; Owner: -
--

GRANT SELECT ON TABLE storage.s3_access_keys TO project_admin;


--
-- Name: TABLE audit_logs; Type: ACL; Schema: system; Owner: -
--

GRANT SELECT ON TABLE system.audit_logs TO project_admin;


--
-- Name: TABLE custom_migrations; Type: ACL; Schema: system; Owner: -
--

GRANT SELECT ON TABLE system.custom_migrations TO project_admin;


--
-- Name: TABLE mcp_usage; Type: ACL; Schema: system; Owner: -
--

GRANT SELECT ON TABLE system.mcp_usage TO project_admin;


--
-- Name: TABLE migrations; Type: ACL; Schema: system; Owner: -
--

GRANT SELECT ON TABLE system.migrations TO project_admin;


--
-- Name: TABLE secrets; Type: ACL; Schema: system; Owner: -
--

GRANT SELECT ON TABLE system.secrets TO project_admin;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO project_admin;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE project_admin IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE project_admin IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES TO authenticated;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO project_admin;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO project_admin;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE project_admin IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE project_admin IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO authenticated;


--
-- PostgreSQL database dump complete
--

\unrestrict 7wCrLgx0qj4VxUTHtUZZDQCiaeLRikeYlNnX6hYJfewue1HO7Hmz5ySOKtLHyF4

