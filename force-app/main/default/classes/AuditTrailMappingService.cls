/**
 * AuditTrailMappingService
 *
 * Transforms SetupAuditTrail SObjects (plus derived severity and compliance
 * data) into Audit_Trail__c SObjects ready for insertion.
 *
 * Approach — fully schema-agnostic:
 *   1. At construction time, use Schema Describe to discover all createable
 *      fields on the target object (Audit_Trail__c).
 *   2. Build a FieldIntent map that associates a semantic "intent" string
 *      (e.g. "action", "createddate", "severity") with the resolved field API
 *      name on the target object using type + naming-convention matching.
 *   3. At record transformation time, set values dynamically by intent key.
 *
 * Security: Security.stripInaccessible is applied before returning records.
 */
public with sharing class AuditTrailMappingService {

    // ── Semantic intent constants (not target field names) ────────────────────
    private static final String INTENT_ACTION      = 'action';
    private static final String INTENT_CHANGED_BY  = 'changedby';
    private static final String INTENT_DETAILS     = 'details';
    private static final String INTENT_CREATED_DT  = 'createddate';
    private static final String INTENT_SECTION     = 'section';
    private static final String INTENT_SEVERITY    = 'severity';
    private static final String INTENT_COMPLIANT   = 'compliant';
    private static final String INTENT_WINDOW      = 'window';
    private static final String INTENT_EXTERNAL_ID = 'externalid';
    private static final String INTENT_RAW         = 'raw';

    // ── Cached intent → target field name map ─────────────────────────────────
    @TestVisible private static Map<String, String> intentToField;

    private final AuditTrailMetadataService metaSvc;

    public AuditTrailMappingService(AuditTrailMetadataService metaSvc) {
        this.metaSvc = metaSvc;
    }

    // ── Map a batch of SAT records to target SObjects ─────────────────────────
    /**
     * @param satRecords      — raw SetupAuditTrail SObjects
     * @param severityMap     — Map<SAT Id, resolved severity string>
     * @param complianceMap   — Map<SAT Id, ComplianceResult>
     * @param existingExtIds  — Set of External_Id values already in the target
     *                          (for deduplication)
     * @return list of Audit_Trail__c SObjects (FLS-stripped, ready for insert)
     */
    public List<SObject> mapRecords(
            List<SObject>                                         satRecords,
            Map<Id, String>                                       severityMap,
            Map<Id, AuditTrailComplianceService.ComplianceResult> complianceMap,
            Set<String>                                           existingExtIds) {

        ensureIntentMap();

        List<SObject> targets = new List<SObject>();
        Schema.SObjectType targetType =
            Schema.getGlobalDescribe().get(AuditTrailConstants.DEFAULT_TARGET_OBJECT.toLowerCase());
        if (targetType == null) return targets;

        for (SObject satRec : satRecords) {
            try {
                String satId = String.valueOf(satRec.get(AuditTrailConstants.SAT_ID));
                if (existingExtIds != null && existingExtIds.contains(satId)) continue;

                SObject target = targetType.newSObject();

                setIntent(target, INTENT_EXTERNAL_ID, satId);
                setIntent(target, INTENT_ACTION,     satRec.get(AuditTrailConstants.SAT_ACTION));
                setIntent(target, INTENT_SECTION,    satRec.get(AuditTrailConstants.SAT_SECTION));
                setIntent(target, INTENT_DETAILS,    satRec.get(AuditTrailConstants.SAT_DISPLAY));
                setIntent(target, INTENT_CREATED_DT, satRec.get(AuditTrailConstants.SAT_CREATED_DATE));

                // Changed by — Lookup to User; set the Id directly
                Object createdById = satRec.get(AuditTrailConstants.SAT_CREATED_BY_ID);
                setIntent(target, INTENT_CHANGED_BY, createdById);

                // Derived severity
                Id    satRecId  = (Id) satRec.get(AuditTrailConstants.SAT_ID);
                String severity = (severityMap != null && severityMap.containsKey(satRecId))
                    ? severityMap.get(satRecId) : AuditTrailConstants.SEVERITY_DEFAULT;
                setIntent(target, INTENT_SEVERITY, severity);

                // Compliance
                AuditTrailComplianceService.ComplianceResult cr =
                    (complianceMap != null && complianceMap.containsKey(satRecId))
                    ? complianceMap.get(satRecId) : null;

                Boolean nonCompliant = (cr == null || cr.label == AuditTrailConstants.NON_COMPLIANT);
                setIntent(target, INTENT_COMPLIANT, nonCompliant);

                if (cr != null && cr.windowId != null) {
                    setIntent(target, INTENT_WINDOW, cr.windowId);
                }

                // Raw JSON snapshot
                setIntent(target, INTENT_RAW, buildRawJson(satRec));

                targets.add(target);
            } catch (Exception e) {
                AuditTrailErrorService.logError(
                    'AuditTrailMappingService.mapRecords',
                    e,
                    String.valueOf(satRec.get(AuditTrailConstants.SAT_ID))
                );
            }
        }

        // Strip fields the running user cannot create
        if (!targets.isEmpty()) {
            SObjectAccessDecision decision =
                Security.stripInaccessible(AccessType.CREATABLE, targets);
            return decision.getRecords();
        }
        return targets;
    }

    // ── Severity Derivation (stateless, called by AuditTrailService) ─────────
    /**
     * Resolves severity for one SAT record by testing active Audit_Trail_Severity__mdt
     * rules in Sort_Order__c priority order.
     *
     * Matching logic:
     *   1. If Regex_Pattern__c is set → Pattern.matches(regex, action)
     *   2. If Section__c is also set → both action AND section must match
     *   3. If Regex_Pattern__c is empty → exact match between DeveloperName and action
     *   4. First matching active rule wins.
     */
    public String resolveSeverity(SObject satRec, List<AuditTrailMetadataService.SeverityRule> rules) {
        if (rules == null || rules.isEmpty()) return AuditTrailConstants.SEVERITY_DEFAULT;

        String action  = (String) satRec.get(AuditTrailConstants.SAT_ACTION);
        String section = (String) satRec.get(AuditTrailConstants.SAT_SECTION);
        if (String.isBlank(action)) return AuditTrailConstants.SEVERITY_DEFAULT;

        for (AuditTrailMetadataService.SeverityRule rule : rules) {
            if (!ruleMatches(rule, action, section)) continue;
            return String.isNotBlank(rule.severityValue)
                ? rule.severityValue : AuditTrailConstants.SEVERITY_DEFAULT;
        }
        return AuditTrailConstants.SEVERITY_DEFAULT;
    }

    // ── Private Helpers ───────────────────────────────────────────────────────

    private Boolean ruleMatches(
            AuditTrailMetadataService.SeverityRule rule,
            String action, String section) {

        Boolean actionMatches;
        if (String.isNotBlank(rule.regexPattern)) {
            try {
                actionMatches = Pattern.matches(rule.regexPattern, action);
            } catch (Exception e) {
                // Malformed regex — treat as no match rather than crashing batch
                return false;
            }
        } else {
            // Fallback: exact DeveloperName == action (legacy/simple configs)
            actionMatches = (rule.developerName != null
                && rule.developerName.equalsIgnoreCase(action));
        }

        if (!actionMatches) return false;

        // Section filter is optional — if specified, section must also match
        if (String.isNotBlank(rule.section) && String.isNotBlank(section)) {
            return section.equalsIgnoreCase(rule.section);
        }
        return true;
    }

    private void setIntent(SObject target, String intent, Object value) {
        if (value == null) return;
        String fieldName = intentToField.get(intent);
        if (String.isBlank(fieldName)) return;
        try {
            target.put(fieldName, value);
        } catch (Exception e) {
            // Type mismatch on a discovered field — skip silently
        }
    }

    private String buildRawJson(SObject satRec) {
        Map<String, Object> raw = new Map<String, Object>{
            'Id'          => satRec.get(AuditTrailConstants.SAT_ID),
            'CreatedDate' => satRec.get(AuditTrailConstants.SAT_CREATED_DATE),
            'CreatedById' => satRec.get(AuditTrailConstants.SAT_CREATED_BY_ID),
            'Action'      => satRec.get(AuditTrailConstants.SAT_ACTION),
            'Section'     => satRec.get(AuditTrailConstants.SAT_SECTION),
            'Display'     => satRec.get(AuditTrailConstants.SAT_DISPLAY),
            'DelegateUser'=> satRec.get(AuditTrailConstants.SAT_DELEGATE_USER)
        };
        return JSON.serialize(raw);
    }

    // ── Intent Map Builder ────────────────────────────────────────────────────
    /**
     * Builds the intent → target field name map once per transaction.
     * Uses Schema Describe to inspect each createable field on the target object
     * and applies naming-convention + type heuristics to assign an intent.
     *
     * Heuristic priority (first match wins per intent):
     *   - externalid : isExternalId() == true
     *   - action     : Text field, name contains 'action'
     *   - changedby  : Lookup to User, name contains 'user' or 'changed' or 'by'
     *   - details    : Text field, name contains 'detail' or 'display'
     *   - createddate: DateTime field, name contains 'date' or 'created' or 'log'
     *   - section    : Text field, name contains 'section'
     *   - severity   : Picklist/Text field, name contains 'severity'
     *   - compliant  : Boolean field, name contains 'compliant'
     *   - window     : Lookup to Deployment_Window__c
     *   - raw        : LongTextArea field, name contains 'raw'
     */
    @TestVisible
    private void ensureIntentMap() {
        if (intentToField != null) return;
        intentToField = new Map<String, String>();

        String targetObj = AuditTrailConstants.DEFAULT_TARGET_OBJECT;
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        if (!gd.containsKey(targetObj.toLowerCase())) return;

        Map<String, Schema.SObjectField> fieldMap =
            gd.get(targetObj.toLowerCase()).getDescribe().fields.getMap();

        for (String fieldApiName : fieldMap.keySet()) {
            Schema.DescribeFieldResult dfr = fieldMap.get(fieldApiName).getDescribe();
            if (!dfr.isCreateable() || dfr.isAutoNumber()) continue;

            String lower = fieldApiName.toLowerCase();
            Schema.DisplayType dtype = dfr.getType();

            // External ID  ─────────────────────────────────────────────────────
            if (!intentToField.containsKey(INTENT_EXTERNAL_ID) && dfr.isExternalId()) {
                intentToField.put(INTENT_EXTERNAL_ID, fieldApiName);
                continue;
            }

            // Action ───────────────────────────────────────────────────────────
            if (!intentToField.containsKey(INTENT_ACTION)
                    && dtype == Schema.DisplayType.String
                    && lower.contains('action')) {
                intentToField.put(INTENT_ACTION, fieldApiName);
                continue;
            }

            // Changed By (User Lookup) ─────────────────────────────────────────
            if (!intentToField.containsKey(INTENT_CHANGED_BY)
                    && dtype == Schema.DisplayType.Reference) {
                List<Schema.SObjectType> userRefs = dfr.getReferenceTo();
                Boolean isUserLookup = false;
                for (Schema.SObjectType userRef : userRefs) {
                    if (userRef.getDescribe().getName() == 'User') { isUserLookup = true; break; }
                }
                if (isUserLookup && (lower.contains('changed') || lower.contains('user') || lower.contains('by'))) {
                    intentToField.put(INTENT_CHANGED_BY, fieldApiName);
                    continue;
                }
            }

            // Details ──────────────────────────────────────────────────────────
            if (!intentToField.containsKey(INTENT_DETAILS)
                    && dtype == Schema.DisplayType.String
                    && (lower.contains('detail') || lower.contains('display'))) {
                intentToField.put(INTENT_DETAILS, fieldApiName);
                continue;
            }

            // Created / Log Date ───────────────────────────────────────────────
            if (!intentToField.containsKey(INTENT_CREATED_DT)
                    && dtype == Schema.DisplayType.DateTime
                    && (lower.contains('date') || lower.contains('created') || lower.contains('log'))) {
                intentToField.put(INTENT_CREATED_DT, fieldApiName);
                continue;
            }

            // Section ──────────────────────────────────────────────────────────
            if (!intentToField.containsKey(INTENT_SECTION)
                    && dtype == Schema.DisplayType.String
                    && lower.contains('section')) {
                intentToField.put(INTENT_SECTION, fieldApiName);
                continue;
            }

            // Severity ─────────────────────────────────────────────────────────
            if (!intentToField.containsKey(INTENT_SEVERITY)
                    && (dtype == Schema.DisplayType.Picklist || dtype == Schema.DisplayType.String)
                    && lower.contains('severity')) {
                intentToField.put(INTENT_SEVERITY, fieldApiName);
                continue;
            }

            // Non-Compliant flag ───────────────────────────────────────────────
            if (!intentToField.containsKey(INTENT_COMPLIANT)
                    && dtype == Schema.DisplayType.Boolean
                    && lower.contains('compliant')) {
                intentToField.put(INTENT_COMPLIANT, fieldApiName);
                continue;
            }

            // Deployment Window Lookup ─────────────────────────────────────────
            if (!intentToField.containsKey(INTENT_WINDOW)
                    && dtype == Schema.DisplayType.Reference) {
                List<Schema.SObjectType> windowRefs = dfr.getReferenceTo();
                for (Schema.SObjectType windowRef : windowRefs) {
                    if (windowRef.getDescribe().getName() == AuditTrailConstants.DW_OBJECT) {
                        intentToField.put(INTENT_WINDOW, fieldApiName);
                        break;
                    }
                }
                continue;
            }

            // Raw JSON (LongTextArea) ──────────────────────────────────────────
            if (!intentToField.containsKey(INTENT_RAW)
                    && dtype == Schema.DisplayType.TextArea
                    && lower.contains('raw')) {
                intentToField.put(INTENT_RAW, fieldApiName);
            }
        }
    }

    /** Clears the cached intent map (used in tests). */
    @TestVisible
    public static void resetIntentMap() {
        intentToField = null;
    }
}