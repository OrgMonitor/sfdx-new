/**
 * ChangeLogConstants
 * Central registry of string literals used across the audit trail batch framework.
 * Only values that are stable at design time are listed here:
 *  - Metadata type names (we author those types)
 *  - Known field names on metadata types we author
 *  - Standard SetupChangeLog field names (Salesforce standard, not custom)
 *  - Logical constants (batch size, lookback window, label strings)
 *
 * Field names on Deployment_Window__c and Change_Log__c are NOT listed here;
 * they are discovered at runtime via Schema Describe.
 */
public class ChangeLogConstants {

    // ── Custom Metadata Type API names ────────────────────────────────────────
    public static final String CONFIG_MDT          = 'Change_Log_Config__mdt';
    public static final String SEVERITY_MDT        = 'Audit_Severity__mdt';
    public static final String CONFIG_RECORD_NAME  = 'Default';

    // ── Change_Log_Config__mdt field names (we author this type) ─────────────
    public static final String CFG_LAST_RUN        = 'Last_Run_Timestamp__c';
    public static final String CFG_EMAIL_CC        = 'Additional_Email_CC__c';
    public static final String CFG_QUEUE_ID        = 'Case_Queue_Id__c';
    public static final String CFG_EMAIL_TMPL      = 'Email_Template_Name__c';

    // ── Change_Log_Severity__mdt field names (we author this type) ───────────
    public static final String SEV_ACTIVE          = 'Active__c';
    public static final String SEV_REGEX           = 'Regex_Pattern__c';
    public static final String SEV_SECTION         = 'Section__c';
    public static final String SEV_VALUE           = 'Severity__c';
    public static final String SEV_SORT_ORDER      = 'Sort_Order__c';

    // ── SetupChangeLog — Salesforce standard object; field names are stable ──
    public static final String SAT_OBJECT          = 'SetupChangeLog';
    public static final String SAT_ID              = 'Id';
    public static final String SAT_CREATED_DATE    = 'CreatedDate';
    public static final String SAT_CREATED_BY_ID   = 'CreatedById';
    public static final String SAT_CREATED_BY_NAME = 'CreatedBy.Name';
    public static final String SAT_ACTION          = 'Action';
    public static final String SAT_SECTION         = 'Section';
    public static final String SAT_DISPLAY         = 'Display';
    public static final String SAT_DELEGATE_USER   = 'DelegateUser';

    // ── Target custom object (discovered / validated at runtime) ───────────────
    // DEFAULT_TARGET_OBJECT is the expected API name for this org; the service
    // layer validates its existence via Schema Describe before use.
    public static final String DEFAULT_TARGET_OBJECT = 'Change_Log__c';

    // ── Deployment window custom object ───────────────────────────────────────
    // Field names on this object are NOT hardcoded; they are discovered at
    // runtime. Only the object API name and the "active" picklist value are
    // stable enough to list here.
    public static final String DW_OBJECT           = 'Deployment_Window__c';
    public static final String DW_ACTIVE_VALUE     = 'Active';

    // ── Filtering ─────────────────────────────────────────────────────────────
    public static final String EXCLUDE_AUTOMATED   = 'Automated Process';
    public static final Integer LOOKBACK_MONTHS    = 3;

    // ── Compliance / severity labels ──────────────────────────────────────────
    public static final String COMPLIANT           = 'Compliant';
    public static final String NON_COMPLIANT       = 'Non-Compliant';
    public static final String SEVERITY_DEFAULT    = 'LOW';

    // ── Target object external ID field (used for upsert deduplication) ───────
    public static final String TARGET_EXT_ID       = 'External_Id__c';

    // ── Batch processing ──────────────────────────────────────────────────────
    public static final Integer BATCH_SIZE         = 200;

    // ── Metadata API full name used when updating the CMT timestamp ───────────
    public static final String CMT_FULL_NAME       = CONFIG_MDT + '.' + CONFIG_RECORD_NAME;
}