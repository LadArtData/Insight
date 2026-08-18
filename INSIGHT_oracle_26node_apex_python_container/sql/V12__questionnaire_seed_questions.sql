ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- QUESTIONNAIRE BACKEND: SEED DATA FOR INSIGHT_QUESTIONS
-- Requires INSIGHT_07 (insight_questions table).
--
-- Generated from the live ALL_QUESTIONS array in INSIGHT_app.html so the
-- seeded rows match exactly what the front end asks -- not hand-
-- transcribed. If a question is added/edited in the app, re-generate
-- this file from the same source rather than editing rows by hand.
-- ============================================================================

MERGE INTO insight_questions tgt
USING (
    SELECT 'INTAKE-001' AS question_id, 'INTAKE' AS module_code, 1 AS phase, 'Phase 1 · Client Intake — Client Identification' AS eyebrow, 'What is the client''s full legal company name, and what should we call them informally?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 1 AS display_order FROM dual
    UNION ALL
    SELECT 'INTAKE-002' AS question_id, 'INTAKE' AS module_code, 1 AS phase, 'Phase 1 · Client Intake — Client Identification' AS eyebrow, 'Who is the primary contact for this engagement (name, title, email, phone)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 2 AS display_order FROM dual
    UNION ALL
    SELECT 'INTAKE-003' AS question_id, 'INTAKE' AS module_code, 1 AS phase, 'Phase 1 · Client Intake — Client Identification' AS eyebrow, 'Who else should be considered a key stakeholder or decision-maker (e.g., CFO, Controller, IT Director)?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 3 AS display_order FROM dual
    UNION ALL
    SELECT 'INTAKE-004' AS question_id, 'INTAKE' AS module_code, 1 AS phase, 'Phase 1 · Client Intake — Company Profile' AS eyebrow, 'What industry/sector is the client in, and approximately how large are they (employee count and/or annual revenue)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 4 AS display_order FROM dual
    UNION ALL
    SELECT 'INTAKE-005' AS question_id, 'INTAKE' AS module_code, 1 AS phase, 'Phase 1 · Client Intake — Company Profile' AS eyebrow, 'Roughly how many legal entities, subsidiaries, or locations does the client operate?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 5 AS display_order FROM dual
    UNION ALL
    SELECT 'INTAKE-006' AS question_id, 'INTAKE' AS module_code, 1 AS phase, 'Phase 1 · Client Intake — Current Environment' AS eyebrow, 'What ERP or financial system(s) is the client currently using, and are they still under contract/support?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 6 AS display_order FROM dual
    UNION ALL
    SELECT 'INTAKE-007' AS question_id, 'INTAKE' AS module_code, 1 AS phase, 'Phase 1 · Client Intake — Current Environment' AS eyebrow, 'Are there other systems already in place that will need to integrate with Oracle Fusion (e.g., payroll, procurement, banking, CRM)?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 7 AS display_order FROM dual
    UNION ALL
    SELECT 'INTAKE-008' AS question_id, 'INTAKE' AS module_code, 1 AS phase, 'Phase 1 · Client Intake — Reason for Engagement' AS eyebrow, 'What prompted the client to reach out now (e.g., system end-of-life, growth, compliance, M&A, dissatisfaction with current provider)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 8 AS display_order FROM dual
    UNION ALL
    SELECT 'INTAKE-009' AS question_id, 'INTAKE' AS module_code, 1 AS phase, 'Phase 1 · Client Intake — Reason for Engagement' AS eyebrow, 'What does the client consider their biggest pain point today?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 9 AS display_order FROM dual
    UNION ALL
    SELECT 'INTAKE-010' AS question_id, 'INTAKE' AS module_code, 1 AS phase, 'Phase 1 · Client Intake — Timeline & Constraints' AS eyebrow, 'Is there a target go-live date or an external deadline driving the timeline (e.g., fiscal year-end, contract expiration)?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 10 AS display_order FROM dual
    UNION ALL
    SELECT 'QUAL-GL' AS question_id, 'GL' AS module_code, 2 AS phase, 'Phase 2 · Needs & Wants — Module Scoping' AS eyebrow, 'Is General Ledger required as the core financial system of record? (GL is the foundation module for every Fusion Financials implementation and is always in scope.)' AS question_text, 'yn' AS answer_type, 1 AS is_required, 1 AS is_locked, 11 AS display_order FROM dual
    UNION ALL
    SELECT 'QUAL-AP' AS question_id, 'AP' AS module_code, 2 AS phase, 'Phase 2 · Needs & Wants — Module Scoping' AS eyebrow, 'Does the organization process vendor/supplier invoices and issue payments to suppliers?' AS question_text, 'yn' AS answer_type, 1 AS is_required, 0 AS is_locked, 12 AS display_order FROM dual
    UNION ALL
    SELECT 'QUAL-AR' AS question_id, 'AR' AS module_code, 2 AS phase, 'Phase 2 · Needs & Wants — Module Scoping' AS eyebrow, 'Does the organization invoice customers and manage receivables, collections, or billing?' AS question_text, 'yn' AS answer_type, 1 AS is_required, 0 AS is_locked, 13 AS display_order FROM dual
    UNION ALL
    SELECT 'QUAL-FA' AS question_id, 'FA' AS module_code, 2 AS phase, 'Phase 2 · Needs & Wants — Module Scoping' AS eyebrow, 'Does the organization need to track, depreciate, transfer, or dispose of capital/fixed assets?' AS question_text, 'yn' AS answer_type, 1 AS is_required, 0 AS is_locked, 14 AS display_order FROM dual
    UNION ALL
    SELECT 'QUAL-CM' AS question_id, 'CM' AS module_code, 2 AS phase, 'Phase 2 · Needs & Wants — Module Scoping' AS eyebrow, 'Does the organization require bank statement reconciliation, cash positioning, or cash forecasting?' AS question_text, 'yn' AS answer_type, 1 AS is_required, 0 AS is_locked, 15 AS display_order FROM dual
    UNION ALL
    SELECT 'QUAL-MULTI' AS question_id, 'GL' AS module_code, 2 AS phase, 'Phase 2 · Needs & Wants — Module Scoping' AS eyebrow, 'Will multiple legal entities or business units require consolidated financial reporting?' AS question_text, 'yn' AS answer_type, 1 AS is_required, 0 AS is_locked, 16 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-001' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Enterprise Structure & Foundation' AS eyebrow, 'What are the legal names, official addresses, Tax IDs, and specific statutory reporting obligations for each legal entity and business unit?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 17 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-002' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Enterprise Structure & Foundation' AS eyebrow, 'What is your primary currency, and will you require multi-currency accounting? What accounting methods (e.g., accrual, modified accrual, cash) are required?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 18 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-003' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Enterprise Structure & Foundation' AS eyebrow, 'What level of physical location tracking is needed (e.g., building, room), and does location data need to integrate with external systems like IT help desk or asset tracking software?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 19 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-004' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Chart of Accounts (COA) & Governance' AS eyebrow, 'Does the proposed segment structure (Fund, Cost Center, Subsidiary, Natural Account, Activity, Future 1) cover all operational and reporting needs?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 20 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-005' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Chart of Accounts (COA) & Governance' AS eyebrow, 'Should the system allow dynamic creation of new account combinations during entry, or should all combinations be manually created and approved by Finance?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 21 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-006' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Chart of Accounts (COA) & Governance' AS eyebrow, 'What specific cross-validation rules should exist to block invalid segment combinations (e.g., restricting certain cost centers to specific natural accounts)? Which departments need access restricted to only their specific account segments?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 22 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-007' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Chart of Accounts (COA) & Governance' AS eyebrow, 'What is the formal workflow, approval path, or board requirement for adding new projects, funds, or segment values?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 23 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-008' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Accounting Calendar & Period Management' AS eyebrow, 'Does your fiscal year follow the standard calendar year or a custom fiscal period?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 24 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-009' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Accounting Calendar & Period Management' AS eyebrow, 'Do you require one adjusting period at year-end or two separate periods (e.g., one for internal year-end adjustments and one for external audit adjustments)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 25 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-010' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Accounting Calendar & Period Management' AS eyebrow, 'What are your policies regarding soft-closing periods, reopening prior periods, and managing future-entry statuses?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 26 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-011' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Journal Entries & Approval Workflows' AS eyebrow, 'What types of manual journals do you enter (e.g., accruals, reclassifications, interfund billings)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 27 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-012' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Journal Entries & Approval Workflows' AS eyebrow, 'What are the dollar thresholds, role hierarchies, or department-specific rules that dictate who must approve a journal before posting?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 28 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-013' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Journal Entries & Approval Workflows' AS eyebrow, 'Which subledgers (Payables, Receivables, Fixed Assets, Projects) should post automatically to the General Ledger versus requiring manual review before posting?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 29 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-014' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Journal Entries & Approval Workflows' AS eyebrow, 'Which departments require automatic reversals for accruals, and are there exceptions (e.g., specialized grant or health departments) that need manual or delayed reversals?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 30 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-015' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Budgeting & Budgetary Control' AS eyebrow, 'What stages/versions of the budget need to be tracked in the system (e.g., Proposed, Executive, Adopted, Amended)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 31 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-016' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Budgeting & Budgetary Control' AS eyebrow, 'At what roll-up level (e.g., Fund, Cost Center, Department) should the system enforce spending limits?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 32 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-017' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Budgeting & Budgetary Control' AS eyebrow, 'Which accounts require an Absolute block on overspending versus an Advisory warning (e.g., advisory for wages/fringes vs. absolute for operational expenses)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 33 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-018' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Budgeting & Budgetary Control' AS eyebrow, 'Who holds the authority to grant budget overrides when transactions exceed available funds?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 34 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-019' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Allocations' AS eyebrow, 'What shared expenses (e.g., IT, facilities, administrative overhead) need to be distributed across departments or funds?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 35 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-020' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Allocations' AS eyebrow, 'What are the distribution drivers for each allocation (e.g., fixed percentages, headcount, square footage, direct expenses, or statistical balances)?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 36 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-021' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Allocations' AS eyebrow, 'Should allocations be calculated and generated dynamically during period-close or on a set recurring schedule?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 37 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-022' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Grant & Compliance Reporting (HHS / Federal / State)' AS eyebrow, 'How do you currently track allowable vs. unallowable costs, federal awards, and state reporting codes?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 38 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-023' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Grant & Compliance Reporting (HHS / Federal / State)' AS eyebrow, 'What specific metadata fields need to be attached to accounts or activities to satisfy external grant reporting (e.g., Assistance Listing/CFDA numbers, PMS subaccounts, Grant Manager names)?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 39 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-024' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Data Conversion, Interfaces & Reporting' AS eyebrow, 'How many years of historical transactional data, summary account balances, and budget history need to be converted from the legacy system?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 40 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-025' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Data Conversion, Interfaces & Reporting' AS eyebrow, 'What third-party or banking interfaces need to feed directly into the general ledger or subledgers?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 41 AS display_order FROM dual
    UNION ALL
    SELECT 'GL-026' AS question_id, 'GL' AS module_code, 3 AS phase, 'Phase 3 · GL Discovery — Data Conversion, Interfaces & Reporting' AS eyebrow, 'What standard financial statements (Balance Sheet, Income Statement, Cash Flow), operational tracking reports, and state/federal regulatory filings must be built out of the box?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 42 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-001' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Supplier Management & Setup' AS eyebrow, 'What is the current process for onboarding and approving new suppliers (e.g., required documentation, W-9/tax forms, banking details)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 43 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-002' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Supplier Management & Setup' AS eyebrow, 'Do suppliers require multiple sites (e.g., separate remit-to, ordering, and corporate addresses)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 44 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-003' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Supplier Management & Setup' AS eyebrow, 'How are suppliers segmented or classified (e.g., by type, category, 1099 reporting status)?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 45 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-004' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Invoice Processing' AS eyebrow, 'How are invoices currently received and entered (e.g., manual entry, scanning/OCR, supplier portal, EDI)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 46 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-005' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Invoice Processing' AS eyebrow, 'What level of PO matching is required (2-way, 3-way, 4-way) and for which transaction types?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 47 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-006' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Invoice Processing' AS eyebrow, 'What are the dollar thresholds and approval hierarchies for non-PO invoices?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 48 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-007' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Invoice Processing' AS eyebrow, 'How are recurring charges (e.g., leases, subscriptions) and prepayments currently tracked and amortized?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 49 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-008' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Payments' AS eyebrow, 'What payment methods are used (check, ACH, wire, virtual card) and do they vary by supplier or region?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 50 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-009' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Payments' AS eyebrow, 'What standard payment terms are offered, and how are early-payment discounts managed?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 51 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-010' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Payments' AS eyebrow, 'What controls exist over payment batches (e.g., dual approval, positive pay)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 52 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-011' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Tax & Compliance' AS eyebrow, 'What tax withholding rules apply, and what regulatory reporting (1099, 1042-S, VAT) is required?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 53 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-012' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Tax & Compliance' AS eyebrow, 'Does the organization self-assess use tax on certain purchases?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 54 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-013' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Interfaces & Reporting' AS eyebrow, 'Is there an upstream procurement/requisitioning system feeding AP, and how tightly should PO and invoice data be integrated?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 55 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-014' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Interfaces & Reporting' AS eyebrow, 'Are employee expense reimbursements processed through AP or a separate system?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 56 AS display_order FROM dual
    UNION ALL
    SELECT 'AP-015' AS question_id, 'AP' AS module_code, 3 AS phase, 'Phase 3 · AP Discovery — Interfaces & Reporting' AS eyebrow, 'What AP-specific reports are required (aging, cash disbursement forecast, supplier spend analysis)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 57 AS display_order FROM dual
    UNION ALL
    SELECT 'AR-001' AS question_id, 'AR' AS module_code, 3 AS phase, 'Phase 3 · AR Discovery — Customer Management' AS eyebrow, 'What is the process for establishing new customer accounts, including credit checks and credit limit setting?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 58 AS display_order FROM dual
    UNION ALL
    SELECT 'AR-002' AS question_id, 'AR' AS module_code, 3 AS phase, 'Phase 3 · AR Discovery — Customer Management' AS eyebrow, 'Do customers require bill-to/ship-to hierarchies or parent-child account structures?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 59 AS display_order FROM dual
    UNION ALL
    SELECT 'AR-003' AS question_id, 'AR' AS module_code, 3 AS phase, 'Phase 3 · AR Discovery — Billing & Invoicing' AS eyebrow, 'How are customer invoices generated (e.g., manual, contract billing, project billing, recurring billing)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 60 AS display_order FROM dual
    UNION ALL
    SELECT 'AR-004' AS question_id, 'AR' AS module_code, 3 AS phase, 'Phase 3 · AR Discovery — Billing & Invoicing' AS eyebrow, 'How are invoices delivered to customers (mail, email, EDI, customer portal)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 61 AS display_order FROM dual
    UNION ALL
    SELECT 'AR-005' AS question_id, 'AR' AS module_code, 3 AS phase, 'Phase 3 · AR Discovery — Billing & Invoicing' AS eyebrow, 'What billing cycles or milestones apply (e.g., monthly, milestone-based, usage-based)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 62 AS display_order FROM dual
    UNION ALL
    SELECT 'AR-006' AS question_id, 'AR' AS module_code, 3 AS phase, 'Phase 3 · AR Discovery — Receipts & Collections' AS eyebrow, 'How are customer payments received (lockbox, ACH, credit card, check) and applied to invoices?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 63 AS display_order FROM dual
    UNION ALL
    SELECT 'AR-007' AS question_id, 'AR' AS module_code, 3 AS phase, 'Phase 3 · AR Discovery — Receipts & Collections' AS eyebrow, 'How are short payments, deductions, and billing disputes currently tracked and resolved?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 64 AS display_order FROM dual
    UNION ALL
    SELECT 'AR-008' AS question_id, 'AR' AS module_code, 3 AS phase, 'Phase 3 · AR Discovery — Receipts & Collections' AS eyebrow, 'What collections workflow, dunning letters, or escalation process is used for past-due accounts?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 65 AS display_order FROM dual
    UNION ALL
    SELECT 'AR-009' AS question_id, 'AR' AS module_code, 3 AS phase, 'Phase 3 · AR Discovery — Credit & Risk Management' AS eyebrow, 'What triggers a credit hold on a customer account, and who has authority to release it?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 66 AS display_order FROM dual
    UNION ALL
    SELECT 'AR-010' AS question_id, 'AR' AS module_code, 3 AS phase, 'Phase 3 · AR Discovery — Credit & Risk Management' AS eyebrow, 'What is the approval process for writing off uncollectible receivables?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 67 AS display_order FROM dual
    UNION ALL
    SELECT 'AR-011' AS question_id, 'AR' AS module_code, 3 AS phase, 'Phase 3 · AR Discovery — Tax & Compliance' AS eyebrow, 'How is sales tax calculated and reported on customer invoices (e.g., third-party tax engine)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 68 AS display_order FROM dual
    UNION ALL
    SELECT 'AR-012' AS question_id, 'AR' AS module_code, 3 AS phase, 'Phase 3 · AR Discovery — Interfaces & Reporting' AS eyebrow, 'What AR-specific reports are required (aging, DSO, cash forecast, customer statements)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 69 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-001' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Asset Categories & Setup' AS eyebrow, 'How are assets categorized (e.g., by type, useful life, depreciation method)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 70 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-002' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Asset Categories & Setup' AS eyebrow, 'Do you require multiple depreciation books (e.g., corporate, tax, budget)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 71 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-003' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Asset Acquisition & Capitalization' AS eyebrow, 'What dollar threshold determines whether a purchase is capitalized versus expensed?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 72 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-004' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Asset Acquisition & Capitalization' AS eyebrow, 'How are assets under construction (CIP) tracked and transferred to in-service status?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 73 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-005' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Asset Acquisition & Capitalization' AS eyebrow, 'Are assets added manually, via mass additions from AP, or via project costing interfaces?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 74 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-006' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Depreciation' AS eyebrow, 'What depreciation methods and useful lives apply by asset category (e.g., straight-line, declining balance)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 75 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-007' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Depreciation' AS eyebrow, 'Is depreciation calculated monthly, and how are mid-year conventions handled?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 76 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-008' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Transfers, Adjustments & Retirements' AS eyebrow, 'What is the process for transferring assets between departments, locations, or cost centers?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 77 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-009' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Transfers, Adjustments & Retirements' AS eyebrow, 'What approval workflow governs asset retirements, sales, or disposals, and how are gains/losses recorded?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 78 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-010' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Physical Inventory & Tracking' AS eyebrow, 'Is a periodic physical inventory of assets required, and how are discrepancies reconciled?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 79 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-011' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Physical Inventory & Tracking' AS eyebrow, 'Are assets tagged/barcoded, and does location tracking need to integrate with other systems?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 80 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-012' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Reporting & Compliance' AS eyebrow, 'What tax depreciation reporting (e.g., federal/state tax books) is required?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 81 AS display_order FROM dual
    UNION ALL
    SELECT 'FA-013' AS question_id, 'FA' AS module_code, 3 AS phase, 'Phase 3 · FA Discovery — Reporting & Compliance' AS eyebrow, 'What standard FA reports are required (asset register, depreciation forecast, disposal summary)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 82 AS display_order FROM dual
    UNION ALL
    SELECT 'CM-001' AS question_id, 'CM' AS module_code, 3 AS phase, 'Phase 3 · CM Discovery — Bank Account Structure' AS eyebrow, 'How many bank accounts and banking relationships need to be set up, and at what level (legal entity, business unit)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 83 AS display_order FROM dual
    UNION ALL
    SELECT 'CM-002' AS question_id, 'CM' AS module_code, 3 AS phase, 'Phase 3 · CM Discovery — Bank Account Structure' AS eyebrow, 'Who requires access to bank account setup and reconciliation, and what segregation of duties is required?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 84 AS display_order FROM dual
    UNION ALL
    SELECT 'CM-003' AS question_id, 'CM' AS module_code, 3 AS phase, 'Phase 3 · CM Discovery — Cash Positioning & Forecasting' AS eyebrow, 'How frequently is cash position reviewed, and what visibility is needed across entities/currencies?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 85 AS display_order FROM dual
    UNION ALL
    SELECT 'CM-004' AS question_id, 'CM' AS module_code, 3 AS phase, 'Phase 3 · CM Discovery — Cash Positioning & Forecasting' AS eyebrow, 'Is cash forecasting required, and what data feeds into it (AP/AR projections, payroll, etc.)?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 86 AS display_order FROM dual
    UNION ALL
    SELECT 'CM-005' AS question_id, 'CM' AS module_code, 3 AS phase, 'Phase 3 · CM Discovery — Bank Statement Reconciliation' AS eyebrow, 'Are bank statements reconciled manually or via automated bank feeds (e.g., BAI2, SWIFT)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 87 AS display_order FROM dual
    UNION ALL
    SELECT 'CM-006' AS question_id, 'CM' AS module_code, 3 AS phase, 'Phase 3 · CM Discovery — Bank Statement Reconciliation' AS eyebrow, 'What matching rules or tolerances are needed to auto-reconcile transactions?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 88 AS display_order FROM dual
    UNION ALL
    SELECT 'CM-007' AS question_id, 'CM' AS module_code, 3 AS phase, 'Phase 3 · CM Discovery — Transactions & Transfers' AS eyebrow, 'How are inter-bank or intercompany transfers initiated and recorded?' AS question_text, 'text' AS answer_type, 0 AS is_required, 0 AS is_locked, 89 AS display_order FROM dual
    UNION ALL
    SELECT 'CM-008' AS question_id, 'CM' AS module_code, 3 AS phase, 'Phase 3 · CM Discovery — Transactions & Transfers' AS eyebrow, 'What payment file formats are required for outbound disbursements (e.g., NACHA, ISO 20022)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 90 AS display_order FROM dual
    UNION ALL
    SELECT 'CM-009' AS question_id, 'CM' AS module_code, 3 AS phase, 'Phase 3 · CM Discovery — Reporting & Compliance' AS eyebrow, 'What CM-specific reports are required (cash position, bank reconciliation status, transaction detail)?' AS question_text, 'text' AS answer_type, 1 AS is_required, 0 AS is_locked, 91 AS display_order FROM dual
) src
ON (tgt.question_id = src.question_id)
WHEN MATCHED THEN UPDATE SET
    tgt.module_code   = src.module_code,
    tgt.phase         = src.phase,
    tgt.eyebrow       = src.eyebrow,
    tgt.question_text = src.question_text,
    tgt.answer_type   = src.answer_type,
    tgt.is_required   = src.is_required,
    tgt.is_locked     = src.is_locked,
    tgt.display_order = src.display_order
WHEN NOT MATCHED THEN INSERT (
    question_id, module_code, phase, eyebrow, question_text, answer_type, is_required, is_locked, display_order
) VALUES (
    src.question_id, src.module_code, src.phase, src.eyebrow, src.question_text, src.answer_type, src.is_required, src.is_locked, src.display_order
);

COMMIT;
