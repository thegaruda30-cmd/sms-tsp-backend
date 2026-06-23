-- ============================================================
-- Request Management System - Supabase PostgreSQL Schema
-- Officer → Admin → TSP → Admin → Officer
-- ============================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- TABLE: users
-- ============================================================
CREATE TABLE IF NOT EXISTS public.users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    full_name       TEXT NOT NULL,
    email           TEXT NOT NULL UNIQUE,
    mobile_number   TEXT,
    role            TEXT NOT NULL CHECK (role IN ('Officer', 'Admin', 'TSP')),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    last_login      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_role     ON public.users (role);
CREATE INDEX IF NOT EXISTS idx_users_email    ON public.users (email);
CREATE INDEX IF NOT EXISTS idx_users_active   ON public.users (is_active);

-- ============================================================
-- TABLE: requests
-- ============================================================
CREATE TABLE IF NOT EXISTS public.requests (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    officer_id          UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    request_title       TEXT NOT NULL,
    request_description TEXT,
    request_data        JSONB,
    status              TEXT NOT NULL DEFAULT 'Submitted'
                            CHECK (status IN (
                                'Submitted',
                                'Sent_To_Admin',
                                'Forwarded_To_TSP',
                                'Response_Received_From_TSP',
                                'Forwarded_To_Officer',
                                'Completed'
                            )),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_requests_officer_id  ON public.requests (officer_id);
CREATE INDEX IF NOT EXISTS idx_requests_status      ON public.requests (status);
CREATE INDEX IF NOT EXISTS idx_requests_created_at  ON public.requests (created_at DESC);

-- ============================================================
-- TABLE: admin_forward_requests
-- Purpose: Admin forwards a request to a TSP
-- ============================================================
CREATE TABLE IF NOT EXISTS public.admin_forward_requests (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    request_id          UUID NOT NULL REFERENCES public.requests(id) ON DELETE RESTRICT,
    admin_id            UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    tsp_id              UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    forwarded_message   TEXT,
    forwarded_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status              TEXT NOT NULL DEFAULT 'Forwarded'
                            CHECK (status IN ('Forwarded', 'Acknowledged', 'Responded'))
);

CREATE INDEX IF NOT EXISTS idx_afr_request_id   ON public.admin_forward_requests (request_id);
CREATE INDEX IF NOT EXISTS idx_afr_admin_id     ON public.admin_forward_requests (admin_id);
CREATE INDEX IF NOT EXISTS idx_afr_tsp_id       ON public.admin_forward_requests (tsp_id);
CREATE INDEX IF NOT EXISTS idx_afr_forwarded_at ON public.admin_forward_requests (forwarded_at DESC);

-- ============================================================
-- TABLE: tsp_responses
-- Purpose: TSP submits a response to a forwarded request
-- ============================================================
CREATE TABLE IF NOT EXISTS public.tsp_responses (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    request_id       UUID NOT NULL REFERENCES public.requests(id) ON DELETE RESTRICT,
    tsp_id           UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    response_message TEXT,
    response_data    JSONB,
    response_date    DATE NOT NULL DEFAULT CURRENT_DATE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tr_request_id ON public.tsp_responses (request_id);
CREATE INDEX IF NOT EXISTS idx_tr_tsp_id     ON public.tsp_responses (tsp_id);
CREATE INDEX IF NOT EXISTS idx_tr_created_at ON public.tsp_responses (created_at DESC);

-- ============================================================
-- TABLE: admin_forward_responses
-- Purpose: Admin forwards TSP response back to Officer
-- ============================================================
CREATE TABLE IF NOT EXISTS public.admin_forward_responses (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    request_id          UUID NOT NULL REFERENCES public.requests(id) ON DELETE RESTRICT,
    response_id         UUID NOT NULL REFERENCES public.tsp_responses(id) ON DELETE RESTRICT,
    admin_id            UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    officer_id          UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    forwarded_response  TEXT,
    forwarded_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status              TEXT NOT NULL DEFAULT 'Forwarded'
                            CHECK (status IN ('Forwarded', 'Delivered', 'Read'))
);

CREATE INDEX IF NOT EXISTS idx_afresp_request_id    ON public.admin_forward_responses (request_id);
CREATE INDEX IF NOT EXISTS idx_afresp_response_id   ON public.admin_forward_responses (response_id);
CREATE INDEX IF NOT EXISTS idx_afresp_admin_id      ON public.admin_forward_responses (admin_id);
CREATE INDEX IF NOT EXISTS idx_afresp_officer_id    ON public.admin_forward_responses (officer_id);
CREATE INDEX IF NOT EXISTS idx_afresp_forwarded_at  ON public.admin_forward_responses (forwarded_at DESC);

-- ============================================================
-- TABLE: officer_received_responses
-- Purpose: Officer receives and reads the final response
-- ============================================================
CREATE TABLE IF NOT EXISTS public.officer_received_responses (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    request_id        UUID NOT NULL REFERENCES public.requests(id) ON DELETE RESTRICT,
    officer_id        UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    response_id       UUID NOT NULL REFERENCES public.tsp_responses(id) ON DELETE RESTRICT,
    received_response TEXT,
    received_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_read           BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_orr_request_id   ON public.officer_received_responses (request_id);
CREATE INDEX IF NOT EXISTS idx_orr_officer_id   ON public.officer_received_responses (officer_id);
CREATE INDEX IF NOT EXISTS idx_orr_response_id  ON public.officer_received_responses (response_id);
CREATE INDEX IF NOT EXISTS idx_orr_is_read      ON public.officer_received_responses (is_read);
CREATE INDEX IF NOT EXISTS idx_orr_received_at  ON public.officer_received_responses (received_at DESC);

-- ============================================================
-- TABLE: request_status_logs
-- Purpose: Full audit trail for every workflow step
-- ============================================================
CREATE TABLE IF NOT EXISTS public.request_status_logs (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    request_id      UUID NOT NULL REFERENCES public.requests(id) ON DELETE RESTRICT,
    action_by       UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    action_type     TEXT NOT NULL,
    action_details  TEXT,
    old_status      TEXT,
    new_status      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rsl_request_id   ON public.request_status_logs (request_id);
CREATE INDEX IF NOT EXISTS idx_rsl_action_by    ON public.request_status_logs (action_by);
CREATE INDEX IF NOT EXISTS idx_rsl_created_at   ON public.request_status_logs (created_at DESC);

-- ============================================================
-- TABLE: login_details
-- Purpose: Dedicated log of all admin/user login events
-- ============================================================
CREATE TABLE IF NOT EXISTS public.login_details (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID REFERENCES public.users(id) ON DELETE SET NULL,
    username        TEXT NOT NULL,
    role            TEXT NOT NULL,
    ip_address      TEXT,
    user_agent      TEXT,
    login_time      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ld_user_id       ON public.login_details (user_id);
CREATE INDEX IF NOT EXISTS idx_ld_login_time    ON public.login_details (login_time DESC);

-- ============================================================
-- TRIGGER: auto-update updated_at on users
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_users_updated_at ON public.users;
CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_requests_updated_at ON public.requests;
CREATE TRIGGER trg_requests_updated_at
    BEFORE UPDATE ON public.requests
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- TABLE: tsp_settings
-- Purpose: Predefined SMS template formats and forwarding numbers for each TSP
-- ============================================================
CREATE TABLE IF NOT EXISTS public.tsp_settings (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tsp_name        TEXT NOT NULL UNIQUE,
    forward_number  TEXT NOT NULL,
    sms_template    TEXT NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- ROW LEVEL SECURITY (RLS) - Enable for all tables
-- ============================================================
ALTER TABLE public.users                     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.requests                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_forward_requests    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tsp_responses             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_forward_responses   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.officer_received_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.request_status_logs       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.login_details             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tsp_settings              ENABLE ROW LEVEL SECURITY;

-- Service role bypass (your backend uses service role key — full access)
DROP POLICY IF EXISTS "service_role_all_users"      ON public.users;
CREATE POLICY "service_role_all_users"      ON public.users                      FOR ALL USING (TRUE);

DROP POLICY IF EXISTS "service_role_all_requests"   ON public.requests;
CREATE POLICY "service_role_all_requests"   ON public.requests                   FOR ALL USING (TRUE);

DROP POLICY IF EXISTS "service_role_all_afr"        ON public.admin_forward_requests;
CREATE POLICY "service_role_all_afr"        ON public.admin_forward_requests     FOR ALL USING (TRUE);

DROP POLICY IF EXISTS "service_role_all_tr"         ON public.tsp_responses;
CREATE POLICY "service_role_all_tr"         ON public.tsp_responses              FOR ALL USING (TRUE);

DROP POLICY IF EXISTS "service_role_all_afresp"     ON public.admin_forward_responses;
CREATE POLICY "service_role_all_afresp"     ON public.admin_forward_responses    FOR ALL USING (TRUE);

DROP POLICY IF EXISTS "service_role_all_orr"        ON public.officer_received_responses;
CREATE POLICY "service_role_all_orr"        ON public.officer_received_responses  FOR ALL USING (TRUE);

DROP POLICY IF EXISTS "service_role_all_rsl"        ON public.request_status_logs;
CREATE POLICY "service_role_all_rsl"        ON public.request_status_logs        FOR ALL USING (TRUE);

DROP POLICY IF EXISTS "service_role_all_ld"         ON public.login_details;
CREATE POLICY "service_role_all_ld"         ON public.login_details             FOR ALL USING (TRUE);

DROP POLICY IF EXISTS "service_role_all_tsp_settings" ON public.tsp_settings;
CREATE POLICY "service_role_all_tsp_settings" ON public.tsp_settings             FOR ALL USING (TRUE);


