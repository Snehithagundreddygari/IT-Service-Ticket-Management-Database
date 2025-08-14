-- IT Service Ticket Management Database
-- Target: PostgreSQL 12+
-- Save as: it_service_ticket_management.sql
-- Run: psql -U <user> -d <db> -f it_service_ticket_management.sql
-- This script creates schema, tables, enums, indexes, functions, triggers, sample data,
-- and helper queries for an IT Service Ticket Management system.

BEGIN;

CREATE SCHEMA IF NOT EXISTS itsm;
SET search_path = itsm;

-- ENUMS
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ticket_priority') THEN
        CREATE TYPE ticket_priority AS ENUM ('P1_Critical','P2_High','P3_Medium','P4_Low');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ticket_status') THEN
        CREATE TYPE ticket_status AS ENUM ('New','Open','In Progress','On Hold','Resolved','Closed');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ticket_source') THEN
        CREATE TYPE ticket_source AS ENUM ('Email','Phone','Web','Portal','Chat','API');
    END IF;
END $$;

-- TABLES
CREATE TABLE IF NOT EXISTS departments (
    department_id SERIAL PRIMARY KEY,
    name VARCHAR(120) UNIQUE NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE IF NOT EXISTS users (
    user_id SERIAL PRIMARY KEY,
    username VARCHAR(80) UNIQUE NOT NULL,
    full_name VARCHAR(150) NOT NULL,
    email VARCHAR(200) UNIQUE,
    department_id INT REFERENCES departments(department_id) ON DELETE SET NULL,
    is_agent BOOLEAN DEFAULT FALSE,
    is_manager BOOLEAN DEFAULT FALSE,
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE IF NOT EXISTS customers (
    customer_id SERIAL PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    contact_email VARCHAR(200),
    contact_phone VARCHAR(40),
    company VARCHAR(150),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE IF NOT EXISTS queues (
    queue_id SERIAL PRIMARY KEY,
    name VARCHAR(120) UNIQUE NOT NULL,
    description TEXT,
    department_id INT REFERENCES departments(department_id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sla_policies (
    sla_id SERIAL PRIMARY KEY,
    name VARCHAR(120) NOT NULL UNIQUE,
    priority ticket_priority NOT NULL,
    response_time_hours INT NOT NULL, -- time to first response
    resolution_time_hours INT NOT NULL, -- time to resolution
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Core ticket table
CREATE TABLE IF NOT EXISTS tickets (
    ticket_id BIGSERIAL PRIMARY KEY,
    ticket_number VARCHAR(32) UNIQUE NOT NULL,
    title VARCHAR(250) NOT NULL,
    description TEXT,
    customer_id INT REFERENCES customers(customer_id) ON DELETE SET NULL,
    created_by INT REFERENCES users(user_id) ON DELETE SET NULL,
    assigned_to INT REFERENCES users(user_id) ON DELETE SET NULL,
    queue_id INT REFERENCES queues(queue_id) ON DELETE SET NULL,
    priority ticket_priority NOT NULL DEFAULT 'P3_Medium',
    status ticket_status NOT NULL DEFAULT 'New',
    source ticket_source NOT NULL DEFAULT 'Portal',
    sla_id INT REFERENCES sla_policies(sla_id) ON DELETE SET NULL,
    sla_response_due TIMESTAMP WITH TIME ZONE,
    sla_resolution_due TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ticket_history (
    history_id BIGSERIAL PRIMARY KEY,
    ticket_id BIGINT REFERENCES tickets(ticket_id) ON DELETE CASCADE,
    changed_by INT REFERENCES users(user_id) ON DELETE SET NULL,
    change_type VARCHAR(80) NOT NULL,
    old_value TEXT,
    new_value TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ticket_comments (
    comment_id BIGSERIAL PRIMARY KEY,
    ticket_id BIGINT REFERENCES tickets(ticket_id) ON DELETE CASCADE,
    author_id INT REFERENCES users(user_id) ON DELETE SET NULL,
    comment_text TEXT NOT NULL,
    internal BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ticket_attachments (
    attachment_id BIGSERIAL PRIMARY KEY,
    ticket_id BIGINT REFERENCES tickets(ticket_id) ON DELETE CASCADE,
    file_name VARCHAR(255),
    content_type VARCHAR(120),
    file_size INT,
    url TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_ticket_status_priority ON tickets(status, priority);
CREATE INDEX IF NOT EXISTS idx_ticket_queue ON tickets(queue_id);
CREATE INDEX IF NOT EXISTS idx_ticket_assigned ON tickets(assigned_to);
CREATE INDEX IF NOT EXISTS idx_ticket_created ON tickets(created_at);

-- SEQUENCE-based ticket number generation helper
CREATE SEQUENCE IF NOT EXISTS ticket_num_seq START 1000;

-- UTILITY FUNCTIONS
-- generate a ticket number like TCKT-2025-000123
CREATE OR REPLACE FUNCTION gen_ticket_number() RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE seqnum bigint := nextval('ticket_num_seq');
BEGIN
    RETURN 'TCKT-' || to_char(now(), 'YYYY') || '-' || lpad(seqnum::text, 6, '0');
END; $$;

-- set SLA due dates based on SLA policy
CREATE OR REPLACE FUNCTION apply_sla_dates(p_ticket_id BIGINT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE t tickets%ROWTYPE; sla_rec sla_policies%ROWTYPE; nowts TIMESTAMP WITH TIME ZONE := now();
BEGIN
    SELECT * INTO t FROM tickets WHERE ticket_id = p_ticket_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'ticket not found'; END IF;
    IF t.sla_id IS NULL THEN
        -- no SLA attached; nothing to do
        RETURN;
    END IF;
    SELECT * INTO sla_rec FROM sla_policies WHERE sla_id = t.sla_id;
    IF NOT FOUND THEN RETURN; END IF;

    UPDATE tickets SET
        sla_response_due = nowts + (interval '1 hour' * sla_rec.response_time_hours),
        sla_resolution_due = nowts + (interval '1 hour' * sla_rec.resolution_time_hours),
        updated_at = now
    WHERE ticket_id = p_ticket_id;
END; $$;

-- create ticket function (inserts ticket + history + applies SLA)
CREATE OR REPLACE FUNCTION create_ticket(
    p_title TEXT,
    p_description TEXT,
    p_customer INT,
    p_created_by INT,
    p_queue INT DEFAULT NULL,
    p_priority ticket_priority DEFAULT 'P3_Medium',
    p_source ticket_source DEFAULT 'Portal',
    p_sla_id INT DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE new_id BIGINT; tnum TEXT;
BEGIN
    tnum := gen_ticket_number();
    INSERT INTO tickets(ticket_number, title, description, customer_id, created_by, queue_id, priority, status, source, sla_id)
    VALUES (tnum, p_title, p_description, p_customer, p_created_by, p_queue, p_priority, 'New', p_source, p_sla_id)
    RETURNING ticket_id INTO new_id;

    INSERT INTO ticket_history(ticket_id, changed_by, change_type, old_value, new_value)
    VALUES (new_id, p_created_by, 'CREATED', NULL, p_title);

    PERFORM apply_sla_dates(new_id);
    RETURN new_id;
END; $$;

-- assign ticket to user or queue
CREATE OR REPLACE FUNCTION assign_ticket(p_ticket_id BIGINT, p_user_id INT, p_queue_id INT, p_changed_by INT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE old_owner TEXT;
BEGIN
    SELECT assigned_to::TEXT INTO old_owner FROM tickets WHERE ticket_id = p_ticket_id;
    UPDATE tickets SET assigned_to = p_user_id, queue_id = p_queue_id, status = 'Open', updated_at = now() WHERE ticket_id = p_ticket_id;
    INSERT INTO ticket_history(ticket_id, changed_by, change_type, old_value, new_value)
    VALUES (p_ticket_id, p_changed_by, 'ASSIGNED', old_owner, COALESCE((SELECT full_name FROM users WHERE user_id = p_user_id), 'Queue:'||p_queue_id));
END; $$;

-- change ticket status
CREATE OR REPLACE FUNCTION change_ticket_status(p_ticket_id BIGINT, p_status ticket_status, p_changed_by INT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE old_status TEXT;
BEGIN
    SELECT status::TEXT INTO old_status FROM tickets WHERE ticket_id = p_ticket_id;
    UPDATE tickets SET status = p_status, updated_at = now() WHERE ticket_id = p_ticket_id;
    INSERT INTO ticket_history(ticket_id, changed_by, change_type, old_value, new_value)
    VALUES (p_ticket_id, p_changed_by, 'STATUS_CHANGE', old_status, p_status::TEXT);
END; $$;

-- add comment
CREATE OR REPLACE FUNCTION add_ticket_comment(p_ticket_id BIGINT, p_author INT, p_text TEXT, p_internal BOOLEAN DEFAULT FALSE) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE cid BIGINT;
BEGIN
    INSERT INTO ticket_comments(ticket_id, author_id, comment_text, internal)
    VALUES (p_ticket_id, p_author, p_text, p_internal)
    RETURNING comment_id INTO cid;
    INSERT INTO ticket_history(ticket_id, changed_by, change_type, old_value, new_value)
    VALUES (p_ticket_id, p_author, 'COMMENT_ADDED', NULL, left(p_text,200));
    RETURN cid;
END; $$;

-- escalate tickets past SLA: bump priority and notify via history (to be scheduled externally)
CREATE OR REPLACE FUNCTION escalate_past_sla() RETURNS INT LANGUAGE plpgsql AS $$
DECLARE rec RECORD; count INT := 0; new_priority ticket_priority;
BEGIN
    FOR rec IN SELECT * FROM tickets WHERE status IN ('New','Open','In Progress','On Hold') AND sla_resolution_due IS NOT NULL AND sla_resolution_due < now() LOOP
        -- compute new priority (make more urgent)
        IF rec.priority = 'P4_Low' THEN new_priority := 'P3_Medium';
        ELSIF rec.priority = 'P3_Medium' THEN new_priority := 'P2_High';
        ELSIF rec.priority = 'P2_High' THEN new_priority := 'P1_Critical';
        ELSE new_priority := rec.priority; END IF;

        IF new_priority IS DISTINCT FROM rec.priority THEN
            UPDATE tickets SET priority = new_priority, status = 'Escalated'::ticket_status, updated_at = now() WHERE ticket_id = rec.ticket_id;
            INSERT INTO ticket_history(ticket_id, changed_by, change_type, old_value, new_value)
            VALUES (rec.ticket_id, NULL, 'ESCALATED', rec.priority::TEXT, new_priority::TEXT);
            count := count + 1;
        END IF;
    END LOOP;
    RETURN count;
END; $$;

-- VIEW: ticket summary
CREATE OR REPLACE VIEW v_ticket_summary AS
SELECT t.ticket_id, t.ticket_number, t.title, t.priority, t.status, t.source, t.created_at, t.updated_at,
       t.sla_response_due, t.sla_resolution_due,
       c.name AS customer_name, u.full_name AS created_by_name, a.full_name AS assigned_to_name, q.name AS queue_name
FROM tickets t
LEFT JOIN customers c ON c.customer_id = t.customer_id
LEFT JOIN users u ON u.user_id = t.created_by
LEFT JOIN users a ON a.user_id = t.assigned_to
LEFT JOIN queues q ON q.queue_id = t.queue_id;

-- SAMPLE DATA
INSERT INTO departments(name, description) VALUES ('Service Desk','Default IT Service Desk') ON CONFLICT DO NOTHING;
INSERT INTO departments(name, description) VALUES ('Infrastructure','Network & Infra') ON CONFLICT DO NOTHING;

INSERT INTO users(username, full_name, email, department_id, is_agent, is_manager)
VALUES
('svc_admin','Service Admin','admin@corp.local', (SELECT department_id FROM departments WHERE name='Service Desk'), true, true)
ON CONFLICT (username) DO NOTHING;

INSERT INTO users(username, full_name, email, department_id, is_agent)
VALUES
('agent1','Agent One','agent1@corp.local', (SELECT department_id FROM departments WHERE name='Service Desk'), true),
('agent2','Agent Two','agent2@corp.local', (SELECT department_id FROM departments WHERE name='Infrastructure'), true)
ON CONFLICT (username) DO NOTHING;

INSERT INTO customers(name, contact_email, company) VALUES ('Alpha Ltd','alpha@alpha.com','Alpha Ltd') ON CONFLICT DO NOTHING;
INSERT INTO customers(name, contact_email, company) VALUES ('Beta Inc','contact@beta.com','Beta Inc') ON CONFLICT DO NOTHING;

INSERT INTO queues(name, description, department_id) VALUES ('General Queue','General support', (SELECT department_id FROM departments WHERE name='Service Desk')) ON CONFLICT DO NOTHING;

INSERT INTO sla_policies(name, priority, response_time_hours, resolution_time_hours)
VALUES ('Standard P3','P3_Medium',2,48), ('High P2','P2_High',1,8), ('Critical P1','P1_Critical',0,4)
ON CONFLICT DO NOTHING;

-- Create a couple of tickets via function
SELECT create_ticket('Unable to login','User cannot login to portal', (SELECT customer_id FROM customers WHERE name='Alpha Ltd'), (SELECT user_id FROM users WHERE username='agent1'), (SELECT queue_id FROM queues WHERE name='General Queue'), 'P2_High'::ticket_priority, 'Portal'::ticket_source, (SELECT sla_id FROM sla_policies WHERE name='High P2'));

SELECT create_ticket('Email delivery failure','Transactional emails bouncing', (SELECT customer_id FROM customers WHERE name='Beta Inc'), (SELECT user_id FROM users WHERE username='agent2'), NULL, 'P1_Critical'::ticket_priority, 'Email'::ticket_source, (SELECT sla_id FROM sla_policies WHERE name='Critical P1'));

-- Provide a convenient function to run escalation and return counts
-- Usage: SELECT escalate_past_sla();

-- NOTES:
-- 1) Scheduling: PostgreSQL does not have a built-in job scheduler in all installations. Use pg_cron, pgAgent, or an external cron job that connects and runs:
--      SELECT itsm.escalate_past_sla();
--    Example (pg_cron): SELECT cron.schedule('*/5 * * * *', 'SELECT itsm.escalate_past_sla()');
-- 2) Notifications: Replace ticket_history inserts with calls to an outbound notification system (emails, webhooks) as needed.
-- 3) Security: Create roles and GRANT appropriate privileges to app users.

COMMIT;
