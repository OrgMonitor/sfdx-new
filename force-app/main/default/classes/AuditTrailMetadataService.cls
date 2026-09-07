/**
 * AuditTrailMetadataService
 *
 * Central service for all metadata resolution within the audit trail framework.
 * Responsibilities:
 *   1. Load and cache Audit_Trail_Config__mdt (last run timestamp + config).
 *   2. Load and cache Audit_Trail_Severity__mdt rules (regex-based matching).
 *   3. Provide Schema Describe caching to avoid redundant describe calls.
 *   4. Discover field API names on dynamic objects (Deployment_Window__c, target).
 *   5. Schedule the async CMT timestamp update via the Metadata API.
 *
 * All field names beyond those on metadata types we author are resolved via
 * Schema Describe at runtime — never hardcoded.
 */
public without sharing class AuditTrailMetadataService {

    // ── Inner: Config DTO ─────────────────────────────────────────────────────
    public class AuditTrailConfig {
        public DateTime lastRunTimestamp;
        public String   emailCC;
        public String   caseQueueId;
        public String   emailTemplateName;
    }

    // ── Inner: Severity Rule ──────────────────────────────────────────────────
    public class SeverityRule {
        public String  developerName;
        public String  regexPattern;
        public String  section;         // null = match any section
        public String  severityValue;
        public Integer sortOrder;
        public Boolean active;
    }

    // ── Inner: Deployment Window Schema ──────────────────────────────────────
    public class DeploymentWindowSchema {
        public String objectApiName;
        public String startField;
        public String endField;
        public String statusField;
        public String activeValue;
        public Boolean isStatusBoolean; // true → field is Checkbox; false → Picklist/Text
    }

    // ── Static Caches ────────────────────────────────────────────────────────
    @TestVisible private static AuditTrailConfig             cachedConfig;
    @TestVisible private static List<SeverityRule>           cachedSeverityRules;
    @TestVisible private static DeploymentWindowSchema       cachedDwSchema;
    @TestVisible private static Map<String, Schema.SObjectType>            globalDescribeCache;
    @TestVisible private static Map<String, Map<String, Schema.SObjectField>> fieldMapCache
        = new Map<String, Map<String, Schema.SObjectField>>();

    // ── Config Loading ────────────────────────────────────────────────────────
    public AuditTrailConfig getConfig() {
        if (cachedConfig != null) return cachedConfig;

        Map<String, Schema.SObjectField> cfgFieldMap = getFieldMap(AuditTrailConstants.CONFIG_MDT);

        // Build query dynamically — only select fields that exist in this org
        Set<String> selectFields = new Set<String>{ 'DeveloperName', 'MasterLabel' };
        for (String fn : new List<String>{
            AuditTrailConstants.CFG_LAST_RUN,
            AuditTrailConstants.CFG_EMAIL_CC,
            AuditTrailConstants.CFG_QUEUE_ID,
            AuditTrailConstants.CFG_EMAIL_TMPL
        }) {
            if (cfgFieldMap.containsKey(fn.toLowerCase())) selectFields.add(fn);
        }

        String devName = AuditTrailConstants.CONFIG_RECORD_NAME;
        String soql = 'SELECT ' + String.join(new List<String>(selectFields), ', ')
            + ' FROM ' + AuditTrailConstants.CONFIG_MDT
            + ' WHERE DeveloperName = :devName LIMIT 1';

        List<SObject> rows = Database.query(soql);

        cachedConfig = new AuditTrailConfig();
        if (!rows.isEmpty()) {
            SObject rec = rows[0];
            cachedConfig.lastRunTimestamp  = safeDateTime(rec, AuditTrailConstants.CFG_LAST_RUN,  cfgFieldMap);
            cachedConfig.emailCC           = safeString(rec,   AuditTrailConstants.CFG_EMAIL_CC,  cfgFieldMap);
            cachedConfig.caseQueueId       = safeString(rec,   AuditTrailConstants.CFG_QUEUE_ID,  cfgFieldMap);
            cachedConfig.emailTemplateName = safeString(rec,   AuditTrailConstants.CFG_EMAIL_TMPL, cfgFieldMap);
        }
        return cachedConfig;
    }

    // ── Severity Rules Loading ────────────────────────────────────────────────
    /**
     * Returns active severity rules sorted by Sort_Order__c ASC.
     * Rules are matched via Regex_Pattern__c against SetupAuditTrail.Action.
     * Optional Section__c narrows the match to a specific audit section.
     */
    public List<SeverityRule> getSeverityRules() {
        if (cachedSeverityRules != null) return cachedSeverityRules;

        Map<String, Schema.SObjectField> sevFieldMap = getFieldMap(AuditTrailConstants.SEVERITY_MDT);

        Set<String> selectFields = new Set<String>{ 'DeveloperName', 'MasterLabel' };
        for (String fn : new List<String>{
            AuditTrailConstants.SEV_ACTIVE,
            AuditTrailConstants.SEV_REGEX,
            AuditTrailConstants.SEV_SECTION,
            AuditTrailConstants.SEV_VALUE,
            AuditTrailConstants.SEV_SORT_ORDER
        }) {
            if (sevFieldMap.containsKey(fn.toLowerCase())) selectFields.add(fn);
        }

        String soql = 'SELECT ' + String.join(new List<String>(selectFields), ', ')
            + ' FROM ' + AuditTrailConstants.SEVERITY_MDT
            + ' ORDER BY ' + AuditTrailConstants.SEV_SORT_ORDER + ' ASC NULLS LAST';

        List<SObject> rows = Database.query(soql);

        cachedSeverityRules = new List<SeverityRule>();
        for (SObject rec : rows) {
            Boolean isActive = (Boolean) rec.get(AuditTrailConstants.SEV_ACTIVE);
            if (isActive == null || !isActive) continue;

            SeverityRule rule     = new SeverityRule();
            rule.developerName    = (String)  rec.get('DeveloperName');
            rule.regexPattern     = safeString(rec, AuditTrailConstants.SEV_REGEX,       sevFieldMap);
            rule.section          = safeString(rec, AuditTrailConstants.SEV_SECTION,     sevFieldMap);
            rule.severityValue    = safeString(rec, AuditTrailConstants.SEV_VALUE,       sevFieldMap);
            Decimal rawSort = (Decimal) rec.get(AuditTrailConstants.SEV_SORT_ORDER);
            rule.sortOrder  = rawSort != null ? rawSort.intValue() : 999;
            rule.active           = true;
            cachedSeverityRules.add(rule);
        }
        return cachedSeverityRules;
    }

    // ── Deployment Window Schema Discovery ───────────────────────────────────
    /**
     * Discovers Deployment_Window__c field names at runtime using Schema Describe.
     * Looks for:
     *   startField  — DateTime/Date field with 'start' in name
     *   endField    — DateTime/Date field with 'end' in name
     *   statusField — Checkbox with 'active' in name, or Picklist/Text with 'status'/'active'
     */
    public DeploymentWindowSchema getDeploymentWindowSchema() {
        if (cachedDwSchema != null) return cachedDwSchema;

        String dwObj = AuditTrailConstants.DW_OBJECT;
        if (!getGlobalDescribe().containsKey(dwObj.toLowerCase())) {
            throw new AuditTrailException('Deployment window object not found: ' + dwObj);
        }

        Map<String, Schema.SObjectField> dwFieldMap = getFieldMap(dwObj);

        DeploymentWindowSchema dwResult = new DeploymentWindowSchema();
        dwResult.objectApiName   = dwObj;
        dwResult.activeValue     = AuditTrailConstants.DW_ACTIVE_VALUE;
        dwResult.isStatusBoolean = false;

        // Priority: prefer fields whose names contain the strongest hints
        String startCandidate = null, endCandidate = null, statusCandidate = null;

        for (String fieldName : dwFieldMap.keySet()) {
            Schema.DescribeFieldResult dfr = dwFieldMap.get(fieldName).getDescribe();
            String lower = fieldName.toLowerCase();
            Schema.DisplayType dtype = dfr.getType();

            // Start/End detection — DateTime or Date type with semantic name
            if (dtype == Schema.DisplayType.DateTime || dtype == Schema.DisplayType.Date) {
                if (lower.contains('start')) {
                    // Prefer more specific names (e.g. start_date_time beats startdt)
                    if (startCandidate == null || fieldName.length() > startCandidate.length()) {
                        startCandidate = fieldName;
                    }
                } else if (lower.contains('end') || lower.contains('close') || lower.contains('finish')) {
                    if (endCandidate == null || fieldName.length() > endCandidate.length()) {
                        endCandidate = fieldName;
                    }
                }
            }

            // Status/Active detection
            if (dtype == Schema.DisplayType.Boolean) {
                if (lower.contains('active') || lower.contains('enable') || lower.contains('open')) {
                    statusCandidate = fieldName;
                    dwResult.isStatusBoolean = true;
                }
            } else if (dtype == Schema.DisplayType.Picklist || dtype == Schema.DisplayType.String) {
                if (lower.contains('status') || lower.contains('state')) {
                    if (!dwResult.isStatusBoolean) {
                        statusCandidate = fieldName;
                    }
                }
            }
        }

        if (startCandidate == null || endCandidate == null || statusCandidate == null) {
            throw new AuditTrailException(
                'Could not discover required fields on ' + dwObj
                + '. Discovered: start=' + startCandidate
                + ', end=' + endCandidate + ', status=' + statusCandidate
            );
        }

        dwResult.startField  = startCandidate;
        dwResult.endField    = endCandidate;
        dwResult.statusField = statusCandidate;

        cachedDwSchema = dwResult;
        return cachedDwSchema;
    }

    // ── Schema Describe Helpers ───────────────────────────────────────────────
    public Map<String, Schema.SObjectField> getFieldMap(String objectApiName) {
        String lower = objectApiName.toLowerCase();
        if (!fieldMapCache.containsKey(lower)) {
            Schema.SObjectType objType = getGlobalDescribe().get(lower);
            fieldMapCache.put(lower, objType != null
                ? objType.getDescribe().fields.getMap()
                : new Map<String, Schema.SObjectField>());
        }
        return fieldMapCache.get(lower);
    }

    public Boolean objectExists(String objectApiName) {
        return getGlobalDescribe().containsKey(objectApiName.toLowerCase());
    }

    public Schema.DescribeSObjectResult getObjectDescribe(String objectApiName) {
        Schema.SObjectType t = getGlobalDescribe().get(objectApiName.toLowerCase());
        if (t == null) throw new AuditTrailException('Object not found: ' + objectApiName);
        return t.getDescribe();
    }

    /** Returns all createable, non-auto-number, non-Id fields on an object. */
    public List<Schema.DescribeFieldResult> getCreateableFields(String objectApiName) {
        List<Schema.DescribeFieldResult> result = new List<Schema.DescribeFieldResult>();
        for (Schema.SObjectField f : getFieldMap(objectApiName).values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (dfr.isCreateable()
                && !dfr.isAutoNumber()
                && dfr.getType() != Schema.DisplayType.ID) {
                result.add(dfr);
            }
        }
        return result;
    }

    // ── CMT Timestamp Update (async Metadata API) ────────────────────────────
    /**
     * Enqueues an async metadata deployment to update Last_Run_Timestamp__c.
     * Custom Metadata cannot be updated synchronously in Apex, so this uses
     * Metadata.Operations.enqueueDeployment. The callback logs any deploy errors.
     */
    public void scheduleTimestampUpdate(DateTime newTimestamp) {
        try {
            Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
            cmd.fullName = AuditTrailConstants.CMT_FULL_NAME;
            cmd.label    = AuditTrailConstants.CONFIG_RECORD_NAME;

            Metadata.CustomMetadataValue mdv = new Metadata.CustomMetadataValue();
            mdv.field = AuditTrailConstants.CFG_LAST_RUN;
            mdv.value = newTimestamp;
            cmd.values.add(mdv);

            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(cmd);

            Metadata.Operations.enqueueDeployment(container, new AuditTrailMdtDeployCallback());
        } catch (Exception e) {
            AuditTrailErrorService.logError('AuditTrailMetadataService.scheduleTimestampUpdate', e, null);
        }
    }

    // ── Cache Reset (test utility) ────────────────────────────────────────────
    @TestVisible
    public static void resetCaches() {
        cachedConfig        = null;
        cachedSeverityRules = null;
        cachedDwSchema      = null;
        globalDescribeCache = null;
        fieldMapCache       = new Map<String, Map<String, Schema.SObjectField>>();
    }

    // ── Private Helpers ───────────────────────────────────────────────────────
    private Map<String, Schema.SObjectType> getGlobalDescribe() {
        if (globalDescribeCache == null) globalDescribeCache = Schema.getGlobalDescribe();
        return globalDescribeCache;
    }

    private DateTime safeDateTime(SObject rec, String fieldName,
                                  Map<String, Schema.SObjectField> fieldMap) {
        return fieldMap.containsKey(fieldName.toLowerCase())
            ? (DateTime) rec.get(fieldName) : null;
    }

    private String safeString(SObject rec, String fieldName,
                               Map<String, Schema.SObjectField> fieldMap) {
        return fieldMap.containsKey(fieldName.toLowerCase())
            ? (String) rec.get(fieldName) : null;
    }
}